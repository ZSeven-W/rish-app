//! The tool batch service's decisions, ported from
//! `AgentToolBatchService.mm`: request shapes, the preparation gate, the
//! per-call analysis of a completed round's raw tool calls, the executor
//! outcome mapping, the final authority check, the ledger-failure rejection,
//! and the approval binding checks. The host keeps the WAL operation
//! relation, the session load, the root proofs, the executors' preparation
//! probes and the denied-approval transaction, and calls back with what it
//! observed.

use crate::canonical::{canonical_json, hash_json};
use crate::execution_ledger::{
    as_str, get, relative_path_argument, write_prior, MAX_SINGLE_WRITE_BYTES,
};
use crate::schema::{
    bounded_utf8, canonical_sha256, canonical_uuid, exact_keys, safe_integer,
    tool_name_well_formed, transcript_reference, MAX_TRANSCRIPT_BYTES,
};
use crate::store::StoreError;
use crate::strict_json::parse_arguments;
use serde_json::{json, Map, Value};

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
const MAX_ATTEMPT_WRITE_BYTES: u64 = 4 * 1024 * 1024;

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

fn equal(left: Option<&Value>, right: Option<&Value>) -> bool {
    matches!((left, right), (Some(l), Some(r)) if l == r)
}

fn is_null(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Null))
}

fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|v| !v.is_null())
}

fn array(value: Option<&Value>) -> &[Value] {
    match value {
        Some(Value::Array(items)) => items,
        _ => &[],
    }
}

fn is_mutation(name: &str) -> bool {
    matches!(name, "write_file" | "git_commit" | "git_push")
        || crate::runtime_tools::is_guest(name)
        || crate::assistant_tools::is_mutation(name)
}

fn is_workspace_tool(name: &str) -> bool {
    matches!(name, "list_dir" | "read_file" | "write_file")
}

// MARK: - request shapes

