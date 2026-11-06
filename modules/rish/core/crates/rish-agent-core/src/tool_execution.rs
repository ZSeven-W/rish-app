//! The tool execution service's decisions, ported from
//! `AgentToolExecutionService.mm`: the execute/recover request shape, the
//! committed-session relation, the pre-execution checks over the WAL views
//! (authority, batch, ledger row, prepared projection, approval or grant
//! binding, ordering, row-state branching), the ledger CAS and result
//! shapes, the settlement of an executor's effect, and the recovery
//! settlement. The host keeps the WAL operation relation, the session
//! load, the root proofs, liveness, the executors and the ledger calls.

use crate::canonical::{canonical_json, hash_bytes, hash_json};
use crate::execution_ledger::{as_str, feedback_string_valid, get};
use crate::schema::{
    bounded_utf8, canonical_sha256, canonical_uuid, exact_keys, safe_integer, transcript_reference,
    MAX_TRANSCRIPT_BYTES,
};
use crate::store::StoreError;
use crate::strict_json::parse_arguments;
use serde_json::{json, Map, Value};

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

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

fn is_mutation(name: &str) -> bool {
    matches!(name, "write_file" | "git_commit" | "git_push")
        || crate::runtime_tools::is_guest(name)
        || crate::assistant_tools::is_mutation(name)
}

// MARK: - request

fn execution_root(value: Option<&Value>) -> bool {
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
    root.get("schema_version") == Some(&json!(1))
        && canonical_uuid(root.get("workspace_id"))
        && safe_integer(
            root.get("workspace_binding_revision"),
            MAX_SAFE_INTEGER,
            false,
        )
        .is_some()
        && canonical_sha256(root.get("root_fingerprint_sha256"))
        && root.get("capabilities").is_some_and(Value::is_array)
}

fn execution_transcript(value: Option<&Value>) -> bool {
    transcript_reference(value)
        && value
            .and_then(|v| get(v, "transcript_bytes"))
            .and_then(Value::as_u64)
            .is_some_and(|b| b <= MAX_TRANSCRIPT_BYTES)
}

/// `validateExecuteRequest:` — `Err(InvalidArgument)` for a malformed shape,
/// `Err(Conflict)` when the CAS and checkpoint disagree.
pub fn execute_request(request: &Value) -> Result<(), StoreError> {
    let mut keys = vec![
        "schema_version",
        "operation_id",
        "controller_cas",
        "committed_checkpoint",
        "task_id",
        "conversation_id",
        "attempt_id",
        "round_id",
        "round_index",
        "batch_kind",
        "manifest_sha256",
        "expected_batch_revision",
        "call_index",
        "call_id",
        "name",
        "arguments_sha256",
        "idempotency_key",
        "expected_execution_revision",
        "transcript",
        "root",
        "approval_reference",
    ];
    let r = |key: &str| get(request, key);
    if let Some(response) = r("user_response") {
        if r("name").and_then(Value::as_str) != Some(crate::user_question::NAME)
            || !crate::user_question::response_shape(response)
        {
            return Err(StoreError::InvalidArgument);
        }
        keys.push("user_response");
    }
    if exact_keys(Some(request), &keys).is_none()
        || r("schema_version") != Some(&json!(2))
        || !canonical_uuid(r("operation_id"))
        || !crate::tool_batch::controller_cas(r("controller_cas"))
        || !crate::tool_batch::checkpoint(r("committed_checkpoint"))
        || !canonical_uuid(r("task_id"))
        || !canonical_uuid(r("conversation_id"))
        || !canonical_uuid(r("attempt_id"))
        || !canonical_uuid(r("round_id"))
        || safe_integer(r("round_index"), 7, true).is_none()
        || !matches!(
            as_str(r("batch_kind")),
            Some("write_batch" | "read_only_batch")
        )
        || !(is_null(r("manifest_sha256")) || canonical_sha256(r("manifest_sha256")))
        || safe_integer(r("expected_batch_revision"), MAX_SAFE_INTEGER, false).is_none()
        || safe_integer(r("call_index"), 15, true).is_none()
        || bounded_utf8(r("call_id"), 128, false).is_none()
        || bounded_utf8(r("name"), 64, false).is_none()
        || !canonical_sha256(r("arguments_sha256"))
        || !canonical_sha256(r("idempotency_key"))
        || safe_integer(r("expected_execution_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !execution_transcript(r("transcript"))
        || !execution_root(r("root"))
        || !(is_null(r("approval_reference")) || canonical_uuid(r("approval_reference")))
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

// MARK: - committed session

/// `DSHAgentExecutionValidateCommittedSession` over the loaded session's
/// conversation for the request (the host has already matched the
/// checkpoint's generation and digest).
pub fn committed_session_matches(
    request: &Value,
    conversation: Option<&Value>,
    require_execution_intent: bool,
) -> bool {
    let Some(conversation) = conversation else {
        return false;
    };
    let expected = get(request, "committed_checkpoint");
    let mut persisted: Option<(&Value, &Value)> = None;
    for attempt in array(get(conversation, "attempts")) {
        if get(attempt, "attempt_id") != get(request, "attempt_id")
            || get(attempt, "journal_revision") != expected.and_then(|e| get(e, "journal_revision"))
        {
            continue;
        }
        let agent = get(attempt, "agent");
        let lineage = agent.and_then(|a| get(a, "round_lineage"));
        if lineage.and_then(|l| get(l, "round_id")) != get(request, "round_id")
            || lineage.and_then(|l| get(l, "round_index")) != get(request, "round_index")
            || agent.and_then(|a| get(a, "root")) != get(request, "root")
            || agent.and_then(|a| get(a, "transcript")) != get(request, "transcript")
        {
            continue;
        }
        for call in array(agent.and_then(|a| get(a, "batch"))) {
            if get(call, "call_index") == get(request, "call_index")
                && get(call, "call_id") == get(request, "call_id")
            {
                persisted = Some((call, agent.expect("checked")));
                break;
            }
        }
    }
    let Some((call, agent)) = persisted else {
        return false;
    };
    !((require_execution_intent && !string_eq(get(agent, "phase"), "execution_intent"))
        || !equal(get(call, "name"), get(request, "name"))
        || !equal(
            get(call, "arguments_sha256"),
            get(request, "arguments_sha256"),
        )
        || !equal(
            get(call, "idempotency_key"),
            get(request, "idempotency_key"),
        )
        || !equal(
            get(call, "native_row_revision"),
            get(request, "expected_execution_revision"),
        )
        || !equal(
            get(call, "approval_reference"),
            get(request, "approval_reference"),
        ))
}

// MARK: - WAL views

fn locator_matches_request(locator: Option<&Value>, request: &Value) -> bool {
    let Some(locator) = locator else { return false };
    equal(get(locator, "task_id"), get(request, "task_id"))
        && equal(get(locator, "attempt_id"), get(request, "attempt_id"))
        && equal(get(locator, "round_id"), get(request, "round_id"))
        && equal(get(locator, "round_index"), get(request, "round_index"))
}

/// `DSHAgentExecutionRow`.
pub fn execution_row<'a>(ledger: &'a [Value], request: &Value) -> Option<&'a Value> {
    ledger.iter().find(|row| {
        let locator = get(row, "locator");
        locator_matches_request(locator, request)
            && equal(
                locator.and_then(|l| get(l, "call_index")),
                get(request, "call_index"),
            )
            && equal(
                locator.and_then(|l| get(l, "call_id")),
                get(request, "call_id"),
            )
            && equal(
                locator.and_then(|l| get(l, "idempotency_key")),
                get(request, "idempotency_key"),
            )
    })
}

fn execution_batch<'a>(batches: &'a [Value], request: &Value) -> Option<&'a Value> {
    batches.iter().find(|batch| {
        equal(get(batch, "task_id"), get(request, "task_id"))
            && equal(get(batch, "attempt_id"), get(request, "attempt_id"))
            && equal(get(batch, "round_id"), get(request, "round_id"))
            && equal(get(batch, "round_index"), get(request, "round_index"))
            && equal(
                get(batch, "batch_revision"),
                get(request, "expected_batch_revision"),
            )
    })
}

