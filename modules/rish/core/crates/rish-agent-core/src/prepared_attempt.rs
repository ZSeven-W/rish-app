//! The prepared attempt store's decisions, ported from
//! `AgentPreparedAttemptStore.mm`: the request shape, the committed-session
//! load and attempt relation (visible history digest included), the
//! observed safe values, the conflict result, and the whole prepare
//! transaction (replay, not_agent, already_prepared, prepared) as a change
//! set over the WAL's operations, operation results, authorities and
//! transcripts. The host keeps the session load, the root resolver, the
//! tool registry, the authority guard and the WAL transaction.

use crate::canonical::{canonical_json, hash_json};
use crate::execution_ledger::{as_str, get};
use crate::schema::{
    bounded_utf8, canonical_sha256, canonical_uuid, exact_keys, exact_keys_with_optional,
    safe_integer, MAX_TRANSCRIPT_BYTES,
};
use crate::store::StoreError;
use serde_json::{json, Map, Value};

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
const MAX_AUTHORITIES: usize = 128;
const MAX_OPERATIONS: usize = 2048;
const MAX_OPERATIONS_PER_ATTEMPT: usize = 256;
const MAX_RESULT_BYTES: usize = 768 * 1024;

fn equal(left: Option<&Value>, right: Option<&Value>) -> bool {
    matches!((left, right), (Some(l), Some(r)) if l == r)
}

fn is_null(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Null))
}

fn array(value: Option<&Value>) -> &[Value] {
    match value {
        Some(Value::Array(items)) => items,
        _ => &[],
    }
}

fn or_null(value: Option<&Value>) -> Value {
    value.cloned().unwrap_or(Value::Null)
}

/// `DSHPreparedSchema`: a safe non-zero integer equal to `expected`.
fn schema(value: Option<&Value>, expected: u64) -> bool {
    safe_integer(value, expected, false) == Some(expected)
}

fn nullable_uuid(value: Option<&Value>) -> bool {
    is_null(value) || canonical_uuid(value)
}

fn nullable_digest(value: Option<&Value>) -> bool {
    is_null(value) || canonical_sha256(value)
}

/// `DSHPreparedExactReference`.
fn exact_reference(value: Option<&Value>) -> bool {
    let Some(reference) = exact_keys(
        value,
        &[
            "schema_version",
            "transcript_ref",
            "generation",
            "transcript_sha256",
            "transcript_bytes",
        ],
    ) else {
        return false;
    };
    schema(reference.get("schema_version"), 1)
        && canonical_uuid(reference.get("transcript_ref"))
        && safe_integer(reference.get("generation"), MAX_SAFE_INTEGER, true).is_some()
        && canonical_sha256(reference.get("transcript_sha256"))
        && safe_integer(
            reference.get("transcript_bytes"),
            MAX_TRANSCRIPT_BYTES,
            true,
        )
        .is_some()
}