/// `DSHAgentBatchControllerCAS`.
pub fn controller_cas(value: Option<&Value>) -> bool {
    let Some(cas) = exact_keys(
        value,
        &[
            "schema_version",
            "conversation_id",
            "task_id",
            "attempt_id",
            "expected_controller_generation",
            "expected_journal_revision",
            "expected_session_generation",
            "expected_session_sha256",
        ],
    ) else {
        return false;
    };
    cas.get("schema_version") == Some(&json!(1))
        && canonical_uuid(cas.get("conversation_id"))
        && canonical_uuid(cas.get("task_id"))
        && canonical_uuid(cas.get("attempt_id"))
        && safe_integer(
            cas.get("expected_controller_generation"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_some()
        && safe_integer(cas.get("expected_journal_revision"), MAX_SAFE_INTEGER, true).is_some()
        && safe_integer(
            cas.get("expected_session_generation"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_some()
        && canonical_sha256(cas.get("expected_session_sha256"))
}

/// `DSHAgentBatchCheckpoint`.
pub fn checkpoint(value: Option<&Value>) -> bool {
    let Some(checkpoint) = exact_keys(
        value,
        &[
            "schema_version",
            "journal_revision",
            "session_generation",
            "session_sha256",
        ],
    ) else {
        return false;
    };
    checkpoint.get("schema_version") == Some(&json!(1))
        && safe_integer(checkpoint.get("journal_revision"), MAX_SAFE_INTEGER, true).is_some()
        && safe_integer(checkpoint.get("session_generation"), MAX_SAFE_INTEGER, true).is_some()
        && canonical_sha256(checkpoint.get("session_sha256"))
}

/// `DSHAgentBatchRoot`.
pub fn batch_root(value: Option<&Value>) -> bool {
    let Some(root) = exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "workspace_id",
            "workspace_binding_revision",
            "project_id",
            "root_fingerprint_sha256",
            "capabilities",
        ],
    ) else {
        return false;
    };
    if root.get("schema_version") != Some(&json!(1))
        || !canonical_uuid(root.get("workspace_id"))
        || safe_integer(
            root.get("workspace_binding_revision"),
            MAX_SAFE_INTEGER,
            false,
        )
        .is_none()
        || !canonical_sha256(root.get("root_fingerprint_sha256"))
        || !root.get("capabilities").is_some_and(Value::is_array)
    {
        return false;
    }
    match as_str(root.get("kind")) {
        Some("workspace") => is_null(root.get("project_id")),
        Some("project") => canonical_uuid(root.get("project_id")),
        _ => false,
    }
}

/// `DSHAgentBatchTranscript`.
pub fn batch_transcript(value: Option<&Value>) -> bool {
    transcript_reference(value)
        && value
            .and_then(|v| get(v, "transcript_bytes"))
            .and_then(Value::as_u64)
            .is_some_and(|b| b <= MAX_TRANSCRIPT_BYTES)
}

/// `DSHAgentBatchTranscriptCanAdvance`.
pub fn transcript_can_advance(authority: Option<&Value>, request: Option<&Value>) -> bool {
    if !batch_transcript(authority) || !batch_transcript(request) {
        return false;
    }
    let (Some(authority), Some(request)) = (authority, request) else {
        return false;
    };
    if !equal(
        get(authority, "transcript_ref"),
        get(request, "transcript_ref"),
    ) {
        return false;
    }
    let authority_generation = get(authority, "generation")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let request_generation = get(request, "generation")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if request_generation < authority_generation {
        return false;
    }
    if request_generation > authority_generation {
        return true;
    }
    equal(
        get(authority, "transcript_sha256"),
        get(request, "transcript_sha256"),
    ) && equal(
        get(authority, "transcript_bytes"),
        get(request, "transcript_bytes"),
    )
}

/// `validatePrepareRequest:` — `Err(InvalidArgument)` for a malformed shape,
/// `Err(Conflict)` when the CAS and checkpoint disagree.
pub fn prepare_request(request: &Value) -> Result<(), StoreError> {
    let keys = [
        "schema_version",
        "operation_id",
        "controller_cas",
        "committed_checkpoint",
        "task_id",
        "conversation_id",
        "attempt_id",
        "round_id",
        "round_index",
        "expected_round_revision",
        "transcript",
        "root",
        "registry_version",
        "toolset_sha256",
        "policy_version",
        "expected_batch_revision",
        "expected_reserved_write_bytes",
    ];
    let r = |key: &str| get(request, key);
    if exact_keys(Some(request), &keys).is_none()
        || r("schema_version") != Some(&json!(2))
        || !canonical_uuid(r("operation_id"))
        || !controller_cas(r("controller_cas"))
        || !checkpoint(r("committed_checkpoint"))
        || !canonical_uuid(r("task_id"))
        || !canonical_uuid(r("conversation_id"))
        || !canonical_uuid(r("attempt_id"))
        || !canonical_uuid(r("round_id"))
        || safe_integer(r("round_index"), 7, true).is_none()
        || safe_integer(r("expected_round_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !batch_transcript(r("transcript"))
        || !batch_root(r("root"))
        || !crate::runtime_tools::registry_version(r("registry_version"))
        || !canonical_sha256(r("toolset_sha256"))
        || !string_eq(r("policy_version"), "agent-v1")
        || safe_integer(r("expected_batch_revision"), MAX_SAFE_INTEGER, true).is_none()
        || safe_integer(
            r("expected_reserved_write_bytes"),
            MAX_ATTEMPT_WRITE_BYTES,
            true,
        )
        .is_none()
    {
        return Err(StoreError::InvalidArgument);
    }
    let cas = r("controller_cas").expect("checked");
    let checkpoint = r("committed_checkpoint").expect("checked");
    if !equal(get(cas, "task_id"), r("task_id"))
        || !equal(get(cas, "attempt_id"), r("attempt_id"))
        || !equal(get(cas, "conversation_id"), r("conversation_id"))
        || !equal(
            get(cas, "expected_journal_revision"),
            get(checkpoint, "journal_revision"),
        )
        || !equal(
            get(cas, "expected_session_generation"),
            get(checkpoint, "session_generation"),
        )
        || !equal(
            get(cas, "expected_session_sha256"),
            get(checkpoint, "session_sha256"),
        )
    {
        return Err(StoreError::Conflict);
    }
    Ok(())
}

// MARK: - results

/// The `prepare_agent_tool_batch` rejection result the host commits.
pub fn rejected_result(
    request: &Value,
    failure_code: &str,
    mutation_batch: bool,
    retry_advice: &str,
) -> Value {
    json!({
        "schema_version": 2, "status": "rejected",
        "operation_id": get(request, "operation_id"), "failure_code": failure_code,
        "expected_batch_revision": get(request, "expected_batch_revision"),
        "expected_reserved_write_bytes": get(request, "expected_reserved_write_bytes"),
        "result_reserved_write_bytes": get(request, "expected_reserved_write_bytes"),
        "effect_gate": if mutation_batch { "closed" } else { "not_applicable" },
        "reservation_status": "unchanged", "effect_dispatched": false,
        "retry_advice": retry_advice,
    })
}

fn reject(request: &Value, failure_code: &str, mutation_batch: bool, retry_advice: &str) -> Value {
    json!({ "reject": rejected_result(request, failure_code, mutation_batch, retry_advice) })
}

/// The `bind_agent_approval` conflict result the host commits.
pub fn approval_conflict(
    request: &Value,
    actual_batch_revision: Option<&Value>,
    actual_decision: Option<&str>,
) -> Value {
    json!({
        "schema_version": 2, "status": "conflict",
        "operation_id": get(request, "operation_id"),
        "failure_code": "E_AGENT_APPROVAL",
        "expected_batch_revision": get(request, "batch_revision"),
        "actual_batch_revision": actual_batch_revision.cloned().unwrap_or(json!(0)),
        "actual_decision": actual_decision.unwrap_or("pending"),
        "observed_checkpoint": get(request, "committed_checkpoint"),
    })
}

// MARK: - preparation

fn authority_matches_prepare(request: &Value, authority: &Value) -> bool {
    string_eq(get(authority, "state"), "prepared")
        && equal(get(authority, "root"), get(request, "root"))
        && equal(
            get(authority, "policy").and_then(|p| get(p, "policy_version")),
            get(request, "policy_version"),
        )
        && equal(
            get(authority, "registry").and_then(|r| get(r, "toolset_sha256")),
            get(request, "toolset_sha256"),
        )
        && equal(
            get(authority, "reserved_write_bytes"),
            get(request, "expected_reserved_write_bytes"),
        )
}

fn round_matches_prepare(request: &Value, round: &Value) -> bool {
    string_eq(get(round, "state"), "completed")
        && equal(
            get(round, "row_revision"),
            get(request, "expected_round_revision"),
        )
        && equal(get(round, "transcript_after"), get(request, "transcript"))
        && string_eq(get(round, "terminal_kind"), "tool_batch")
}

/// The checks between the started operation and the transcript read:
/// committed session and prepared root (`session_ok`, `root_ok`), the
/// authority and completed round relations, and the round limit.
pub fn prepare_gate(
    request: &Value,
    authority: Option<&Value>,
    round: Option<&Value>,
    session_ok: bool,
    root_ok: bool,
) -> Value {
    if !session_ok || !root_ok {
        return reject(request, "E_AGENT_ROOT_STALE", false, "requery");
    }
    match (authority, round) {
        (Some(authority), Some(round))
            if authority_matches_prepare(request, authority)
                && round_matches_prepare(request, round) => {}
        (None, _) => return reject(request, "E_AGENT_ROOT_STALE", false, "requery"),
        _ => return reject(request, "E_AGENT_CONFLICT", false, "requery"),
    }
    if get(request, "round_index")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        >= 7
    {
        return reject(request, "E_AGENT_ROUND_LIMIT", false, "none");
    }
    json!({ "proceed": true })
}

/// `DSHAgentBatchRawAssistant`: the last assistant message of the round
/// that carries tool calls.
fn raw_assistant<'a>(messages: &'a [Value], round_index: Option<&Value>) -> Option<&'a Value> {
    messages.iter().rfind(|message| {
        string_eq(get(message, "role"), "assistant")
            && equal(get(message, "round_index"), round_index)
            && matches!(get(message, "tool_calls"), Some(Value::Array(calls)) if !calls.is_empty())
    })
}

/// `DSHAgentBatchArgumentsContainBadPath`.
fn arguments_contain_bad_path(name: &str, arguments_json: Option<&Value>) -> bool {
    if !is_workspace_tool(name) {
        return false;
    }
    let arguments: Option<Map<String, Value>> = as_str(arguments_json)
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
        .and_then(|value| match value {
            Value::Object(map) => Some(map),
            _ => None,
        });
    let allow_root = name == "list_dir";
    let path = arguments.as_ref().and_then(|a| a.get("path"));
    if path.is_none() && allow_root && arguments.as_ref().is_some_and(|a| a.is_empty()) {
        return false;
    }
    let Some(Value::String(path)) = path else {
        return true;
    };
    if (path.is_empty() && !allow_root)
        || path.starts_with('/')
        || path.contains('\\')
        || relative_path_argument(Some(&Value::String(path.clone())), true).is_none()
            && path.chars().any(|c| c.is_control())
    {
        return true;
    }
    use unicode_normalization::UnicodeNormalization;
    if path.nfc().ne(path.chars()) || path.chars().any(|c| c.is_control()) {
        return true;
    }
    path.split('/').any(|component| {
        component.is_empty() || matches!(component, "." | ".." | ".git" | ".trash")
    })
}

/// `DSHAgentToolArgumentsAccepted`: `Ok` or `Err((failure_code, reason))`.
pub fn tool_arguments_accepted(
    name: Option<&Value>,
    arguments: &Map<String, Value>,
) -> Result<(), (&'static str, &'static str)> {
    const SCHEMA: (&str, &str) = (
        "E_AGENT_BAD_ARGUMENTS",
        "arguments_do_not_match_tool_schema",
    );
    let Some(tool_name) = tool_name_well_formed(name) else {
        return Err(SCHEMA);
    };
    if crate::assistant_tools::is_assistant(tool_name) {
        return crate::assistant_tools::arguments_valid(tool_name, arguments)
            .then_some(())
            .ok_or(SCHEMA);
    }
    if crate::runtime_tools::is_runtime(tool_name) {
        return crate::runtime_tools::arguments_valid(tool_name, arguments)
            .then_some(())
            .ok_or(SCHEMA);
    }
    let object = Value::Object(arguments.clone());
    if tool_name == crate::user_question::NAME {
        return crate::user_question::arguments_valid(&object)
            .then_some(())
            .ok_or(SCHEMA);
    }
    if is_workspace_tool(tool_name) {
        let list_directory = tool_name == "list_dir";
        let path = arguments.get("path");
        let exact_path = match tool_name {
            "write_file" => path.is_some_and(Value::is_string),
            "list_dir" => arguments.is_empty() || exact_keys(Some(&object), &["path"]).is_some(),
            _ => exact_keys(Some(&object), &["path"]).is_some(),
        };
        let empty = Value::String(String::new());
        let path = if list_directory && path.is_none() {
            Some(&empty)
        } else {
            path
        };
        let Some(Value::String(text)) = path.filter(|_| exact_path) else {
            return Err(SCHEMA);
        };
        if relative_path_argument(Some(&Value::String(text.clone())), list_directory).is_none() {
            return Err((
                "E_AGENT_BAD_PATH",
                if text.starts_with('/') {
                    "path_must_be_relative_to_workspace_root"
                } else {
                    "path_contains_disallowed_segment_or_character"
                },
            ));
        }
    }
    match tool_name {
        "write_file" => {
            let content = arguments.get("content");
            let expected_revision = arguments.get("expected_revision");
            let expected_prior = arguments.get("expected_prior");
            // The provider schema this tool is advertised with lists only
            // `path` and `content` as required, so a model that follows it and
            // omits the optional `expected_revision` was being told its call
            // did not match the schema it had just been given. Omitting the
            // field asserts the same thing passing null asserts -- that no
            // prior revision is claimed -- and the write's own precondition
            // still decides whether that is true of the disk.
            let keys_ok = exact_keys(Some(&object), &["path", "content"]).is_some()
                || exact_keys(Some(&object), &["path", "content", "expected_revision"]).is_some()
                || exact_keys(Some(&object), &["path", "content", "expected_prior"]).is_some();
            let Some(Value::String(content)) = content else {
                return Err(SCHEMA);
            };
            if !keys_ok
                || expected_revision
                    .is_some_and(|r| !r.is_null() && bounded_utf8(Some(r), 256, false).is_none())
                || expected_prior.is_some_and(|p| !write_prior(Some(p)))
            {
                return Err(SCHEMA);
            }
            // A provider's stringified JSON/JS sentinel is not an opaque file
            // revision. Refuse the new call as repairable tool feedback before
            // a filesystem precondition can turn it into an attempt conflict.
            // Do not put this check in the digest or persisted shape validators:
            // historical calls, including malformed calls, must remain readable.
            if matches!(
                expected_revision.and_then(Value::as_str),
                Some("null" | "undefined")
            ) {
                return Err((
                    "E_AGENT_BAD_ARGUMENTS",
                    "expected_revision_must_be_json_null_or_a_read_file_revision",
                ));
            }
            if content.len() as u64 > MAX_SINGLE_WRITE_BYTES {
                return Err((
                    "E_AGENT_BAD_ARGUMENTS",
                    "content_exceeds_single_write_limit",
                ));
            }
        }
        "git_commit" => {
            if exact_keys(Some(&object), &["message"]).is_none()
                || bounded_utf8(arguments.get("message"), 500, false).is_none()
            {
                return Err(SCHEMA);
            }
        }
        "git_push" => {
            if !arguments.is_empty() {
                return Err(SCHEMA);
            }
        }
        _ => {}
    }
    Ok(())
}

/// `DSHAgentBatchConversationGrant` over the conversation's grants.
fn conversation_grant<'a>(
    grants: &'a [Value],
    conversation_id: Option<&Value>,
    root: &Value,
    name: &str,
) -> Option<&'a Value> {
    let family = match name {
        "write_file" => "file_write",
        "create_assistant_task"
        | "update_assistant_task"
        | "remember_assistant_memory"
        | "forget_assistant_memory" => "assistant_metadata",
        "git_commit" => "git_commit",
        _ if crate::runtime_tools::is_mutation(name) || name.ends_with("_guest_cgi") => {
            "guest_service"
        }
        _ => return None,
    };
    grants.iter().find(|grant| {
        equal(get(grant, "conversation_id"), conversation_id)
            && equal(get(grant, "workspace_id"), get(root, "workspace_id"))
            && equal(get(grant, "project_id"), get(root, "project_id"))
            && equal(
                get(grant, "binding_revision"),
                get(root, "workspace_binding_revision"),
            )
            && equal(
                get(grant, "root_fingerprint_sha256"),
                get(root, "root_fingerprint_sha256"),
            )
            && string_eq(get(grant, "tool_family"), family)
            && crate::runtime_tools::grant_supports_tool(get(grant, "registry_version"), name)
            && string_eq(get(grant, "policy_version"), "agent-v1")
            && canonical_uuid(get(grant, "grant_id"))
    })
}

