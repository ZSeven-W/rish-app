//! The runtime coordinator's decisions, ported from `AgentRuntimeCoordinator.mm`.
//!
//! This first cut covers the read-only half: request shapes, the session proof
//! every controller-facing operation starts from, and the tool and attempt
//! projections. The host keeps the stores, the transactions and the executors;
//! it loads the session snapshot and the WAL state and passes both in, and
//! calls the typed services itself, handing their answers back as facts.

use serde_json::{json, Map, Value};

use crate::canonical::hash_json;
use crate::schema::{
    canonical_sha256, canonical_timestamp, canonical_uuid, exact_keys, is_null, safe_integer,
    MAX_SAFE_INTEGER,
};
use crate::store::StoreError;

fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key)
}

fn at<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    value.and_then(|value| value.get(key))
}

fn as_str(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str)
}

fn array(value: Option<&Value>) -> &[Value] {
    value.and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

fn owned(value: Option<&Value>) -> Value {
    value.cloned().unwrap_or(Value::Null)
}

fn u64_of(value: Option<&Value>) -> u64 {
    value.and_then(Value::as_u64).unwrap_or(0)
}

/// The exact keys each controller-facing request carries. `DSHRuntimeRequest`
/// additionally pins `schema_version` to 2.
fn request_keys(op: &str) -> Option<&'static [&'static str]> {
    Some(match op {
        "query_tool" => &[
            "schema_version",
            "controller_cas",
            "task_id",
            "conversation_id",
            "attempt_id",
            "round_id",
            "round_index",
            "call_index",
            "call_id",
            "idempotency_key",
            "expected_execution_revision",
            "expected_transcript",
            "expected_root_fingerprint_sha256",
            "expected_workspace_binding_revision",
        ],
        "query_attempt" => &[
            "schema_version",
            "controller_cas",
            "task_id",
            "conversation_id",
            "attempt_id",
            "expected_journal_revision",
            "expected_session_generation",
            "expected_session_sha256",
            "expected_transcript",
            "expected_root_fingerprint_sha256",
            "expected_workspace_binding_revision",
        ],
        _ => return None,
    })
}

/// `DSHRuntimeControllerMatchesIdentity`.
fn controller_matches_identity(request: &Value) -> bool {
    let cas = get(request, "controller_cas");
    cas.is_some_and(Value::is_object)
        && at(cas, "conversation_id") == get(request, "conversation_id")
        && at(cas, "task_id") == get(request, "task_id")
        && at(cas, "attempt_id") == get(request, "attempt_id")
}

/// `DSHRuntimeRequest` plus the identity check every query starts with.
pub fn request_shape(op: &str, request: &Value) -> Result<(), StoreError> {
    let Some(keys) = request_keys(op) else {
        return Err(StoreError::InvalidArgument);
    };
    if exact_keys(Some(request), keys).is_none()
        || get(request, "schema_version") != Some(&json!(2))
        || !controller_matches_identity(request)
    {
        return Err(StoreError::InvalidArgument);
    }
    Ok(())
}

/// The execution locator `queryAgentTool` builds from its request.
pub fn tool_locator(request: &Value) -> Value {
    json!({
        "schema_version": 2,
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "call_index": get(request, "call_index"),
        "call_id": get(request, "call_id"),
        "idempotency_key": get(request, "idempotency_key"),
    })
}

/// `DSHRuntimeChildOperationID`: a stable UUID derived from the parent
/// operation and a purpose, so a retried parent names the same child.
pub fn child_operation_id(operation_id: &Value, purpose: &str) -> Option<String> {
    let digest = hash_json(
        "agent-child-operation",
        &json!({ "operation_id": operation_id, "purpose": purpose }),
    )?;
    if digest.len() != 64 {
        return None;
    }
    let mut hex: Vec<u8> = digest.as_bytes()[..32].to_vec();
    hex[12] = b'4';
    let nibble = match hex[16] {
        digit @ b'0'..=b'9' => digit - b'0',
        letter => 10 + letter - b'a',
    };
    hex[16] = std::char::from_digit(u32::from((nibble & 0x3) | 0x8), 16)? as u8;
    let hex = String::from_utf8(hex).ok()?;
    Some(format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    ))
}

/// `DSHRuntimeSessionProof`: the committed session must still say what the
/// controller thinks it says. `facts` carries what the host read beside the
/// session bytes — the snapshot's generation and digest.
pub fn session_proof(
    session: &Value,
    facts: &Value,
    expectations: &Value,
) -> Result<Value, StoreError> {
    if get(session, "schema_version") != Some(&json!(9))
        || !get(session, "conversations").is_some_and(Value::is_array)
        || !get(session, "session_events").is_some_and(Value::is_array)
    {
        return Err(StoreError::Corrupt);
    }
    let conversation = array(get(session, "conversations"))
        .iter()
        .find(|candidate| get(candidate, "id") == get(expectations, "conversation_id"));
    let attempt = array(conversation.and_then(|c| get(c, "attempts")))
        .iter()
        .find(|candidate| get(candidate, "attempt_id") == get(expectations, "attempt_id"));
    let controller = attempt
        .and_then(|attempt| get(attempt, "agent"))
        .and_then(|agent| get(agent, "controller_generation"));
    let journal = attempt.and_then(|attempt| get(attempt, "journal_revision"));
    if attempt.and_then(|attempt| get(attempt, "turn_id")) != get(expectations, "task_id")
        || safe_integer(controller, MAX_SAFE_INTEGER, true).is_none()
        || safe_integer(journal, MAX_SAFE_INTEGER, true).is_none()
    {
        return Err(StoreError::Conflict);
    }
    let generation = get(facts, "session_generation");
    let digest = get(facts, "session_sha256");
    let matches = controller == get(expectations, "expected_controller_generation")
        && journal == get(expectations, "expected_journal_revision")
        && generation == get(expectations, "expected_session_generation")
        && digest == get(expectations, "expected_session_sha256");
    Ok(json!({
        "matches": matches,
        "controller_generation": controller,
        "journal_revision": journal,
        "session_generation": generation,
        "session_sha256": digest,
    }))
}

/// `readAgentRoundPresentations`' own request shape and ownership check.
pub fn presentations_request(request: &Value) -> Result<(), StoreError> {
    if exact_keys(
        Some(request),
        &["schema_version", "conversation_id", "attempt_id"],
    )
    .is_none()
        || get(request, "schema_version") != Some(&json!(1))
        || !canonical_uuid(get(request, "conversation_id"))
        || !canonical_uuid(get(request, "attempt_id"))
    {
        return Err(StoreError::InvalidArgument);
    }
    Ok(())
}

/// Whether the committed session still lists this attempt under this
/// conversation; a presentation read of an attempt the session does not own is
/// not found rather than empty.
pub fn session_owns_attempt(session: &Value, conversation_id: &Value, attempt_id: &Value) -> bool {
    array(get(session, "conversations"))
        .iter()
        .filter(|conversation| get(conversation, "id") == Some(conversation_id))
        .any(|conversation| {
            array(get(conversation, "attempts"))
                .iter()
                .any(|attempt| get(attempt, "attempt_id") == Some(attempt_id))
        })
}

/// `DSHRuntimeFindLedgerRow`.
fn find_ledger_row<'a>(state: &'a Value, locator: &Value) -> Option<&'a Value> {
    array(get(state, "ledger"))
        .iter()
        .find(|row| get(row, "locator") == Some(locator))
}

/// `DSHRuntimeFindAuthority`.
fn find_authority<'a>(
    state: &'a Value,
    task_id: Option<&Value>,
    attempt_id: Option<&Value>,
) -> Option<&'a Value> {
    array(get(state, "authorities"))
        .iter()
        .find(|row| get(row, "task_id") == task_id && get(row, "attempt_id") == attempt_id)
}

/// `DSHRuntimeReferenceForRow`: a settled row speaks through the transcript it
/// produced, an unsettled one through the transcript it was written against.
fn reference_for_row(row: &Value) -> Value {
    match get(row, "transcript_after") {
        Some(after) if !after.is_null() => after.clone(),
        _ => owned(get(row, "transcript_before")),
    }
}

/// `DSHRuntimeToolStatus`.
fn tool_status(row: &Value) -> Value {
    let state = get(row, "state");
    if !string_eq(state, "settled") {
        return owned(state);
    }
    match as_str(get(row, "receipt").and_then(|receipt| get(receipt, "outcome"))) {
        Some("ok") => json!("completed"),
        Some("denied") => json!("denied"),
        _ => json!("failed"),
    }
}

/// `DSHRuntimeToolProjection`.
pub fn tool_projection(row: &Value) -> Value {
    let locator = get(row, "locator");
    json!({
        "schema_version": 2,
        "task_id": at(locator, "task_id"),
        "attempt_id": at(locator, "attempt_id"),
        "round_id": at(locator, "round_id"),
        "round_index": at(locator, "round_index"),
        "call_index": at(locator, "call_index"),
        "call_id": at(locator, "call_id"),
        "name": get(row, "name"),
        "arguments_sha256": get(row, "arguments_sha256"),
        "idempotency_key": at(locator, "idempotency_key"),
        "execution_revision": get(row, "row_revision"),
        "status": tool_status(row),
        "transcript": reference_for_row(row),
        "receipt": get(row, "receipt"),
    })
}

fn execution_conflict(failure_code: &str, request: &Value, actual: Value) -> Value {
    json!({
        "schema_version": 2,
        "status": "conflict",
        "failure_code": failure_code,
        "expected_execution_revision": get(request, "expected_execution_revision"),
        "actual_execution_revision": actual,
    })
}

/// The conflict a tool query reports when the session no longer matches the
/// controller's checkpoint: the revision the ledger actually holds, or zero.
pub fn query_tool_session_conflict(state: &Value, request: &Value) -> Value {
    let locator = tool_locator(request);
    let actual = find_ledger_row(state, &locator)
        .and_then(|row| get(row, "row_revision"))
        .cloned()
        .unwrap_or(json!(0));
    execution_conflict("E_AGENT_CONFLICT", request, actual)
}

/// The conflict a tool query reports when the ledger itself refused: a root
/// that moved and a transcript that moved are named apart from a plain
/// revision conflict.
pub fn query_tool_ledger_conflict(state: &Value, request: &Value) -> Value {
    let locator = tool_locator(request);
    let row = find_ledger_row(state, &locator);
    let failure_code = match row {
        Some(row)
            if get(row, "root_fingerprint_sha256")
                != get(request, "expected_root_fingerprint_sha256")
                || get(row, "binding_revision")
                    != get(request, "expected_workspace_binding_revision") =>
        {
            "E_AGENT_ROOT_STALE"
        }
        Some(row) if get(row, "transcript_before") != get(request, "expected_transcript") => {
            "E_AGENT_TRANSCRIPT"
        }
        _ => "E_AGENT_CONFLICT",
    };
    let actual = row
        .and_then(|row| get(row, "row_revision"))
        .cloned()
        .unwrap_or(json!(0));
    execution_conflict(failure_code, request, actual)
}