fn controller_cas(cas: Option<&Value>, request: &Value) -> bool {
    let Some(cas) = exact_keys(
        cas,
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
    schema(cas.get("schema_version"), 1)
        && canonical_uuid(cas.get("conversation_id"))
        && canonical_uuid(cas.get("task_id"))
        && canonical_uuid(cas.get("attempt_id"))
        && equal(cas.get("conversation_id"), get(request, "conversation_id"))
        && equal(cas.get("task_id"), get(request, "task_id"))
        && equal(cas.get("attempt_id"), get(request, "attempt_id"))
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

/// Host facts the request shape needs from the harness catalogue.
#[derive(Debug, Clone, Default)]
pub struct Env {
    /// `[DSHHarnessSupportedModels() containsObject:request.model]`.
    pub model_supported: bool,
    /// `DSHHarnessIdForModel(request.model)`.
    pub harness_id: Option<String>,
}

/// `DSHPreparedRequestShape`.
pub fn request_shape(request: &Value, env: &Env) -> bool {
    let keys = [
        "schema_version",
        "operation_id",
        "controller_cas",
        "committed_checkpoint",
        "task_id",
        "conversation_id",
        "attempt_id",
        "workspace_id",
        "project_id",
        "workspace_binding_revision",
        "transport_schema_version",
        "model",
        "thinking_mode",
        "visible_message_ids",
        "visible_history_sha256",
        "visible_message_count",
        "project_context_sha256",
        "registry_version",
        "expected_policy_version",
        "expected_transcript",
    ];
    let r = |key: &str| get(request, key);
    let checkpoint = r("committed_checkpoint");
    let c = |key: &str| checkpoint.and_then(|c| get(c, key));
    let transport_2 = r("transport_schema_version") == Some(&json!(2));
    let transport_3 = r("transport_schema_version") == Some(&json!(3));
    let visible_ids = array(r("visible_message_ids"));
    if exact_keys_with_optional(Some(request), &keys, &["harness_id"]).is_none()
        || !schema(r("schema_version"), 2)
        || !canonical_uuid(r("operation_id"))
        || !canonical_uuid(r("task_id"))
        || !canonical_uuid(r("conversation_id"))
        || !canonical_uuid(r("attempt_id"))
        || !controller_cas(r("controller_cas"), request)
        || exact_keys(
            checkpoint,
            &[
                "schema_version",
                "journal_revision",
                "session_generation",
                "session_sha256",
            ],
        )
        .is_none()
        || !schema(c("schema_version"), 1)
        || safe_integer(c("journal_revision"), MAX_SAFE_INTEGER, true).is_none()
        || safe_integer(c("session_generation"), MAX_SAFE_INTEGER, true).is_none()
        || !canonical_sha256(c("session_sha256"))
        || !nullable_uuid(r("workspace_id"))
        || !nullable_uuid(r("project_id"))
        || !(is_null(r("workspace_binding_revision"))
            || safe_integer(r("workspace_binding_revision"), MAX_SAFE_INTEGER, false).is_some())
        || !(transport_2 || transport_3)
        || bounded_utf8(r("model"), 128, false).is_none()
        || bounded_utf8(r("thinking_mode"), 32, false).is_none()
        || !r("visible_message_ids").is_some_and(Value::is_array)
        || visible_ids.len() > 96
        || !canonical_sha256(r("visible_history_sha256"))
        || safe_integer(r("visible_message_count"), 96, true).is_none()
        || visible_ids.len() as u64
            != r("visible_message_count")
                .and_then(Value::as_u64)
                .unwrap_or(0)
        || !nullable_digest(r("project_context_sha256"))
        || !crate::runtime_tools::registry_version(r("registry_version"))
        || !(is_null(r("expected_policy_version"))
            || as_str(r("expected_policy_version")) == Some("agent-v1"))
        || !(is_null(r("expected_transcript")) || exact_reference(r("expected_transcript")))
    {
        return false;
    }
    if !env.model_supported
        || (r("harness_id").is_some() && as_str(r("harness_id")) != env.harness_id.as_deref())
        || !matches!(as_str(r("thinking_mode")), Some("off" | "high" | "max"))
    {
        return false;
    }
    let mut seen: Vec<&str> = Vec::new();
    for id in visible_ids {
        let Some(text) = as_str(Some(id)).filter(|_| canonical_uuid(Some(id))) else {
            return false;
        };
        if seen.contains(&text) {
            return false;
        }
        seen.push(text);
    }
    let has_workspace = !is_null(r("workspace_id"));
    let has_project = !is_null(r("project_id"));
    let has_revision = !is_null(r("workspace_binding_revision"));
    if has_workspace != has_revision || (has_project && !has_workspace) {
        return false;
    }
    let has_context = !is_null(r("project_context_sha256"));
    if transport_3 != (has_context && has_project) {
        return false;
    }
    !transport_3 || has_project
}

/// `DSHPreparedControllerCheckpointRelation`.
pub fn checkpoint_relation(request: &Value) -> bool {
    let cas = get(request, "controller_cas");
    let checkpoint = get(request, "committed_checkpoint");
    equal(
        cas.and_then(|c| get(c, "expected_journal_revision")),
        checkpoint.and_then(|c| get(c, "journal_revision")),
    ) && equal(
        cas.and_then(|c| get(c, "expected_session_generation")),
        checkpoint.and_then(|c| get(c, "session_generation")),
    ) && equal(
        cas.and_then(|c| get(c, "expected_session_sha256")),
        checkpoint.and_then(|c| get(c, "session_sha256")),
    )
}

// MARK: - session

/// `DSHPreparedParseSessionJSON` + `DSHPreparedFindConversation`: the
/// loaded session's conversation for the request. `Err(Corrupt)` when the
/// text is not a supported session object in canonical form; `Ok(None)` when the
/// conversation is absent.
pub fn session_conversation(
    session_json: &[u8],
    request: &Value,
) -> Result<Option<Value>, StoreError> {
    if session_json.is_empty() {
        return Err(StoreError::Corrupt);
    }
    let parsed: Value = serde_json::from_slice(session_json).map_err(|_| StoreError::Corrupt)?;
    if !parsed.is_object()
        || !crate::session_schema::supported_session_version(get(&parsed, "schema_version"))
    {
        return Err(StoreError::Corrupt);
    }
    let canonical = canonical_json(&parsed).map_err(|_| StoreError::Corrupt)?;
    if canonical != session_json {
        return Err(StoreError::Corrupt);
    }
    Ok(find_conversation(&parsed, get(request, "conversation_id")).cloned())
}

fn find_conversation<'a>(session: &'a Value, conversation_id: Option<&Value>) -> Option<&'a Value> {
    array(get(session, "conversations"))
        .iter()
        .find(|c| get(c, "id") == conversation_id && conversation_id.is_some())
}

fn find_attempt<'a>(conversation: &'a Value, attempt_id: Option<&Value>) -> Option<&'a Value> {
    array(get(conversation, "attempts"))
        .iter()
        .find(|a| get(a, "attempt_id") == attempt_id && attempt_id.is_some())
}