/// `DSHAgentBatchRejectionReason`.
fn rejection_reason(name: &str, failure_code: &str) -> &'static str {
    if failure_code == "E_AGENT_BAD_PATH" {
        "path_must_be_relative_to_workspace_root"
    } else if name.ends_with("_guest_cgi") {
        "paths_must_be_workspace_relative_and_keys_exact"
    } else {
        "arguments_do_not_match_tool_schema"
    }
}

/// The per-call analysis of the round's raw tool calls against the round's
/// presentation and the authority's registry. `messages` is the transcript's
/// native message list (`None` when it could not be read); `grants` the
/// committed conversation's `agent_grants`. Returns `{reject}` or
/// `{calls, mutation_batch}` where each call carries either a `rejection` or
/// the `executor` (`workspace` | `guest` | `runtime` | `git`) the host must run with the
/// parsed `arguments`, or neither for a durably denied call.
pub fn prepare_calls(
    request: &Value,
    round: &Value,
    messages: Option<&[Value]>,
    authority: &Value,
    grants: &[Value],
) -> Value {
    let round_calls = array(get(round, "calls"));
    let assistant =
        messages.and_then(|messages| raw_assistant(messages, get(request, "round_index")));
    let raw_calls = array(assistant.and_then(|a| get(a, "tool_calls")));
    if raw_calls.is_empty() || raw_calls.len() > 16 || raw_calls.len() != round_calls.len() {
        return reject(request, "E_AGENT_LEDGER", false, "wait_for_reconciliation");
    }
    let registry_tools = array(get(authority, "registry").and_then(|r| get(r, "tools")));
    let mut calls = Vec::with_capacity(raw_calls.len());
    let mut mutation_batch = false;
    for (index, raw) in raw_calls.iter().enumerate() {
        let presentation = &round_calls[index];
        let name = as_str(get(raw, "name")).unwrap_or_default();
        let arguments_sha =
            crate::schema::arguments_sha256(get(raw, "name"), get(raw, "arguments_json"));
        mutation_batch = mutation_batch || is_mutation(name);
        let matches = arguments_sha.as_ref().is_some_and(|digest| {
            equal(get(raw, "call_id"), get(presentation, "call_id"))
                && equal(get(raw, "name"), get(presentation, "name"))
                && as_str(get(presentation, "arguments_sha256")) == Some(digest.as_str())
                && get(presentation, "call_index") == Some(&json!(index))
        });
        if !matches {
            let failure = if arguments_contain_bad_path(name, get(raw, "arguments_json")) {
                "E_AGENT_BAD_PATH"
            } else {
                "E_AGENT_BAD_ARGUMENTS"
            };
            return reject(request, failure, mutation_batch, "none");
        }
        let registry_tool = registry_tools
            .iter()
            .find(|tool| equal(get(tool, "name"), get(raw, "name")));
        let mut access = registry_tool
            .and_then(|t| as_str(get(t, "access")))
            .unwrap_or("durable_deny");
        if crate::assistant_tools::is_assistant(name)
            && authority["registry"]["registry_version"] != 5
        {
            access = "durable_deny";
        }
        let grant = if access == "conversation_confirm" {
            conversation_grant(
                grants,
                get(request, "conversation_id"),
                get(request, "root").unwrap_or(&Value::Null),
                name,
            )
        } else {
            None
        };
        let mut rejection = Value::Null;
        let mut executor = Value::Null;
        let mut arguments = Value::Null;
        if access != "durable_deny" {
            match as_str(get(raw, "arguments_json")).and_then(parse_arguments) {
                None => {
                    rejection = json!({ "failure_code": "E_AGENT_BAD_ARGUMENTS", "reason": "arguments_not_a_json_object" });
                }
                Some(parsed) => match tool_arguments_accepted(get(raw, "name"), &parsed) {
                    Err((code, reason)) => {
                        rejection = json!({ "failure_code": code, "reason": reason })
                    }
                    Ok(()) => {
                        executor = Value::String(
                            if is_workspace_tool(name) {
                                "workspace"
                            } else if crate::assistant_tools::is_assistant(name) {
                                "assistant"
                            } else if crate::runtime_tools::is_runtime(name) {
                                "runtime"
                            } else if name.ends_with("_guest_cgi") {
                                "guest"
                            } else {
                                "git"
                            }
                            .to_string(),
                        );
                        arguments = Value::Object(parsed);
                        if name == crate::user_question::NAME {
                            executor = Value::Null;
                        }
                    }
                },
            }
        }
        calls.push(json!({
            "call_index": index, "call_id": get(raw, "call_id"),
            "name": name, "arguments_json": get(raw, "arguments_json"),
            "arguments_sha256": arguments_sha,
            "safe_summary_key": registry_tool.and_then(|t| get(t, "safe_summary_key")).cloned().unwrap_or(json!("agent.unknown")),
            "access": access,
            "grant_reference": grant.and_then(|g| get(g, "grant_id")).cloned().unwrap_or(Value::Null),
            "mutation": is_mutation(name),
            "rejection": rejection,
            "executor": executor,
            "arguments": arguments,
        }));
    }
    json!({ "calls": calls, "mutation_batch": mutation_batch })
}