/// The answer a tool query gives once the ledger has spoken.
pub fn query_tool_result(queried: &Value, request: &Value) -> Value {
    if string_eq(get(queried, "status"), "not_started") {
        if get(request, "expected_execution_revision") == Some(&json!(0)) {
            return queried.clone();
        }
        return execution_conflict("E_AGENT_CONFLICT", request, json!(0));
    }
    let row = get(queried, "row").unwrap_or(&Value::Null);
    if get(row, "row_revision") != get(request, "expected_execution_revision") {
        return execution_conflict("E_AGENT_CONFLICT", request, owned(get(row, "row_revision")));
    }
    let tool = tool_projection(row);
    json!({
        "schema_version": 2,
        "status": get(&tool, "status"),
        "tool": tool,
    })
}

fn attempt_conflict(failure_code: &str, request: &Value, proof: &Value) -> Value {
    json!({
        "schema_version": 2,
        "status": "conflict",
        "failure_code": failure_code,
        "expected_journal_revision": get(request, "expected_journal_revision"),
        "actual_journal_revision": get(proof, "journal_revision"),
        "expected_session_generation": get(request, "expected_session_generation"),
        "actual_session_generation": get(proof, "session_generation"),
    })
}

/// An attempt query pins the checkpoint twice: once through the controller's
/// own CAS and once through the request's expectations.
pub fn query_attempt_session_conflict(request: &Value, proof: &Value) -> Option<Value> {
    let request_matches = get(proof, "journal_revision")
        == get(request, "expected_journal_revision")
        && get(proof, "session_generation") == get(request, "expected_session_generation")
        && get(proof, "session_sha256") == get(request, "expected_session_sha256");
    if get(proof, "matches") == Some(&json!(true)) && request_matches {
        return None;
    }
    Some(attempt_conflict("E_AGENT_CONFLICT", request, proof))
}

/// The prepared authority the store handed back has to be the one the request
/// names, on the root and transcript the request expects.
pub fn query_attempt_base_conflict(base: &Value, request: &Value, proof: &Value) -> Option<Value> {
    let root = get(base, "root");
    if get(base, "conversation_id") == get(request, "conversation_id")
        && get(base, "transcript") == get(request, "expected_transcript")
        && at(root, "root_fingerprint_sha256") == get(request, "expected_root_fingerprint_sha256")
        && at(root, "workspace_binding_revision")
            == get(request, "expected_workspace_binding_revision")
    {
        return None;
    }
    Some(attempt_conflict("E_AGENT_ROOT_STALE", request, proof))
}

/// `DSHRuntimeLatestRound`.
fn latest_round<'a>(
    state: &'a Value,
    task_id: Option<&Value>,
    attempt_id: Option<&Value>,
) -> Option<&'a Value> {
    let mut latest: Option<&Value> = None;
    for row in array(get(state, "rounds")) {
        let locator = get(row, "locator");
        if at(locator, "task_id") != task_id || at(locator, "attempt_id") != attempt_id {
            continue;
        }
        let index = u64_of(at(locator, "round_index"));
        let better = latest.is_none_or(|latest| {
            index > u64_of(get(latest, "locator").and_then(|l| get(l, "round_index")))
        });
        if better {
            latest = Some(row);
        }
    }
    latest
}

/// `DSHRuntimeLatestBatch`: the highest round, and within it the highest
/// revision.
fn latest_batch<'a>(
    state: &'a Value,
    task_id: Option<&Value>,
    attempt_id: Option<&Value>,
) -> Option<&'a Value> {
    let mut latest: Option<&Value> = None;
    for row in array(get(state, "batches")) {
        if get(row, "task_id") != task_id || get(row, "attempt_id") != attempt_id {
            continue;
        }
        let better = latest.is_none_or(|latest| {
            u64_of(get(row, "round_index")) > u64_of(get(latest, "round_index"))
                || (get(row, "round_index") == get(latest, "round_index")
                    && u64_of(get(row, "batch_revision")) > u64_of(get(latest, "batch_revision")))
        });
        if better {
            latest = Some(row);
        }
    }
    latest
}

/// `DSHRuntimeLatestBatchCalls`: the prepare-time projection is the source of
/// safe summaries, previews and approval envelopes; the persisted bind
/// decisions and ledger settlements are merged onto it so a recovery after a
/// kill replays decisions and denial receipts instead of re-presenting calls
/// that are already settled.
pub fn latest_batch_calls(state: &Value, batch: &Value) -> Value {
    if batch.is_null() {
        return json!([]);
    }
    let snapshots = array(get(state, "operation_results"));
    let prepared = snapshots.iter().rev().find_map(|snapshot| {
        let wrapper = get(snapshot, "result");
        let receipt = at(wrapper, "result").and_then(|result| get(result, "receipt"));
        let bound = |key: &str| at(receipt, key) == get(batch, key);
        if string_eq(at(wrapper, "result_kind"), "prepare_agent_tool_batch")
            && bound("task_id")
            && bound("attempt_id")
            && bound("round_id")
            && bound("batch_revision")
        {
            at(receipt, "calls")
        } else {
            None
        }
    });
    let Some(prepared) = prepared else {
        return json!([]);
    };
    let mut merged = Vec::with_capacity(array(Some(prepared)).len());
    for projection in array(Some(prepared)) {
        let mut call = projection.as_object().cloned().unwrap_or_default();
        for snapshot in snapshots.iter().rev() {
            let wrapper = get(snapshot, "result");
            if !string_eq(at(wrapper, "result_kind"), "bind_agent_approval") {
                continue;
            }
            let result = at(wrapper, "result").and_then(|result| get(result, "result"));
            if !matches!(
                as_str(at(result, "status")),
                Some("bound" | "already_bound")
            ) {
                continue;
            }
            if at(result, "task_id") != get(batch, "task_id")
                || at(result, "attempt_id") != get(batch, "attempt_id")
                || at(result, "round_id") != get(batch, "round_id")
                || at(result, "call_index") != call.get("call_index")
                || at(result, "call_id") != call.get("call_id")
            {
                continue;
            }
            let decision = as_str(at(result, "decision")).unwrap_or_default();
            if matches!(decision, "denied" | "cancelled") {
                call.insert("approval_state".into(), json!(decision));
                call.insert("approval_token".into(), Value::Null);
                call.insert("approval_reference".into(), Value::Null);
            } else {
                call.insert("approval_state".into(), json!("bound"));
                call.insert(
                    "approval_reference".into(),
                    owned(at(result, "approval_reference")),
                );
            }
            if decision == "denied" && at(result, "receipt").is_some_and(Value::is_object) {
                call.insert("execution_status".into(), json!("denied"));
                call.insert("receipt".into(), owned(at(result, "receipt")));
            }
            break;
        }
        for row in array(get(state, "ledger")) {
            let locator = get(row, "locator");
            let bound = |key: &str| at(locator, key) == get(batch, key);
            let call_bound = |key: &str| at(locator, key) == call.get(key);
            if !bound("task_id")
                || !bound("attempt_id")
                || !bound("round_id")
                || !bound("round_index")
                || !call_bound("call_index")
                || !call_bound("call_id")
                || !call_bound("idempotency_key")
            {
                continue;
            }
            call.insert(
                "native_row_revision".into(),
                owned(get(row, "row_revision")),
            );
            if string_eq(get(row, "state"), "settled") {
                call.insert("execution_status".into(), tool_status(row));
                call.insert("receipt".into(), owned(get(row, "receipt")));
                call.insert("execution_revision".into(), owned(get(row, "row_revision")));
            }
            break;
        }
        merged.push(Value::Object(call));
    }
    Value::Array(merged)
}

/// The attempt an attempt query returns: the prepared authority, the
/// controller's own counters, and whatever the latest round and batch say
/// about the phase it is in.
pub fn query_attempt_projection(
    state: &Value,
    base: &Value,
    proof: &Value,
    request: &Value,
) -> Value {
    let task_id = get(request, "task_id");
    let attempt_id = get(request, "attempt_id");
    let mut attempt = base.as_object().cloned().unwrap_or_default();
    if let Some(frozen) = crate::session_schema::frozen_ids_for_projection(proof, request, base) {
        attempt.insert("frozen_grant_ids".into(), frozen);
    }
    attempt.insert(
        "controller_generation".into(),
        owned(get(proof, "controller_generation")),
    );
    attempt.insert(
        "journal_revision".into(),
        owned(get(proof, "journal_revision")),
    );
    if let Some(round) = latest_round(state, task_id, attempt_id) {
        let locator = get(round, "locator");
        let state_name = as_str(get(round, "state")).unwrap_or_default();
        attempt.insert("round_id".into(), owned(at(locator, "round_id")));
        attempt.insert("round_index".into(), owned(at(locator, "round_index")));
        attempt.insert("round_revision".into(), owned(get(round, "row_revision")));
        attempt.insert(
            "round_status".into(),
            if state_name == "in_flight" {
                json!("active")
            } else {
                json!(state_name)
            },
        );
        match state_name {
            "in_flight" | "cancel_requested" => {
                attempt.insert("phase".into(), json!("round_in_flight"));
            }
            "cancelled" => {
                attempt.insert("phase".into(), json!("cancelled"));
            }
            "unknown" | "ambiguous" => {
                attempt.insert("phase".into(), json!(state_name));
            }
            _ => {}
        }
    }
    if let Some(batch) = latest_batch(state, task_id, attempt_id) {
        let calls = latest_batch_calls(state, batch);
        if let Some(frozen) = crate::session_schema::frozen_ids_after_lost_prepare(
            state, batch, &calls, proof, request, base,
        ) {
            attempt.insert("frozen_grant_ids".into(), frozen);
        }
        attempt.insert("batch_kind".into(), owned(get(batch, "kind")));
        attempt.insert("batch_revision".into(), owned(get(batch, "batch_revision")));
        attempt.insert(
            "manifest_sha256".into(),
            owned(get(batch, "manifest_sha256")),
        );
        // A batch whose every call already holds a receipt (executed, denied
        // or refused at preparation) is waiting for the next round; approval
        // checks only concern calls that are still unsettled.
        let calls_array = array(Some(&calls));
        let mut all_settled = !calls_array.is_empty();
        let mut pending_approval = false;
        for call in calls_array {
            let settled = get(call, "receipt").is_some_and(|receipt| !receipt.is_null());
            if !settled {
                all_settled = false;
                if string_eq(get(call, "approval_state"), "pending") {
                    pending_approval = true;
                }
            }
        }
        attempt.insert(
            "phase".into(),
            if all_settled {
                json!("tool_result_pending")
            } else if pending_approval {
                json!("approval_pending")
            } else {
                json!("batch_frozen")
            },
        );
        attempt.insert("batch".into(), calls);
    }
    let authority_state =
        find_authority(state, task_id, attempt_id).and_then(|row| get(row, "state"));
    let status = if matches!(
        as_str(authority_state),
        Some("terminal" | "cleanup_pending")
    ) {
        "terminal"
    } else {
        "active"
    };
    json!({ "schema_version": 2, "status": status, "attempt": Value::Object(attempt) })
}