/// `DSHPreparedObservedSafeValues` over the load's snapshot and the
/// conversation (either may be absent).
pub fn observed_values(
    request: &Value,
    snapshot: Option<&Value>,
    conversation: Option<&Value>,
) -> Value {
    let checkpoint = get(request, "committed_checkpoint");
    let snapshot = snapshot.filter(|s| s.is_object());
    let session_generation = snapshot
        .and_then(|s| get(s, "generation"))
        .or_else(|| checkpoint.and_then(|c| get(c, "session_generation")));
    let session_sha256 = snapshot
        .and_then(|s| get(s, "session_sha256"))
        .or_else(|| checkpoint.and_then(|c| get(c, "session_sha256")));
    let attempt = conversation.and_then(|c| find_attempt(c, get(request, "attempt_id")));
    let journal_revision = attempt
        .and_then(|a| get(a, "journal_revision"))
        .filter(|v| v.is_number())
        .cloned()
        .unwrap_or(json!(0));
    let controller_generation = attempt
        .and_then(|a| get(a, "agent"))
        .filter(|a| a.is_object())
        .and_then(|a| get(a, "controller_generation"))
        .filter(|v| v.is_number())
        .cloned()
        .unwrap_or(json!(0));
    json!({
        "controller_generation": controller_generation,
        "journal_revision": journal_revision,
        "session_generation": session_generation.cloned().unwrap_or(json!(0)),
        "session_sha256": session_sha256.cloned().unwrap_or_else(|| or_null(checkpoint.and_then(|c| get(c, "session_sha256")))),
    })
}

/// `DSHPreparedConflictResult`.
pub fn conflict_result(request: &Value, failure_code: &str, observed: &Value) -> Value {
    let cas = get(request, "controller_cas");
    let checkpoint = get(request, "committed_checkpoint");
    let o = |key: &str| get(observed, key).filter(|v| !v.is_null()).cloned();
    json!({
        "schema_version": 2,
        "status": "conflict",
        "operation_id": get(request, "operation_id"),
        "failure_code": failure_code,
        "expected_controller_generation": cas.and_then(|c| get(c, "expected_controller_generation")),
        "expected_journal_revision": cas.and_then(|c| get(c, "expected_journal_revision")),
        "expected_session_generation": checkpoint.and_then(|c| get(c, "session_generation")),
        "expected_session_sha256": checkpoint.and_then(|c| get(c, "session_sha256")),
        "actual_controller_generation": o("controller_generation").unwrap_or(json!(0)),
        "actual_journal_revision": o("journal_revision").unwrap_or(json!(0)),
        "actual_session_generation": o("session_generation").unwrap_or(json!(0)),
        "actual_session_sha256": o("session_sha256").unwrap_or_else(|| or_null(checkpoint.and_then(|c| get(c, "session_sha256")))),
    })
}

/// `DSHPreparedVisibleHistory`: the digest input for the visible messages,
/// `None` when a message or attachment is missing.
fn visible_history(conversation: &Value, message_ids: &[Value]) -> Option<Vec<Value>> {
    let messages: Vec<&Value> = array(get(conversation, "messages")).iter().collect();
    let mut visible = Vec::with_capacity(message_ids.len());
    for message_id in message_ids {
        let id = as_str(Some(message_id))?;
        let message = messages
            .iter()
            .rev()
            .find(|m| as_str(get(m, "id")) == Some(id))
            .copied()?;
        if !message.is_object() {
            return None;
        }
        let mut attachments = Vec::new();
        for attachment in array(get(message, "attachments")) {
            if !attachment.is_object() {
                return None;
            }
            attachments.push(json!({
                "schema_version": get(attachment, "schema_version"),
                "id": get(attachment, "id"),
                "kind": get(attachment, "kind"),
                "name": get(attachment, "name"),
                "mime_type": get(attachment, "mime_type"),
                "size": get(attachment, "size"),
            }));
        }
        visible.push(json!({
            "role": get(message, "role"),
            "content": get(message, "text"),
            "attachments": attachments,
        }));
    }
    Some(visible)
}

/// `DSHPreparedSessionAttemptMatches` over the committed conversation.
pub fn session_attempt_matches(request: &Value, conversation: Option<&Value>) -> bool {
    let Some(conversation) = conversation else {
        return false;
    };
    let Some(attempt) = find_attempt(conversation, get(request, "attempt_id")) else {
        return false;
    };
    if !equal(get(attempt, "turn_id"), get(request, "task_id"))
        || !equal(get(attempt, "model_id"), get(request, "model"))
        || !equal(get(attempt, "thinking_mode"), get(request, "thinking_mode"))
    {
        return false;
    }
    let null = Value::Null;
    let stored = |key: &str| get(attempt, key).unwrap_or(&null);
    let conversation_field = |key: &str| get(conversation, key).unwrap_or(&null);
    if Some(stored("workspace_id")) != get(request, "workspace_id")
        || Some(stored("context_project_id")) != get(request, "project_id")
        || Some(stored("workspace_binding_revision")) != get(request, "workspace_binding_revision")
        || !equal(get(conversation, "id"), get(request, "conversation_id"))
        || Some(conversation_field("workspace_id")) != get(request, "workspace_id")
        || Some(conversation_field("project_id")) != get(request, "project_id")
    {
        return false;
    }
    let Some(Value::Array(stored_ids)) = get(attempt, "visible_message_ids") else {
        return false;
    };
    if Some(&Value::Array(stored_ids.clone())) != get(request, "visible_message_ids")
        || stored_ids.len() as u64
            != get(request, "visible_message_count")
                .and_then(Value::as_u64)
                .unwrap_or(u64::MAX)
    {
        return false;
    }
    let Some(visible) = visible_history(conversation, stored_ids) else {
        return false;
    };
    let Some(digest) = hash_json("visible-history", &json!({ "messages": visible })) else {
        return false;
    };
    if as_str(get(request, "visible_history_sha256")) != Some(digest.as_str())
        || (!is_null(get(attempt, "visible_history_sha256"))
            && as_str(get(attempt, "visible_history_sha256")) != Some(digest.as_str()))
    {
        return false;
    }
    let disposition = as_str(get(attempt, "context_disposition"));
    let transport_3 = get(request, "transport_schema_version") == Some(&json!(3));
    let has_project = !is_null(get(request, "project_id"));
    if transport_3 {
        let context = get(attempt, "project_context").filter(|c| c.is_object());
        let context_digest = context.and_then(|c| get(c, "snapshot_sha256"));
        disposition == Some("verified")
            && canonical_sha256(context_digest)
            && equal(context_digest, get(request, "project_context_sha256"))
            && has_project
    } else {
        !(!is_null(get(request, "project_context_sha256"))
            || (has_project && disposition != Some("explicit_without_context"))
            || (!has_project && disposition != Some("unbound")))
    }
}