fn approval_preview_for(name: &str, prepared: Option<&Value>) -> Value {
    if let Some(preview) = prepared
        .and_then(|p| get(p, "approval_preview"))
        .filter(|p| p.is_object())
    {
        return preview.clone();
    }
    if name == "start_guest_cgi" && prepared.is_some() {
        let condition = prepared.and_then(|p| get(p, "precondition"));
        let mut paths: Vec<Value> = Vec::new();
        for key in ["index_path", "backend_path"] {
            if let Some(path) = condition.and_then(|c| get(c, key)) {
                paths.push(path.clone());
            }
        }
        if let Some(initial) = present(condition.and_then(|c| get(c, "initial_data_path"))) {
            paths.push(initial.clone());
        }
        return json!({ "schema_version": 1, "kind": "start_guest_cgi", "paths": paths, "content_bytes": Value::Null, "prior": Value::Null, "diff_preview": Value::Null, "diff_truncated": false });
    }
    if matches!(name, "git_commit" | "git_push")
        || crate::runtime_tools::is_guest(name)
        || crate::assistant_tools::is_mutation(name)
    {
        // Git calls never carry file content; the preview names only the
        // mutation kind. Commit/push messages stay native-private.
        return json!({ "schema_version": 1, "kind": name, "paths": [], "content_bytes": Value::Null, "prior": Value::Null, "diff_preview": Value::Null, "diff_truncated": false });
    }
    Value::Null
}

/// Folds the executors' outcomes into the prepared calls. `outcomes[i]` is
/// `{"prepared": {...}}`, `{"error": <native code>}` or `null` (not run,
/// because the call needed no executor or the host stopped at an earlier
/// failure). Returns `{reject}` or `{prepared_calls, mutation_batch,
/// capabilities, needs_project_lease, needs_project_write_lease}`.
pub fn prepare_finish(request: &Value, calls: &[Value], outcomes: &[Value]) -> Value {
    let mut prepared_calls: Vec<Value> = Vec::with_capacity(calls.len());
    let mut mutation_batch = false;
    for (index, call) in calls.iter().enumerate() {
        let name = as_str(get(call, "name")).unwrap_or_default();
        mutation_batch = mutation_batch || get(call, "mutation") == Some(&Value::Bool(true));
        let outcome = outcomes.get(index).filter(|o| !o.is_null());
        let mut rejection = get(call, "rejection").cloned().unwrap_or(Value::Null);
        let question_prepared = (name == crate::user_question::NAME)
            .then(|| crate::user_question::prepared(&call["arguments"]))
            .flatten();
        let mut prepared: Option<&Value> = question_prepared.as_ref();
        if rejection.is_null() && !is_null(get(call, "executor")) && get(call, "executor").is_some()
        {
            match outcome {
                Some(outcome)
                    if (crate::runtime_tools::is_runtime(name)
                        || crate::assistant_tools::is_assistant(name))
                        && crate::runtime_tools::prepare_rejection(get(outcome, "rejection")) =>
                {
                    rejection = get(outcome, "rejection").cloned().unwrap_or(Value::Null);
                }
                Some(outcome) if get(outcome, "prepared").is_some_and(Value::is_object) => {
                    prepared = get(outcome, "prepared")
                }
                other => {
                    let code = other
                        .and_then(|o| get(o, "error"))
                        .and_then(Value::as_u64)
                        .unwrap_or(0) as u8;
                    let failure = if code == StoreError::InvalidArgument.code() {
                        if is_workspace_tool(name) {
                            "E_AGENT_BAD_PATH"
                        } else {
                            "E_AGENT_BAD_ARGUMENTS"
                        }
                    } else if code == StoreError::Conflict.code() {
                        "E_AGENT_CONFLICT"
                    } else if code == StoreError::OwnerLost.code() {
                        "E_AGENT_ROOT_STALE"
                    } else {
                        "E_AGENT_CAPABILITY"
                    };
                    if code == StoreError::InvalidArgument.code() {
                        rejection = json!({ "failure_code": failure, "reason": rejection_reason(name, failure) });
                    } else {
                        let advice = if matches!(failure, "E_AGENT_CONFLICT" | "E_AGENT_ROOT_STALE")
                        {
                            "requery"
                        } else {
                            "none"
                        };
                        return reject(request, failure, mutation_batch, advice);
                    }
                }
            }
        }
        let approval_preview = if rejection.is_null() {
            if crate::assistant_tools::is_mutation(name) {
                crate::assistant_tools::approval_preview(name, &call["arguments"])
            } else {
                approval_preview_for(name, prepared)
            }
        } else {
            Value::Null
        };
        prepared_calls.push(json!({
            "call_index": get(call, "call_index"), "call_id": get(call, "call_id"),
            "name": name, "arguments_json": get(call, "arguments_json"),
            "arguments_sha256": get(call, "arguments_sha256"),
            "safe_summary_key": get(call, "safe_summary_key"),
            "access": get(call, "access"),
            "precondition": prepared.and_then(|p| get(p, "precondition")).cloned().unwrap_or(Value::Null),
            "reserved_write_bytes": prepared.and_then(|p| get(p, "reserved_write_bytes")).cloned().unwrap_or(json!(0)),
            "grant_reference": get(call, "grant_reference"),
            "approval_preview": approval_preview,
            "rejection": rejection,
        }));
    }
    // One refused call settles the whole batch without executing anything:
    // its siblings carry the same code with an explicit "not executed" reason
    // so the next round can reconsider the batch as a unit.
    let first_rejection = prepared_calls
        .iter()
        .map(|c| get(c, "rejection").cloned().unwrap_or(Value::Null))
        .find(|r| !r.is_null());
    if let Some(first) = first_rejection {
        for call in &mut prepared_calls {
            let Value::Object(map) = call else { continue };
            if map.get("rejection").is_some_and(Value::is_null)
                && !string_eq(map.get("access"), "durable_deny")
            {
                let failure_code = if !as_str(map.get("name")).is_some_and(|name| {
                    crate::runtime_tools::is_runtime(name)
                        || crate::assistant_tools::is_assistant(name)
                }) && matches!(
                    as_str(get(&first, "failure_code")),
                    Some("E_AGENT_CAPABILITY" | "E_AGENT_TOOL_FAILED")
                ) {
                    json!("E_AGENT_BAD_ARGUMENTS")
                } else {
                    get(&first, "failure_code").cloned().unwrap_or(Value::Null)
                };
                map.insert(
                    "rejection".into(),
                    json!({ "failure_code": failure_code, "reason": "not_executed_because_another_call_was_rejected" }),
                );
                map.insert("precondition".into(), Value::Null);
                map.insert("reserved_write_bytes".into(), json!(0));
                map.insert("approval_preview".into(), Value::Null);
            }
        }
    }
    let mut capabilities: Vec<&str> = Vec::new();
    let mut needs_project_lease = false;
    let mut needs_project_write_lease = false;
    for call in &prepared_calls {
        let name = as_str(get(call, "name")).unwrap_or_default();
        let capability = if crate::assistant_tools::is_assistant(name) {
            "file_read"
        } else if matches!(
            name,
            "list_dir"
                | "read_file"
                | "list_runtime_environments"
                | "list_assistant_tasks"
                | "search_assistant_memory"
        ) {
            "file_read"
        } else if name == "write_file" {
            "file_write"
        } else if crate::runtime_tools::is_guest(name) {
            "guest_service"
        } else if name.starts_with("git_") {
            needs_project_lease = true;
            if matches!(name, "git_commit" | "git_push") {
                needs_project_write_lease = true;
            }
            name
        } else {
            continue;
        };
        if !capabilities.contains(&capability) {
            capabilities.push(capability);
        }
    }
    json!({
        "prepared_calls": prepared_calls,
        "mutation_batch": mutation_batch,
        "capabilities": capabilities,
        "needs_project_lease": needs_project_lease,
        "needs_project_write_lease": needs_project_write_lease,
    })
}