/// `DSHRuntimeCleanupOutboxProof`: the committed session's cleanup outbox has
/// to hold exactly this cleanup, described exactly as the request describes it.
pub fn cleanup_outbox_proof(session: &Value, request: &Value) -> bool {
    let outbox = get(session, "agent_transcript_cleanup_outbox");
    if get(session, "schema_version") != Some(&json!(9)) || !outbox.is_some_and(Value::is_array) {
        return false;
    }
    let mut matched: Option<&Value> = None;
    for candidate in array(outbox) {
        if get(candidate, "cleanup_id") != get(request, "cleanup_id") {
            continue;
        }
        if matched.is_some() {
            return false;
        }
        matched = Some(candidate);
    }
    let keys = [
        "schema_version",
        "cleanup_id",
        "conversation_id",
        "task_id",
        "attempt_id",
        "transcript_ref",
        "transcript_sha256",
        "reason",
        "created_at",
    ];
    let bound = |key: &str| at(matched, key) == get(request, key);
    exact_keys(matched, &keys).is_some()
        && at(matched, "schema_version") == Some(&json!(1))
        && bound("conversation_id")
        && bound("task_id")
        && bound("attempt_id")
        && bound("transcript_ref")
        && bound("transcript_sha256")
        && matches!(
            as_str(at(matched, "reason")),
            Some("completed" | "cancelled" | "failed" | "conversation_deleted")
        )
        && canonical_timestamp(at(matched, "created_at"))
}

/// `DSHRuntimeCancelSourceProof`: a cancellation is only honoured when the
/// committed session holds exactly one matching cancel event, issued by the
/// completion controller for the phase the attempt is actually in.
pub fn cancel_source_proof(session: &Value, request: &Value) -> bool {
    let target = get(request, "target");
    let token = get(request, "cancel_token");
    let token_keys = [
        "schema_version",
        "issuer",
        "source_event_id",
        "token",
        "task_id",
        "attempt_id",
        "expected_phase",
        "reason_code",
    ];
    let token_shape = exact_keys(token, &token_keys).is_some()
        && at(token, "schema_version") == Some(&json!(2))
        && string_eq(at(token, "issuer"), "completion_controller")
        && canonical_uuid(at(token, "source_event_id"))
        && at(token, "token") == at(token, "source_event_id")
        && canonical_uuid(at(token, "task_id"))
        && canonical_uuid(at(token, "attempt_id"))
        && matches!(
            as_str(at(token, "expected_phase")),
            Some(
                "ready_for_round"
                    | "batch_frozen"
                    | "round_in_flight"
                    | "approval_pending"
                    | "execution_intent"
                    | "tool_result_pending"
            )
        )
        && matches!(
            as_str(at(token, "reason_code")),
            Some("E_AGENT_CANCELLED" | "E_AGENT_ROOT_STALE" | "E_AGENT_PERSISTENCE")
        )
        && at(token, "task_id") == at(target, "task_id")
        && at(token, "attempt_id") == at(target, "attempt_id");
    if get(session, "schema_version") != Some(&json!(9)) || !token_shape {
        return false;
    }
    let conversation_id = at(get(request, "controller_cas"), "conversation_id");
    let conversation = array(get(session, "conversations"))
        .iter()
        .find(|candidate| get(candidate, "id") == conversation_id);
    let attempt = array(conversation.and_then(|c| get(c, "attempts")))
        .iter()
        .find(|candidate| get(candidate, "attempt_id") == at(target, "attempt_id"));
    let agent = attempt.and_then(|attempt| get(attempt, "agent"));
    if attempt.and_then(|attempt| get(attempt, "turn_id")) != at(target, "task_id")
        || at(agent, "phase") != at(token, "expected_phase")
    {
        return false;
    }
    let mut matched: Option<&Value> = None;
    for event in array(get(session, "session_events")) {
        if get(event, "event_id") != at(token, "source_event_id") {
            continue;
        }
        if matched.is_some() {
            return false;
        }
        matched = Some(event);
    }
    let event_keys = [
        "schema_version",
        "event_id",
        "attempt_id",
        "seq",
        "kind",
        "round_index",
        "call_id",
        "status",
        "safe_summary_key",
        "arguments_sha256",
        "result_sha256",
        "approval_reference",
        "failure_code",
        "created_at",
    ];
    let event_shape = exact_keys(matched, &event_keys).is_some()
        && at(matched, "schema_version") == Some(&json!(2))
        && string_eq(at(matched, "kind"), "cancel")
        && canonical_uuid(at(matched, "event_id"))
        && canonical_uuid(at(matched, "attempt_id"))
        && safe_integer(at(matched, "seq"), MAX_SAFE_INTEGER, true).is_some()
        && is_null(at(matched, "safe_summary_key"))
        && is_null(at(matched, "result_sha256"))
        && at(matched, "approval_reference") == at(matched, "event_id")
        && canonical_timestamp(at(matched, "created_at"));
    let common = event_shape
        && at(matched, "attempt_id") == at(target, "attempt_id")
        && string_eq(at(matched, "status"), "cancelled")
        && at(matched, "failure_code") == at(token, "reason_code");
    let target_matches = match as_str(at(target, "kind")) {
        Some("attempt") => {
            is_null(at(matched, "round_index"))
                && is_null(at(matched, "call_id"))
                && is_null(at(matched, "arguments_sha256"))
        }
        Some("round") => {
            at(matched, "round_index") == at(target, "round_index")
                && is_null(at(matched, "call_id"))
                && is_null(at(matched, "arguments_sha256"))
        }
        Some("tool") => {
            let mut journal_call: Option<&Value> = None;
            for candidate in array(at(agent, "batch")) {
                if get(candidate, "call_id") != at(target, "call_id")
                    || get(candidate, "call_index") != at(target, "call_index")
                {
                    continue;
                }
                if journal_call.is_some() {
                    return false;
                }
                journal_call = Some(candidate);
            }
            at(matched, "round_index") == at(target, "round_index")
                && at(matched, "call_id") == at(target, "call_id")
                && canonical_sha256(at(matched, "arguments_sha256"))
                && at(agent, "round_index") == at(target, "round_index")
                && at(journal_call, "arguments_sha256") == at(matched, "arguments_sha256")
        }
        _ => false,
    };
    common && target_matches
}

// MARK: - finalize, discard and interrupt

/// What the host does with the transaction it is holding. `commit` carries the
/// arguments for the WAL operation commit the host still makes itself, so its
/// fault hook keeps speaking where it always did.
pub enum Settlement {
    Settle {
        changes: Map<String, Value>,
        commit: Value,
        output: Value,
    },
    Error(StoreError),
}

/// `DSHRuntimeControllerMatchesCheckpoint`.
fn controller_matches_checkpoint(request: &Value) -> bool {
    let cas = get(request, "controller_cas");
    let checkpoint = get(request, "committed_checkpoint");
    cas.is_some_and(Value::is_object)
        && checkpoint.is_some_and(Value::is_object)
        && at(cas, "expected_journal_revision") == at(checkpoint, "journal_revision")
        && at(cas, "expected_session_generation") == at(checkpoint, "session_generation")
        && at(cas, "expected_session_sha256") == at(checkpoint, "session_sha256")
}

const FINALIZE_KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "controller_cas",
    "committed_checkpoint",
    "task_id",
    "conversation_id",
    "attempt_id",
    "terminal_reason",
    "cleanup_id",
    "transcript",
    "root",
];

const DISCARD_KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "cleanup_id",
    "task_id",
    "conversation_id",
    "attempt_id",
    "transcript_ref",
    "transcript_sha256",
];

const INTERRUPT_KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "cleanup_id",
    "task_id",
    "conversation_id",
    "attempt_id",
    "transcript_ref",
    "transcript_sha256",
    "reason",
    "expected_session_generation",
    "expected_session_sha256",
];

fn settle_request(op: &str, request: &Value) -> Result<(), StoreError> {
    let keys = match op {
        "finalize" => FINALIZE_KEYS,
        "discard" => DISCARD_KEYS,
        "interrupt" => INTERRUPT_KEYS,
        _ => return Err(StoreError::InvalidArgument),
    };
    if exact_keys(Some(request), keys).is_none()
        || get(request, "schema_version") != Some(&json!(2))
        || (op == "finalize" && !controller_matches_checkpoint(request))
        || (op == "interrupt"
            && !matches!(
                as_str(get(request, "reason")),
                Some("completed" | "cancelled" | "failed")
            ))
    {
        return Err(StoreError::InvalidArgument);
    }
    Ok(())
}

/// `DSHRuntimeInterruptionProof`: the committed session has to record the
/// attempt as terminal and carry the exact cleanup-outbox entry, at exactly
/// the snapshot the caller says it saw.
pub fn interruption_proof(session: &Value, facts: &Value, request: &Value) -> bool {
    if get(facts, "session_generation") != get(request, "expected_session_generation")
        || get(facts, "session_sha256") != get(request, "expected_session_sha256")
        || get(session, "schema_version") != Some(&json!(9))
    {
        return false;
    }
    let outbox = get(session, "agent_transcript_cleanup_outbox");
    if !outbox.is_some_and(Value::is_array) {
        return false;
    }
    let mut matched: Option<&Value> = None;
    for candidate in array(outbox) {
        if get(candidate, "cleanup_id") != get(request, "cleanup_id") {
            continue;
        }
        if matched.is_some() {
            return false;
        }
        matched = Some(candidate);
    }
    let keys = [
        "schema_version",
        "cleanup_id",
        "conversation_id",
        "task_id",
        "attempt_id",
        "transcript_ref",
        "transcript_sha256",
        "reason",
        "created_at",
    ];
    let bound = |key: &str| at(matched, key) == get(request, key);
    if exact_keys(matched, &keys).is_none()
        || at(matched, "schema_version") != Some(&json!(1))
        || !bound("conversation_id")
        || !bound("task_id")
        || !bound("attempt_id")
        || !bound("transcript_ref")
        || !bound("transcript_sha256")
        || !bound("reason")
        || !canonical_timestamp(at(matched, "created_at"))
    {
        return false;
    }
    let conversation = array(get(session, "conversations"))
        .iter()
        .find(|candidate| get(candidate, "id") == get(request, "conversation_id"));
    let attempt = array(conversation.and_then(|c| get(c, "attempts")))
        .iter()
        .find(|candidate| get(candidate, "attempt_id") == get(request, "attempt_id"));
    let Some(attempt) = attempt else { return false };
    if get(attempt, "turn_id") != get(request, "task_id") {
        return false;
    }
    let status = as_str(get(attempt, "status")).unwrap_or_default();
    let agent = get(attempt, "agent");
    // Either the controller recorded the interruption itself and there is no
    // agent journal left, or the journal is terminal on exactly this
    // transcript.
    let interrupted = status == "failed"
        && string_eq(get(attempt, "failure_code"), "E_ATTEMPT_INTERRUPTED")
        && string_eq(at(matched, "reason"), "failed");
    let journal_terminal = !is_null(agent) && {
        let transcript = at(agent, "transcript");
        matches!(status, "completed" | "cancelled" | "failed")
            && at(transcript, "transcript_ref") == get(request, "transcript_ref")
            && at(transcript, "transcript_sha256") == get(request, "transcript_sha256")
    };
    (interrupted && is_null(agent)) || journal_terminal
}

/// `DSHRuntimeExactDiscardedCleanup`: only a discarded cleanup row that still
/// proves this exact transcript ownership may close an operation whose durable
/// residue is already gone.
pub fn exact_discarded_cleanup(state: &Value, request: &Value) -> bool {
    let row = array(get(state, "cleanup"))
        .iter()
        .find(|row| get(row, "cleanup_id") == get(request, "cleanup_id"));
    let bound = |key: &str| at(row, key) == get(request, key);
    string_eq(at(row, "status"), "discarded")
        && bound("attempt_id")
        && bound("transcript_ref")
        && bound("transcript_sha256")
        && at(row, "cleanup_owner") == get(request, "task_id")
}