// MARK: - projections

fn empty_registry(toolset_sha256: Option<&Value>) -> Value {
    json!({ "schema_version": 2, "registry_version": 2, "toolset_sha256": toolset_sha256, "tools": [] })
}

fn phase_for_authority(authority: &Value) -> &'static str {
    match as_str(get(authority, "state")) {
        Some("prepared") => "ready_for_round",
        Some("cleanup_pending") => "failed",
        _ => "final_response",
    }
}

/// `DSHPreparedProjectionForAuthority`.
pub fn projection_for_authority(
    authority: &Value,
    controller_generation: Option<&Value>,
    journal_revision: Option<&Value>,
) -> Value {
    json!({
        "schema_version": 2,
        "task_id": get(authority, "task_id"),
        "conversation_id": get(authority, "conversation_id"),
        "attempt_id": get(authority, "attempt_id"),
        "phase": phase_for_authority(authority),
        "controller_generation": controller_generation.cloned().unwrap_or(json!(0)),
        "journal_revision": journal_revision.cloned().unwrap_or(json!(0)),
        "authority_revision": get(authority, "authority_revision"),
        "root": get(authority, "root"),
        "policy": get(authority, "policy"),
        "registry": get(authority, "registry"),
        "transcript": get(authority, "transcript"),
        "round_index": 0,
        "round_id": Value::Null,
        "round_revision": Value::Null,
        "round_status": Value::Null,
        "batch_kind": Value::Null,
        "batch_revision": Value::Null,
        "manifest_sha256": Value::Null,
        "call_index": Value::Null,
        "batch": [],
        "frozen_grant_ids": [],
        "reserved_write_bytes": get(authority, "reserved_write_bytes"),
        "cancel_source_event_id": Value::Null,
        "cleanup_id": get(authority, "cleanup_id"),
    })
}

fn not_agent_projection(
    request: &Value,
    controller_generation: Option<&Value>,
    journal_revision: Option<&Value>,
    toolset_sha256: Option<&Value>,
) -> Value {
    json!({
        "schema_version": 2,
        "task_id": get(request, "task_id"),
        "conversation_id": get(request, "conversation_id"),
        "attempt_id": get(request, "attempt_id"),
        "phase": "not_agent",
        "controller_generation": controller_generation,
        "journal_revision": journal_revision,
        "authority_revision": 0,
        "root": Value::Null,
        "policy": Value::Null,
        "registry": empty_registry(toolset_sha256),
        "transcript": Value::Null,
        "round_index": 0,
        "round_id": Value::Null,
        "round_revision": Value::Null,
        "round_status": Value::Null,
        "batch_kind": Value::Null,
        "batch_revision": Value::Null,
        "manifest_sha256": Value::Null,
        "call_index": Value::Null,
        "batch": [],
        "frozen_grant_ids": [],
        "reserved_write_bytes": 0,
        "cancel_source_event_id": Value::Null,
        "cleanup_id": Value::Null,
    })
}

fn transcript_reference(row: &Value) -> Value {
    json!({
        "schema_version": 1,
        "transcript_ref": get(row, "transcript_ref"),
        "generation": get(row, "generation"),
        "transcript_sha256": get(row, "transcript_sha256"),
        "transcript_bytes": get(row, "transcript_bytes"),
    })
}