/// The final authority check after the root proof, and the ledger's internal
/// request. Returns `{reject}` or `{internal}`.
pub fn prepare_final(
    request: &Value,
    authority: &Value,
    final_authority: Option<&Value>,
    started_authority_revision: Option<&Value>,
    request_sha256: Option<&Value>,
    prepared_calls: &[Value],
    mutation_batch: bool,
) -> Value {
    let Some(final_authority) = final_authority else {
        return reject(request, "E_AGENT_CONFLICT", mutation_batch, "requery");
    };
    if !string_eq(get(final_authority, "state"), "prepared")
        || !equal(get(final_authority, "root"), get(request, "root"))
        || !transcript_can_advance(
            get(final_authority, "transcript"),
            get(request, "transcript"),
        )
        || !equal(
            get(final_authority, "reserved_write_bytes"),
            get(request, "expected_reserved_write_bytes"),
        )
        || !equal(
            get(final_authority, "authority_revision"),
            started_authority_revision,
        )
        || !equal(get(final_authority, "policy"), get(authority, "policy"))
        || !equal(get(final_authority, "registry"), get(authority, "registry"))
    {
        return reject(request, "E_AGENT_CONFLICT", mutation_batch, "requery");
    }
    json!({ "internal": {
        "schema_version": 2, "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"), "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "round_revision": get(request, "expected_round_revision"),
        "root": get(request, "root"), "transcript": get(request, "transcript"),
        "policy": get(final_authority, "policy"),
        "expected_batch_revision": get(request, "expected_batch_revision"),
        "expected_reserved_write_bytes": get(request, "expected_reserved_write_bytes"),
        "calls": prepared_calls, "operation_id": get(request, "operation_id"),
        "operation_request_sha256": request_sha256,
        "conversation_id": get(request, "conversation_id"),
        "controller_cas": get(request, "controller_cas"),
        "observed_checkpoint": get(request, "committed_checkpoint"),
    }})
}

/// The rejection committed when the ledger refuses the prepared batch.
pub fn prepare_ledger_failure(request: &Value, native_code: u8, prepared_calls: &[Value]) -> Value {
    let failure_code = if native_code == StoreError::Capacity.code() {
        "E_AGENT_CAPACITY"
    } else if native_code == StoreError::Conflict.code() {
        "E_AGENT_CONFLICT"
    } else if native_code == StoreError::InvalidArgument.code() {
        "E_AGENT_BAD_ARGUMENTS"
    } else if native_code == StoreError::OwnerLost.code() {
        "E_AGENT_ROOT_STALE"
    } else if native_code == StoreError::Persistence.code() {
        // A store that could not write says so in a code every layer already
        // carries. Reporting it as a ledger refusal hides the one cause the
        // person holding the device can act on.
        "E_AGENT_PERSISTENCE"
    } else {
        "E_AGENT_LEDGER"
    };
    let has_mutation = prepared_calls.iter().any(|call| {
        as_str(get(call, "name")).is_some_and(is_mutation)
            && !string_eq(get(call, "access"), "durable_deny")
    });
    let retry_advice = if native_code == StoreError::Capacity.code() {
        "wait_for_reconciliation"
    } else if native_code == StoreError::Conflict.code()
        || native_code == StoreError::OwnerLost.code()
    {
        "requery"
    } else if native_code == StoreError::InvalidArgument.code() {
        "none"
    } else {
        "wait_for_reconciliation"
    };
    rejected_result(request, failure_code, has_mutation, retry_advice)
}

// MARK: - approval binding