/// `DSHRuntimeFinalRoundProvesTranscriptAdvance`: a terminal provider round
/// persists its assistant message and transcript row in one transaction, but
/// unlike a tool batch there is no later ledger transaction to advance the
/// prepared authority. Finalization may bridge exactly that one-generation gap
/// only when the latest completed final/blocked round is the immutable proof
/// for the requested transition.
fn final_round_proves_transcript_advance(
    state: &Value,
    authority: &Value,
    request: &Value,
    expected_authority_revision: Option<&Value>,
) -> bool {
    if !string_eq(get(authority, "state"), "prepared")
        || get(authority, "root") != get(request, "root")
        || get(authority, "authority_revision") != expected_authority_revision
    {
        return false;
    }
    let before = get(authority, "transcript");
    let after = get(request, "transcript");
    if at(before, "transcript_ref") != at(after, "transcript_ref")
        || u64_of(at(after, "generation")) != u64_of(at(before, "generation")) + 1
    {
        return false;
    }
    let latest = latest_round(state, get(request, "task_id"), get(request, "attempt_id"));
    let mut proof: Option<&Value> = None;
    let mut count = 0usize;
    for round in array(get(state, "rounds")) {
        let locator = get(round, "locator");
        if at(locator, "task_id") != get(request, "task_id")
            || at(locator, "attempt_id") != get(request, "attempt_id")
            || !string_eq(get(round, "state"), "completed")
            || get(round, "transcript_before") != before
            || get(round, "transcript_after") != after
        {
            continue;
        }
        count += 1;
        proof = Some(round);
    }
    if count != 1 || proof != latest {
        return false;
    }
    let proof = proof.expect("checked");
    let terminal_kind = as_str(get(proof, "terminal_kind")).unwrap_or_default();
    let finish_reason =
        as_str(get(proof, "completion_receipt").and_then(|receipt| get(receipt, "finish_reason")))
            .unwrap_or_default();
    match as_str(get(request, "terminal_reason")) {
        Some("completed") => terminal_kind == "final" && finish_reason == "stop",
        Some("failed") => {
            terminal_kind == "blocked" && matches!(finish_reason, "length" | "content_filter")
        }
        // Cancellation never gains a transcript handoff exception.
        _ => false,
    }
}

fn commit_arguments(
    request: &Value,
    started: &Value,
    result_status: &Value,
    result_ref: Value,
    result_revision: Value,
    result_kind: &str,
    result: &Value,
) -> Value {
    json!({
        "operation_id": get(request, "operation_id"),
        "request_sha256": get(started, "request_sha256"),
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "terminal_state": "committed",
        "result_status": result_status,
        "result_ref": result_ref,
        "result_revision": result_revision,
        "safe_result": { "schema_version": 2, "result_kind": result_kind, "result": result },
    })
}

/// `finalizeAgentAttempt`'s transaction body: the authority moves to
/// cleanup_pending, the transcript to terminal, and the cleanup row is created
/// if it is not already there.
pub fn finalize_transaction(
    state: &Value,
    request: &Value,
    started: &Value,
    timestamp: &str,
    retention_until: &str,
) -> Settlement {
    let task_id = get(request, "task_id");
    let attempt_id = get(request, "attempt_id");
    let transcript_ref = at(get(request, "transcript"), "transcript_ref");
    let authorities = array(get(state, "authorities"));
    let transcripts = array(get(state, "transcripts"));
    let authority_index = authorities
        .iter()
        .position(|row| get(row, "task_id") == task_id && get(row, "attempt_id") == attempt_id);
    let transcript_index = transcripts
        .iter()
        .position(|row| get(row, "transcript_ref") == transcript_ref);
    let (Some(authority_index), Some(transcript_index)) = (authority_index, transcript_index)
    else {
        return Settlement::Error(StoreError::Conflict);
    };
    let authority = &authorities[authority_index];
    let transcript = &transcripts[transcript_index];
    let revision = at(get(started, "record"), "authority_revision");
    let final_round_advance =
        final_round_proves_transcript_advance(state, authority, request, revision);
    let authority_current = get(authority, "conversation_id") == get(request, "conversation_id")
        && get(authority, "root") == get(request, "root")
        && (get(authority, "transcript") == get(request, "transcript") || final_round_advance)
        && get(authority, "authority_revision") == revision
        && (string_eq(get(authority, "state"), "prepared")
            || (string_eq(get(authority, "state"), "cleanup_pending")
                && get(authority, "cleanup_id") == get(request, "cleanup_id")));
    let transcript_current = get(transcript, "attempt_id") == attempt_id
        && get(transcript, "transcript_sha256")
            == at(get(request, "transcript"), "transcript_sha256")
        && matches!(as_str(get(transcript, "state")), Some("open" | "terminal"));
    if !authority_current || !transcript_current {
        return Settlement::Error(StoreError::Conflict);
    }
    let mut cleanup = array(get(state, "cleanup")).to_vec();
    let mut cleanup_found = false;
    for entry in &cleanup {
        if get(entry, "cleanup_id") != get(request, "cleanup_id") {
            continue;
        }
        cleanup_found = true;
        if get(entry, "attempt_id") != attempt_id
            || get(entry, "transcript_ref") != transcript_ref
            || get(entry, "transcript_sha256")
                != at(get(request, "transcript"), "transcript_sha256")
            || get(entry, "cleanup_owner") != task_id
            || get(entry, "reason") != get(request, "terminal_reason")
        {
            return Settlement::Error(StoreError::Conflict);
        }
    }
    if !cleanup_found {
        cleanup.push(json!({
            "schema_version": 1,
            "cleanup_id": get(request, "cleanup_id"),
            "attempt_id": attempt_id,
            "transcript_ref": transcript_ref,
            "transcript_sha256": at(get(request, "transcript"), "transcript_sha256"),
            "cleanup_owner": task_id,
            "reason": get(request, "terminal_reason"),
            "created_at": timestamp,
            "status": "pending",
        }));
    }
    let revision_value = u64_of(get(authority, "authority_revision"));
    let already_terminal = string_eq(get(authority, "state"), "cleanup_pending")
        && cleanup_found
        && string_eq(get(transcript, "state"), "terminal");
    let result_revision = if already_terminal {
        revision_value
    } else {
        revision_value + 1
    };
    let mut authorities = authorities.to_vec();
    let mut transcripts = transcripts.to_vec();
    if !already_terminal {
        let mut updated = transcripts[transcript_index]
            .as_object()
            .cloned()
            .unwrap_or_default();
        updated.insert("state".into(), json!("terminal"));
        updated.insert("retention_until".into(), json!(retention_until));
        updated.insert("updated_at".into(), json!(timestamp));
        transcripts[transcript_index] = Value::Object(updated);
        let mut updated = authorities[authority_index]
            .as_object()
            .cloned()
            .unwrap_or_default();
        updated.insert("state".into(), json!("cleanup_pending"));
        updated.insert("cleanup_id".into(), owned(get(request, "cleanup_id")));
        updated.insert("transcript".into(), owned(get(request, "transcript")));
        updated.insert("authority_revision".into(), json!(result_revision));
        updated.insert("updated_at".into(), json!(timestamp));
        authorities[authority_index] = Value::Object(updated);
    }
    let status = if already_terminal {
        "already_terminal"
    } else {
        "terminal"
    };
    let result = json!({
        "schema_version": 2,
        "status": status,
        "operation_id": get(request, "operation_id"),
        "cleanup_id": get(request, "cleanup_id"),
        "transcript": get(request, "transcript"),
    });
    let mut changes = Map::new();
    changes.insert("authorities".into(), Value::Array(authorities));
    changes.insert("transcripts".into(), Value::Array(transcripts));
    changes.insert("cleanup".into(), Value::Array(cleanup));
    let commit = commit_arguments(
        request,
        started,
        &json!(status),
        json!({
            "schema_version": 2,
            "kind": "authority",
            "task_id": task_id,
            "attempt_id": attempt_id,
            "authority_revision": result_revision,
        }),
        json!(result_revision),
        "finalize_agent_attempt",
        &result,
    );
    Settlement::Settle {
        changes,
        commit,
        output: result,
    }
}

/// The conflict result a refused finalize commits, so a retry sees the same
/// answer instead of racing again.
pub fn finalize_conflict_commit(request: &Value, started: &Value, failure_code: &str) -> Value {
    let result = json!({
        "schema_version": 2,
        "status": "conflict",
        "operation_id": get(request, "operation_id"),
        "failure_code": failure_code,
    });
    let mut commit = commit_arguments(
        request,
        started,
        &json!("conflict"),
        json!({ "schema_version": 2, "kind": "none" }),
        Value::Null,
        "finalize_agent_attempt",
        &result,
    );
    if let Some(commit) = commit.as_object_mut() {
        commit.insert("terminal_state".into(), json!("conflict"));
    }
    json!({ "commit": commit, "output": result })
}

/// Whether a row's writer has provably released it. The WAL's owner sweep
/// retires a dead writer's row and sets its owner to null, so an explicit null
/// owner is the record that no writer holds the row any more; a row that still
/// names an owner, or carries no owner field at all, is not provably abandoned
/// and fails closed.
fn row_owner_is_released(row: &Value) -> bool {
    matches!(get(row, "owner"), Some(Value::Null))
}

/// Whether an operation of this kind can touch anything outside the WAL. Only
/// tool execution reaches the workspace or a git remote; every other kind
/// rewrites WAL rows and nothing else. An unknown kind is treated as reaching
/// the workspace so a future kind fails closed until it is listed here.
fn operation_kind_reaches_workspace(kind: Option<&Value>) -> bool {
    !matches!(
        as_str(kind),
        Some(
            "prepare_agent_attempt"
                | "complete_agent_round_v2"
                | "prepare_agent_tool_batch"
                | "bind_agent_approval"
                | "finalize_agent_attempt"
                | "interrupt_agent_attempt"
                | "cancel_agent_attempt"
                | "discard_agent_attempt"
                | "recover_agent_attempt"
        )
    )
}

/// The residue discard's three relaxations, named as the caller passes them.
fn option_set(options: &Value, name: &str) -> bool {
    array(Some(options))
        .iter()
        .any(|option| string_eq(Some(option), name))
}

fn row_attempt(row: &Value) -> Option<&Value> {
    get(row, "attempt_id").or_else(|| get(row, "locator").and_then(|l| get(l, "attempt_id")))
}

