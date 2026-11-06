//! The two production batch-level ledger operations —
//! `prepareAgentToolBatchWithRequest:` and
//! `openAgentWriteBatchEffectGateWithRequest:` — as pure reducers in the
//! [`crate::ledger_ops`] view/effect shape. The facade collects the frozen
//! round, the attempt's batches, the task/attempt reservation, the request's
//! transcript row, the attempt's ledger rows and dispatch markers, the
//! round's denied calls, the task/attempt authorities and the task/attempt
//! operation results; approval tokens are host-generated UUIDs handed in
//! through the environment because the reducer has no randomness.
//!
//! `reserveWriteBytesForAttempt` and `prepareAgentWriteBatch` have no
//! production caller and stay in Objective-C until they are deleted.

use crate::canonical::{canonical_json, hash_bytes, hash_json};
use crate::execution_ledger::*;
use crate::ledger_ops::{
    advance_authority, change_json, dispatch_state_in, write_manifest_call_for_intent, Change,
    Slotted, View as RowView,
};
use crate::schema::*;
use crate::store::StoreError;
use serde_json::{json, Map, Value};

const MAX_DENIED_CALLS_PER_ATTEMPT: u64 = 128;
const MAX_DENIED_CALLS: u64 = 2048;
const ZERO_KEY: &str = "0000000000000000000000000000000000000000000000000000000000000000";