/// `DSHAgentApprovalToken`.
pub fn approval_token(value: Option<&Value>) -> bool {
    let keys = [
        "schema_version",
        "token",
        "controller_cas",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "batch_call_ids",
        "batch_arguments_sha256",
        "batch_revision",
        "manifest_sha256",
        "call_index",
        "call_id",
        "name",
        "arguments_sha256",
        "idempotency_key",
        "root_fingerprint_sha256",
        "binding_revision",
        "policy_version",
        "registry_version",
        "access",
        "allowed_decisions",
    ];
    let Some(token) = exact_keys(value, &keys) else {
        return false;
    };
    let t = |key: &str| token.get(key);
    let (Some(Value::Array(call_ids)), Some(Value::Array(digests))) =
        (t("batch_call_ids"), t("batch_arguments_sha256"))
    else {
        return false;
    };
    if t("schema_version") != Some(&json!(2))
        || !canonical_uuid(t("token"))
        || !controller_cas(t("controller_cas"))
        || !canonical_uuid(t("task_id"))
        || !canonical_uuid(t("attempt_id"))
        || !canonical_uuid(t("round_id"))
        || safe_integer(t("round_index"), 7, true).is_none()
        || call_ids.len() != digests.len()
        || safe_integer(t("batch_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !canonical_sha256(t("manifest_sha256"))
        || safe_integer(t("call_index"), 15, true).is_none()
        || bounded_utf8(t("call_id"), 128, false).is_none()
        || bounded_utf8(t("name"), 64, false).is_none()
        || !canonical_sha256(t("arguments_sha256"))
        || !canonical_sha256(t("idempotency_key"))
        || !canonical_sha256(t("root_fingerprint_sha256"))
        || safe_integer(t("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !string_eq(t("policy_version"), "agent-v1")
        || !crate::runtime_tools::registry_version(t("registry_version"))
        || !matches!(
            as_str(t("access")),
            Some("conversation_confirm" | "confirm_once")
        )
        || !t("allowed_decisions").is_some_and(Value::is_array)
    {
        return false;
    }
    let call_index = t("call_index").and_then(Value::as_u64).unwrap_or(0) as usize;
    if call_ids.is_empty()
        || call_ids.len() > 16
        || call_index >= call_ids.len()
        || !equal(call_ids.get(call_index), t("call_id"))
        || !equal(digests.get(call_index), t("arguments_sha256"))
        || !equal(
            t("controller_cas").and_then(|c| get(c, "task_id")),
            t("task_id"),
        )
        || !equal(
            t("controller_cas").and_then(|c| get(c, "attempt_id")),
            t("attempt_id"),
        )
    {
        return false;
    }
    let mut seen: Vec<&str> = Vec::new();
    for (index, call_id) in call_ids.iter().enumerate() {
        let Some(id) = bounded_utf8(Some(call_id), 128, false) else {
            return false;
        };
        if !canonical_sha256(digests.get(index)) || seen.contains(&id) {
            return false;
        }
        seen.push(id);
    }
    let name = as_str(t("name")).unwrap_or_default();
    // git_push follows the git_commit pattern: conversation_confirm access
    // with the full decision set.
    is_mutation(name)
        && t("allowed_decisions")
            == Some(&json!([
                "denied",
                "allow_once",
                "allow_conversation",
                "cancelled"
            ]))
}

/// `bindAgentApprovalWithRequest:`'s request validation; returns whether
/// the token's relation to the request holds (committed as a conflict after
/// the operation starts when it does not).
pub fn bind_request(request: &Value) -> Result<bool, StoreError> {
    let keys = [
        "schema_version",
        "operation_id",
        "controller_cas",
        "committed_checkpoint",
        "task_id",
        "conversation_id",
        "attempt_id",
        "round_id",
        "round_index",
        "manifest_sha256",
        "batch_revision",
        "call_index",
        "call_id",
        "token",
        "decision",
        "deny_message",
    ];
    let r = |key: &str| get(request, key);
    if exact_keys(Some(request), &keys).is_none()
        || r("schema_version") != Some(&json!(2))
        || !canonical_uuid(r("operation_id"))
        || !controller_cas(r("controller_cas"))
        || !checkpoint(r("committed_checkpoint"))
        || !canonical_uuid(r("task_id"))
        || !canonical_uuid(r("conversation_id"))
        || !canonical_uuid(r("attempt_id"))
        || !canonical_uuid(r("round_id"))
        || safe_integer(r("round_index"), 7, true).is_none()
        || !canonical_sha256(r("manifest_sha256"))
        || safe_integer(r("batch_revision"), MAX_SAFE_INTEGER, false).is_none()
        || safe_integer(r("call_index"), 15, true).is_none()
        || bounded_utf8(r("call_id"), 128, false).is_none()
        || !approval_token(r("token"))
        || !r("decision").is_some_and(Value::is_string)
    {
        return Err(StoreError::InvalidArgument);
    }
    let decision = as_str(r("decision")).unwrap_or_default();
    let deny_message_valid = if decision == "denied" {
        is_null(r("deny_message")) || bounded_utf8(r("deny_message"), 2000, true).is_some()
    } else {
        is_null(r("deny_message"))
    };
    if !deny_message_valid {
        return Err(StoreError::InvalidArgument);
    }
    let token = r("token").expect("checked");
    let relation = equal(get(token, "task_id"), r("task_id"))
        && equal(get(token, "attempt_id"), r("attempt_id"))
        && equal(get(token, "round_id"), r("round_id"))
        && equal(get(token, "round_index"), r("round_index"))
        && equal(get(token, "batch_revision"), r("batch_revision"))
        && equal(get(token, "manifest_sha256"), r("manifest_sha256"))
        && equal(get(token, "call_index"), r("call_index"))
        && equal(get(token, "call_id"), r("call_id"))
        && array(get(token, "allowed_decisions"))
            .iter()
            .any(|d| Some(d) == r("decision"))
        && !(decision == "allow_conversation" && string_eq(get(token, "access"), "confirm_once"));
    Ok(relation)
}

fn conversation_id_of(conversation: &Value) -> Option<&Value> {
    get(conversation, "id").or_else(|| get(conversation, "conversation_id"))
}

/// `DSHAgentBatchPersistedApprovalCall` over the request's conversation.
fn persisted_approval_call<'a>(conversation: &'a Value, request: &Value) -> Option<&'a Value> {
    if conversation_id_of(conversation) != get(request, "conversation_id") {
        return None;
    }
    for attempt in array(get(conversation, "attempts")) {
        if get(attempt, "attempt_id") != get(request, "attempt_id") {
            continue;
        }
        if get(attempt, "journal_revision")
            != get(request, "committed_checkpoint").and_then(|c| get(c, "journal_revision"))
        {
            return None;
        }
        let agent = get(attempt, "agent").filter(|a| a.is_object())?;
        let lineage = get(agent, "round_lineage");
        if lineage.and_then(|l| get(l, "round_id")) != get(request, "round_id")
            || lineage.and_then(|l| get(l, "round_index")) != get(request, "round_index")
        {
            return None;
        }
        return array(get(agent, "batch")).iter().find(|call| {
            get(call, "call_index") == get(request, "call_index")
                && get(call, "call_id") == get(request, "call_id")
        });
    }
    None
}

/// `DSHAgentBatchApprovalEventMatches`.
fn approval_event_matches(events: &[Value], request: &Value, call: &Value) -> bool {
    let mut matches = 0;
    for event in events {
        let e = |key: &str| get(event, key);
        let reference_matches = equal(e("approval_reference"), get(call, "approval_reference"))
            || (is_null(get(call, "approval_reference"))
                && equal(e("approval_reference"), e("event_id")));
        if equal(e("attempt_id"), get(request, "attempt_id"))
            && string_eq(e("kind"), "approval")
            && equal(e("round_index"), get(request, "round_index"))
            && equal(e("call_id"), get(request, "call_id"))
            && string_eq(e("status"), "approval")
            && equal(e("arguments_sha256"), get(call, "arguments_sha256"))
            && equal(e("safe_summary_key"), get(call, "safe_summary_key"))
            && reference_matches
            && is_null(e("result_sha256"))
        {
            if !is_null(get(call, "approval_reference"))
                && !equal(e("event_id"), get(call, "approval_reference"))
            {
                return false;
            }
            matches += 1;
        }
    }
    matches == 1
}

/// `DSHAgentBatchNativeApprovalEnvelope`: the one persisted token with this id.
fn native_approval_token<'a>(
    operation_results: &'a [Value],
    token_id: Option<&Value>,
) -> Option<&'a Value> {
    let mut found: Option<&Value> = None;
    for snapshot in operation_results {
        let wrapper = get(snapshot, "result");
        if !string_eq(
            wrapper.and_then(|w| get(w, "result_kind")),
            "prepare_agent_tool_batch",
        ) {
            continue;
        }
        let calls = wrapper
            .and_then(|w| get(w, "result"))
            .and_then(|r| get(r, "receipt"))
            .and_then(|r| get(r, "calls"));
        for call in array(calls) {
            let candidate = get(call, "approval_token").filter(|c| c.is_object());
            if candidate.is_none() || candidate.and_then(|c| get(c, "token")) != token_id {
                continue;
            }
            if found.is_some() {
                return None;
            }
            found = candidate;
        }
    }
    found
}

fn canonical_equal(left: &Value, right: &Value) -> bool {
    matches!((canonical_json(left), canonical_json(right)), (Ok(l), Ok(r)) if l == r)
}