/// `DSHAgentExecutionPreparedProjection`: the prepared batch's call from
/// the operation results (a tagged union; only prepared batch receipts
/// count).
fn prepared_projection<'a>(operation_results: &'a [Value], request: &Value) -> Option<&'a Value> {
    for snapshot in operation_results {
        let wrapper = get(snapshot, "result");
        if !string_eq(get(snapshot, "operation_kind"), "prepare_agent_tool_batch")
            || !string_eq(
                wrapper.and_then(|w| get(w, "result_kind")),
                "prepare_agent_tool_batch",
            )
        {
            continue;
        }
        let result = wrapper.and_then(|w| get(w, "result"));
        if !string_eq(result.and_then(|r| get(r, "status")), "prepared") {
            continue;
        }
        let Some(receipt) = result
            .and_then(|r| get(r, "receipt"))
            .filter(|r| r.is_object())
        else {
            continue;
        };
        if !equal(get(receipt, "task_id"), get(request, "task_id"))
            || !equal(get(receipt, "attempt_id"), get(request, "attempt_id"))
            || !equal(get(receipt, "round_id"), get(request, "round_id"))
            || !equal(get(receipt, "round_index"), get(request, "round_index"))
            || !equal(
                get(receipt, "batch_revision"),
                get(request, "expected_batch_revision"),
            )
        {
            continue;
        }
        if let Some(call) = array(get(receipt, "calls")).iter().find(|call| {
            equal(get(call, "call_index"), get(request, "call_index"))
                && equal(get(call, "call_id"), get(request, "call_id"))
                && equal(
                    get(call, "idempotency_key"),
                    get(request, "idempotency_key"),
                )
        }) {
            return Some(call);
        }
    }
    None
}

/// `DSHAgentExecutionApprovalBound`.
fn approval_bound(operation_results: &[Value], request: &Value) -> bool {
    if is_null(get(request, "approval_reference")) {
        return false;
    }
    for snapshot in operation_results {
        let result = get(snapshot, "result").and_then(|r| get(r, "result"));
        let Some(result) = result else { continue };
        if !string_eq(get(result, "status"), "bound")
            || !equal(get(result, "task_id"), get(request, "task_id"))
            || !equal(get(result, "attempt_id"), get(request, "attempt_id"))
            || !equal(get(result, "round_id"), get(request, "round_id"))
            || !equal(get(result, "call_index"), get(request, "call_index"))
            || !equal(get(result, "call_id"), get(request, "call_id"))
            || !equal(
                get(result, "approval_reference"),
                get(request, "approval_reference"),
            )
        {
            continue;
        }
        return matches!(
            as_str(get(result, "decision")),
            Some("allow_once" | "allow_conversation")
        );
    }
    false
}