/// `DSHPreparedAuthorityMatchesRequest`.
fn authority_matches_request(
    authority: &Value,
    request: &Value,
    root: &Value,
    policy: Option<&Value>,
    registry: &Value,
) -> bool {
    if !crate::assistant_context::authority_valid(authority)
        || !equal(get(authority, "task_id"), get(request, "task_id"))
        || !equal(
            get(authority, "conversation_id"),
            get(request, "conversation_id"),
        )
        || !equal(get(authority, "attempt_id"), get(request, "attempt_id"))
        || get(authority, "root") != Some(root)
        || get(authority, "policy") != policy
        || get(authority, "registry") != Some(registry)
        || !equal(
            get(authority, "transport_schema_version"),
            get(request, "transport_schema_version"),
        )
        || !equal(get(authority, "model"), get(request, "model"))
        || !equal(
            get(authority, "thinking_mode"),
            get(request, "thinking_mode"),
        )
        || !equal(
            get(authority, "visible_message_ids"),
            get(request, "visible_message_ids"),
        )
        || !equal(
            get(authority, "visible_history_sha256"),
            get(request, "visible_history_sha256"),
        )
        || !equal(
            get(authority, "visible_message_count"),
            get(request, "visible_message_count"),
        )
        || !equal(
            get(authority, "project_context_sha256"),
            get(request, "project_context_sha256"),
        )
    {
        return false;
    }
    let expected = get(request, "expected_transcript");
    !is_null(expected) && equal(get(authority, "transcript"), expected)
}

// MARK: - transaction

/// What the host hands the prepare transaction.
pub struct Transaction<'a> {
    pub request: &'a Value,
    pub request_sha256: &'a str,
    /// The resolved frozen root, `None` for a conversation without one.
    pub root: Option<&'a Value>,
    pub policy: Option<&'a Value>,
    pub registry: &'a Value,
    /// Validated native-store profile fact, never part of the UI request.
    pub assistant_context: Option<&'a Value>,
    /// `registry.toolsetSHA256`, for the not_agent projection.
    pub toolset_sha256: Option<&'a Value>,
    pub operations: &'a [Value],
    pub operation_results: &'a [Value],
    pub authorities: &'a [Value],
    pub transcripts: &'a [Value],
    /// Fresh UUID candidates for a new transcript row (`DSHPreparedTranscriptRow`
    /// tries at most 16).
    pub transcript_refs: &'a [Value],
    /// Clock readings consumed in the order the native code read them.
    pub timestamps: &'a [Value],
}

/// The transaction's outcome.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// The operation already ran: its stored safe result, and the public
    /// result to return.
    Replay { result: Value },
    /// A conflict the caller reports with the observed values.
    Conflict,
    /// Rows to append and the public result to return.
    Commit {
        transcript: Option<Value>,
        authority: Option<Value>,
        operation: Value,
        operation_result: Value,
        result: Value,
    },
}

fn public_result(
    status: &str,
    operation_id: Option<&Value>,
    attempt: Value,
    checkpoint: Option<&Value>,
) -> Value {
    let mut map = Map::new();
    map.insert("schema_version".into(), json!(2));
    map.insert("status".into(), json!(status));
    map.insert("operation_id".into(), or_null(operation_id));
    map.insert("attempt".into(), attempt);
    map.insert("observed_checkpoint".into(), or_null(checkpoint));
    if status == "not_agent" {
        map.insert("failure_code".into(), json!("E_AGENT_NO_ROOT"));
    }
    Value::Object(map)
}

fn transcript_row(
    attempt_id: Option<&Value>,
    root_fingerprint: Option<&Value>,
    existing: &[Value],
    candidates: &[Value],
    timestamp: &Value,
) -> Result<Value, StoreError> {
    let reference = candidates
        .iter()
        .take(16)
        .find(|candidate| {
            !existing
                .iter()
                .any(|row| get(row, "transcript_ref") == Some(candidate))
        })
        .ok_or(StoreError::Capacity)?;
    let digest_input = json!({
        "schema_version": 1,
        "transcript_ref": reference,
        "attempt_id": attempt_id,
        "root_fingerprint_sha256": root_fingerprint,
        "generation": 0,
        "messages": [],
    });
    let bytes = canonical_json(&digest_input).map_err(|_| StoreError::InvalidArgument)?;
    let digest = hash_json("agent-transcript", &digest_input).ok_or(StoreError::InvalidArgument)?;
    if bytes.len() as u64 > MAX_TRANSCRIPT_BYTES {
        return Err(StoreError::InvalidArgument);
    }
    Ok(json!({
        "schema_version": 1,
        "transcript_ref": reference,
        "attempt_id": attempt_id,
        "root_fingerprint_sha256": root_fingerprint,
        "generation": 0,
        "messages": [],
        "transcript_sha256": digest,
        "transcript_bytes": bytes.len(),
        "state": "open",
        "retention_until": Value::Null,
        "created_at": timestamp,
        "updated_at": timestamp,
    }))
}