/// Everything `bindAgentApprovalWithRequest:` decides between the started
/// operation and the commit. `conversation` is the committed session's
/// conversation for the request (`None` when the session could not be
/// loaded or has none), `events` its `session_events`; `operation_results`,
/// `batches` and `ledger` come from the WAL snapshot; `root_ok` is the
/// prepared-root validation for the authority's root; `session_ok_after` the
/// second committed-session check. Returns `{conflict: <result>}` or
/// `{proceed: {...}}`; `Err(Conflict)` when an allow_conversation decision
/// has no grant.
#[allow(clippy::too_many_arguments)]
pub fn bind_check(
    request: &Value,
    token_relation_valid: bool,
    conversation: Option<&Value>,
    events: &[Value],
    operation_results: &[Value],
    authority: Option<&Value>,
    batches: &[Value],
    ledger: &[Value],
    root_ok: bool,
    session_ok_after: bool,
) -> Result<Value, StoreError> {
    let token = get(request, "token").expect("validated");
    let decision = as_str(get(request, "decision")).unwrap_or_default();
    let pending = |revision: Option<&Value>| json!({ "conflict": approval_conflict(request, revision, Some("pending")) });
    if !token_relation_valid {
        return Ok(pending(get(request, "batch_revision")));
    }
    let persisted_call = conversation.and_then(|c| persisted_approval_call(c, request));
    let persisted_allowed = decision.starts_with("allow_");
    let persisted_token = persisted_call.and_then(|c| get(c, "approval_token"));
    let persisted_reference = persisted_call.and_then(|c| get(c, "approval_reference"));
    let call_ok = persisted_call.is_some_and(|call| {
        equal(get(call, "approval_decision"), get(request, "decision"))
            && (!persisted_allowed || equal(persisted_token, get(token, "token")))
            && (persisted_allowed || is_null(persisted_token))
            && (!persisted_allowed || canonical_uuid(persisted_reference))
            && (persisted_allowed || is_null(persisted_reference))
            && approval_event_matches(events, request, call)
    });
    if !call_ok {
        return Ok(pending(get(request, "batch_revision")));
    }
    let persisted_call = persisted_call.expect("checked");
    match native_approval_token(operation_results, get(token, "token")) {
        Some(native) if canonical_equal(native, token) => {}
        _ => return Ok(pending(get(request, "batch_revision"))),
    }
    let Some(authority) = authority.filter(|_| root_ok) else {
        return Ok(pending(get(request, "batch_revision")));
    };
    let batch = batches.iter().rev().find(|candidate| {
        equal(get(candidate, "task_id"), get(request, "task_id"))
            && equal(get(candidate, "attempt_id"), get(request, "attempt_id"))
            && equal(get(candidate, "round_id"), get(request, "round_id"))
            && equal(get(candidate, "round_index"), get(request, "round_index"))
            && equal(
                get(candidate, "batch_revision"),
                get(request, "batch_revision"),
            )
    });
    let root = get(authority, "root");
    let Some(batch) = batch else {
        return Ok(pending(None));
    };
    if !equal(
        root.and_then(|r| get(r, "root_fingerprint_sha256")),
        get(token, "root_fingerprint_sha256"),
    ) || !equal(
        root.and_then(|r| get(r, "workspace_binding_revision")),
        get(token, "binding_revision"),
    ) {
        return Ok(pending(get(batch, "batch_revision")));
    }
    let manifest_call = array(get(batch, "manifest_calls"))
        .iter()
        .find(|candidate| {
            let locator = get(candidate, "locator");
            equal(
                locator.and_then(|l| get(l, "call_index")),
                get(request, "call_index"),
            ) && equal(
                locator.and_then(|l| get(l, "call_id")),
                get(request, "call_id"),
            ) && equal(
                locator.and_then(|l| get(l, "idempotency_key")),
                get(token, "idempotency_key"),
            )
        });
    let intent_row = manifest_call.and_then(|m| {
        ledger
            .iter()
            .find(|row| equal(get(row, "locator"), get(m, "locator")))
    });
    let precondition_sha = intent_row.and_then(|row| {
        hash_json(
            "tool-precondition",
            &json!({ "schema_version": 1, "name": get(row, "name"), "precondition": get(row, "precondition") }),
        )
    });
    let (Some(manifest_call), Some(intent_row)) = (manifest_call, intent_row) else {
        return Ok(pending(get(batch, "batch_revision")));
    };
    if !string_eq(get(intent_row, "state"), "intent")
        || !equal(get(intent_row, "name"), get(token, "name"))
        || !equal(
            get(intent_row, "arguments_sha256"),
            get(token, "arguments_sha256"),
        )
        || as_str(get(manifest_call, "precondition_sha256")) != precondition_sha.as_deref()
    {
        return Ok(pending(get(batch, "batch_revision")));
    }
    if !session_ok_after {
        return Ok(pending(get(batch, "batch_revision")));
    }
    let prior_binding = operation_results
        .iter()
        .map(|s| get(s, "result").and_then(|r| get(r, "result")))
        .find(|candidate| {
            candidate.is_some_and(|candidate| {
                matches!(
                    as_str(get(candidate, "status")),
                    Some("bound" | "already_bound")
                ) && equal(get(candidate, "task_id"), get(request, "task_id"))
                    && equal(get(candidate, "attempt_id"), get(request, "attempt_id"))
                    && equal(get(candidate, "round_id"), get(request, "round_id"))
                    && equal(get(candidate, "call_index"), get(request, "call_index"))
                    && equal(get(candidate, "call_id"), get(request, "call_id"))
            })
        });
    let prior_binding = prior_binding.flatten();
    if let Some(prior) = prior_binding {
        if !equal(get(prior, "decision"), get(request, "decision")) {
            return Ok(
                json!({ "conflict": approval_conflict(request, get(prior, "result_batch_revision"), as_str(get(prior, "decision"))) }),
            );
        }
    }
    let approval_reference = match prior_binding {
        None => {
            if persisted_allowed {
                persisted_reference.cloned()
            } else {
                None
            }
        }
        Some(prior) => present(get(prior, "approval_reference")).cloned(),
    };
    let mut grant: Option<Value> = prior_binding
        .and_then(|p| present(get(p, "grant")))
        .cloned();
    if grant.is_none() && decision == "allow_conversation" {
        let name = as_str(get(token, "name")).unwrap_or_default();
        let family = if crate::assistant_tools::is_mutation(name) {
            "assistant_metadata"
        } else if name == "git_commit" {
            "git_commit"
        } else if crate::runtime_tools::is_guest(name) {
            "guest_service"
        } else {
            "file_write"
        };
        grant = array(conversation.and_then(|c| get(c, "agent_grants")))
            .iter()
            .find(|candidate| {
                equal(
                    get(candidate, "conversation_id"),
                    get(request, "conversation_id"),
                ) && equal(
                    get(candidate, "workspace_id"),
                    root.and_then(|r| get(r, "workspace_id")),
                ) && equal(
                    get(candidate, "project_id"),
                    root.and_then(|r| get(r, "project_id")),
                ) && equal(
                    get(candidate, "binding_revision"),
                    root.and_then(|r| get(r, "workspace_binding_revision")),
                ) && equal(
                    get(candidate, "root_fingerprint_sha256"),
                    root.and_then(|r| get(r, "root_fingerprint_sha256")),
                ) && string_eq(get(candidate, "tool_family"), family)
                    && equal(
                        get(candidate, "registry_version"),
                        get(token, "registry_version"),
                    )
                    && string_eq(get(candidate, "policy_version"), "agent-v1")
            })
            .cloned();
        if grant.is_none() {
            return Err(StoreError::Conflict);
        }
    }
    let result_ref = json!({
        "schema_version": 2, "kind": "approval",
        "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
        "call_index": get(request, "call_index"), "call_id": get(request, "call_id"),
        "batch_revision": get(request, "batch_revision"),
    });
    let denied_fresh = prior_binding.is_none() && decision == "denied";
    let mut feedback_json = Value::Null;
    if denied_fresh {
        let feedback = json!({
            "schema_version": 1, "name": get(token, "name"),
            "outcome": "denied",
            "payload": { "schema_version": 1, "failure_code": "E_AGENT_DENIED_BY_USER", "user_message": get(request, "deny_message") },
        });
        let bytes = canonical_json(&feedback).map_err(|_| StoreError::InvalidArgument)?;
        feedback_json =
            Value::String(String::from_utf8(bytes).map_err(|_| StoreError::InvalidArgument)?);
    }
    let mut receipt = Value::Null;
    let mut transcript = Value::Null;
    if prior_binding.is_some()
        && decision == "denied"
        && string_eq(get(intent_row, "state"), "settled")
        && string_eq(
            get(intent_row, "receipt").and_then(|r| get(r, "outcome")),
            "denied",
        )
    {
        // An already-bound denial replays the authoritative settlement.
        receipt = get(intent_row, "receipt").cloned().unwrap_or(Value::Null);
        transcript = get(intent_row, "transcript_after")
            .cloned()
            .unwrap_or(Value::Null);
    }
    let status = if prior_binding.is_none() {
        "bound"
    } else {
        "already_bound"
    };
    let result = json!({
        "schema_version": 2,
        "status": status,
        "operation_id": get(request, "operation_id"),
        "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"), "call_index": get(request, "call_index"),
        "call_id": get(request, "call_id"), "decision": get(request, "decision"),
        "approval_reference": approval_reference.unwrap_or(Value::Null),
        "grant": grant.unwrap_or(Value::Null),
        "result_batch_revision": get(request, "batch_revision"),
        "observed_checkpoint": get(request, "committed_checkpoint"),
        "receipt": receipt, "transcript": transcript,
    });
    let _ = persisted_call;
    Ok(json!({ "proceed": {
        "intent_locator": get(intent_row, "locator"),
        "denied_fresh": denied_fresh,
        "feedback_json": feedback_json,
        "result_ref": result_ref,
        "result": result,
        "status": status,
    }}))
}