/// `DSHAgentExecutionConversationGrantBound` over the committed
/// conversation's grants (`None` when the session did not match).
fn conversation_grant_bound(grants: Option<&[Value]>, request: &Value) -> bool {
    let name = as_str(get(request, "name")).unwrap_or_default();
    let family = match name {
        "write_file" => "file_write",
        "create_assistant_task"
        | "update_assistant_task"
        | "remember_assistant_memory"
        | "forget_assistant_memory" => "assistant_metadata",
        "git_commit" => "git_commit",
        "git_push" => "git_push",
        _ if crate::runtime_tools::is_mutation(name) || name.ends_with("_guest_cgi") => {
            "guest_service"
        }
        _ => return false,
    };
    if is_null(get(request, "approval_reference")) {
        return false;
    }
    let Some(grants) = grants else { return false };
    let root = get(request, "root");
    grants.iter().any(|grant| {
        equal(get(grant, "grant_id"), get(request, "approval_reference"))
            && equal(
                get(grant, "conversation_id"),
                get(request, "conversation_id"),
            )
            && equal(
                get(grant, "workspace_id"),
                root.and_then(|r| get(r, "workspace_id")),
            )
            && equal(
                get(grant, "project_id"),
                root.and_then(|r| get(r, "project_id")),
            )
            && equal(
                get(grant, "binding_revision"),
                root.and_then(|r| get(r, "workspace_binding_revision")),
            )
            && equal(
                get(grant, "root_fingerprint_sha256"),
                root.and_then(|r| get(r, "root_fingerprint_sha256")),
            )
            && string_eq(get(grant, "tool_family"), family)
            && crate::runtime_tools::grant_supports_tool(get(grant, "registry_version"), name)
            && string_eq(get(grant, "policy_version"), "agent-v1")
    })
}

// MARK: - results

/// `DSHAgentExecutionCAS`.
pub fn execution_cas(row: &Value, state: &str) -> Value {
    let owner = get(row, "owner").filter(|o| !o.is_null());
    json!({
        "schema_version": 2, "locator": get(row, "locator"),
        "expected_row_revision": get(row, "row_revision"), "expected_state": state,
        "expected_owner_generation": or_null(owner.and_then(|o| get(o, "owner_generation"))),
        "expected_launch_id": or_null(owner.and_then(|o| get(o, "launch_id"))),
        "expected_native_task_id": or_null(owner.and_then(|o| get(o, "native_task_id"))),
        "expected_transcript_generation": get(row, "transcript_before").and_then(|t| get(t, "generation")),
        "expected_transcript_sha256": get(row, "transcript_before").and_then(|t| get(t, "transcript_sha256")),
        "expected_root_fingerprint_sha256": get(row, "root_fingerprint_sha256"),
        "expected_binding_revision": get(row, "binding_revision"),
    })
}

fn public_status(receipt: Option<&Value>) -> &'static str {
    match as_str(receipt.and_then(|r| get(r, "outcome"))) {
        Some("ok") => "completed",
        Some("denied") => "denied",
        Some("cancelled") => "cancelled",
        Some("ambiguous") => "ambiguous",
        _ => "failed",
    }
}

fn identity_fields(request: &Value) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert("schema_version".into(), json!(2));
    for key in [
        "operation_id",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "call_index",
        "call_id",
        "name",
        "idempotency_key",
    ] {
        map.insert(key.into(), or_null(get(request, key)));
    }
    map
}

/// `DSHAgentExecutionSafeResult`: a settled row as the public result.
pub fn safe_result(request: &Value, row: &Value) -> Value {
    let receipt = get(row, "receipt");
    let effect_may_have_occurred = !string_eq(receipt.and_then(|r| get(r, "outcome")), "cancelled");
    let mut map = identity_fields(request);
    map.insert("status".into(), json!(public_status(receipt)));
    map.insert(
        "result_execution_revision".into(),
        or_null(get(row, "row_revision")),
    );
    map.insert("transcript".into(), or_null(get(row, "transcript_after")));
    map.insert("receipt".into(), or_null(receipt));
    map.insert(
        "effect_may_have_occurred".into(),
        json!(effect_may_have_occurred),
    );
    Value::Object(map)
}

/// `DSHAgentExecutionActiveResult`.
pub fn active_result(
    request: &Value,
    row: &Value,
    status: &str,
    effect_may_have_occurred: bool,
) -> Value {
    let mut map = identity_fields(request);
    map.insert("status".into(), json!(status));
    map.insert(
        "result_execution_revision".into(),
        or_null(get(row, "row_revision")),
    );
    map.insert("transcript".into(), or_null(get(request, "transcript")));
    map.insert("receipt".into(), Value::Null);
    map.insert(
        "effect_may_have_occurred".into(),
        json!(effect_may_have_occurred),
    );
    Value::Object(map)
}

fn unknown_result(request: &Value, row: &Value, failure_code: &str) -> Value {
    let mut map = identity_fields(request);
    map.insert("status".into(), json!("unknown"));
    map.insert(
        "result_execution_revision".into(),
        or_null(get(row, "row_revision")),
    );
    map.insert("transcript".into(), or_null(get(request, "transcript")));
    map.insert("receipt".into(), Value::Null);
    map.insert("effect_may_have_occurred".into(), json!(false));
    map.insert("failure_code".into(), json!(failure_code));
    Value::Object(map)
}

fn ambiguous_receipt(request: &Value, result_sha256: &str, result_bytes: usize) -> Value {
    json!({
        "schema_version": 1, "call_id": get(request, "call_id"),
        "name": get(request, "name"),
        "arguments_sha256": get(request, "arguments_sha256"),
        "result_sha256": result_sha256, "result_bytes": result_bytes,
        "truncated": false, "duration_ms": 0,
        "outcome": "ambiguous",
        "failure_code": "E_AGENT_EXECUTION_AMBIGUOUS",
        "approval_reference": get(request, "approval_reference"),
    })
}