/// The body of `prepareAgentAttemptWithRequest:`'s WAL transaction.
pub fn transaction(input: &Transaction) -> Result<Outcome, StoreError> {
    let request = input.request;
    if request.get("assistant_context").is_some() {
        return Err(StoreError::InvalidArgument);
    }
    let v5 = input.registry["registry_version"] == 5 || request["registry_version"] == 5;
    if v5 {
        if input.registry["registry_version"] != 5
            || request["registry_version"] != 5
            || !input.assistant_context.is_some_and(|context| {
                crate::assistant_context::valid(context)
                    && context["conversation_id"] == request["conversation_id"]
            })
        {
            return Err(StoreError::InvalidArgument);
        }
    } else if input.assistant_context.is_some() {
        return Err(StoreError::InvalidArgument);
    }
    let operation_id = get(request, "operation_id");
    let checkpoint = get(request, "committed_checkpoint");
    let controller_generation =
        get(request, "controller_cas").and_then(|c| get(c, "expected_controller_generation"));
    let journal_revision = checkpoint.and_then(|c| get(c, "journal_revision"));
    let mut clock = input.timestamps.iter();
    let mut tick = || clock.next().cloned().unwrap_or(Value::Null);

    let existing_authority = input.authorities.iter().find(|a| {
        equal(get(a, "task_id"), get(request, "task_id"))
            && equal(get(a, "attempt_id"), get(request, "attempt_id"))
    });
    if existing_authority.is_some_and(|authority| {
        !crate::assistant_context::authority_valid(authority)
            || authority["conversation_id"] != request["conversation_id"]
    }) {
        return Ok(Outcome::Conflict);
    }

    if let Some(existing) = input
        .operations
        .iter()
        .find(|o| get(o, "operation_id") == operation_id)
    {
        if as_str(get(existing, "operation_kind")) != Some("prepare_agent_attempt")
            || as_str(get(existing, "request_sha256")) != Some(input.request_sha256)
            || !equal(get(existing, "task_id"), get(request, "task_id"))
            || !equal(get(existing, "attempt_id"), get(request, "attempt_id"))
        {
            return Ok(Outcome::Conflict);
        }
        let snapshot = input
            .operation_results
            .iter()
            .find(|s| get(s, "operation_id") == operation_id)
            .ok_or(StoreError::Persistence)?;
        let safe = get(snapshot, "result").ok_or(StoreError::Persistence)?;
        let mut result = get(safe, "result").cloned().unwrap_or(Value::Null);
        if as_str(get(&result, "status")) == Some("prepared") {
            if let Value::Object(map) = &mut result {
                map.insert("status".into(), json!("already_prepared"));
            }
        }
        return Ok(Outcome::Replay { result });
    }

    let mut new_transcript: Option<Value> = None;
    let mut new_authority: Option<Value> = None;
    let status;
    let attempt_projection;
    let authority_for_ref: Option<Value>;
    match (input.root, existing_authority) {
        (None, Some(_)) => return Ok(Outcome::Conflict),
        (None, None) => {
            status = "not_agent";
            attempt_projection = not_agent_projection(
                request,
                controller_generation,
                journal_revision,
                input.toolset_sha256,
            );
            authority_for_ref = None;
        }
        (Some(root), Some(existing)) => {
            if !authority_matches_request(existing, request, root, input.policy, input.registry) {
                return Ok(Outcome::Conflict);
            }
            status = "already_prepared";
            attempt_projection =
                projection_for_authority(existing, controller_generation, journal_revision);
            authority_for_ref = Some(existing.clone());
        }
        (Some(root), None) => {
            if input.authorities.len() >= MAX_AUTHORITIES {
                return Err(StoreError::Capacity);
            }
            let existing_transcript = input
                .transcripts
                .iter()
                .find(|t| equal(get(t, "attempt_id"), get(request, "attempt_id")));
            let expected = get(request, "expected_transcript");
            let transcript: Value = match existing_transcript {
                Some(row) => {
                    if !equal(
                        get(row, "root_fingerprint_sha256"),
                        get(root, "root_fingerprint_sha256"),
                    ) || is_null(expected)
                        || (!is_null(expected) && Some(&transcript_reference(row)) != expected)
                    {
                        return Err(StoreError::Conflict);
                    }
                    row.clone()
                }
                None => {
                    let created = tick();
                    let row = transcript_row(
                        get(request, "attempt_id"),
                        get(root, "root_fingerprint_sha256"),
                        input.transcripts,
                        input.transcript_refs,
                        &created,
                    )?;
                    if !is_null(expected) {
                        return Err(StoreError::Conflict);
                    }
                    new_transcript = Some(row.clone());
                    row
                }
            };
            let created_at = tick();
            let updated_at = tick();
            let mut authority = json!({
                "schema_version": 2,
                "task_id": get(request, "task_id"),
                "conversation_id": get(request, "conversation_id"),
                "attempt_id": get(request, "attempt_id"),
                "root": root,
                "policy": input.policy,
                "registry": input.registry,
                "transport_schema_version": get(request, "transport_schema_version"),
                "model": get(request, "model"),
                "thinking_mode": get(request, "thinking_mode"),
                "visible_message_ids": get(request, "visible_message_ids"),
                "visible_history_sha256": get(request, "visible_history_sha256"),
                "visible_message_count": get(request, "visible_message_count"),
                "project_context_sha256": get(request, "project_context_sha256"),
                "transcript": transcript_reference(&transcript),
                "reserved_write_bytes": 0,
                "authority_revision": 1,
                "state": "prepared",
                "cleanup_id": Value::Null,
                "created_at": created_at,
                "updated_at": updated_at,
            });
            if let Some(context) = input.assistant_context {
                authority["assistant_context"] = context.clone();
            }
            if !crate::assistant_context::authority_valid(&authority) {
                return Err(StoreError::InvalidArgument);
            }
            status = "prepared";
            attempt_projection =
                projection_for_authority(&authority, controller_generation, journal_revision);
            authority_for_ref = Some(authority.clone());
            new_authority = Some(authority);
        }
    }
    let public = public_result(status, operation_id, attempt_projection, checkpoint);
    let safe =
        json!({ "schema_version": 2, "result_kind": "prepare_agent_attempt", "result": public });
    let result_bytes = canonical_json(&safe).map_err(|_| StoreError::Capacity)?;
    let result_sha = hash_json(
        "agent-operation-result",
        &json!({ "operation_kind": "prepare_agent_attempt", "result_status": status, "result": safe }),
    )
    .ok_or(StoreError::Capacity)?;
    if result_bytes.is_empty() || result_bytes.len() > MAX_RESULT_BYTES {
        return Err(StoreError::Capacity);
    }
    let created = tick();
    let snapshot = json!({
        "schema_version": 2,
        "operation_id": operation_id,
        "operation_kind": "prepare_agent_attempt",
        "result_status": status,
        "result_sha256": result_sha,
        "result_bytes": result_bytes.len(),
        "result": safe,
        "created_at": created,
    });
    let attempt_operations = input
        .operations
        .iter()
        .filter(|o| equal(get(o, "attempt_id"), get(request, "attempt_id")))
        .count();
    if attempt_operations >= MAX_OPERATIONS_PER_ATTEMPT
        || input.operations.len() >= MAX_OPERATIONS
        || input.operation_results.len() >= MAX_OPERATIONS
    {
        return Err(StoreError::Capacity);
    }
    let revision = authority_for_ref
        .as_ref()
        .and_then(|a| get(a, "authority_revision"))
        .cloned();
    let result_ref = match &revision {
        Some(revision) => json!({
            "schema_version": 2, "kind": "authority",
            "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
            "authority_revision": revision,
        }),
        None => json!({ "schema_version": 2, "kind": "none" }),
    };
    let operation = json!({
        "schema_version": 2,
        "operation_id": operation_id,
        "operation_kind": "prepare_agent_attempt",
        "request_sha256": input.request_sha256,
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "result_ref": result_ref,
        "state": if revision.is_some() { "committed" } else { "rejected" },
        "result_status": status,
        "result_revision": revision.clone().unwrap_or(Value::Null),
        "result_snapshot_ref": {
            "schema_version": 2,
            "operation_id": operation_id,
            "result_sha256": get(&snapshot, "result_sha256"),
            "result_bytes": get(&snapshot, "result_bytes"),
        },
        "authority_revision": revision.unwrap_or(json!(0)),
        "created_at": get(&snapshot, "created_at"),
        "updated_at": get(&snapshot, "created_at"),
    });
    let result = get(&safe, "result").cloned().unwrap_or(Value::Null);
    Ok(Outcome::Commit {
        transcript: new_transcript,
        authority: new_authority,
        operation,
        operation_result: snapshot,
        result,
    })
}