#[derive(Debug, Clone, Default)]
pub struct Env {
    pub launch_id: String,
    pub now: String,
    /// Fresh lowercase UUIDs for approval tokens, consumed in call order.
    pub approval_tokens: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct View {
    /// Whether ledger, dispatch, batches, reservations, transcripts and
    /// denied_calls tables all exist in the candidate.
    pub tables_present: bool,
    /// Round rows whose locator matches the request's task/attempt/round.
    pub rounds: Vec<Value>,
    pub batches: Vec<Slotted>,
    pub reservations: Vec<Slotted>,
    /// The full transcript row named by the request's transcript reference.
    pub transcript: Option<Value>,
    /// Message-free summaries of every transcript row (for row binding).
    pub transcript_summaries: Vec<Value>,
    /// The attempt's ledger rows.
    pub ledger_rows: Vec<Value>,
    /// The attempt's execution dispatch markers.
    pub dispatch: Vec<Value>,
    /// Denied-call rows of the request's round.
    pub denied_calls: Vec<Value>,
    pub denied_attempt_count: u64,
    pub denied_total_count: u64,
    pub authorities: Option<Vec<Slotted>>,
    pub authorities_present: bool,
    pub operations_present: bool,
    /// Operation result snapshots of the task/attempt.
    pub operation_results: Vec<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct Effect {
    pub commit: bool,
    pub output: Value,
    pub changes: Vec<Change>,
    pub commit_operation: Option<Value>,
}

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

fn u64_of(value: Option<&Value>) -> u64 {
    value.and_then(Value::as_u64).unwrap_or(0)
}

fn set(map: &mut Map<String, Value>, key: &str, value: Value) {
    map.insert(key.to_string(), value);
}

fn quadruple_matches(record: &Value, request: &Value) -> bool {
    get(record, "task_id") == get(request, "task_id")
        && get(record, "attempt_id") == get(request, "attempt_id")
        && get(record, "round_id") == get(request, "round_id")
        && get(record, "round_index") == get(request, "round_index")
}

// MARK: - Validators

/// `DSHAgentWriteReservationPolicy`.
pub fn write_reservation_policy(value: Option<&Value>) -> bool {
    let keys = [
        "schema_version",
        "policy_version",
        "max_single_write_bytes",
        "max_batch_write_bytes",
        "max_attempt_write_bytes",
    ];
    let Some(map) = exact_keys(value, &keys) else {
        return false;
    };
    let single = u64_of(map.get("max_single_write_bytes"));
    let batch = u64_of(map.get("max_batch_write_bytes"));
    let attempt = u64_of(map.get("max_attempt_write_bytes"));
    safe_integer(map.get("schema_version"), 1, false).is_some()
        && bounded_utf8(map.get("policy_version"), 128, false).is_some()
        && single == MAX_SINGLE_WRITE_BYTES
        && safe_integer(
            map.get("max_single_write_bytes"),
            MAX_SINGLE_WRITE_BYTES,
            false,
        )
        .is_some()
        && safe_integer(
            map.get("max_batch_write_bytes"),
            MAX_BATCH_WRITE_BYTES,
            false,
        )
        .is_some()
        && batch >= MAX_SINGLE_WRITE_BYTES
        && safe_integer(
            map.get("max_attempt_write_bytes"),
            MAX_ATTEMPT_WRITE_BYTES,
            false,
        )
        .is_some()
        && attempt >= batch
}

/// `DSHAgentWriteManifestCallShape`.
pub fn write_manifest_call_shape(call: Option<&Value>) -> bool {
    let Some(call) = call.filter(|c| c.is_object()) else {
        return false;
    };
    if safe_integer(get(call, "schema_version"), 2, false) != Some(2)
        || !ledger_locator(get(call, "locator"))
        || !canonical_sha256(get(call, "precondition_sha256"))
    {
        return false;
    }
    match as_str(get(call, "mutation_kind")) {
        Some("file_write") => {
            let keys = [
                "schema_version",
                "mutation_kind",
                "locator",
                "precondition_sha256",
                "relative_path_sha256",
                "prior",
                "content_sha256",
                "content_bytes",
            ];
            exact_keys(Some(call), &keys).is_some()
                && canonical_sha256(get(call, "relative_path_sha256"))
                && write_prior(get(call, "prior"))
                && canonical_sha256(get(call, "content_sha256"))
                && safe_integer(get(call, "content_bytes"), MAX_SINGLE_WRITE_BYTES, true).is_some()
        }
        Some(
            "git_commit"
            | "git_push"
            | "start_guest_cgi"
            | "stop_guest_cgi"
            | "install_runtime_environment"
            | "run_program"
            | "start_runtime_service"
            | "stop_runtime_service"
            | "create_assistant_task"
            | "update_assistant_task"
            | "remember_assistant_memory"
            | "forget_assistant_memory",
        ) => {
            exact_keys(
                Some(call),
                &[
                    "schema_version",
                    "mutation_kind",
                    "locator",
                    "precondition_sha256",
                    "content_bytes",
                ],
            )
            .is_some()
                && get(call, "content_bytes").and_then(Value::as_u64) == Some(0)
        }
        _ => false,
    }
}

/// `DSHAgentApprovalPreview`.
pub fn approval_preview(preview: Option<&Value>) -> bool {
    if preview
        .and_then(|p| p.get("kind"))
        .and_then(Value::as_str)
        .is_some_and(crate::assistant_tools::is_mutation)
    {
        return crate::assistant_tools::approval_preview_shape(preview);
    }
    if preview.is_some_and(|value| value["kind"] == crate::user_question::NAME) {
        return crate::user_question::question_shape(preview);
    }
    let keys = [
        "schema_version",
        "kind",
        "paths",
        "content_bytes",
        "prior",
        "diff_preview",
        "diff_truncated",
    ];
    let Some(map) = exact_keys(preview, &keys) else {
        return false;
    };
    let Some(Value::Array(paths)) = map.get("paths") else {
        return false;
    };
    let kind = as_str(map.get("kind"));
    if safe_integer(map.get("schema_version"), 1, false) != Some(1)
        || !matches!(
            kind,
            Some(
                "list_dir"
                    | "read_file"
                    | "write_file"
                    | "git_commit"
                    | "git_push"
                    | "start_guest_cgi"
                    | "stop_guest_cgi"
                    | "list_runtime_environments"
                    | "list_assistant_tasks"
                    | "search_assistant_memory"
                    | "install_runtime_environment"
                    | "run_program"
                    | "start_runtime_service"
                    | "stop_runtime_service"
                    | "create_assistant_task"
                    | "update_assistant_task"
                    | "remember_assistant_memory"
                    | "forget_assistant_memory"
            )
        )
        || paths.len() > 8
        || !matches!(map.get("diff_truncated"), Some(Value::Bool(_)))
    {
        return false;
    }
    for path in paths {
        let Some(text) = as_str(Some(path)) else {
            return false;
        };
        if text.is_empty()
            || text.len() > 512
            || text.starts_with('/')
            || text.contains('\\')
            || text.contains('\0')
            || text.chars().any(|c| c.is_control())
        {
            return false;
        }
    }
    let content_bytes = map.get("content_bytes");
    let prior = map.get("prior");
    let diff = map.get("diff_preview");
    if !(is_null(content_bytes)
        || safe_integer(content_bytes, MAX_SINGLE_WRITE_BYTES, true).is_some())
    {
        return false;
    }
    let prior_ok = is_null(prior)
        || exact_keys(prior, &["schema_version", "kind", "bytes"]).is_some_and(|p| {
            safe_integer(p.get("schema_version"), 1, false) == Some(1)
                && matches!(as_str(p.get("kind")), Some("absent" | "known"))
                && (is_null(p.get("bytes"))
                    || safe_integer(p.get("bytes"), MAX_SINGLE_WRITE_BYTES * 2, true).is_some())
        });
    if !prior_ok || !(is_null(diff) || bounded_utf8(diff, 4096, true).is_some()) {
        return false;
    }
    match kind {
        Some("write_file") => paths.len() == 1 && !is_null(content_bytes) && !is_null(prior),
        Some("start_guest_cgi") => {
            matches!(paths.len(), 0 | 2 | 3)
                && is_null(content_bytes)
                && is_null(prior)
                && is_null(diff)
        }
        Some("git_commit" | "git_push" | "stop_guest_cgi") => {
            paths.is_empty() && is_null(content_bytes) && is_null(prior) && is_null(diff)
        }
        _ => is_null(content_bytes) && is_null(prior) && is_null(diff),
    }
}

/// `DSHAgentLedgerRejection`.
pub fn ledger_rejection(rejection: Option<&Value>) -> bool {
    let Some(map) = exact_keys(rejection, &["failure_code", "reason"]) else {
        return false;
    };
    matches!(
        as_str(map.get("failure_code")),
        Some("E_AGENT_BAD_ARGUMENTS" | "E_AGENT_BAD_PATH")
    ) && bounded_utf8(map.get("reason"), 64, false)
        .is_some_and(|reason| reason.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'))
}

fn transcript_summary_bound(view: &View, row: &Value) -> Result<(), StoreError> {
    let reference = get(row, "transcript_before").and_then(|b| get(b, "transcript_ref"));
    let transcript = view
        .transcript_summaries
        .iter()
        .find(|t| get(t, "transcript_ref") == reference);
    transcript_bound(transcript, row)
}

/// `DSHAgentBatchEffectGateRevalidated`.
fn batch_effect_gate_revalidated(view: &View, batch: &Value) -> Result<(), StoreError> {
    let (Some(Value::Array(calls)), Some(Value::Array(write_keys))) =
        (get(batch, "manifest_calls"), get(batch, "write_keys"))
    else {
        return Err(StoreError::Corrupt);
    };
    if calls.is_empty() || calls.len() != write_keys.len() {
        return Err(StoreError::Corrupt);
    }
    let manifest = hash_json("write-manifest", &json!({ "calls": calls }));
    if manifest.as_deref() != as_str(get(batch, "manifest_sha256")) {
        return Err(StoreError::Corrupt);
    }
    let mut reservation: Option<&Value> = None;
    for entry in &view.reservations {
        if get(&entry.record, "task_id") == get(batch, "task_id")
            && get(&entry.record, "attempt_id") == get(batch, "attempt_id")
        {
            if reservation.is_some() {
                return Err(StoreError::Corrupt);
            }
            reservation = Some(&entry.record);
        }
    }
    let Some(reservation) = reservation else {
        return Err(StoreError::Conflict);
    };
    if get(reservation, "root_fingerprint_sha256") != get(batch, "root_fingerprint_sha256")
        || get(reservation, "binding_revision") != get(batch, "binding_revision")
        || !write_reservation_policy(get(reservation, "policy"))
        || u64_of(get(batch, "reserved_write_bytes"))
            > u64_of(get(reservation, "reserved_write_bytes"))
        || get(batch, "batch_revision") != get(reservation, "reservation_version")
    {
        return Err(StoreError::Conflict);
    }
    let mut locator_keys: Vec<Vec<u8>> = Vec::new();
    let mut paths: Vec<&Value> = Vec::new();
    for (index, call) in calls.iter().enumerate() {
        let locator = get(call, "locator");
        if !write_manifest_call_shape(Some(call))
            || Some(&write_keys[index]) != locator.and_then(|l| get(l, "idempotency_key"))
        {
            return Err(StoreError::Conflict);
        }
        let file_mutation = string_eq(get(call, "mutation_kind"), "file_write");
        if file_mutation {
            let path = get(call, "relative_path_sha256");
            if string_eq(get(call, "prior").and_then(|p| get(p, "kind")), "unknown")
                || path.is_some_and(|p| paths.contains(&p))
            {
                return Err(StoreError::Conflict);
            }
            if let Some(path) = path {
                paths.push(path);
            }
        }
        let Some(key) = locator.and_then(|l| canonical_json(l).ok()) else {
            return Err(StoreError::Corrupt);
        };
        if locator_keys.contains(&key) {
            return Err(StoreError::Corrupt);
        }
        locator_keys.push(key);
        let mut row: Option<&Value> = None;
        for candidate in &view.ledger_rows {
            if get(candidate, "locator") == locator {
                if row.is_some() {
                    return Err(StoreError::Corrupt);
                }
                row = Some(candidate);
            }
        }
        let expected_name = if file_mutation {
            "write_file".to_string()
        } else {
            as_str(get(call, "mutation_kind"))
                .unwrap_or_default()
                .to_string()
        };
        let precondition_sha = row.and_then(|row| {
            hash_json(
                "tool-precondition",
                &json!({ "schema_version": 1, "name": get(row, "name"), "precondition": get(row, "precondition") }),
            )
        });
        let Some(row) = row else {
            return Err(StoreError::Conflict);
        };
        let receipt = get(row, "receipt").filter(|r| r.is_object());
        let user_denied_row = string_eq(get(row, "state"), "settled")
            && receipt.is_some_and(|receipt| {
                string_eq(get(receipt, "outcome"), "denied")
                    && string_eq(get(receipt, "failure_code"), "E_AGENT_DENIED_BY_USER")
                    && is_null(get(receipt, "approval_reference"))
            })
            && is_null(get(row, "settled_facts"));
        if !ledger_row(row)
            || (!string_eq(get(row, "state"), "intent") && !user_denied_row)
            || get(row, "locator").and_then(|l| get(l, "task_id")) != get(batch, "task_id")
            || get(row, "locator").and_then(|l| get(l, "attempt_id")) != get(batch, "attempt_id")
            || get(row, "root_fingerprint_sha256") != get(batch, "root_fingerprint_sha256")
            || get(row, "binding_revision") != get(batch, "binding_revision")
            || as_str(get(row, "name")) != Some(expected_name.as_str())
            || precondition_sha.is_none()
            || precondition_sha.as_deref() != as_str(get(call, "precondition_sha256"))
        {
            return Err(StoreError::Conflict);
        }
        transcript_summary_bound(view, row)?;
        if dispatch_state_in(&view.dispatch, get(row, "locator")) != Some("not_dispatched") {
            return Err(StoreError::Conflict);
        }
        let precondition = get(row, "precondition").unwrap_or(&Value::Null);
        if !file_mutation {
            if u64_of(get(row, "reserved_write_bytes")) != 0
                || get(row, "reserved_write_bytes")
                    .and_then(Value::as_u64)
                    .is_none()
            {
                return Err(StoreError::Conflict);
            }
            continue;
        }
        if get(precondition, "relative_path_sha256") != get(call, "relative_path_sha256")
            || get(precondition, "prior") != get(call, "prior")
            || get(precondition, "content_sha256") != get(call, "content_sha256")
            || get(precondition, "content_bytes") != get(call, "content_bytes")
            || get(row, "reserved_write_bytes") != get(call, "content_bytes")
        {
            return Err(StoreError::Conflict);
        }
        let mut found = false;
        if let Some(Value::Array(keys)) = get(reservation, "keys") {
            for key in keys {
                if get(key, "idempotency_key") != locator.and_then(|l| get(l, "idempotency_key")) {
                    continue;
                }
                if !string_eq(get(key, "state"), "active")
                    || get(key, "relative_path_sha256") != get(call, "relative_path_sha256")
                    || get(key, "content_sha256") != get(call, "content_sha256")
                    || get(key, "content_bytes") != get(call, "content_bytes")
                {
                    return Err(StoreError::Conflict);
                }
                found = true;
            }
        }
        if !found {
            return Err(StoreError::Conflict);
        }
    }
    Ok(())
}

/// `DSHAgentMutationBatchApprovalsBound`.
fn mutation_batch_approvals_bound(view: &View, batch: &Value) -> Result<(), StoreError> {
    if !view.authorities_present && !view.operations_present {
        return Ok(());
    }
    let mut receipt: Option<&Value> = None;
    for snapshot in &view.operation_results {
        let wrapper = get(snapshot, "result").unwrap_or(&Value::Null);
        let candidate = get(wrapper, "result")
            .and_then(|r| get(r, "receipt"))
            .unwrap_or(&Value::Null);
        if string_eq(get(wrapper, "result_kind"), "prepare_agent_tool_batch")
            && quadruple_matches(candidate, batch)
            && get(candidate, "batch_revision") == get(batch, "batch_revision")
            && get(candidate, "manifest_sha256") == get(batch, "manifest_sha256")
        {
            if receipt.is_some() {
                return Err(StoreError::Corrupt);
            }
            receipt = Some(candidate);
        }
    }
    let Some(receipt) = receipt else {
        return Err(StoreError::Conflict);
    };
    let Some(Value::Array(calls)) = get(batch, "manifest_calls") else {
        return Err(StoreError::Conflict);
    };
    for manifest_call in calls {
        let locator = get(manifest_call, "locator").unwrap_or(&Value::Null);
        let safe_call = match get(receipt, "calls") {
            Some(Value::Array(candidates)) => candidates.iter().find(|candidate| {
                get(candidate, "call_index") == get(locator, "call_index")
                    && get(candidate, "call_id") == get(locator, "call_id")
                    && get(candidate, "idempotency_key") == get(locator, "idempotency_key")
            }),
            _ => None,
        };
        let Some(safe_call) = safe_call else {
            return Err(StoreError::Conflict);
        };
        if string_eq(get(safe_call, "approval_state"), "bound")
            && !is_null(get(safe_call, "approval_reference"))
        {
            continue;
        }
        let mut bound = false;
        let mut denied_settled = false;
        for snapshot in &view.operation_results {
            let result = get(snapshot, "result")
                .and_then(|r| get(r, "result"))
                .unwrap_or(&Value::Null);
            if !matches!(
                as_str(get(result, "status")),
                Some("bound" | "already_bound")
            ) || get(result, "task_id") != get(batch, "task_id")
                || get(result, "attempt_id") != get(batch, "attempt_id")
                || get(result, "round_id") != get(batch, "round_id")
                || get(result, "call_index") != get(safe_call, "call_index")
                || get(result, "call_id") != get(safe_call, "call_id")
                || get(result, "result_batch_revision") != get(batch, "batch_revision")
            {
                continue;
            }
            if matches!(
                as_str(get(result, "decision")),
                Some("allow_once" | "allow_conversation")
            ) && !is_null(get(result, "approval_reference"))
            {
                bound = true;
                break;
            }
            if string_eq(get(result, "decision"), "denied")
                && is_null(get(result, "approval_reference"))
                && get(result, "receipt").is_some_and(|r| r.is_object())
                && string_eq(
                    get(result, "receipt").and_then(|r| get(r, "outcome")),
                    "denied",
                )
            {
                denied_settled = true;
                break;
            }
        }
        if !bound && !denied_settled {
            return Err(StoreError::Conflict);
        }
    }
    Ok(())
}

// MARK: - Operations

struct DeniedCandidate {
    call: Value,
    projection_index: usize,
    outcome: &'static str,
    failure_code: Value,
    reason: Option<Value>,
}

fn locator_for(request: &Value, call: &Value, key: &str) -> Value {
    json!({
        "schema_version": 2,
        "task_id": get(request, "task_id"),
        "attempt_id": get(request, "attempt_id"),
        "round_id": get(request, "round_id"),
        "round_index": get(request, "round_index"),
        "call_index": get(call, "call_index"),
        "call_id": get(call, "call_id"),
        "idempotency_key": key,
    })
}

#[allow(clippy::too_many_lines)]
fn prepare_tool_batch(request: &Value, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let compound = get(request, "operation_id").is_some();
    let mut request_keys = vec![
        "schema_version",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "round_revision",
        "root",
        "transcript",
        "policy",
        "expected_batch_revision",
        "expected_reserved_write_bytes",
        "calls",
    ];
    if compound {
        request_keys.extend([
            "operation_id",
            "operation_request_sha256",
            "conversation_id",
            "controller_cas",
            "observed_checkpoint",
        ]);
    }
    let Some(Value::Array(calls)) = get(request, "calls") else {
        return Err(StoreError::InvalidArgument);
    };
    if exact_keys(Some(request), &request_keys).is_none()
        || safe_integer(get(request, "schema_version"), 2, false) != Some(2)
        || !canonical_uuid(get(request, "task_id"))
        || !canonical_uuid(get(request, "attempt_id"))
        || !canonical_uuid(get(request, "round_id"))
        || safe_integer(get(request, "round_index"), 7, true).is_none()
        || safe_integer(get(request, "round_revision"), MAX_SAFE_INTEGER, false).is_none()
        || !root_full(get(request, "root"))
        || !transcript_reference(get(request, "transcript"))
        || !write_reservation_policy(get(request, "policy"))
        || safe_integer(
            get(request, "expected_batch_revision"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_none()
        || safe_integer(
            get(request, "expected_reserved_write_bytes"),
            MAX_ATTEMPT_WRITE_BYTES,
            true,
        )
        .is_none()
        || calls.is_empty()
        || calls.len() > 16
        || (compound
            && (!canonical_uuid(get(request, "operation_id"))
                || !canonical_sha256(get(request, "operation_request_sha256"))
                || !canonical_uuid(get(request, "conversation_id"))
                || !get(request, "controller_cas").is_some_and(|c| c.is_object())
                || !get(request, "observed_checkpoint").is_some_and(|c| c.is_object())))
    {
        return Err(StoreError::InvalidArgument);
    }
    let timestamp = env.now.as_str();
    let root = get(request, "root").expect("validated");
    let transcript = get(request, "transcript").expect("validated");
    let mut intents: Vec<Value> = Vec::new();
    let mut projections: Vec<Map<String, Value>> = Vec::new();
    let mut denied: Vec<DeniedCandidate> = Vec::new();
    let mut manifest_calls: Vec<Value> = Vec::new();
    let mut write_keys: Vec<Value> = Vec::new();
    let mut call_ids: Vec<Value> = Vec::new();
    let mut write_paths: Vec<Value> = Vec::new();
    let mut source_calls: Vec<Value> = Vec::new();

    for (index, supplied) in calls.iter().enumerate() {
        let mut rejection: Option<&Value> = None;
        let mut call_map = object_map(supplied);
        // `prepare_calls` writes this key on every call and leaves it null when
        // there is nothing to reject. Removing it only when it is non-null left
        // an accepted call carrying a key the exact-key check below refuses --
        // so a rejected call could be prepared and an accepted one never could.
        let supplied_rejection = call_map.remove("rejection");
        if let Some(supplied_rejection) = supplied_rejection.as_ref() {
            if !supplied_rejection.is_null() {
                if !(ledger_rejection(Some(supplied_rejection))
                    || (as_str(get(supplied, "name")).is_some_and(|name| {
                        crate::runtime_tools::is_runtime(name)
                            || crate::assistant_tools::is_assistant(name)
                    }) && crate::runtime_tools::prepare_rejection(Some(supplied_rejection))))
                {
                    return Err(StoreError::InvalidArgument);
                }
                rejection = Some(supplied_rejection);
            }
        }
        let call = Value::Object(call_map);
        let mut call_keys = vec![
            "call_index",
            "call_id",
            "name",
            "arguments_json",
            "arguments_sha256",
            "safe_summary_key",
            "access",
            "precondition",
            "reserved_write_bytes",
        ];
        if compound {
            call_keys.push("grant_reference");
        }
        let mut keys_with_preview = call_keys.clone();
        keys_with_preview.push("approval_preview");
        let preview = get(&call, "approval_preview").filter(|p| !p.is_null());
        if (exact_keys(Some(&call), &call_keys).is_none()
            && exact_keys(Some(&call), &keys_with_preview).is_none())
            || get(&call, "call_index").and_then(Value::as_u64) != Some(index as u64)
            || bounded_utf8(get(&call, "call_id"), 128, false).is_none()
            || tool_name_well_formed(get(&call, "name")).is_none()
            || bounded_utf8(get(&call, "arguments_json"), 256 * 1024, false).is_none()
            || !canonical_sha256(get(&call, "arguments_sha256"))
            || bounded_utf8(get(&call, "safe_summary_key"), 128, false).is_none()
            || as_str(get(&call, "access")).is_none()
            || safe_integer(
                get(&call, "reserved_write_bytes"),
                MAX_SINGLE_WRITE_BYTES,
                true,
            )
            .is_none()
            || preview.is_some_and(|preview| !approval_preview(Some(preview)))
            || (compound
                && !(is_null(get(&call, "grant_reference"))
                    || canonical_uuid(get(&call, "grant_reference"))))
            || call_ids.contains(get(&call, "call_id").unwrap_or(&Value::Null))
        {
            return Err(StoreError::InvalidArgument);
        }
        call_ids.push(get(&call, "call_id").cloned().unwrap_or(Value::Null));
        let access = as_str(get(&call, "access")).unwrap_or_default().to_string();
        let durable_deny = access == "durable_deny";
        if !durable_deny
            && !matches!(
                access.as_str(),
                "auto" | "conversation_confirm" | "confirm_once"
            )
        {
            return Err(StoreError::InvalidArgument);
        }
        let reserved_zero = get(&call, "reserved_write_bytes").and_then(Value::as_u64) == Some(0);
        let name = as_str(get(&call, "name")).unwrap_or_default().to_string();
        if durable_deny {
            if !is_null(get(&call, "precondition")) || !reserved_zero {
                return Err(StoreError::Conflict);
            }
            let projection = json!({
                "schema_version": 2,
                "call_index": get(&call, "call_index"), "call_id": get(&call, "call_id"),
                "name": name, "arguments_sha256": get(&call, "arguments_sha256"),
                "idempotency_key": null, "safe_summary_key": "agent.unknown", "access": "durable_deny",
                "approval_state": "denied", "approval_token": null, "approval_reference": null,
                "execution_status": "denied", "execution_revision": null, "native_row_revision": null,
                "receipt": null, "approval_preview": null,
            });
            projections.push(object_map(&projection));
            let known = matches!(
                name.as_str(),
                "list_dir"
                    | "read_file"
                    | "write_file"
                    | "git_status"
                    | "git_commit"
                    | "git_push"
                    | "start_guest_cgi"
                    | "stop_guest_cgi"
                    | "list_runtime_environments"
                    | "list_assistant_tasks"
                    | "search_assistant_memory"
                    | "install_runtime_environment"
                    | "run_program"
                    | "start_runtime_service"
                    | "stop_runtime_service"
                    | "create_assistant_task"
                    | "update_assistant_task"
                    | "remember_assistant_memory"
                    | "forget_assistant_memory"
            );
            denied.push(DeniedCandidate {
                call: call.clone(),
                projection_index: projections.len() - 1,
                outcome: "denied",
                failure_code: Value::from(if known {
                    "E_AGENT_CAPABILITY"
                } else {
                    "E_AGENT_UNKNOWN_TOOL"
                }),
                reason: None,
            });
            source_calls.push(call);
            continue;
        }
        if let Some(rejection) = rejection {
            if !is_null(get(&call, "precondition")) || !reserved_zero {
                return Err(StoreError::Conflict);
            }
            let Some(rejected_sha) =
                arguments_sha256(get(&call, "name"), get(&call, "arguments_json"))
            else {
                return Err(StoreError::InvalidArgument);
            };
            if as_str(get(&call, "arguments_sha256")) != Some(rejected_sha.as_str()) {
                return Err(StoreError::Conflict);
            }
            let rejected_locator = locator_for(request, &call, ZERO_KEY);
            let Some(rejected_key) = idempotency_key_for_locator(
                Some(&rejected_locator),
                get(root, "root_fingerprint_sha256"),
                Some(&Value::from(rejected_sha.as_str())),
            ) else {
                return Err(StoreError::InvalidArgument);
            };
            let projection = json!({
                "schema_version": 2,
                "call_index": get(&call, "call_index"), "call_id": get(&call, "call_id"),
                "name": name, "arguments_sha256": rejected_sha, "idempotency_key": rejected_key,
                "safe_summary_key": get(&call, "safe_summary_key"), "access": access,
                "approval_state": if access == "auto" { "not_required" } else { "cancelled" },
                "approval_token": null, "approval_reference": null,
                "execution_status": "failed", "execution_revision": 1,
                "native_row_revision": null, "receipt": null, "approval_preview": null,
            });
            projections.push(object_map(&projection));
            denied.push(DeniedCandidate {
                call: call.clone(),
                projection_index: projections.len() - 1,
                outcome: "failed",
                failure_code: get(rejection, "failure_code")
                    .cloned()
                    .unwrap_or(Value::Null),
                reason: get(rejection, "reason").cloned(),
            });
            source_calls.push(call);
            continue;
        }
        let precondition = get(&call, "precondition").unwrap_or(&Value::Null);
        if !precondition_shape(Some(precondition))
            || get(precondition, "kind") != get(&call, "name")
        {
            return Err(StoreError::InvalidArgument);
        }
        let Some(arguments_sha) =
            arguments_sha256(get(&call, "name"), get(&call, "arguments_json"))
        else {
            return Err(StoreError::InvalidArgument);
        };
        if as_str(get(&call, "arguments_sha256")) != Some(arguments_sha.as_str()) {
            return Err(StoreError::Conflict);
        }
        let mut locator = locator_for(request, &call, ZERO_KEY);
        let Some(key) = idempotency_key_for_locator(
            Some(&locator),
            get(root, "root_fingerprint_sha256"),
            Some(&Value::from(arguments_sha.as_str())),
        ) else {
            return Err(StoreError::InvalidArgument);
        };
        locator["idempotency_key"] = Value::from(key.as_str());
        let intent = json!({
            "schema_version": 2, "locator": locator, "row_revision": 1,
            "root_fingerprint_sha256": get(root, "root_fingerprint_sha256"),
            "binding_revision": get(root, "workspace_binding_revision"),
            "transcript_before": transcript, "name": name,
            "arguments_sha256": arguments_sha, "precondition": precondition,
            "reserved_write_bytes": get(&call, "reserved_write_bytes"),
            "state": "intent", "owner": null, "settled_facts": null, "transcript_after": null,
            "receipt": null, "created_at": timestamp, "updated_at": timestamp,
        });
        if crate::assistant_tools::is_assistant(&name) {
            let expected_access = if crate::assistant_tools::is_mutation(&name) {
                "conversation_confirm"
            } else {
                "auto"
            };
            let authorized = view.authorities.as_ref().is_some_and(|authorities| {
                authorities.iter().any(|entry| {
                    let authority = &entry.record;
                    crate::assistant_context::authority_valid(authority)
                        && authority["task_id"] == request["task_id"]
                        && authority["attempt_id"] == request["attempt_id"]
                        && authority["conversation_id"] == request["conversation_id"]
                        && authority["registry"]["registry_version"] == 5
                        && authority["root"] == request["root"]
                        && authority["state"] == "prepared"
                        && authority["registry"]["tools"]
                            .as_array()
                            .is_some_and(|tools| {
                                tools.iter().any(|tool| {
                                    tool["name"] == name && tool["access"] == expected_access
                                })
                            })
                })
            });
            if !authorized
                || access != expected_access
                || precondition["conversation_id"] != request["conversation_id"]
            {
                return Err(StoreError::Conflict);
            }
        }
        if !ledger_row(&intent) {
            return Err(StoreError::Conflict);
        }
        raw_arguments_bind_intent(get(&call, "arguments_json"), &intent)?;
        if crate::assistant_tools::is_mutation(&name) {
            let arguments = as_str(get(&call, "arguments_json"))
                .and_then(crate::strict_json::parse_arguments)
                .map(Value::Object)
                .ok_or(StoreError::InvalidArgument)?;
            if call["approval_preview"]
                != crate::assistant_tools::approval_preview(&name, &arguments)
            {
                return Err(StoreError::Conflict);
            }
        }
        let file_mutation = name == "write_file";
        let git_mutation = matches!(
            name.as_str(),
            "git_commit"
                | "git_push"
                | "start_guest_cgi"
                | "stop_guest_cgi"
                | "install_runtime_environment"
                | "run_program"
                | "start_runtime_service"
                | "stop_runtime_service"
                | "create_assistant_task"
                | "update_assistant_task"
                | "remember_assistant_memory"
                | "forget_assistant_memory"
        );
        if file_mutation || git_mutation {
            if file_mutation {
                let path_digest = get(precondition, "relative_path_sha256")
                    .cloned()
                    .unwrap_or(Value::Null);
                if write_paths.contains(&path_digest)
                    || get(&call, "reserved_write_bytes") != get(precondition, "content_bytes")
                    || string_eq(
                        get(precondition, "prior").and_then(|p| get(p, "kind")),
                        "unknown",
                    )
                {
                    return Err(StoreError::Conflict);
                }
                write_paths.push(path_digest);
            } else if !reserved_zero {
                return Err(StoreError::Conflict);
            }
            let manifest_call = write_manifest_call_for_intent(&intent);
            if !write_manifest_call_shape(manifest_call.as_ref()) {
                return Err(StoreError::InvalidArgument);
            }
            manifest_calls.push(manifest_call.expect("validated"));
            write_keys.push(Value::from(key.as_str()));
        } else if !reserved_zero {
            return Err(StoreError::Conflict);
        }
        intents.push(intent);
        let projection = json!({
            "schema_version": 2,
            "call_index": get(&call, "call_index"), "call_id": get(&call, "call_id"),
            "name": name, "arguments_sha256": arguments_sha, "idempotency_key": key,
            "safe_summary_key": get(&call, "safe_summary_key"), "access": access,
            "approval_state": if access == "auto" { "not_required" } else { "pending" },
            "approval_token": null, "approval_reference": null,
            "execution_status": "intent", "execution_revision": 1, "native_row_revision": 1,
            "receipt": null, "approval_preview": get(&call, "approval_preview").cloned().unwrap_or(Value::Null),
        });
        projections.push(object_map(&projection));
        source_calls.push(call);
    }

    // Replay: an existing batch for this round answers without committing.
    for entry in &view.batches {
        let existing = &entry.record;
        if !quadruple_matches(existing, request) {
            continue;
        }
        let same_manifest = if manifest_calls.is_empty() {
            is_null(get(existing, "manifest_sha256"))
        } else {
            get(existing, "manifest_calls") == Some(&Value::Array(manifest_calls.clone()))
        };
        if !same_manifest {
            return Err(StoreError::Conflict);
        }
        let mut replay_transcript = transcript.clone();
        for denial in &view.denied_calls {
            if !quadruple_matches(denial, request) {
                continue;
            }
            for projection in projections.iter_mut() {
                if projection.get("call_index") == get(denial, "call_index")
                    && projection.get("call_id") == get(denial, "call_id")
                    && projection.get("arguments_sha256") == get(denial, "arguments_sha256")
                {
                    set(
                        projection,
                        "native_row_revision",
                        get(denial, "row_revision").cloned().unwrap_or(Value::Null),
                    );
                    set(
                        projection,
                        "receipt",
                        get(denial, "receipt").cloned().unwrap_or(Value::Null),
                    );
                    if u64_of(get(denial, "transcript_after").and_then(|t| get(t, "generation")))
                        > u64_of(get(&replay_transcript, "generation"))
                    {
                        replay_transcript = get(denial, "transcript_after")
                            .cloned()
                            .unwrap_or(Value::Null);
                    }
                }
            }
        }
        let calls: Vec<Value> = projections.into_iter().map(Value::Object).collect();
        return Ok(Effect {
            commit: false,
            output: json!({
                "schema_version": 2, "status": "already_prepared",
                "batch_kind": get(existing, "kind"), "batch_revision": get(existing, "batch_revision"),
                "manifest_sha256": get(existing, "manifest_sha256"),
                "batch_new_write_bytes": get(existing, "reservation_delta_bytes"),
                "reserved_write_bytes": get(existing, "attempt_reserved_write_bytes"),
                "effect_gate": get(existing, "effect_gate"), "calls": calls,
                "transcript": replay_transcript,
            }),
            ..Default::default()
        });
    }

    // Transaction phase.
    if !view.tables_present {
        return Err(StoreError::Corrupt);
    }
    if view.rounds.len() > 1 {
        return Err(StoreError::Corrupt);
    }
    let frozen_round = view.rounds.first();
    if compound
        && !frozen_round.is_some_and(|round| {
            string_eq(get(round, "state"), "completed")
                && get(round, "row_revision") == get(request, "round_revision")
                && get(round, "transcript_after") == Some(transcript)
                && string_eq(get(round, "terminal_kind"), "tool_batch")
        })
    {
        return Err(StoreError::Conflict);
    }
    if view
        .batches
        .iter()
        .any(|entry| quadruple_matches(&entry.record, request))
    {
        return Err(StoreError::Conflict);
    }
    let latest_attempt_batch = view.batches.iter().rev().find(|entry| {
        get(&entry.record, "task_id") == get(request, "task_id")
            && get(&entry.record, "attempt_id") == get(request, "attempt_id")
    });
    let expected_prior_revision = latest_attempt_batch
        .and_then(|entry| get(&entry.record, "batch_revision").cloned())
        .unwrap_or(Value::from(0u64));
    if get(request, "expected_batch_revision") != Some(&expected_prior_revision) {
        return Err(StoreError::Conflict);
    }
    let mut existing_attempt_rows = 0u64;
    for row in &view.ledger_rows {
        if get(row, "locator").and_then(|l| get(l, "attempt_id")) == get(request, "attempt_id") {
            existing_attempt_rows += 1;
        }
        if intents
            .iter()
            .any(|intent| get(row, "locator") == get(intent, "locator"))
        {
            return Err(StoreError::Conflict);
        }
    }
    if existing_attempt_rows + intents.len() as u64 > MAX_LEDGER_ROWS_PER_ATTEMPT as u64 {
        return Err(StoreError::Capacity);
    }
    for intent in &intents {
        transcript_bound(view.transcript.as_ref(), intent)?;
    }
    let Some(transcript_row) = view
        .transcript
        .as_ref()
        .filter(|row| get(row, "transcript_ref") == get(transcript, "transcript_ref"))
    else {
        return Err(StoreError::Conflict);
    };
    if get(transcript_row, "attempt_id") != get(request, "attempt_id")
        || get(transcript_row, "root_fingerprint_sha256") != get(root, "root_fingerprint_sha256")
        || get(transcript_row, "generation") != get(transcript, "generation")
        || get(transcript_row, "transcript_sha256") != get(transcript, "transcript_sha256")
        || get(transcript_row, "transcript_bytes") != get(transcript, "transcript_bytes")
        || !string_eq(get(transcript_row, "state"), "open")
    {
        return Err(StoreError::Conflict);
    }
    let mut transcript_next = object_map(transcript_row);

    let reservation_entry = view.reservations.iter().find(|entry| {
        get(&entry.record, "task_id") == get(request, "task_id")
            && get(&entry.record, "attempt_id") == get(request, "attempt_id")
    });
    let reservation_absent = reservation_entry.is_none();
    let mut reservation = match reservation_entry {
        Some(entry) => {
            let record = &entry.record;
            if get(record, "root_fingerprint_sha256") != get(root, "root_fingerprint_sha256")
                || get(record, "binding_revision") != get(root, "workspace_binding_revision")
                || get(record, "policy") != get(request, "policy")
            {
                return Err(StoreError::Conflict);
            }
            object_map(record)
        }
        None => object_map(&json!({
            "schema_version": 1, "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
            "root_fingerprint_sha256": get(root, "root_fingerprint_sha256"),
            "binding_revision": get(root, "workspace_binding_revision"),
            "policy": get(request, "policy"), "reserved_write_bytes": 0, "reservation_version": 0, "keys": [],
        })),
    };
    let mut reserved = u64_of(reservation.get("reserved_write_bytes"));
    if reserved != u64_of(get(request, "expected_reserved_write_bytes")) {
        return Err(StoreError::Conflict);
    }
    let mut keys = match reservation.get("keys") {
        Some(Value::Array(keys)) => keys.clone(),
        _ => Vec::new(),
    };
    let mut batch_new = 0u64;
    for manifest_call in &manifest_calls {
        if !string_eq(get(manifest_call, "mutation_kind"), "file_write") {
            continue;
        }
        let idempotency_key = get(manifest_call, "locator").and_then(|l| get(l, "idempotency_key"));
        let candidate = json!({
            "idempotency_key": idempotency_key,
            "relative_path_sha256": get(manifest_call, "relative_path_sha256"),
            "content_sha256": get(manifest_call, "content_sha256"),
            "content_bytes": get(manifest_call, "content_bytes"), "state": "active",
        });
        match keys
            .iter()
            .find(|key| get(key, "idempotency_key") == idempotency_key)
        {
            Some(existing) => {
                if *existing != candidate {
                    return Err(StoreError::Corrupt);
                }
            }
            None => {
                keys.push(candidate);
                batch_new += u64_of(get(manifest_call, "content_bytes"));
            }
        }
    }
    let policy = get(request, "policy").expect("validated");
    let max_batch = u64_of(get(policy, "max_batch_write_bytes"));
    let max_attempt = u64_of(get(policy, "max_attempt_write_bytes"));
    if batch_new > max_batch || reserved > max_attempt || batch_new > max_attempt - reserved {
        return Err(StoreError::Capacity);
    }
    reserved += batch_new;
    let mut reservation_version = u64_of(reservation.get("reservation_version"));
    if !manifest_calls.is_empty() {
        if reservation_version == MAX_SAFE_INTEGER {
            return Err(StoreError::Capacity);
        }
        reservation_version += 1;
    }
    let batch_revision = if manifest_calls.is_empty() {
        u64_of(get(request, "round_revision"))
    } else {
        reservation_version
    };
    let mut changes: Vec<Change> = Vec::new();
    if !manifest_calls.is_empty() {
        set(
            &mut reservation,
            "reserved_write_bytes",
            Value::from(reserved),
        );
        set(
            &mut reservation,
            "reservation_version",
            Value::from(reservation_version),
        );
        set(&mut reservation, "keys", Value::Array(keys));
        match reservation_entry {
            Some(entry) => changes.push(Change::ReplaceReservation {
                slot: entry.slot,
                record: Value::Object(reservation),
            }),
            None => changes.push(Change::InsertReservation(Value::Object(reservation))),
        }
    } else if reservation_absent && reserved != 0 {
        return Err(StoreError::Conflict);
    }

    for intent in &intents {
        changes.push(Change::InsertLedgerRow(intent.clone()));
        changes.push(Change::InsertDispatchMarker(json!({
            "schema_version": 1, "kind": "execution", "locator": get(intent, "locator"), "dispatch_state": "not_dispatched",
        })));
    }
    let mut transcript_changed = false;
    if !denied.is_empty() {
        if view.denied_attempt_count + denied.len() as u64 > MAX_DENIED_CALLS_PER_ATTEMPT
            || view.denied_total_count + denied.len() as u64 > MAX_DENIED_CALLS
        {
            return Err(StoreError::Capacity);
        }
        let mut messages = match transcript_next.get("messages") {
            Some(Value::Array(messages)) => messages.clone(),
            _ => Vec::new(),
        };
        let mut current_reference = transcript.clone();
        for candidate in &denied {
            let call = &candidate.call;
            let mut payload =
                json!({ "schema_version": 1, "failure_code": candidate.failure_code });
            if let Some(reason) = &candidate.reason {
                payload["reason"] = reason.clone();
            }
            let feedback = json!({ "schema_version": 1, "name": get(call, "name"), "outcome": candidate.outcome, "payload": payload });
            let feedback_bytes =
                canonical_json(&feedback).map_err(|_| StoreError::InvalidArgument)?;
            let feedback_string = String::from_utf8(feedback_bytes.clone())
                .map_err(|_| StoreError::InvalidArgument)?;
            let feedback_sha =
                hash_bytes("tool-result", &feedback_bytes).ok_or(StoreError::InvalidArgument)?;
            if feedback_bytes.len() > 8 * 1024 {
                return Err(StoreError::InvalidArgument);
            }
            feedback_string_valid(&feedback_string)?;
            messages.push(json!({
                "schema_version": 1, "role": "tool", "round_index": get(request, "round_index"),
                "call_id": get(call, "call_id"), "content": feedback_string, "truncated": false,
            }));
            let generation = u64_of(transcript_next.get("generation"));
            if generation == MAX_SAFE_INTEGER {
                return Err(StoreError::Capacity);
            }
            let generation = generation + 1;
            let (digest, bytes) = transcript_digest(
                &Value::Object(transcript_next.clone()),
                &messages,
                generation,
            )?;
            set(
                &mut transcript_next,
                "messages",
                Value::Array(messages.clone()),
            );
            set(&mut transcript_next, "generation", Value::from(generation));
            set(
                &mut transcript_next,
                "transcript_sha256",
                Value::from(digest.as_str()),
            );
            set(&mut transcript_next, "transcript_bytes", Value::from(bytes));
            set(&mut transcript_next, "updated_at", Value::from(timestamp));
            let after = transcript_reference_value(
                transcript_next.get("transcript_ref"),
                generation,
                &digest,
                bytes,
            );
            let receipt = json!({
                "schema_version": 1, "call_id": get(call, "call_id"), "name": get(call, "name"),
                "arguments_sha256": get(call, "arguments_sha256"), "result_sha256": feedback_sha,
                "result_bytes": feedback_bytes.len() as u64, "truncated": false, "duration_ms": 0,
                "outcome": candidate.outcome, "failure_code": candidate.failure_code, "approval_reference": null,
            });
            let denied_row = json!({
                "schema_version": 1, "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
                "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
                "call_index": get(call, "call_index"), "call_id": get(call, "call_id"), "name": get(call, "name"),
                "arguments_sha256": get(call, "arguments_sha256"),
                "root_fingerprint_sha256": get(root, "root_fingerprint_sha256"),
                "binding_revision": get(root, "workspace_binding_revision"),
                "transcript_before": current_reference,
                "state": if candidate.outcome == "failed" { "rejected" } else { "denied" },
                "row_revision": 1, "feedback": feedback, "transcript_after": after, "receipt": receipt,
                "created_at": timestamp, "updated_at": timestamp,
            });
            changes.push(Change::InsertDeniedCall(denied_row));
            let projection = &mut projections[candidate.projection_index];
            set(projection, "native_row_revision", Value::from(1u64));
            set(projection, "receipt", receipt);
            current_reference = after;
        }
        transcript_changed = true;
    }
    let manifest = if manifest_calls.is_empty() {
        None
    } else {
        Some(
            hash_json("write-manifest", &json!({ "calls": manifest_calls }))
                .ok_or(StoreError::InvalidArgument)?,
        )
    };
    let batch = if manifest_calls.is_empty() {
        json!({
            "schema_version": 2, "kind": "read_only_batch",
            "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
            "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
            "batch_revision": batch_revision, "manifest_sha256": null,
            "reservation_delta_bytes": 0, "reserved_write_bytes": 0,
            "attempt_reserved_write_bytes": reserved, "effect_gate": "not_applicable",
            "created_at": timestamp, "updated_at": timestamp,
        })
    } else {
        json!({
            "schema_version": 2, "kind": "write_batch",
            "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
            "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
            "batch_revision": batch_revision,
            "root_fingerprint_sha256": get(root, "root_fingerprint_sha256"),
            "binding_revision": get(root, "workspace_binding_revision"),
            "manifest_sha256": manifest, "manifest_calls": manifest_calls,
            "write_keys": write_keys, "reservation_delta_bytes": batch_new,
            "reserved_write_bytes": reserved, "attempt_reserved_write_bytes": reserved,
            "effect_gate": "closed", "created_at": timestamp, "updated_at": timestamp,
        })
    };
    changes.push(Change::InsertBatch(batch.clone()));
    let result_transcript = json!({
        "schema_version": 1,
        "transcript_ref": transcript_next.get("transcript_ref"),
        "generation": transcript_next.get("generation"),
        "transcript_sha256": transcript_next.get("transcript_sha256"),
        "transcript_bytes": transcript_next.get("transcript_bytes"),
    });
    let authority_view = RowView {
        authorities: view.authorities.clone(),
        ..Default::default()
    };
    let authority_change = advance_authority(
        &authority_view,
        get(request, "task_id"),
        get(request, "attempt_id"),
        root,
        transcript,
        &result_transcript,
        Some(policy),
        get(request, "expected_reserved_write_bytes"),
        Some(&Value::from(reserved)),
        true,
        timestamp,
    )?;
    let mut approval_registry_version = Value::from(
        if source_calls
            .iter()
            .any(|call| as_str(get(call, "name")).is_some_and(crate::assistant_tools::is_assistant))
        {
            5u64
        } else if source_calls
            .iter()
            .any(|call| as_str(get(call, "name")).is_some_and(crate::runtime_tools::is_runtime))
        {
            3u64
        } else if matches!(get(root, "capabilities"), Some(Value::Array(caps)) if caps.iter().any(|c| c == "guest_service"))
        {
            2u64
        } else {
            1u64
        },
    );
    if let Some(authorities) = &view.authorities {
        for entry in authorities {
            if get(&entry.record, "task_id") == get(request, "task_id")
                && get(&entry.record, "attempt_id") == get(request, "attempt_id")
            {
                approval_registry_version = get(&entry.record, "registry")
                    .and_then(|r| get(r, "registry_version"))
                    .cloned()
                    .unwrap_or(Value::Null);
            }
        }
    }
    if transcript_changed {
        changes.push(Change::ReplaceTranscript(Value::Object(transcript_next)));
    }
    changes.extend(authority_change);

    let mut commit_operation = None;
    if compound {
        let call_ids: Vec<Value> = projections
            .iter()
            .map(|p| p.get("call_id").cloned().unwrap_or(Value::Null))
            .collect();
        let digests: Vec<Value> = projections
            .iter()
            .map(|p| p.get("arguments_sha256").cloned().unwrap_or(Value::Null))
            .collect();
        let mut token_cursor = 0usize;
        for projection in projections.iter_mut() {
            if !string_eq(projection.get("approval_state"), "pending")
                || !is_null(projection.get("receipt"))
            {
                continue;
            }
            let source = &source_calls[u64_of(projection.get("call_index")) as usize];
            let grant = get(source, "grant_reference");
            if !is_null(grant) && grant.is_some() {
                set(projection, "approval_state", Value::from("bound"));
                set(
                    projection,
                    "approval_reference",
                    grant.cloned().unwrap_or(Value::Null),
                );
                continue;
            }
            let Some(manifest) = &manifest else {
                return Err(StoreError::Conflict);
            };
            let Some(token) = env.approval_tokens.get(token_cursor) else {
                return Err(StoreError::Corrupt);
            };
            token_cursor += 1;
            let once = string_eq(projection.get("access"), "confirm_once");
            let allowed: Vec<&str> = if once {
                vec!["denied", "allow_once", "cancelled"]
            } else {
                vec!["denied", "allow_once", "allow_conversation", "cancelled"]
            };
            let approval_token = json!({
                "schema_version": 2, "token": token,
                "controller_cas": get(request, "controller_cas"),
                "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
                "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
                "batch_call_ids": call_ids, "batch_arguments_sha256": digests,
                "batch_revision": batch_revision, "manifest_sha256": manifest,
                "call_index": projection.get("call_index"), "call_id": projection.get("call_id"),
                "name": projection.get("name"), "arguments_sha256": projection.get("arguments_sha256"),
                "idempotency_key": projection.get("idempotency_key"),
                "root_fingerprint_sha256": get(root, "root_fingerprint_sha256"),
                "binding_revision": get(root, "workspace_binding_revision"),
                "policy_version": "agent-v1", "registry_version": approval_registry_version,
                "access": projection.get("access"), "allowed_decisions": allowed,
            });
            set(projection, "approval_token", approval_token);
        }
        let calls: Vec<Value> = projections.iter().cloned().map(Value::Object).collect();
        let receipt = json!({
            "schema_version": 2, "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
            "round_id": get(request, "round_id"), "round_index": get(request, "round_index"),
            "batch_kind": get(&batch, "kind"), "batch_revision": batch_revision,
            "manifest_sha256": get(&batch, "manifest_sha256"), "transcript": result_transcript,
            "calls": calls, "batch_new_write_bytes": batch_new, "reserved_write_bytes": reserved,
            "effect_gate": get(&batch, "effect_gate"),
        });
        let result = json!({
            "schema_version": 2, "status": "prepared", "operation_id": get(request, "operation_id"),
            "receipt": receipt, "observed_checkpoint": get(request, "observed_checkpoint"),
        });
        commit_operation = Some(json!({
            "operation_id": get(request, "operation_id"),
            "request_sha256": get(request, "operation_request_sha256"),
            "task_id": get(request, "task_id"), "attempt_id": get(request, "attempt_id"),
            "terminal_state": "committed", "result_status": "prepared",
            "result_ref": {
                "schema_version": 2, "kind": "batch", "task_id": get(request, "task_id"),
                "attempt_id": get(request, "attempt_id"), "round_id": get(request, "round_id"),
                "round_index": get(request, "round_index"), "batch_revision": batch_revision,
            },
            "result_revision": batch_revision,
            "safe_result": { "schema_version": 2, "result_kind": "prepare_agent_tool_batch", "result": result },
        }));
    }
    let calls: Vec<Value> = projections.into_iter().map(Value::Object).collect();
    Ok(Effect {
        commit: true,
        output: json!({
            "schema_version": 2, "status": "prepared",
            "batch_kind": get(&batch, "kind"), "batch_revision": batch_revision,
            "manifest_sha256": get(&batch, "manifest_sha256"),
            "batch_new_write_bytes": batch_new, "reserved_write_bytes": reserved,
            "effect_gate": get(&batch, "effect_gate"), "calls": calls,
            "transcript": result_transcript, "operation_result": null,
        }),
        changes,
        commit_operation,
    })
}

fn open_effect_gate(request: &Value, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let keys = [
        "schema_version",
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "expected_batch_revision",
        "manifest_sha256",
        "expected_effect_gate",
    ];
    if exact_keys(Some(request), &keys).is_none()
        || safe_integer(get(request, "schema_version"), 2, false) != Some(2)
        || !canonical_uuid(get(request, "task_id"))
        || !canonical_uuid(get(request, "attempt_id"))
        || !canonical_uuid(get(request, "round_id"))
        || safe_integer(get(request, "round_index"), 7, true).is_none()
        || safe_integer(
            get(request, "expected_batch_revision"),
            MAX_SAFE_INTEGER,
            false,
        )
        .is_none()
        || !canonical_sha256(get(request, "manifest_sha256"))
        || !string_eq(get(request, "expected_effect_gate"), "closed")
    {
        return Err(StoreError::InvalidArgument);
    }
    let Some(entry) = view.batches.iter().find(|entry| {
        let batch = &entry.record;
        quadruple_matches(batch, request)
            && get(batch, "batch_revision") == get(request, "expected_batch_revision")
            && get(batch, "manifest_sha256") == get(request, "manifest_sha256")
    }) else {
        return Err(StoreError::NotFound);
    };
    let batch = &entry.record;
    if string_eq(get(batch, "effect_gate"), "open") {
        return Ok(Effect {
            commit: false,
            output: json!({ "schema_version": 1, "status": "already_open", "manifest_sha256": get(batch, "manifest_sha256"), "effect_gate": "open" }),
            ..Default::default()
        });
    }
    if !string_eq(get(batch, "effect_gate"), "closed") {
        return Err(StoreError::Conflict);
    }
    mutation_batch_approvals_bound(view, batch)?;
    batch_effect_gate_revalidated(view, batch)?;
    let mut updated = object_map(batch);
    set(&mut updated, "effect_gate", Value::from("open"));
    set(&mut updated, "updated_at", Value::from(env.now.as_str()));
    Ok(Effect {
        commit: true,
        output: json!({ "schema_version": 1, "status": "open", "manifest_sha256": get(batch, "manifest_sha256"), "effect_gate": "open" }),
        changes: vec![Change::ReplaceBatch {
            slot: entry.slot,
            record: Value::Object(updated),
        }],
        commit_operation: None,
    })
}

/// Runs one batch-level operation: `prepare_tool_batch` or `open_effect_gate`.
pub fn reduce(op: &str, request: &Value, env: &Env, view: &View) -> Result<Effect, StoreError> {
    match op {
        "prepare_tool_batch" => prepare_tool_batch(request, env, view),
        "open_effect_gate" => open_effect_gate(request, env, view),
        _ => Err(StoreError::InvalidArgument),
    }
}

// MARK: - JSON envelope

/// `{"op","request","env","view"}` in; `{"ok":true,"commit","output","changes",
/// "commit_operation"}` or `{"ok":false,"error":<code>}` out.
pub fn reduce_json(input: &str) -> String {
    let value = match reduce_json_inner(input) {
        Ok(effect) => json!({
            "ok": true,
            "commit": effect.commit,
            "output": effect.output,
            "changes": effect.changes.iter().map(change_json).collect::<Vec<_>>(),
            "commit_operation": effect.commit_operation,
        }),
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn slotted_list(value: Option<&Value>) -> Vec<Slotted> {
    match value {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|item| {
                Some(Slotted {
                    slot: get(item, "slot")?.as_u64()?,
                    record: get(item, "record")?.clone(),
                })
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn list(value: Option<&Value>) -> Vec<Value> {
    match value {
        Some(Value::Array(items)) => items.clone(),
        _ => Vec::new(),
    }
}

fn reduce_json_inner(input: &str) -> Result<Effect, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(StoreError::Corrupt)?;
    let request = get(&envelope, "request").ok_or(StoreError::Corrupt)?;
    let env_value = get(&envelope, "env").ok_or(StoreError::Corrupt)?;
    let view_value = get(&envelope, "view").ok_or(StoreError::Corrupt)?;
    let env = Env {
        launch_id: as_str(get(env_value, "launch_id"))
            .ok_or(StoreError::Corrupt)?
            .to_owned(),
        now: as_str(get(env_value, "now"))
            .ok_or(StoreError::Corrupt)?
            .to_owned(),
        approval_tokens: list(get(env_value, "approval_tokens"))
            .iter()
            .filter_map(|t| as_str(Some(t)).map(str::to_owned))
            .collect(),
    };
    let flag = |key: &str| get(view_value, key) == Some(&Value::Bool(true));
    let view = View {
        tables_present: flag("tables_present"),
        rounds: list(get(view_value, "rounds")),
        batches: slotted_list(get(view_value, "batches")),
        reservations: slotted_list(get(view_value, "reservations")),
        transcript: get(view_value, "transcript")
            .filter(|t| !t.is_null())
            .cloned(),
        transcript_summaries: list(get(view_value, "transcript_summaries")),
        ledger_rows: list(get(view_value, "ledger_rows")),
        dispatch: list(get(view_value, "dispatch")),
        denied_calls: list(get(view_value, "denied_calls")),
        denied_attempt_count: u64_of(get(view_value, "denied_attempt_count")),
        denied_total_count: u64_of(get(view_value, "denied_total_count")),
        authorities: match get(view_value, "authorities") {
            None | Some(Value::Null) => None,
            Some(list) => Some(slotted_list(Some(list))),
        },
        authorities_present: flag("authorities_present"),
        operations_present: flag("operations_present"),
        operation_results: list(get(view_value, "operation_results")),
    };
    reduce(op, request, &env, &view)
}