/// `DSHRuntimeDiscardAttemptResidue`: fail-closed discard of every WAL row one
/// attempt owns. The caller has already proven the authority and started the
/// operation; this refuses while any round outcome or executed effect is
/// unprovable, and hands back the rows to keep.
pub fn residue_discard(
    state: &Value,
    request: &Value,
    operation_kind: &str,
    options: &Value,
    started: &Value,
    timestamp: &str,
) -> Settlement {
    let attempt_id = get(request, "attempt_id");
    let mut cleanup = array(get(state, "cleanup")).to_vec();
    let mut cleanup_index = cleanup
        .iter()
        .position(|row| get(row, "cleanup_id") == get(request, "cleanup_id"));
    if cleanup_index.is_none() && option_set(options, "create_cleanup_row") {
        cleanup.push(json!({
            "schema_version": 1,
            "cleanup_id": get(request, "cleanup_id"),
            "attempt_id": attempt_id,
            "transcript_ref": get(request, "transcript_ref"),
            "transcript_sha256": get(request, "transcript_sha256"),
            "cleanup_owner": get(request, "task_id"),
            "reason": get(request, "reason"),
            "created_at": timestamp,
            "status": "pending",
        }));
        cleanup_index = Some(cleanup.len() - 1);
    }
    let Some(cleanup_index) = cleanup_index else {
        return Settlement::Error(StoreError::Conflict);
    };
    {
        let row = &cleanup[cleanup_index];
        let bound = |key: &str| get(row, key) == get(request, key);
        if get(row, "attempt_id") != attempt_id
            || !bound("transcript_ref")
            || !bound("transcript_sha256")
            || get(row, "cleanup_owner") != get(request, "task_id")
            || !string_eq(get(row, "status"), "pending")
        {
            return Settlement::Error(StoreError::Conflict);
        }
    }
    for round in array(get(state, "rounds")) {
        if get(round, "locator").and_then(|l| get(l, "attempt_id")) != attempt_id {
            continue;
        }
        let round_state = as_str(get(round, "state")).unwrap_or_default();
        // A round that still has a live writer is never discarded: its outcome
        // may still arrive. The owner sweep retires a dead writer's round to
        // unknown/ambiguous and releases the owner, and such a row is exactly
        // the residue an interrupt exists to clear. A round is a provider call
        // and reaches no workspace or git remote; the ledger and dispatch
        // checks below remain the sole proof for anything that did.
        if matches!(round_state, "in_flight" | "cancel_requested") {
            return Settlement::Error(StoreError::Conflict);
        }
        if matches!(round_state, "unknown" | "ambiguous")
            && !(option_set(options, "unsettled_rounds") && row_owner_is_released(round))
        {
            return Settlement::Error(StoreError::Conflict);
        }
    }
    for row in array(get(state, "ledger")) {
        let locator = get(row, "locator");
        if at(locator, "attempt_id") != attempt_id {
            continue;
        }
        let row_state = as_str(get(row, "state")).unwrap_or_default();
        if matches!(
            row_state,
            "running" | "cancel_requested" | "unknown" | "ambiguous"
        ) {
            return Settlement::Error(StoreError::Conflict);
        }
        if row_state != "intent" {
            continue;
        }
        if !option_set(options, "undispatched_intents") {
            return Settlement::Error(StoreError::Conflict);
        }
        for dispatch in array(get(state, "dispatch")) {
            if !string_eq(get(dispatch, "kind"), "execution") || get(dispatch, "locator") != locator
            {
                continue;
            }
            if string_eq(get(dispatch, "dispatch_state"), "dispatched") {
                return Settlement::Error(StoreError::Conflict);
            }
        }
    }
    let mut kept_operations = Vec::new();
    let mut removed: Vec<&Value> = Vec::new();
    for operation in array(get(state, "operations")) {
        if get(operation, "attempt_id") != attempt_id
            || get(operation, "operation_id") == get(request, "operation_id")
        {
            kept_operations.push(operation.clone());
            continue;
        }
        let operation_state = as_str(get(operation, "state")).unwrap_or_default();
        let unsettled = matches!(operation_state, "started" | "unknown" | "ambiguous");
        // An unsettled operation only blocks the discard when it could have
        // reached the workspace: whether an execute ran is proven by its ledger
        // row and dispatch marker above, and a settled row cannot hide a
        // started execute. Every other kind mutates nothing but this WAL, so
        // the residue it left is exactly what is discarded here. A dead
        // writer's ambiguous round, or a finalize that never committed, would
        // otherwise pin the attempt forever.
        if unsettled && operation_kind_reaches_workspace(get(operation, "operation_kind")) {
            return Settlement::Error(StoreError::Conflict);
        }
        if !unsettled && !matches!(operation_state, "committed" | "rejected" | "conflict") {
            return Settlement::Error(StoreError::Corrupt);
        }
        if let Some(id) = get(operation, "operation_id") {
            removed.push(id);
        }
    }
    let kept_results: Vec<Value> = array(get(state, "operation_results"))
        .iter()
        .filter(|result| !get(result, "operation_id").is_some_and(|id| removed.contains(&id)))
        .cloned()
        .collect();
    let mut updated_cleanup = cleanup[cleanup_index]
        .as_object()
        .cloned()
        .unwrap_or_default();
    updated_cleanup.insert("status".into(), json!("discarded"));
    cleanup[cleanup_index] = Value::Object(updated_cleanup);
    let keep = |rows: &[Value]| -> Value {
        Value::Array(
            rows.iter()
                .filter(|row| row_attempt(row) != attempt_id)
                .cloned()
                .collect(),
        )
    };
    let mut changes = Map::new();
    for key in [
        "authorities",
        "rounds",
        "ledger",
        "reservations",
        "batches",
        "denied_calls",
    ] {
        changes.insert(key.into(), keep(array(get(state, key))));
    }
    changes.insert(
        "dispatch".into(),
        Value::Array(
            array(get(state, "dispatch"))
                .iter()
                .filter(|row| get(row, "locator").and_then(|l| get(l, "attempt_id")) != attempt_id)
                .cloned()
                .collect(),
        ),
    );
    changes.insert(
        "transcripts".into(),
        Value::Array(
            array(get(state, "transcripts"))
                .iter()
                .filter(|row| get(row, "attempt_id") != attempt_id)
                .cloned()
                .collect(),
        ),
    );
    changes.insert("cleanup".into(), Value::Array(cleanup));
    changes.insert("operations".into(), Value::Array(kept_operations));
    changes.insert("operation_results".into(), Value::Array(kept_results));
    let result = json!({
        "schema_version": 2,
        "status": "discarded",
        "operation_id": get(request, "operation_id"),
        "cleanup_id": get(request, "cleanup_id"),
    });
    let commit = commit_arguments(
        request,
        started,
        &json!("discarded"),
        json!({ "schema_version": 2, "kind": "cleanup", "cleanup_id": get(request, "cleanup_id") }),
        json!(1),
        operation_kind,
        &result,
    );
    Settlement::Settle {
        changes,
        commit,
        output: result,
    }
}

/// The already-missing close: the durable residue is gone, so the operation is
/// committed with nothing to discard.
pub fn already_missing_commit(request: &Value, started: &Value, operation_kind: &str) -> Value {
    let result = json!({
        "schema_version": 2,
        "status": "already_missing",
        "operation_id": get(request, "operation_id"),
        "cleanup_id": get(request, "cleanup_id"),
    });
    let commit = commit_arguments(
        request,
        started,
        &json!("already_missing"),
        json!({ "schema_version": 2, "kind": "cleanup", "cleanup_id": get(request, "cleanup_id") }),
        json!(1),
        operation_kind,
        &result,
    );
    json!({ "commit": commit, "output": result })
}

/// Whether the attempt's authority is in a state this command may settle.
pub fn settle_authority_state(state: &Value, request: &Value, op: &str) -> Value {
    let authority = find_authority(state, get(request, "task_id"), get(request, "attempt_id"));
    let Some(authority) = authority else {
        return json!({ "authority": Value::Null, "settles": false });
    };
    let settles = get(authority, "conversation_id") == get(request, "conversation_id")
        && match op {
            // A discard only ever follows a committed finalize.
            "discard" => {
                string_eq(get(authority, "state"), "cleanup_pending")
                    && get(authority, "cleanup_id") == get(request, "cleanup_id")
            }
            // An interrupt also clears a writer that died while still prepared.
            _ => {
                string_eq(get(authority, "state"), "prepared")
                    || (string_eq(get(authority, "state"), "cleanup_pending")
                        && get(authority, "cleanup_id") == get(request, "cleanup_id"))
            }
        };
    json!({ "authority": authority, "settles": settles })
}

fn settlement_json(settlement: Settlement) -> Value {
    match settlement {
        Settlement::Settle {
            changes,
            commit,
            output,
        } => json!({
            "result": "settle",
            "changes": Value::Object(changes),
            "commit": commit,
            "output": output,
        }),
        Settlement::Error(error) => json!({ "result": "error", "error": error.code() }),
    }
}

// MARK: - cancel

const CANCEL_KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "controller_cas",
    "committed_checkpoint",
    "target",
    "cancel_token",
    "expected_round_revision",
    "expected_execution_revision",
    "expected_transcript",
    "root",
];

const RECOVER_KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "controller_cas",
    "committed_checkpoint",
    "target",
    "action",
    "expected_round_revision",
    "expected_execution_revision",
    "expected_transcript",
    "root",
];

/// `cancelAgentAttempt` and `recoverAgentAttempt` both address a target, and
/// the controller's own CAS has to name the same attempt as that target.
pub fn target_request(op: &str, request: &Value) -> Result<(), StoreError> {
    let keys = match op {
        "cancel" => CANCEL_KEYS,
        "recover" => RECOVER_KEYS,
        _ => return Err(StoreError::InvalidArgument),
    };
    let target = get(request, "target").filter(|target| target.is_object());
    let cas = get(request, "controller_cas");
    let token = get(request, "cancel_token");
    if exact_keys(Some(request), keys).is_none()
        || get(request, "schema_version") != Some(&json!(2))
        || target.is_none()
        || !controller_matches_checkpoint(request)
        || at(cas, "task_id") != at(target, "task_id")
        || at(cas, "attempt_id") != at(target, "attempt_id")
        || (op == "cancel"
            && (at(token, "task_id") != at(target, "task_id")
                || at(token, "attempt_id") != at(target, "attempt_id")))
    {
        return Err(StoreError::InvalidArgument);
    }
    Ok(())
}

/// The conflict shape both target commands report, which names what the
/// controller expected beside what the session actually says.
pub fn target_conflict(
    request: &Value,
    proof: &Value,
    failure_code: &str,
    with_target: bool,
    actual_journal_revision: Option<&Value>,
) -> Value {
    let cas = get(request, "controller_cas");
    let mut conflict = Map::new();
    conflict.insert("schema_version".into(), json!(2));
    conflict.insert("status".into(), json!("conflict"));
    conflict.insert("operation_id".into(), owned(get(request, "operation_id")));
    if with_target {
        conflict.insert("target".into(), owned(get(request, "target")));
    }
    conflict.insert("failure_code".into(), json!(failure_code));
    conflict.insert(
        "expected_controller_generation".into(),
        owned(at(cas, "expected_controller_generation")),
    );
    conflict.insert(
        "expected_journal_revision".into(),
        owned(at(cas, "expected_journal_revision")),
    );
    conflict.insert(
        "actual_controller_generation".into(),
        owned(get(proof, "controller_generation")),
    );
    // A recovery that learned a newer journal revision from its own attempt
    // query reports that one instead of the proof's.
    conflict.insert(
        "actual_journal_revision".into(),
        owned(actual_journal_revision.or_else(|| get(proof, "journal_revision"))),
    );
    Value::Object(conflict)
}