// MARK: - JSON envelope

/// `{"op", ...}` in; `{"ok":true,...}` or `{"ok":false,"error":<code>}` out.
pub fn reduce_json(input: &str) -> String {
    let value = match reduce_json_inner(input) {
        Ok(output) => {
            let mut object = output.as_object().cloned().unwrap_or_default();
            object.insert("ok".to_string(), Value::Bool(true));
            Value::Object(object)
        }
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn reduce_json_inner(input: &str) -> Result<Value, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(StoreError::Corrupt)?;
    let field = |key: &str| get(&envelope, key).ok_or(StoreError::InvalidArgument);
    let request = field("request")?;
    match op {
        "prepare_request" => {
            prepare_request(request)?;
            Ok(json!({}))
        }
        "rejected" => Ok(json!({ "rejected": rejected_result(
            request,
            as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?,
            get(&envelope, "mutation_batch") == Some(&Value::Bool(true)),
            as_str(get(&envelope, "retry_advice")).ok_or(StoreError::InvalidArgument)?,
        )})),
        "prepare_gate" => Ok(prepare_gate(
            request,
            present(get(&envelope, "authority")),
            present(get(&envelope, "round")),
            get(&envelope, "session_ok") == Some(&Value::Bool(true)),
            get(&envelope, "root_ok") == Some(&Value::Bool(true)),
        )),
        "prepare_calls" => {
            let messages = match get(&envelope, "messages") {
                Some(Value::Array(items)) => Some(items.as_slice()),
                _ => None,
            };
            Ok(prepare_calls(
                request,
                field("round")?,
                messages,
                field("authority")?,
                array(get(&envelope, "grants")),
            ))
        }
        "prepare_finish" => Ok(prepare_finish(
            request,
            array(get(&envelope, "calls")),
            array(get(&envelope, "outcomes")),
        )),
        "prepare_final" => Ok(prepare_final(
            request,
            field("authority")?,
            present(get(&envelope, "final_authority")),
            get(&envelope, "started_authority_revision"),
            get(&envelope, "request_sha256"),
            array(get(&envelope, "prepared_calls")),
            get(&envelope, "mutation_batch") == Some(&Value::Bool(true)),
        )),
        "prepare_ledger_failure" => Ok(json!({ "rejected": prepare_ledger_failure(
            request,
            get(&envelope, "native_code").and_then(Value::as_u64).unwrap_or(0) as u8,
            array(get(&envelope, "prepared_calls")),
        )})),
        "bind_request" => Ok(json!({ "token_relation_valid": bind_request(request)? })),
        "bind_check" => bind_check(
            request,
            get(&envelope, "token_relation_valid") == Some(&Value::Bool(true)),
            present(get(&envelope, "conversation")),
            array(get(&envelope, "events")),
            array(get(&envelope, "operation_results")),
            present(get(&envelope, "authority")),
            array(get(&envelope, "batches")),
            array(get(&envelope, "ledger")),
            get(&envelope, "root_ok") == Some(&Value::Bool(true)),
            get(&envelope, "session_ok_after") == Some(&Value::Bool(true)),
        ),
        _ => Err(StoreError::InvalidArgument),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_acceptance_matches_the_tool_schemas() {
        let name = json!("write_file");
        let ok: Map<String, Value> =
            json!({ "path": "a/b.txt", "content": "x", "expected_revision": Value::Null })
                .as_object()
                .unwrap()
                .clone();
        assert_eq!(tool_arguments_accepted(Some(&name), &ok), Ok(()));
        let bad_path: Map<String, Value> =
            json!({ "path": "/etc", "content": "x", "expected_revision": Value::Null })
                .as_object()
                .unwrap()
                .clone();
        assert_eq!(
            tool_arguments_accepted(Some(&name), &bad_path)
                .unwrap_err()
                .0,
            "E_AGENT_BAD_PATH"
        );
        let list = json!("list_dir");
        assert_eq!(tool_arguments_accepted(Some(&list), &Map::new()), Ok(()));
        let push = json!("git_push");
        assert_eq!(
            tool_arguments_accepted(Some(&push), &ok).unwrap_err().1,
            "arguments_do_not_match_tool_schema"
        );
    }

    #[test]
    fn ledger_failure_names_every_store_reason_it_can() {
        let request = json!({
            "operation_id": "op", "expected_batch_revision": 1,
            "expected_reserved_write_bytes": 0,
        });
        let code = |store: StoreError| {
            let result = prepare_ledger_failure(&request, store.code(), &[]);
            (
                as_str(get(&result, "failure_code")).unwrap().to_string(),
                as_str(get(&result, "retry_advice")).unwrap().to_string(),
            )
        };
        assert_eq!(code(StoreError::Capacity).0, "E_AGENT_CAPACITY");
        assert_eq!(
            code(StoreError::Conflict),
            ("E_AGENT_CONFLICT".into(), "requery".into())
        );
        assert_eq!(
            code(StoreError::InvalidArgument),
            ("E_AGENT_BAD_ARGUMENTS".into(), "none".into())
        );
        assert_eq!(
            code(StoreError::OwnerLost),
            ("E_AGENT_ROOT_STALE".into(), "requery".into())
        );
        assert_eq!(
            code(StoreError::Persistence),
            (
                "E_AGENT_PERSISTENCE".into(),
                "wait_for_reconciliation".into()
            )
        );
        // These three have no code of their own; the ledger refusal is the
        // honest answer for them, not a default the others fall through to.
        for store in [
            StoreError::Corrupt,
            StoreError::Unavailable,
            StoreError::NotFound,
        ] {
            assert_eq!(code(store).0, "E_AGENT_LEDGER", "{store:?}");
        }
    }

    #[test]
    fn transcript_advance_rules() {
        let a = json!({ "schema_version": 1, "transcript_ref": "0f0e3b1a-4c7d-4e2f-9a1b-2c3d4e5f6a7b", "generation": 3, "transcript_sha256": "a".repeat(64), "transcript_bytes": 10 });
        let mut b = a.clone();
        b["generation"] = json!(4);
        assert!(transcript_can_advance(Some(&a), Some(&b)));
        assert!(!transcript_can_advance(Some(&b), Some(&a)));
        let mut c = a.clone();
        c["transcript_bytes"] = json!(11);
        assert!(!transcript_can_advance(Some(&a), Some(&c)));
    }
}