/// `DSHAgentExecutionAmbiguousResult`: a lost owner with a dispatched effect.
pub fn ambiguous_result(request: &Value, row: &Value) -> Result<Value, StoreError> {
    let feedback = json!({
        "schema_version": 1, "name": get(request, "name"),
        "outcome": "ambiguous",
        "payload": { "schema_version": 1, "failure_code": "E_AGENT_EXECUTION_AMBIGUOUS" },
    });
    let bytes = canonical_json(&feedback).map_err(|_| StoreError::InvalidArgument)?;
    let digest = hash_bytes("tool-result", &bytes).ok_or(StoreError::InvalidArgument)?;
    let mut map = identity_fields(request);
    map.insert("status".into(), json!("ambiguous"));
    map.insert(
        "result_execution_revision".into(),
        get(row, "row_revision").cloned().unwrap_or(json!(1)),
    );
    map.insert("transcript".into(), or_null(get(request, "transcript")));
    map.insert(
        "receipt".into(),
        ambiguous_receipt(request, &digest, bytes.len()),
    );
    map.insert("effect_may_have_occurred".into(), json!(true));
    map.insert("failure_code".into(), json!("E_AGENT_EXECUTION_AMBIGUOUS"));
    Ok(Value::Object(map))
}

/// The `execute_agent_tool` conflict result the host commits.
pub fn conflict_result(request: &Value, row: Option<&Value>, failure_code: &str) -> Value {
    let actual_state = row
        .and_then(|r| as_str(get(r, "state")))
        .unwrap_or("intent");
    json!({
        "schema_version": 2, "status": "conflict",
        "operation_id": get(request, "operation_id"), "failure_code": failure_code,
        "expected_execution_revision": get(request, "expected_execution_revision"),
        "actual_execution_revision": row.and_then(|r| get(r, "row_revision")).cloned().unwrap_or(json!(0)),
        "actual_status": actual_state,
    })
}

fn result_ref(request: &Value, execution_revision: Option<&Value>) -> Value {
    json!({
        "schema_version": 2, "kind": "tool",
        "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
        "call_index": get(request, "call_index"), "call_id": get(request, "call_id"),
        "execution_revision": execution_revision,
    })
}

// MARK: - execute

/// What the host observed before the executor runs.
pub struct ExecuteView<'a> {
    pub authority: Option<&'a Value>,
    pub batches: &'a [Value],
    pub ledger: &'a [Value],
    pub operation_results: &'a [Value],
    /// The committed session's conversation for the request when its
    /// checkpoint matched, else `None`.
    pub conversation: Option<&'a Value>,
    pub root_ok: bool,
    /// `dispatchStateForKind:execution` for the row, when the host looked.
    pub dispatch_state: Option<&'a str>,
    /// Whether the row's owner task is alive, when the host looked.
    pub owner_alive: bool,
}

/// Everything between the started operation and the transcript read.
/// `{conflict: <result>}` (commit as conflict), `{commit: {result,
/// result_ref, revision}}` (a settled row replayed), `{result}` (returned
/// without commit: active, unknown, ambiguous), or `{proceed: true}`.
pub fn execute_precheck(request: &Value, view: &ExecuteView) -> Result<Value, StoreError> {
    let row = execution_row(view.ledger, request);
    let conflict = |code: &str| json!({ "conflict": conflict_result(request, row, code) });
    if !committed_session_matches(request, view.conversation, true) || !view.root_ok {
        return Ok(conflict("E_AGENT_ROOT_STALE"));
    }
    let batch = execution_batch(view.batches, request);
    let projection = prepared_projection(view.operation_results, request);
    let (Some(authority), Some(batch), Some(row), Some(projection)) =
        (view.authority, batch, row, projection)
    else {
        return Ok(conflict("E_AGENT_CONFLICT"));
    };
    if !string_eq(get(authority, "state"), "prepared")
        || !equal(get(authority, "root"), get(request, "root"))
        || !equal(get(batch, "kind"), get(request, "batch_kind"))
        || !equal(
            get(batch, "manifest_sha256"),
            get(request, "manifest_sha256"),
        )
        || !equal(get(row, "name"), get(request, "name"))
        || !equal(
            get(row, "arguments_sha256"),
            get(request, "arguments_sha256"),
        )
    {
        return Ok(conflict("E_AGENT_CONFLICT"));
    }
    if as_str(get(request, "name")).is_some_and(crate::assistant_tools::is_assistant)
        && (!crate::assistant_context::authority_valid(authority)
            || row["precondition"]["conversation_id"] != request["conversation_id"]
            || authority["conversation_id"] != request["conversation_id"]
            || authority["registry"]["registry_version"] != 5)
    {
        return Ok(conflict("E_AGENT_CAPABILITY"));
    }
    // A later call cannot overtake an earlier executable call in the same round.
    let call_index = get(request, "call_index")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    for candidate in view.ledger {
        let locator = get(candidate, "locator");
        if locator_matches_request(locator, request)
            && locator
                .and_then(|l| get(l, "call_index"))
                .and_then(Value::as_u64)
                .unwrap_or(0)
                < call_index
            && !matches!(
                as_str(get(candidate, "state")),
                Some("settled" | "cancelled")
            )
        {
            return Ok(conflict("E_AGENT_CONFLICT"));
        }
    }
    let automatic = string_eq(get(projection, "access"), "auto");
    let grants = view.conversation.map(|c| array(get(c, "agent_grants")));
    if (automatic && !is_null(get(request, "approval_reference")))
        || (!automatic
            && !approval_bound(view.operation_results, request)
            && !conversation_grant_bound(grants, request))
    {
        return Ok(conflict("E_AGENT_APPROVAL"));
    }
    let state = as_str(get(row, "state")).unwrap_or_default();
    match state {
        "settled" | "cancelled" | "ambiguous" => {
            let result = safe_result(request, row);
            return Ok(json!({ "commit": {
                "result": result,
                "result_ref": result_ref(request, get(row, "row_revision")),
                "revision": get(row, "row_revision"),
            }}));
        }
        "running" | "cancel_requested" => {
            let dispatched = view.dispatch_state == Some("dispatched");
            if !view.owner_alive && dispatched {
                return Ok(json!({ "result": ambiguous_result(request, row)? }));
            }
            if !view.owner_alive {
                return Ok(json!({ "result": unknown_result(request, row, "E_AGENT_LEDGER") }));
            }
            return Ok(json!({ "result": active_result(request, row, state, dispatched) }));
        }
        "unknown" => {
            return Ok(
                json!({ "result": unknown_result(request, row, "E_AGENT_EXECUTION_AMBIGUOUS") }),
            )
        }
        _ => {}
    }
    if state != "intent"
        || !equal(
            get(row, "row_revision"),
            get(request, "expected_execution_revision"),
        )
    {
        return Ok(conflict("E_AGENT_CONFLICT"));
    }
    Ok(json!({ "proceed": true }))
}