/// Which cancellation this command is: the target names a tool row, a round,
/// an attempt that never started a round, or nothing the WAL knows about.
pub fn cancel_plan(state: &Value, request: &Value) -> Value {
    let target = get(request, "target");
    let kind = as_str(at(target, "kind")).unwrap_or_default();
    let task_id = at(target, "task_id");
    let attempt_id = at(target, "attempt_id");
    let row = if kind == "tool" {
        array(get(state, "ledger")).iter().find(|candidate| {
            let locator = get(candidate, "locator");
            at(locator, "task_id") == task_id
                && at(locator, "attempt_id") == attempt_id
                && at(locator, "round_id") == at(target, "round_id")
                && at(locator, "call_index") == at(target, "call_index")
                && at(locator, "call_id") == at(target, "call_id")
                && at(locator, "idempotency_key") == at(target, "idempotency_key")
        })
    } else {
        None
    };
    if kind == "round" || (kind == "attempt" && row.is_none()) {
        let latest = if kind == "round" {
            None
        } else {
            latest_round(state, task_id, attempt_id)
        };
        let round_target = if kind == "round" {
            owned(target)
        } else {
            owned(latest.and_then(|round| get(round, "locator")))
        };
        let revision = if kind == "round" {
            // A controller that cancels a round still in flight has not yet
            // heard the row's revision back -- the reply that carries it is
            // the one being stopped -- and says 0, which no row ever has.
            // The round the target names is then taken at the revision the
            // WAL holds, as an attempt cancellation already is. Without
            // this, every cancellation of a running round was refused as a
            // malformed selector (leaving the app mid-reply, 2026-09-25).
            let requested = get(request, "expected_round_revision");
            if requested == Some(&json!(0)) {
                owned(
                    array(get(state, "rounds"))
                        .iter()
                        .find(|candidate| {
                            let locator = get(candidate, "locator");
                            at(locator, "task_id") == task_id
                                && at(locator, "attempt_id") == attempt_id
                                && at(locator, "round_id") == at(target, "round_id")
                        })
                        .and_then(|round| get(round, "row_revision")),
                )
            } else {
                owned(requested)
            }
        } else {
            owned(latest.and_then(|round| get(round, "row_revision")))
        };
        if !round_target.is_null() && !revision.is_null() {
            return json!({
                "plan": "round",
                "round_target": round_target,
                "expected_round_revision": revision,
            });
        }
    }
    if row.is_none()
        && kind == "attempt"
        && string_eq(
            at(get(request, "cancel_token"), "expected_phase"),
            "ready_for_round",
        )
        && latest_round(state, task_id, attempt_id).is_none()
    {
        // Nothing has been launched yet, so the attempt is simply cancelled.
        return json!({ "plan": "never_started" });
    }
    match row {
        None => json!({ "plan": "not_found" }),
        Some(row) => json!({ "plan": "row", "row": row, "state": get(row, "state") }),
    }
}

fn cancel_result(request: &Value, status: &str, fields: Map<String, Value>) -> Value {
    let mut result = Map::new();
    result.insert("schema_version".into(), json!(2));
    result.insert("status".into(), json!(status));
    result.insert("operation_id".into(), owned(get(request, "operation_id")));
    result.insert("target".into(), owned(get(request, "target")));
    result.insert("result_round_revision".into(), Value::Null);
    result.insert("result_execution_revision".into(), Value::Null);
    result.insert(
        "transcript".into(),
        owned(get(request, "expected_transcript")),
    );
    result.insert("receipt".into(), Value::Null);
    result.insert("effect_may_have_occurred".into(), json!(false));
    result.insert(
        "observed_checkpoint".into(),
        owned(get(request, "committed_checkpoint")),
    );
    for (key, value) in fields {
        result.insert(key, value);
    }
    Value::Object(result)
}

/// The answer a round cancellation reports once the round journal has spoken.
pub fn cancel_round_result(request: &Value, cancelled: &Value, proof: &Value) -> Value {
    if string_eq(get(cancelled, "status"), "conflict") {
        let code = as_str(get(cancelled, "failure_code")).unwrap_or("E_AGENT_CONFLICT");
        return target_conflict(request, proof, code, true, None);
    }
    let status = if string_eq(get(cancelled, "status"), "cancelled") {
        "cancelled"
    } else {
        "cancel_requested"
    };
    let mut fields = Map::new();
    fields.insert(
        "result_round_revision".into(),
        owned(get(cancelled, "result_round_revision")),
    );
    fields.insert("transcript".into(), owned(get(cancelled, "transcript")));
    cancel_result(request, status, fields)
}

/// The answer an attempt that never launched a round reports.
pub fn cancel_never_started_result(request: &Value) -> Value {
    cancel_result(request, "cancelled", Map::new())
}

/// The answer a cancellation of a row the WAL does not know reports.
pub fn cancel_not_found_result(request: &Value) -> Value {
    let mut fields = Map::new();
    fields.insert("failure_code".into(), json!("E_AGENT_NOT_FOUND"));
    cancel_result(request, "unknown", fields)
}

/// The answer a tool cancellation reports once the ledger has moved the row.
/// `dispatched` is the host's own dispatch marker: only it knows whether the
/// execution was handed out.
pub fn cancel_row_result(request: &Value, updated: &Value, dispatched: bool) -> Value {
    let status = match as_str(get(updated, "state")) {
        Some("cancelled") => "cancelled",
        Some("cancel_requested") => "cancel_requested",
        _ => "settled",
    };
    let mut fields = Map::new();
    fields.insert(
        "result_execution_revision".into(),
        owned(get(updated, "row_revision")),
    );
    fields.insert("transcript".into(), reference_for_row(updated));
    fields.insert("receipt".into(), owned(get(updated, "receipt")));
    fields.insert("effect_may_have_occurred".into(), json!(dispatched));
    cancel_result(request, status, fields)
}

/// `DSHRuntimeCommitCancelResult`: which reference the cancellation's own
/// operation result points at.
pub fn cancel_commit(request: &Value, started: &Value, result: &Value) -> Value {
    let target = get(request, "target");
    let status = as_str(get(result, "status")).unwrap_or_default();
    let terminal_state = match status {
        "conflict" => "conflict",
        "unknown" | "ambiguous" => status,
        _ => "committed",
    };
    let unsettled = matches!(status, "conflict" | "unknown" | "ambiguous");
    let mut result_ref = json!({ "schema_version": 2, "kind": "none" });
    let mut revision = Value::Null;
    if !unsettled && string_eq(at(target, "kind"), "attempt") {
        revision = owned(at(get(started, "record"), "authority_revision"));
        result_ref = json!({
            "schema_version": 2, "kind": "authority",
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "authority_revision": revision,
        });
    } else if status != "conflict" && !is_null(get(result, "result_execution_revision")) {
        revision = owned(get(result, "result_execution_revision"));
        result_ref = json!({
            "schema_version": 2, "kind": "tool",
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "round_id": at(target, "round_id"), "round_index": at(target, "round_index"),
            "call_index": at(target, "call_index"), "call_id": at(target, "call_id"),
            "execution_revision": revision,
        });
    } else if status != "conflict" && !is_null(get(result, "result_round_revision")) {
        revision = owned(get(result, "result_round_revision"));
        result_ref = json!({
            "schema_version": 2, "kind": "round",
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "round_id": at(target, "round_id"), "round_index": at(target, "round_index"),
            "round_revision": revision,
        });
    }
    json!({
        "operation_id": get(request, "operation_id"),
        "request_sha256": get(started, "request_sha256"),
        "task_id": at(target, "task_id"),
        "attempt_id": at(target, "attempt_id"),
        "terminal_state": terminal_state,
        "result_status": status,
        "result_ref": result_ref,
        "result_revision": revision,
        "safe_result": {
            "schema_version": 2,
            "result_kind": "cancel_agent_attempt",
            "result": result,
        },
    })
}

/// `DSHRuntimeCommitRecoveryResult`. The round and tool revisions are read
/// back from the state the host hands in, because the service the recovery
/// just ran may have moved them.
pub fn recovery_commit(
    state: &Value,
    request: &Value,
    started: &Value,
    result: &Value,
) -> Result<Value, StoreError> {
    let target = get(request, "target");
    let status = as_str(get(result, "status")).unwrap_or_default();
    let terminal_state = if status == "conflict" {
        "conflict"
    } else {
        "committed"
    };
    let kind = as_str(at(target, "kind")).unwrap_or_default();
    let mut result_ref = json!({ "schema_version": 2, "kind": "none" });
    let mut revision = Value::Null;
    if status != "conflict" && kind == "attempt" {
        revision = owned(at(get(started, "record"), "authority_revision"));
        result_ref = json!({
            "schema_version": 2, "kind": "authority",
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "authority_revision": revision,
        });
    } else if status != "conflict" && kind == "round" {
        let completed = get(result, "completed_round");
        revision = if completed.is_some_and(Value::is_object) {
            owned(completed.and_then(|round| get(round, "result_round_revision")))
        } else {
            owned(get(request, "expected_round_revision"))
        };
        for row in array(get(state, "rounds")) {
            let locator = get(row, "locator");
            if at(locator, "task_id") == at(target, "task_id")
                && at(locator, "attempt_id") == at(target, "attempt_id")
                && at(locator, "round_id") == at(target, "round_id")
                && at(locator, "round_index") == at(target, "round_index")
            {
                revision = owned(get(row, "row_revision"));
                break;
            }
        }
        result_ref = json!({
            "schema_version": 2, "kind": "round",
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "round_id": at(target, "round_id"), "round_index": at(target, "round_index"),
            "round_revision": revision,
        });
    } else if status != "conflict" && kind == "tool" {
        let locator = json!({
            "schema_version": 2,
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "round_id": at(target, "round_id"), "round_index": at(target, "round_index"),
            "call_index": at(target, "call_index"), "call_id": at(target, "call_id"),
            "idempotency_key": at(target, "idempotency_key"),
        });
        revision = owned(find_ledger_row(state, &locator).and_then(|row| get(row, "row_revision")));
        if safe_integer(Some(&revision), MAX_SAFE_INTEGER, false).is_none() {
            return Err(StoreError::Corrupt);
        }
        result_ref = json!({
            "schema_version": 2, "kind": "tool",
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "round_id": at(target, "round_id"), "round_index": at(target, "round_index"),
            "call_index": at(target, "call_index"), "call_id": at(target, "call_id"),
            "execution_revision": revision,
        });
    }
    Ok(json!({
        "operation_id": get(request, "operation_id"),
        "request_sha256": get(started, "request_sha256"),
        "task_id": at(target, "task_id"),
        "attempt_id": at(target, "attempt_id"),
        "terminal_state": terminal_state,
        "result_status": status,
        "result_ref": result_ref,
        "result_revision": revision,
        "safe_result": {
            "schema_version": 2,
            "result_kind": "recover_agent_attempt",
            "result": result,
        },
    }))
}

// MARK: - recovery

/// What a recovery reports and what the controller should do next. The pair is
/// always decided together, so it travels together.
fn outcome(status: &str, next: &str) -> Value {
    json!({ "status": status, "next_action": next })
}

/// Which persistence step a completed round asks the controller for.
fn persist_step(completed_round: Option<&Value>) -> &'static str {
    match as_str(at(completed_round, "kind")) {
        Some("final") => "persist_final",
        Some("tool_batch") => "persist_batch",
        _ => "persist_round",
    }
}

/// The status a recovery starts from: an attempt the query already calls
/// terminal is not resumed by recovering it.
pub fn recover_initial_outcome(attempt_query: &Value) -> Value {
    let status = if string_eq(get(attempt_query, "status"), "terminal") {
        "terminal"
    } else {
        "resumed"
    };
    outcome(status, "none")
}