// MARK: - JSON envelope

/// `{"op","request",...}` in; `{"ok":true,...}` or `{"ok":false,"error":<code>}` out.
pub fn reduce_json(input: &str, session_json: &[u8]) -> String {
    let value = match reduce_json_inner(input, session_json) {
        Ok(output) => {
            let mut object = output.as_object().cloned().unwrap_or_default();
            object.insert("ok".to_string(), Value::Bool(true));
            Value::Object(object)
        }
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn reduce_json_inner(input: &str, session_json: &[u8]) -> Result<Value, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(StoreError::Corrupt)?;
    let field = |key: &str| get(&envelope, key).ok_or(StoreError::InvalidArgument);
    let present = |key: &str| get(&envelope, key).filter(|v| !v.is_null());
    let request = field("request")?;
    match op {
        "request" => {
            let env = Env {
                model_supported: get(&envelope, "model_supported") == Some(&Value::Bool(true)),
                harness_id: as_str(get(&envelope, "harness_id")).map(str::to_owned),
            };
            if !request_shape(request, &env) {
                return Err(StoreError::InvalidArgument);
            }
            Ok(json!({ "checkpoint_relation": checkpoint_relation(request) }))
        }
        "session" => Ok(json!({ "conversation": session_conversation(session_json, request)? })),
        "observed" => Ok(
            json!({ "observed": observed_values(request, present("snapshot"), present("conversation")) }),
        ),
        "conflict" => Ok(json!({ "result": conflict_result(
            request,
            as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?,
            field("observed")?,
        )})),
        "session_matches" => {
            Ok(json!({ "matches": session_attempt_matches(request, present("conversation")) }))
        }
        "projection" => Ok(json!({ "projection": projection_for_authority(
            field("authority")?,
            get(&envelope, "controller_generation"),
            get(&envelope, "journal_revision"),
        )})),
        "transaction" => {
            let outcome = transaction(&Transaction {
                request,
                request_sha256: as_str(get(&envelope, "request_sha256"))
                    .ok_or(StoreError::InvalidArgument)?,
                root: present("root"),
                policy: present("policy"),
                registry: field("registry")?,
                assistant_context: get(&envelope, "assistant_context"),
                toolset_sha256: get(&envelope, "toolset_sha256"),
                operations: array(get(&envelope, "operations")),
                operation_results: array(get(&envelope, "operation_results")),
                authorities: array(get(&envelope, "authorities")),
                transcripts: array(get(&envelope, "transcripts")),
                transcript_refs: array(get(&envelope, "transcript_refs")),
                timestamps: array(get(&envelope, "timestamps")),
            })?;
            Ok(match outcome {
                Outcome::Replay { result } => json!({ "outcome": "replay", "result": result }),
                Outcome::Conflict => json!({ "outcome": "conflict" }),
                Outcome::Commit {
                    transcript,
                    authority,
                    operation,
                    operation_result,
                    result,
                } => json!({
                    "outcome": "commit",
                    "transcript": transcript,
                    "authority": authority,
                    "operation": operation,
                    "operation_result": operation_result,
                    "result": result,
                }),
            })
        }
        _ => Err(StoreError::InvalidArgument),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> Value {
        json!({
            "schema_version": 2,
            "operation_id": "0f0e3b1a-4c7d-4e2f-9a1b-2c3d4e5f6a7b",
            "controller_cas": {
                "schema_version": 1,
                "conversation_id": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                "task_id": "9b8a7c6d-5e4f-4321-8765-43210fedcba9",
                "attempt_id": "2a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                "expected_controller_generation": 0,
                "expected_journal_revision": 3,
                "expected_session_generation": 7,
                "expected_session_sha256": "a".repeat(64),
            },
            "committed_checkpoint": { "schema_version": 1, "journal_revision": 3, "session_generation": 7, "session_sha256": "a".repeat(64) },
            "task_id": "9b8a7c6d-5e4f-4321-8765-43210fedcba9",
            "conversation_id": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
            "attempt_id": "2a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
            "workspace_id": Value::Null, "project_id": Value::Null, "workspace_binding_revision": Value::Null,
            "transport_schema_version": 2, "model": "deepseek-v4-flash", "thinking_mode": "off",
            "visible_message_ids": [], "visible_history_sha256": "b".repeat(64), "visible_message_count": 0,
            "project_context_sha256": Value::Null, "registry_version": 2,
            "expected_policy_version": Value::Null, "expected_transcript": Value::Null,
        })
    }

    #[test]
    fn request_shape_needs_the_catalogue() {
        let env = Env {
            model_supported: true,
            harness_id: Some("dsh".into()),
        };
        assert!(request_shape(&request(), &env));
        assert!(!request_shape(&request(), &Env::default()));
        let mut bad = request();
        bad["transport_schema_version"] = json!(3);
        assert!(!request_shape(&bad, &env));
        assert!(checkpoint_relation(&request()));
    }

    #[test]
    fn transaction_creates_transcript_and_authority_once() {
        let request = request();
        let root = json!({ "root_fingerprint_sha256": "c".repeat(64), "kind": "workspace" });
        let registry = json!({ "schema_version": 2, "registry_version": 2, "toolset_sha256": "d".repeat(64), "tools": [] });
        let policy = json!({ "policy_version": "agent-v1" });
        let refs = vec![json!("3a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")];
        let times = vec![json!("2026-09-15T00:00:00.000Z"); 4];
        let first = transaction(&Transaction {
            request: &request,
            request_sha256: "sha",
            root: Some(&root),
            policy: Some(&policy),
            registry: &registry,
            assistant_context: None,
            toolset_sha256: registry.get("toolset_sha256"),
            operations: &[],
            operation_results: &[],
            authorities: &[],
            transcripts: &[],
            transcript_refs: &refs,
            timestamps: &times,
        })
        .unwrap();
        let Outcome::Commit {
            transcript,
            authority,
            operation,
            operation_result,
            result,
        } = first
        else {
            panic!("commit")
        };
        assert!(transcript.is_some() && authority.is_some());
        assert_eq!(result["status"], "prepared");
        assert_eq!(operation["state"], "committed");
        let replay = transaction(&Transaction {
            request: &request,
            request_sha256: "sha",
            root: Some(&root),
            policy: Some(&policy),
            registry: &registry,
            assistant_context: None,
            toolset_sha256: registry.get("toolset_sha256"),
            operations: std::slice::from_ref(&operation),
            operation_results: std::slice::from_ref(&operation_result),
            authorities: std::slice::from_ref(authority.as_ref().unwrap()),
            transcripts: std::slice::from_ref(transcript.as_ref().unwrap()),
            transcript_refs: &refs,
            timestamps: &times,
        })
        .unwrap();
        assert_eq!(
            replay,
            Outcome::Replay {
                result: {
                    let mut r = result.clone();
                    r["status"] = json!("already_prepared");
                    r
                }
            }
        );
        let no_root = transaction(&Transaction {
            request: &request,
            request_sha256: "sha",
            root: None,
            policy: None,
            registry: &registry,
            assistant_context: None,
            toolset_sha256: registry.get("toolset_sha256"),
            operations: &[],
            operation_results: &[],
            authorities: &[],
            transcripts: &[],
            transcript_refs: &refs,
            timestamps: &times,
        })
        .unwrap();
        let Outcome::Commit {
            result, operation, ..
        } = no_root
        else {
            panic!("commit")
        };
        assert_eq!(result["status"], "not_agent");
        assert_eq!(result["failure_code"], "E_AGENT_NO_ROOT");
        assert_eq!(operation["state"], "rejected");
    }
}