/// `DSHAgentExecutionRawCall` + digest check: the parsed arguments of the
/// request's call in the transcript, or `None` (E_AGENT_TRANSCRIPT).
pub fn execute_arguments(
    request: &Value,
    messages: Option<&[Value]>,
) -> Option<Map<String, Value>> {
    let messages = messages?;
    let raw = messages
        .iter()
        .filter(|m| {
            string_eq(get(m, "role"), "assistant")
                && equal(get(m, "round_index"), get(request, "round_index"))
        })
        .flat_map(|m| array(get(m, "tool_calls")).iter())
        .find(|call| {
            equal(get(call, "call_id"), get(request, "call_id"))
                && equal(get(call, "name"), get(request, "name"))
        })?;
    let digest = crate::schema::arguments_sha256(get(request, "name"), get(raw, "arguments_json"))?;
    if as_str(get(request, "arguments_sha256")) != Some(digest.as_str()) {
        return None;
    }
    as_str(get(raw, "arguments_json")).and_then(parse_arguments)
}

/// Whether a write-batch effect gate must be opened before the effect.
pub fn needs_effect_gate(request: &Value) -> bool {
    string_eq(get(request, "batch_kind"), "write_batch")
        && as_str(get(request, "name")).is_some_and(is_mutation)
}

/// The effect gate request for the ledger.
pub fn effect_gate_request(request: &Value) -> Value {
    json!({
        "schema_version": 2, "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "expected_batch_revision": get(request, "expected_batch_revision"),
        "manifest_sha256": get(request, "manifest_sha256"),
        "expected_effect_gate": "closed",
    })
}

/// The canonical feedback string of a native tool failure, validated as
/// the ledger requires.
fn feedback_string(feedback: &Value) -> Result<String, StoreError> {
    let bytes = canonical_json(feedback).map_err(|_| StoreError::InvalidArgument)?;
    let text = String::from_utf8(bytes).map_err(|_| StoreError::InvalidArgument)?;
    feedback_string_valid(&text)?;
    Ok(text)
}

/// `DSHAgentExecutionGenericFailure`: the effect recorded when the executor
/// returned nothing.
pub fn generic_failure_effect(name: Option<&Value>) -> Result<Value, StoreError> {
    let feedback = feedback_string(&json!({
        "schema_version": 1, "name": name, "outcome": "failed",
        "payload": { "schema_version": 1, "failure_code": "E_AGENT_TOOL_FAILED" },
    }))?;
    Ok(json!({
        "schema_version": 1, "status": "failed", "feedback": feedback,
        "settled_facts": Value::Null, "truncated": false,
        "effect_may_have_occurred": false,
    }))
}

/// Only a native pre-effect refusal may use this failed effect. Persistence
/// uncertainty must stay recoverable and probe its durable store receipt.
pub fn assistant_failure_effect(name: &str, code: &str) -> Result<Value, StoreError> {
    if !crate::assistant_tools::is_assistant(name)
        || !matches!(
            code,
            "E_AGENT_CONFLICT" | "E_AGENT_BAD_ARGUMENTS" | "E_AGENT_NOT_FOUND"
        )
    {
        return Err(StoreError::InvalidArgument);
    }
    let feedback = feedback_string(&json!({"schema_version":1,"name":name,"outcome":"failed",
        "payload":{"schema_version":1,"failure_code":code}}))?;
    Ok(
        json!({"schema_version":1,"status":"failed","feedback":feedback,"settled_facts":null,
        "truncated":false,"effect_may_have_occurred":false}),
    )
}

/// The ambiguous effect recorded when a guest service's session vanished
/// under it.
pub fn ambiguous_effect(name: Option<&Value>) -> Result<Value, StoreError> {
    let feedback = feedback_string(&json!({
        "schema_version": 1, "name": name, "outcome": "ambiguous",
        "payload": { "schema_version": 1, "failure_code": "E_AGENT_EXECUTION_AMBIGUOUS" },
    }))?;
    Ok(json!({
        "schema_version": 1, "status": "ambiguous", "feedback": feedback,
        "settled_facts": Value::Null, "truncated": false,
        "effect_may_have_occurred": true,
    }))
}