/// `recoverAgentAttempt`'s round branch, for everything except the retry
/// action: the round journal's own answer decides both halves.
pub fn recover_round_outcome(round_recovery: &Value) -> Result<Value, StoreError> {
    match as_str(get(round_recovery, "status")) {
        Some("completed") => {
            let completed = get(round_recovery, "completed_round");
            if !completed.is_some_and(Value::is_object) {
                return Err(StoreError::Corrupt);
            }
            let mut result = outcome("resumed", persist_step(completed));
            if let Some(result) = result.as_object_mut() {
                result.insert("completed_round".into(), owned(completed));
            }
            Ok(result)
        }
        Some("unknown" | "ambiguous") => {
            Ok(outcome("manual_reconciliation", "inspect_native_state"))
        }
        Some("failed_retryable") => Ok(outcome("retryable", "retry_same_round")),
        Some("cancelled") => Ok(outcome("terminal", "none")),
        // Anything else leaves the status the attempt query already gave.
        _ => Ok(Value::Null),
    }
}

/// A retry only proceeds from a round the journal still calls failed_retryable
/// at exactly the revision the controller expects.
pub fn recover_retry_allowed(round_recovery: &Value, request: &Value) -> bool {
    string_eq(get(round_recovery, "status"), "failed_retryable")
        && get(round_recovery, "result_round_revision") == get(request, "expected_round_revision")
}

/// The stored round row has to agree, and its launch attempt has to be inside
/// the retry budget. Returns the next launch attempt.
pub fn recover_retry_launch_attempt(state: &Value, request: &Value) -> Result<u64, StoreError> {
    let target = get(request, "target");
    let row = array(get(state, "rounds")).iter().find(|candidate| {
        let locator = get(candidate, "locator");
        at(locator, "task_id") == at(target, "task_id")
            && at(locator, "attempt_id") == at(target, "attempt_id")
            && at(locator, "round_id") == at(target, "round_id")
            && at(locator, "round_index") == at(target, "round_index")
    });
    let launch_attempt = u64_of(row.and_then(|row| get(row, "launch_attempt")));
    if !row.is_some_and(|row| string_eq(get(row, "state"), "failed_retryable"))
        || row.and_then(|row| get(row, "row_revision")) != get(request, "expected_round_revision")
        || launch_attempt == 0
        || launch_attempt >= 8
    {
        return Err(StoreError::Conflict);
    }
    Ok(launch_attempt + 1)
}

/// The round the retry relaunches, built from the same authority facts the
/// original launch was bound to.
pub fn recover_retry_request(
    request: &Value,
    authority: &Value,
    launch_attempt: u64,
    child_operation_id: &str,
) -> Value {
    let target = get(request, "target");
    let cas = get(request, "controller_cas");
    let registry = get(authority, "registry");
    json!({
        "schema_version": 2,
        "operation_id": child_operation_id,
        "controller_cas": cas,
        "committed_checkpoint": get(request, "committed_checkpoint"),
        "task_id": at(target, "task_id"),
        "conversation_id": at(cas, "conversation_id"),
        "attempt_id": at(target, "attempt_id"),
        "round_id": at(target, "round_id"),
        "round_index": at(target, "round_index"),
        "launch_attempt": launch_attempt,
        "expected_round_revision": get(request, "expected_round_revision"),
        "transport_schema_version": get(authority, "transport_schema_version"),
        "model": get(authority, "model"),
        "thinking_mode": get(authority, "thinking_mode"),
        "visible_history_sha256": get(authority, "visible_history_sha256"),
        "visible_message_count": get(authority, "visible_message_count"),
        "project_context_sha256": get(authority, "project_context_sha256"),
        "transcript": get(request, "expected_transcript"),
        "root": get(request, "root"),
        "registry_version": at(registry, "registry_version"),
        "toolset_sha256": at(registry, "toolset_sha256"),
    })
}

/// What the relaunched round reports. A completed retry is recovered once more
/// so the controller is handed the round journal's own projection, not the
/// launch's.
pub fn recover_retry_outcome(retried: &Value, after_retry: &Value) -> Result<Value, StoreError> {
    match as_str(get(retried, "status")) {
        Some("completed") => {
            let completed = get(after_retry, "completed_round");
            if !completed.is_some_and(Value::is_object) {
                return Err(StoreError::Corrupt);
            }
            let mut result = outcome("resumed", persist_step(completed));
            if let Some(result) = result.as_object_mut() {
                result.insert("completed_round".into(), owned(completed));
            }
            Ok(result)
        }
        Some("failed_retryable" | "in_flight") => Ok(outcome("retryable", "retry_same_round")),
        _ => Ok(outcome("manual_reconciliation", "inspect_native_state")),
    }
}

/// `recoverAgentAttempt`'s tool branch: the ledger row, the batch it belongs
/// to and the prepare-time call projection are all required, and together they
/// name the execution the recovery re-runs.
pub fn recover_tool_plan(
    state: &Value,
    request: &Value,
    authority: &Value,
    child_operation_id: &str,
) -> Result<Value, StoreError> {
    let target = get(request, "target");
    let cas = get(request, "controller_cas");
    let row = array(get(state, "ledger"))
        .iter()
        .find(|candidate| {
            let locator = get(candidate, "locator");
            at(locator, "task_id") == at(target, "task_id")
                && at(locator, "attempt_id") == at(target, "attempt_id")
                && at(locator, "round_id") == at(target, "round_id")
                && at(locator, "round_index") == at(target, "round_index")
                && at(locator, "call_index") == at(target, "call_index")
                && at(locator, "call_id") == at(target, "call_id")
                && at(locator, "idempotency_key") == at(target, "idempotency_key")
        })
        .ok_or(StoreError::NotFound)?;
    let batch = array(get(state, "batches")).iter().find(|candidate| {
        get(candidate, "task_id") == at(target, "task_id")
            && get(candidate, "attempt_id") == at(target, "attempt_id")
            && get(candidate, "round_id") == at(target, "round_id")
            && get(candidate, "round_index") == at(target, "round_index")
    });
    let calls = latest_batch_calls(state, batch.unwrap_or(&Value::Null));
    let call = array(Some(&calls)).iter().find(|candidate| {
        get(candidate, "call_index") == at(target, "call_index")
            && get(candidate, "call_id") == at(target, "call_id")
    });
    let (Some(batch), Some(call)) = (batch, call) else {
        return Err(StoreError::Corrupt);
    };
    let tool_request = json!({
        "schema_version": 2,
        "operation_id": child_operation_id,
        "controller_cas": cas,
        "committed_checkpoint": get(request, "committed_checkpoint"),
        "task_id": at(target, "task_id"),
        "conversation_id": at(cas, "conversation_id"),
        "attempt_id": at(target, "attempt_id"),
        "round_id": at(target, "round_id"),
        "round_index": at(target, "round_index"),
        "batch_kind": get(batch, "kind"),
        "manifest_sha256": get(batch, "manifest_sha256"),
        "expected_batch_revision": get(batch, "batch_revision"),
        "call_index": at(target, "call_index"),
        "call_id": at(target, "call_id"),
        "name": get(row, "name"),
        "arguments_sha256": get(row, "arguments_sha256"),
        "idempotency_key": at(target, "idempotency_key"),
        "expected_execution_revision": get(request, "expected_execution_revision"),
        "transcript": get(request, "expected_transcript"),
        "root": get(request, "root"),
        "approval_reference": get(call, "approval_reference").unwrap_or(&Value::Null),
    });
    // A retried recovery reuses the authority revision its own child operation
    // was started under, so the replay compares like with like.
    let authority_revision = array(get(state, "operations"))
        .iter()
        .find(|operation| as_str(get(operation, "operation_id")) == Some(child_operation_id))
        .and_then(|operation| get(operation, "authority_revision"))
        .or_else(|| get(authority, "authority_revision"));
    Ok(json!({
        "tool_request": tool_request,
        "authority_revision": authority_revision,
    }))
}

/// A tool recovery that reached a terminal answer commits it against its own
/// child operation.
pub fn recover_tool_commit(
    request: &Value,
    tool_started: &Value,
    tool_recovery: &Value,
    child_operation_id: &str,
) -> Result<Value, StoreError> {
    let target = get(request, "target");
    let status = as_str(get(tool_recovery, "status")).unwrap_or_default();
    let revision = get(tool_recovery, "result_execution_revision");
    if as_str(get(tool_recovery, "operation_id")) != Some(child_operation_id)
        || safe_integer(revision, MAX_SAFE_INTEGER, false).is_none()
    {
        return Err(StoreError::Corrupt);
    }
    Ok(json!({
        "operation_id": child_operation_id,
        "request_sha256": get(tool_started, "request_sha256"),
        "task_id": at(target, "task_id"),
        "attempt_id": at(target, "attempt_id"),
        "terminal_state": if status == "ambiguous" { "ambiguous" } else { "committed" },
        "result_status": status,
        "result_ref": {
            "schema_version": 2, "kind": "tool",
            "task_id": at(target, "task_id"), "attempt_id": at(target, "attempt_id"),
            "round_id": at(target, "round_id"), "round_index": at(target, "round_index"),
            "call_index": at(target, "call_index"), "call_id": at(target, "call_id"),
            "execution_revision": revision,
        },
        "result_revision": revision,
        "safe_result": {
            "schema_version": 2,
            "result_kind": "execute_agent_tool",
            "result": tool_recovery,
        },
    }))
}

/// Whether a tool recovery's answer is one the child operation settles.
pub fn recover_tool_is_terminal(tool_recovery: &Value) -> bool {
    matches!(
        as_str(get(tool_recovery, "status")),
        Some("completed" | "failed" | "denied" | "cancelled" | "ambiguous")
    )
}

/// What the tool branch reports once the execution service has spoken.
pub fn recover_tool_outcome(tool_recovery: &Value) -> Value {
    if recover_tool_is_terminal(tool_recovery) {
        return outcome("resumed", "persist_tool_result");
    }
    match as_str(get(tool_recovery, "status")) {
        Some("not_started" | "intent") => outcome("resumed", "persist_approval"),
        _ => outcome("manual_reconciliation", "inspect_native_state"),
    }
}

/// `finishRecovery`: the attempt as the query sees it now, beside whatever the
/// branch concluded.
pub fn recover_result(request: &Value, attempt: &Value, settled: &Value) -> Value {
    json!({
        "schema_version": 2,
        "status": get(settled, "status"),
        "operation_id": get(request, "operation_id"),
        "next_action": get(settled, "next_action"),
        "attempt": attempt,
        "completed_round": get(settled, "completed_round").unwrap_or(&Value::Null),
    })
}