/// Turns an executor's effect into the ledger settlement: the receipt, the
/// tool message, the CAS patch and the operation record. `duration_ms` is
/// the host's clock reading.
pub fn settlement_plan(
    request: &Value,
    row: &Value,
    effect: &Value,
    request_sha256: Option<&Value>,
    duration_ms: u64,
) -> Result<Value, StoreError> {
    let Some(feedback_text) = as_str(get(effect, "feedback")) else {
        return Err(StoreError::InvalidArgument);
    };
    let runtime = as_str(get(request, "name")).is_some_and(crate::runtime_tools::is_runtime);
    let assistant = as_str(get(request, "name")).is_some_and(crate::assistant_tools::is_assistant);
    let expected_state = if request["name"] == crate::user_question::NAME {
        let feedback: Value =
            serde_json::from_str(feedback_text).map_err(|_| StoreError::InvalidArgument)?;
        if row["state"] != "intent"
            || !crate::user_question::facts_match(row, &feedback, &effect["settled_facts"])
        {
            return Err(StoreError::Conflict);
        }
        "intent"
    } else if runtime || assistant {
        if get(row, "name") != get(request, "name")
            || get(row, "arguments_sha256") != get(request, "arguments_sha256")
            || (runtime && !crate::runtime_tools::effect_valid(row, effect))
            || (assistant
                && (!crate::assistant_tools::effect_valid(row, effect)
                    || row["precondition"]["conversation_id"] != request["conversation_id"]))
        {
            return Err(StoreError::Conflict);
        }
        match as_str(get(row, "state")) {
            Some(state @ ("running" | "cancel_requested")) => state,
            _ => return Err(StoreError::Conflict),
        }
    } else {
        "running"
    };
    let feedback_bytes = feedback_text.as_bytes();
    let result_sha =
        hash_bytes("tool-result", feedback_bytes).ok_or(StoreError::InvalidArgument)?;
    let feedback: Value =
        serde_json::from_str(feedback_text).map_err(|_| StoreError::InvalidArgument)?;
    if !feedback.is_object() {
        return Err(StoreError::InvalidArgument);
    }
    let outcome = as_str(get(&feedback, "outcome")).unwrap_or_default();
    let failure_code = if outcome == "ok" {
        None
    } else {
        get(&feedback, "payload").and_then(|p| get(p, "failure_code"))
    };
    let duration = duration_ms.min(24 * 60 * 60 * 1000);
    let receipt = json!({
        "schema_version": 1, "call_id": get(request, "call_id"),
        "name": get(request, "name"),
        "arguments_sha256": get(request, "arguments_sha256"),
        "result_sha256": result_sha, "result_bytes": feedback_bytes.len(),
        "truncated": get(effect, "truncated"), "duration_ms": duration,
        "outcome": outcome, "failure_code": or_null(failure_code),
        "approval_reference": get(request, "approval_reference"),
    });
    let message = json!({
        "schema_version": 1, "role": "tool",
        "round_index": get(request, "round_index"), "call_id": get(request, "call_id"),
        "content": feedback_text, "truncated": get(effect, "truncated"),
    });
    let ambiguous = outcome == "ambiguous";
    Ok(json!({
        "cas": execution_cas(row, expected_state),
        "patch": {
            "state": if ambiguous { "ambiguous" } else if (runtime || assistant) && outcome == "cancelled" { "cancelled" } else { "settled" },
            "settled_facts": get(effect, "settled_facts"), "receipt": receipt,
        },
        "message": message,
        "operation": {
            "operation_id": get(request, "operation_id"),
            "request_sha256": request_sha256,
            "effect_may_have_occurred": get(effect, "effect_may_have_occurred"),
        },
    }))
}

/// The result returned when the ledger could not settle the effect.
pub fn settle_failed_result(request: &Value, row: &Value, plan: &Value, effect: &Value) -> Value {
    if get(effect, "effect_may_have_occurred") == Some(&Value::Bool(true)) {
        let mut receipt = get(plan, "patch")
            .and_then(|p| get(p, "receipt"))
            .cloned()
            .unwrap_or(json!({}));
        if let Value::Object(map) = &mut receipt {
            map.insert("outcome".into(), json!("ambiguous"));
            map.insert("failure_code".into(), json!("E_AGENT_EXECUTION_AMBIGUOUS"));
        }
        let mut map = identity_fields(request);
        map.insert("status".into(), json!("ambiguous"));
        map.insert(
            "result_execution_revision".into(),
            or_null(get(row, "row_revision")),
        );
        map.insert("transcript".into(), or_null(get(request, "transcript")));
        map.insert("receipt".into(), receipt);
        map.insert("effect_may_have_occurred".into(), json!(true));
        map.insert("failure_code".into(), json!("E_AGENT_EXECUTION_AMBIGUOUS"));
        return Value::Object(map);
    }
    unknown_result(request, row, "E_AGENT_LEDGER")
}

// MARK: - recover