/// `rish_agent_runtime_reduce`.
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
    let request = get(&envelope, "request").unwrap_or(&Value::Null);
    let state = get(&envelope, "state").unwrap_or(&Value::Null);
    let session = get(&envelope, "session").unwrap_or(&Value::Null);
    let mut reply = Map::new();
    match op {
        "query_tool_request" => {
            request_shape("query_tool", request)?;
            reply.insert("locator".into(), tool_locator(request));
        }
        "query_attempt_request" => request_shape("query_attempt", request)?,
        "presentations_request" => presentations_request(request)?,
        "session_proof" => {
            let facts = get(&envelope, "facts").unwrap_or(&Value::Null);
            reply.insert("proof".into(), session_proof(session, facts, request)?);
        }
        "session_owns_attempt" => {
            reply.insert(
                "owns".into(),
                json!(session_owns_attempt(
                    session,
                    get(request, "conversation_id").unwrap_or(&Value::Null),
                    get(request, "attempt_id").unwrap_or(&Value::Null)
                )),
            );
        }
        "query_tool_session_conflict" => {
            reply.insert("output".into(), query_tool_session_conflict(state, request));
        }
        "query_tool_ledger_conflict" => {
            reply.insert("output".into(), query_tool_ledger_conflict(state, request));
        }
        "query_tool_result" => {
            let queried = get(&envelope, "queried").ok_or(StoreError::InvalidArgument)?;
            reply.insert("output".into(), query_tool_result(queried, request));
        }
        "query_attempt_session_conflict" => {
            let proof = get(&envelope, "proof").ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "output".into(),
                owned(query_attempt_session_conflict(request, proof).as_ref()),
            );
        }
        "query_attempt_base_conflict" => {
            let proof = get(&envelope, "proof").ok_or(StoreError::InvalidArgument)?;
            let base = get(&envelope, "base").ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "output".into(),
                owned(query_attempt_base_conflict(base, request, proof).as_ref()),
            );
        }
        "query_attempt_projection" => {
            let proof = get(&envelope, "proof").ok_or(StoreError::InvalidArgument)?;
            let base = get(&envelope, "base").ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "output".into(),
                query_attempt_projection(state, base, proof, request),
            );
        }
        "tool_projection" => {
            let row = get(&envelope, "row").ok_or(StoreError::InvalidArgument)?;
            reply.insert("tool".into(), tool_projection(row));
        }
        "latest_batch_calls" => {
            let batch = get(&envelope, "batch").unwrap_or(&Value::Null);
            reply.insert("calls".into(), latest_batch_calls(state, batch));
        }
        "settle_request" => {
            let kind = as_str(get(&envelope, "kind")).ok_or(StoreError::InvalidArgument)?;
            settle_request(kind, request)?;
        }
        "interruption_proof" => {
            let facts = get(&envelope, "facts").unwrap_or(&Value::Null);
            reply.insert(
                "proves".into(),
                json!(interruption_proof(session, facts, request)),
            );
        }
        "exact_discarded_cleanup" => {
            reply.insert(
                "proves".into(),
                json!(exact_discarded_cleanup(state, request)),
            );
        }
        "settle_authority_state" => {
            let kind = as_str(get(&envelope, "kind")).ok_or(StoreError::InvalidArgument)?;
            return Ok(settle_authority_state(state, request, kind));
        }
        "finalize_transaction" => {
            let started = get(&envelope, "started").ok_or(StoreError::InvalidArgument)?;
            let timestamp = as_str(get(&envelope, "timestamp")).unwrap_or_default();
            let retention = as_str(get(&envelope, "retention_until")).unwrap_or_default();
            return Ok(settlement_json(finalize_transaction(
                state, request, started, timestamp, retention,
            )));
        }
        "finalize_conflict" => {
            let started = get(&envelope, "started").ok_or(StoreError::InvalidArgument)?;
            let code = as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?;
            return Ok(finalize_conflict_commit(request, started, code));
        }
        "residue_discard" => {
            let started = get(&envelope, "started").ok_or(StoreError::InvalidArgument)?;
            let kind = as_str(get(&envelope, "kind")).ok_or(StoreError::InvalidArgument)?;
            let options = get(&envelope, "options").unwrap_or(&Value::Null);
            let timestamp = as_str(get(&envelope, "timestamp")).unwrap_or_default();
            return Ok(settlement_json(residue_discard(
                state, request, kind, options, started, timestamp,
            )));
        }
        "already_missing" => {
            let started = get(&envelope, "started").ok_or(StoreError::InvalidArgument)?;
            let kind = as_str(get(&envelope, "kind")).ok_or(StoreError::InvalidArgument)?;
            return Ok(already_missing_commit(request, started, kind));
        }
        "target_request" => {
            let kind = as_str(get(&envelope, "kind")).ok_or(StoreError::InvalidArgument)?;
            target_request(kind, request)?;
        }
        "target_conflict" => {
            let proof = get(&envelope, "proof").ok_or(StoreError::InvalidArgument)?;
            let code = as_str(get(&envelope, "failure_code")).ok_or(StoreError::InvalidArgument)?;
            let with_target = get(&envelope, "with_target") != Some(&json!(false));
            let journal = get(&envelope, "actual_journal_revision");
            reply.insert(
                "output".into(),
                target_conflict(request, proof, code, with_target, journal),
            );
        }
        "cancel_plan" => return Ok(cancel_plan(state, request)),
        "cancel_round_result" => {
            let proof = get(&envelope, "proof").ok_or(StoreError::InvalidArgument)?;
            let cancelled = get(&envelope, "cancelled").ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "output".into(),
                cancel_round_result(request, cancelled, proof),
            );
        }
        "cancel_never_started_result" => {
            reply.insert("output".into(), cancel_never_started_result(request));
        }
        "cancel_not_found_result" => {
            reply.insert("output".into(), cancel_not_found_result(request));
        }
        "cancel_row_result" => {
            let updated = get(&envelope, "updated").ok_or(StoreError::InvalidArgument)?;
            let dispatched = get(&envelope, "dispatched") == Some(&json!(true));
            reply.insert(
                "output".into(),
                cancel_row_result(request, updated, dispatched),
            );
        }
        "cancel_commit" => {
            let started = get(&envelope, "started").ok_or(StoreError::InvalidArgument)?;
            let result = get(&envelope, "settled").ok_or(StoreError::InvalidArgument)?;
            reply.insert("commit".into(), cancel_commit(request, started, result));
        }
        "recovery_commit" => {
            let started = get(&envelope, "started").ok_or(StoreError::InvalidArgument)?;
            let result = get(&envelope, "settled").ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "commit".into(),
                recovery_commit(state, request, started, result)?,
            );
        }
        "recover_initial_outcome" => {
            let query = get(&envelope, "attempt_query").ok_or(StoreError::InvalidArgument)?;
            reply.insert("settled".into(), recover_initial_outcome(query));
        }
        "recover_round_outcome" => {
            let recovery = get(&envelope, "recovery").ok_or(StoreError::InvalidArgument)?;
            reply.insert("settled".into(), recover_round_outcome(recovery)?);
        }
        "recover_retry_allowed" => {
            let recovery = get(&envelope, "recovery").ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "allowed".into(),
                json!(recover_retry_allowed(recovery, request)),
            );
        }
        "recover_retry_launch_attempt" => {
            reply.insert(
                "launch_attempt".into(),
                json!(recover_retry_launch_attempt(state, request)?),
            );
        }
        "recover_retry_request" => {
            let authority = get(&envelope, "authority").ok_or(StoreError::InvalidArgument)?;
            let launch = get(&envelope, "launch_attempt")
                .and_then(Value::as_u64)
                .ok_or(StoreError::InvalidArgument)?;
            let child =
                as_str(get(&envelope, "child_operation_id")).ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "request".into(),
                recover_retry_request(request, authority, launch, child),
            );
        }
        "recover_retry_outcome" => {
            let retried = get(&envelope, "retried").ok_or(StoreError::InvalidArgument)?;
            let after = get(&envelope, "after_retry").unwrap_or(&Value::Null);
            reply.insert("settled".into(), recover_retry_outcome(retried, after)?);
        }
        "recover_tool_plan" => {
            let authority = get(&envelope, "authority").ok_or(StoreError::InvalidArgument)?;
            let child =
                as_str(get(&envelope, "child_operation_id")).ok_or(StoreError::InvalidArgument)?;
            return recover_tool_plan(state, request, authority, child);
        }
        "recover_tool_commit" => {
            let started = get(&envelope, "started").ok_or(StoreError::InvalidArgument)?;
            let recovery = get(&envelope, "recovery").ok_or(StoreError::InvalidArgument)?;
            let child =
                as_str(get(&envelope, "child_operation_id")).ok_or(StoreError::InvalidArgument)?;
            reply.insert(
                "commit".into(),
                recover_tool_commit(request, started, recovery, child)?,
            );
        }
        "recover_tool_outcome" => {
            let recovery = get(&envelope, "recovery").ok_or(StoreError::InvalidArgument)?;
            reply.insert("terminal".into(), json!(recover_tool_is_terminal(recovery)));
            reply.insert("settled".into(), recover_tool_outcome(recovery));
        }
        "recover_result" => {
            let attempt = get(&envelope, "attempt").ok_or(StoreError::InvalidArgument)?;
            let settled = get(&envelope, "settled").ok_or(StoreError::InvalidArgument)?;
            reply.insert("output".into(), recover_result(request, attempt, settled));
        }
        "cleanup_outbox_proof" => {
            reply.insert(
                "proves".into(),
                json!(cleanup_outbox_proof(session, request)),
            );
        }
        "cancel_source_proof" => {
            reply.insert(
                "proves".into(),
                json!(cancel_source_proof(session, request)),
            );
        }
        "child_operation_id" => {
            let purpose = as_str(get(&envelope, "purpose")).ok_or(StoreError::InvalidArgument)?;
            let operation_id = get(request, "operation_id").ok_or(StoreError::InvalidArgument)?;
            let child =
                child_operation_id(operation_id, purpose).ok_or(StoreError::InvalidArgument)?;
            reply.insert("operation_id".into(), json!(child));
        }
        _ => return Err(StoreError::InvalidArgument),
    }
    Ok(Value::Object(reply))
}

#[cfg(test)]
mod cancel_plan_tests {
    use super::cancel_plan;
    use serde_json::json;

    const TASK: &str = "11111111-1111-4111-8111-111111111111";
    const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
    const ROUND: &str = "33333333-3333-4333-8333-333333333333";

    fn state() -> serde_json::Value {
        json!({ "rounds": [
            { "locator": { "task_id": TASK, "attempt_id": ATTEMPT, "round_id": ROUND, "round_index": 0 },
              "row_revision": 3, "state": "in_flight" },
        ] })
    }

    fn request(revision: u64) -> serde_json::Value {
        json!({
            "target": { "schema_version": 2, "kind": "round", "task_id": TASK, "attempt_id": ATTEMPT,
                        "round_id": ROUND, "round_index": 0 },
            "expected_round_revision": revision,
        })
    }

    // A controller cancelling a round still in flight has not heard its row
    // revision yet and says 0; the plan takes the round at the WAL's revision.
    #[test]
    fn a_running_round_is_cancelled_at_the_revision_the_wal_holds() {
        let plan = cancel_plan(&state(), &request(0));
        assert_eq!(plan["plan"], json!("round"));
        assert_eq!(plan["expected_round_revision"], json!(3));
    }

    // A revision the controller did hear is kept: a stale one still conflicts
    // where the selector compares it with the row.
    #[test]
    fn a_known_revision_is_kept_as_asked() {
        assert_eq!(cancel_plan(&state(), &request(2))["expected_round_revision"], json!(2));
    }

    // Nothing in the WAL for that round and nothing known: no round plan.
    #[test]
    fn an_unknown_round_with_no_revision_is_not_a_round_plan() {
        let empty = json!({ "rounds": [] });
        assert_ne!(cancel_plan(&empty, &request(0))["plan"], json!("round"));
    }
}