/// `recoverAgentToolWithRequest:` after the executor's recovery probe:
/// `{settle: {cas, patch, message, operation}}` when the effect settled and
/// the row was still active, else `{result}`.
pub fn recover_plan(request: &Value, row: &Value, recovered: &Value) -> Result<Value, StoreError> {
    let name = as_str(get(request, "name")).unwrap_or_default();
    let status = as_str(get(recovered, "status")).unwrap_or_default();
    let precondition = get(row, "precondition");
    if status == "settled"
        && matches!(
            as_str(get(row, "state")),
            Some("running" | "cancel_requested")
        )
    {
        if crate::runtime_tools::is_runtime(name) || crate::assistant_tools::is_assistant(name) {
            if let Some(effect) = get(recovered, "effect").filter(|e| {
                if crate::assistant_tools::is_assistant(name) {
                    crate::assistant_tools::effect_valid(row, e)
                } else {
                    crate::runtime_tools::effect_valid(row, e)
                }
            }) {
                let recovery_sha = hash_json(
                    "agent-operation-request",
                    &json!({ "operation_kind": "execute_agent_tool", "request": request }),
                )
                .ok_or(StoreError::InvalidArgument)?;
                return Ok(
                    json!({ "settle": settlement_plan(request, row, effect, Some(&json!(recovery_sha)), 0)? }),
                );
            }
        }
        let mut payload: Option<Value> = None;
        let mut facts: Option<Value> = None;
        if name == "write_file"
            && bounded_utf8(get(recovered, "actual_revision"), 256, false).is_some()
        {
            payload = Some(json!({
                "schema_version": 1,
                "bytes": precondition.and_then(|p| get(p, "content_bytes")),
                "revision": get(recovered, "actual_revision"),
            }));
            facts = Some(json!({
                "schema_version": 1, "kind": "write_file",
                "actual_revision": get(recovered, "actual_revision"),
                "content_sha256": precondition.and_then(|p| get(p, "content_sha256")),
            }));
        } else if name == "git_commit"
            && equal(
                get(recovered, "actual_commit_oid"),
                precondition.and_then(|p| get(p, "expected_commit_oid")),
            )
        {
            payload = Some(json!({
                "schema_version": 1,
                "commit_oid": get(recovered, "actual_commit_oid"),
                "tree_oid": precondition.and_then(|p| get(p, "tree_oid")),
            }));
            facts = Some(
                json!({ "schema_version": 1, "kind": "git_commit", "actual_commit_oid": get(recovered, "actual_commit_oid") }),
            );
        } else if name == "git_push"
            && equal(
                get(recovered, "actual_remote_oid"),
                precondition.and_then(|p| get(p, "target_oid")),
            )
        {
            payload = Some(json!({
                "schema_version": 1, "remote": "origin",
                "remote_ref": precondition.and_then(|p| get(p, "remote_ref")),
                "pushed_oid": get(recovered, "actual_remote_oid"),
            }));
            facts = Some(
                json!({ "schema_version": 1, "kind": "git_push", "actual_remote_oid": get(recovered, "actual_remote_oid") }),
            );
        }
        if let (Some(payload), Some(facts)) = (payload, facts) {
            let feedback = feedback_string(
                &json!({ "schema_version": 1, "name": name, "outcome": "ok", "payload": payload }),
            )?;
            let result_sha = hash_bytes("tool-result", feedback.as_bytes())
                .ok_or(StoreError::InvalidArgument)?;
            let receipt = json!({
                "schema_version": 1, "call_id": get(request, "call_id"),
                "name": name,
                "arguments_sha256": get(request, "arguments_sha256"),
                "result_sha256": result_sha,
                "result_bytes": feedback.len(), "truncated": false,
                "duration_ms": 0, "outcome": "ok",
                "failure_code": Value::Null,
                "approval_reference": get(request, "approval_reference"),
            });
            let recovery_sha = hash_json(
                "agent-operation-request",
                &json!({ "operation_kind": "execute_agent_tool", "request": request }),
            )
            .ok_or(StoreError::InvalidArgument)?;
            return Ok(json!({ "settle": {
                "cas": execution_cas(row, as_str(get(row, "state")).unwrap_or_default()),
                "patch": { "state": "settled", "settled_facts": facts, "receipt": receipt },
                "message": {
                    "schema_version": 1, "role": "tool",
                    "round_index": get(request, "round_index"),
                    "call_id": get(request, "call_id"), "content": feedback,
                    "truncated": false,
                },
                "operation": {
                    "operation_id": get(request, "operation_id"),
                    "request_sha256": recovery_sha,
                    "effect_may_have_occurred": true,
                },
            }}));
        }
    }
    Ok(json!({ "result": {
        "schema_version": 2,
        "status": if status == "settled" { "manual_reconciliation" } else { status },
        "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
        "call_index": get(request, "call_index"), "call_id": get(request, "call_id"),
        "idempotency_key": get(request, "idempotency_key"),
        "execution_revision": get(row, "row_revision"),
        "effect_may_have_occurred": status != "not_dispatched",
    }}))
}

/// `DSHAgentExecutionRawCall`'s parse for recovery (no digest check).
pub fn recover_arguments(
    request: &Value,
    messages: Option<&[Value]>,
) -> Option<Map<String, Value>> {
    let messages = messages?;
    let raw = messages
        .iter()
        .filter(|m| {
            string_eq(get(m, "role"), "assistant")
                && equal(get(m, "round_index"), get(request, "round_index"))
        })
        .flat_map(|m| array(get(m, "tool_calls")).iter())
        .find(|call| {
            equal(get(call, "call_id"), get(request, "call_id"))
                && equal(get(call, "name"), get(request, "name"))
        })?;
    as_str(get(raw, "arguments_json")).and_then(parse_arguments)
}

// MARK: - JSON envelope

/// `{"op","request",...}` in; `{"ok":true,...}` or `{"ok":false,"error":<code>}` out.
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
    let messages = || match get(&envelope, "messages") {
        Some(Value::Array(items)) => Some(items.as_slice()),
        _ => None,
    };
    match op {
        "question_response" => {
            let row = field("row")?;
            if request["name"] != crate::user_question::NAME
                || row["name"] != crate::user_question::NAME
                || !crate::user_question::question_shape(row.get("precondition"))
                || !crate::user_question::response_valid(
                    &row["precondition"]["question"],
                    &request["user_response"],
                )
            {
                return Err(StoreError::InvalidArgument);
            }
            if row["state"] == "settled"
                && crate::canonical::hash_json("agent-user-response", &request["user_response"])
                    .as_deref()
                    != row["settled_facts"]["response_sha256"].as_str()
            {
                return Err(StoreError::Conflict);
            }
            Ok(json!({}))
        }
        "question_settlement" => crate::user_question::settlement(
            request,
            field("row")?,
            field("arguments")?,
            field("request_sha256")?,
        ),
        "request" => {
            execute_request(request)?;
            Ok(json!({}))
        }
        "session_matches" => Ok(json!({ "matches": committed_session_matches(
            request,
            get(&envelope, "conversation").filter(|c| !c.is_null()),
            get(&envelope, "require_execution_intent") == Some(&Value::Bool(true)),
        )})),
        "row" => Ok(json!({ "row": execution_row(array(get(&envelope, "ledger")), request) })),
        "precheck" => execute_precheck(
            request,
            &ExecuteView {
                authority: get(&envelope, "authority").filter(|a| !a.is_null()),
                batches: array(get(&envelope, "batches")),
                ledger: array(get(&envelope, "ledger")),
                operation_results: array(get(&envelope, "operation_results")),
                conversation: get(&envelope, "conversation").filter(|c| !c.is_null()),
                root_ok: get(&envelope, "root_ok") == Some(&Value::Bool(true)),
                dispatch_state: as_str(get(&envelope, "dispatch_state")),
                owner_alive: get(&envelope, "owner_alive") == Some(&Value::Bool(true)),
            },
        ),
        "conflict" => Ok(json!({ "result": conflict_result(
            request,
            get(&envelope, "row").filter(|r| !r.is_null()),
            as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?,
        )})),
        "arguments" => {
            Ok(json!({ "arguments": execute_arguments(request, messages()).map(Value::Object) }))
        }
        "recover_arguments" => {
            Ok(json!({ "arguments": recover_arguments(request, messages()).map(Value::Object) }))
        }
        "effect_gate" => Ok(
            json!({ "needed": needs_effect_gate(request), "request": effect_gate_request(request) }),
        ),
        "execution_cas" => Ok(
            json!({ "cas": execution_cas(field("row")?, as_str(get(&envelope, "state")).ok_or(StoreError::InvalidArgument)?) }),
        ),
        "active_result" => Ok(json!({ "result": active_result(
            request,
            field("row")?,
            as_str(get(&envelope, "status")).ok_or(StoreError::InvalidArgument)?,
            get(&envelope, "effect_may_have_occurred") == Some(&Value::Bool(true)),
        )})),
        "safe_result" => Ok(json!({ "result": safe_result(request, field("row")?) })),
        "generic_failure" => Ok(json!({ "effect": generic_failure_effect(get(request, "name"))? })),
        "assistant_failure" => Ok(json!({"effect":assistant_failure_effect(
            as_str(get(request,"name")).ok_or(StoreError::InvalidArgument)?,
            as_str(get(&envelope,"failure_code")).ok_or(StoreError::InvalidArgument)?)?})),
        "ambiguous_effect" => Ok(json!({ "effect": ambiguous_effect(get(request, "name"))? })),
        "settlement" => settlement_plan(
            request,
            field("row")?,
            field("effect")?,
            get(&envelope, "request_sha256"),
            get(&envelope, "duration_ms")
                .and_then(Value::as_u64)
                .unwrap_or(0),
        ),
        "settle_failed" => Ok(
            json!({ "result": settle_failed_result(request, field("row")?, field("plan")?, field("effect")?) }),
        ),
        "recover" => recover_plan(request, field("row")?, field("recovered")?),
        _ => Err(StoreError::InvalidArgument),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(state: &str) -> Value {
        json!({
            "locator": { "task_id": "t", "attempt_id": "a", "round_id": "r", "round_index": 0, "call_index": 0, "call_id": "c", "idempotency_key": "k" },
            "state": state, "row_revision": 3, "owner": Value::Null,
            "transcript_before": { "generation": 1, "transcript_sha256": "s" },
            "root_fingerprint_sha256": "f", "binding_revision": 1,
            "receipt": { "outcome": "ok" }, "transcript_after": { "generation": 2 },
        })
    }

    #[test]
    fn results_follow_the_row() {
        let request = json!({ "operation_id": "o", "task_id": "t", "attempt_id": "a", "round_id": "r", "round_index": 0, "call_index": 0, "call_id": "c", "name": "read_file", "idempotency_key": "k", "transcript": { "generation": 1 }, "approval_reference": Value::Null, "arguments_sha256": "x" });
        let settled = safe_result(&request, &row("settled"));
        assert_eq!(settled["status"], "completed");
        assert_eq!(settled["effect_may_have_occurred"], true);
        let cas = execution_cas(&row("running"), "running");
        assert_eq!(cas["expected_owner_generation"], Value::Null);
        assert_eq!(cas["expected_row_revision"], 3);
        let conflict = conflict_result(&request, None, "E_AGENT_CONFLICT");
        assert_eq!(conflict["actual_status"], "intent");
        assert_eq!(conflict["actual_execution_revision"], 0);
        let ambiguous = ambiguous_result(&request, &row("running")).unwrap();
        assert_eq!(ambiguous["receipt"]["outcome"], "ambiguous");
    }

    #[test]
    fn recovery_settles_only_matching_facts() {
        let request = json!({ "operation_id": "o", "task_id": "t", "attempt_id": "a", "round_id": "r", "round_index": 0, "call_index": 0, "call_id": "c", "name": "git_commit", "idempotency_key": "k", "arguments_sha256": "x", "approval_reference": Value::Null });
        let mut row = row("running");
        row["precondition"] = json!({ "expected_commit_oid": "abc", "tree_oid": "tree" });
        let plan = recover_plan(
            &request,
            &row,
            &json!({ "status": "settled", "actual_commit_oid": "abc" }),
        )
        .unwrap();
        assert_eq!(plan["settle"]["patch"]["state"], "settled");
        let other = recover_plan(
            &request,
            &row,
            &json!({ "status": "settled", "actual_commit_oid": "zzz" }),
        )
        .unwrap();
        assert_eq!(other["result"]["status"], "manual_reconciliation");
        let idle = recover_plan(&request, &row, &json!({ "status": "not_dispatched" })).unwrap();
        assert_eq!(idle["result"]["effect_may_have_occurred"], false);
    }
}
