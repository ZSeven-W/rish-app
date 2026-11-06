//! Row-level operations of the execution ledger as a pure reducer, in the
//! view/effect shape of [`crate::round_journal`]. The Objective-C facade owns
//! the WAL transaction (or the caller's candidate for the in-state helpers):
//! it collects the [`View`] — the ledger row, the attempt's execution
//! dispatch markers, the bound transcript row, the attempt's reservation and
//! batch records, the task/attempt authorities and the liveness answers —
//! calls [`reduce_json`], and applies the returned [`Change`]s in order.
//! Settlement additionally returns [`CommitOperation`], which the facade
//! hands to `DSHAgentNativeWALCommitOperationInState` on the same candidate.
//!
//! Check order and error codes follow the ObjC methods exactly.

use crate::canonical::{canonical_json, hash_bytes, hash_json};
use crate::execution_ledger::*;
use crate::schema::*;
use crate::store::StoreError;
use serde_json::{json, Map, Value};

/// Host facts the reducer cannot derive.
#[derive(Debug, Clone, Default)]
pub struct Env {
    pub launch_id: String,
    /// `[wal currentTimestamp]`.
    pub now: String,
    /// Ledger rows already recorded for the attempt (insert capacity).
    pub attempt_row_count: u64,
}

/// A record with the host-issued slot it occupies in its WAL table.
#[derive(Debug, Clone)]
pub struct Slotted {
    pub slot: u64,
    pub record: Value,
}

/// What the facade found in the WAL candidate for the locator at hand.
#[derive(Debug, Clone, Default)]
pub struct View {
    pub row: Option<Value>,
    /// Every `kind == "execution"` dispatch marker of the attempt, in order.
    pub dispatch: Vec<Value>,
    /// The transcript row named by `row.transcript_before.transcript_ref`.
    pub transcript: Option<Value>,
    /// For the in-state helpers: the transcript row named by the caller's
    /// `expected_transcript.transcript_ref`.
    pub expected_transcript: Option<Value>,
    /// Reservation records of the attempt, in table order.
    pub reservations: Vec<Slotted>,
    /// Batch records of the attempt, in table order.
    pub batches: Vec<Slotted>,
    /// `None` when the authorities table is absent or empty (the schema-1
    /// seam, where authority advance is skipped); otherwise the records of
    /// the task/attempt, in table order (possibly none).
    pub authorities: Option<Vec<Slotted>>,
    pub arg_owner_alive: bool,
    pub row_owner_alive: bool,
}

/// One table change the facade applies verbatim.
#[derive(Debug, Clone, PartialEq)]
pub enum Change {
    InsertLedgerRow(Value),
    ReplaceLedgerRow(Value),
    InsertDispatchMarker(Value),
    MarkDispatched(Value),
    ReplaceTranscript(Value),
    ReplaceReservation { slot: u64, record: Value },
    ReplaceBatch { slot: u64, record: Value },
    ReplaceAuthority { slot: u64, record: Value },
    InsertReservation(Value),
    InsertBatch(Value),
    InsertDeniedCall(Value),
}

/// The operation commit the settle facade performs through
/// `DSHAgentNativeWALCommitOperationInState` after applying the changes.
#[derive(Debug, Clone, PartialEq)]
pub struct CommitOperation {
    pub operation_id: Value,
    pub request_sha256: Value,
    pub task_id: Value,
    pub attempt_id: Value,
    pub terminal_state: String,
    pub result_status: String,
    pub result_ref: Value,
    pub result_revision: Value,
    pub safe_result: Value,
}

#[derive(Debug, Clone, Default)]
pub struct Effect {
    pub commit: bool,
    pub output: Value,
    pub changes: Vec<Change>,
    pub commit_operation: Option<CommitOperation>,
}

fn null() -> Value {
    Value::Null
}

fn set(map: &mut Map<String, Value>, key: &str, value: Value) {
    map.insert(key.to_string(), value);
}

fn u64_of(value: Option<&Value>) -> u64 {
    value.and_then(Value::as_u64).unwrap_or(0)
}

fn string_eq(value: Option<&Value>, expected: &str) -> bool {
    as_str(value) == Some(expected)
}

/// `DSHAgentLedgerDispatchState` over the attempt's execution markers.
pub(crate) fn dispatch_state_in<'a>(
    dispatch: &'a [Value],
    locator: Option<&Value>,
) -> Option<&'a str> {
    dispatch
        .iter()
        .find(|entry| {
            string_eq(get(entry, "kind"), "execution") && get(entry, "locator") == locator
        })
        .and_then(|entry| as_str(get(entry, "dispatch_state")))
}

fn dispatch_state<'a>(view: &'a View, locator: Option<&Value>) -> Option<&'a str> {
    view.dispatch
        .iter()
        .find(|entry| {
            string_eq(get(entry, "kind"), "execution") && get(entry, "locator") == locator
        })
        .and_then(|entry| as_str(get(entry, "dispatch_state")))
}

fn transcript_reference_of(transcript: &Value) -> Value {
    json!({
        "schema_version": 1,
        "transcript_ref": get(transcript, "transcript_ref"),
        "generation": get(transcript, "generation"),
        "transcript_sha256": get(transcript, "transcript_sha256"),
        "transcript_bytes": get(transcript, "transcript_bytes"),
    })
}

fn row_root_expectation(row: &Value) -> Value {
    json!({
        "schema_version": 1,
        "root_fingerprint_sha256": get(row, "root_fingerprint_sha256"),
        "binding_revision": get(row, "binding_revision"),
    })
}

fn bump_revision(row: &mut Map<String, Value>, capacity_at_max: bool) -> Result<(), StoreError> {
    let revision = u64_of(row.get("row_revision"));
    if capacity_at_max && revision >= MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    set(row, "row_revision", Value::from(revision + 1));
    Ok(())
}

// MARK: - Manifest calls and effect gates

/// `DSHAgentWriteManifestCallForIntent`.
pub fn write_manifest_call_for_intent(intent: &Value) -> Option<Value> {
    let precondition = get(intent, "precondition")?;
    let name = as_str(get(intent, "name"))?;
    let precondition_sha = hash_json(
        "tool-precondition",
        &json!({ "schema_version": 1, "name": name, "precondition": precondition }),
    )?;
    match name {
        "write_file" => Some(json!({
            "schema_version": 2, "mutation_kind": "file_write",
            "locator": get(intent, "locator"),
            "precondition_sha256": precondition_sha,
            "relative_path_sha256": get(precondition, "relative_path_sha256"),
            "prior": get(precondition, "prior"),
            "content_sha256": get(precondition, "content_sha256"),
            "content_bytes": get(precondition, "content_bytes"),
        })),
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
        | "forget_assistant_memory" => Some(json!({
            "schema_version": 2, "mutation_kind": name,
            "locator": get(intent, "locator"),
            "precondition_sha256": precondition_sha, "content_bytes": 0,
        })),
        _ => None,
    }
}

fn batch_matches_row(batch: &Value, row: &Value) -> bool {
    let locator = get(row, "locator");
    get(batch, "attempt_id") == locator.and_then(|l| get(l, "attempt_id"))
        && matches!(get(batch, "write_keys"), Some(Value::Array(keys)) if keys.iter().any(|key| Some(key) == locator.and_then(|l| get(l, "idempotency_key"))))
}

/// `DSHAgentWriteBatchEffectGateOpen`.
fn write_batch_effect_gate_open(view: &View, row: &Value) -> bool {
    let name = as_str(get(row, "name")).unwrap_or_default();
    if !matches!(
        name,
        "write_file"
            | "git_commit"
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
    ) {
        return true;
    }
    let locator = get(row, "locator");
    let Some(batch) = view
        .batches
        .iter()
        .map(|entry| &entry.record)
        .find(|batch| batch_matches_row(batch, row))
    else {
        return false;
    };
    if !string_eq(get(batch, "effect_gate"), "open")
        || get(batch, "task_id") != locator.and_then(|l| get(l, "task_id"))
        || get(batch, "round_id") != locator.and_then(|l| get(l, "round_id"))
        || get(batch, "round_index") != locator.and_then(|l| get(l, "round_index"))
    {
        return false;
    }
    let expected = write_manifest_call_for_intent(row);
    let Some(Value::Array(calls)) = get(batch, "manifest_calls") else {
        return false;
    };
    match calls.iter().find(|call| get(call, "locator") == locator) {
        Some(call) => expected.as_ref() == Some(call),
        None => false,
    }
}

/// `DSHAgentMutationBatchProvesNoDispatch`.
fn mutation_batch_proves_no_dispatch(view: &View, batch: &Value) -> bool {
    let Some(Value::Array(calls)) = get(batch, "manifest_calls") else {
        return false;
    };
    !calls.is_empty()
        && calls
            .iter()
            .all(|call| dispatch_state(view, get(call, "locator")) == Some("not_dispatched"))
}

// MARK: - Authority advance

fn authority_root_matches(authority_root: Option<&Value>, candidate: &Value) -> bool {
    let Some(authority_root) = authority_root.filter(|r| r.is_object()) else {
        return false;
    };
    if !candidate.is_object() {
        return false;
    }
    if root_full(Some(candidate)) {
        return authority_root == candidate;
    }
    if !root_expectation(Some(candidate)) {
        return false;
    }
    get(candidate, "root_fingerprint_sha256") == get(authority_root, "root_fingerprint_sha256")
        && get(candidate, "binding_revision") == get(authority_root, "workspace_binding_revision")
}

/// `DSHAgentLedgerAdvanceAuthority`. Returns the replaced authority record,
/// or `None` when the table is absent/empty and the advance is skipped.
#[allow(clippy::too_many_arguments)]
pub fn advance_authority(
    view: &View,
    task_id: Option<&Value>,
    attempt_id: Option<&Value>,
    root: &Value,
    expected_transcript: &Value,
    next_transcript: &Value,
    policy: Option<&Value>,
    expected_reserved: Option<&Value>,
    next_reserved: Option<&Value>,
    allow_expected_transcript_advance: bool,
    timestamp: &str,
) -> Result<Option<Change>, StoreError> {
    let Some(candidates) = &view.authorities else {
        return Ok(None);
    };
    let mut found: Option<&Slotted> = None;
    for candidate in candidates {
        if get(&candidate.record, "task_id") == task_id
            && get(&candidate.record, "attempt_id") == attempt_id
        {
            if found.is_some() {
                return Err(StoreError::Corrupt);
            }
            found = Some(candidate);
        }
    }
    let authority = found.map(|entry| &entry.record);
    let authority_value = authority.cloned().unwrap_or(Value::Null);
    let root_matches = authority_root_matches(get(&authority_value, "root"), root);
    let authority_transcript = get(&authority_value, "transcript");
    let mut transcript_matches = authority_transcript == Some(expected_transcript);
    if !transcript_matches
        && allow_expected_transcript_advance
        && authority_transcript.and_then(|t| get(t, "transcript_ref"))
            == get(expected_transcript, "transcript_ref")
        && u64_of(get(expected_transcript, "generation"))
            > u64_of(authority_transcript.and_then(|t| get(t, "generation")))
    {
        transcript_matches = true;
    }
    if authority.is_none()
        || !string_eq(get(&authority_value, "state"), "prepared")
        || !root_matches
        || !transcript_matches
        || policy.is_some_and(|policy| get(&authority_value, "policy") != Some(policy))
        || expected_reserved
            .is_some_and(|expected| get(&authority_value, "reserved_write_bytes") != Some(expected))
    {
        return Err(StoreError::Conflict);
    }
    let revision = u64_of(get(&authority_value, "authority_revision"));
    if revision == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    let mut updated = object_map(&authority_value);
    set(&mut updated, "transcript", next_transcript.clone());
    if let Some(next) = next_reserved {
        set(&mut updated, "reserved_write_bytes", next.clone());
    }
    set(
        &mut updated,
        "authority_revision",
        Value::from(revision + 1),
    );
    set(&mut updated, "updated_at", Value::from(timestamp));
    let slot = found.expect("authority found").slot;
    Ok(Some(Change::ReplaceAuthority {
        slot,
        record: Value::Object(updated),
    }))
}

// MARK: - Operations

fn locate_row<'a>(view: &'a View, locator: Option<&Value>) -> Option<&'a Value> {
    view.row
        .as_ref()
        .filter(|row| get(row, "locator") == locator)
}

fn insert(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let insert_cas = args.get("insert_cas").unwrap_or(&Value::Null);
    let intent = args.get("intent").unwrap_or(&Value::Null);
    if !intent.is_object() {
        return Err(StoreError::InvalidArgument);
    }
    raw_arguments_bind_intent(args.get("arguments_json"), intent)?;
    let digest = arguments_sha256(get(intent, "name"), args.get("arguments_json"));
    if digest.is_none() || digest.as_deref() != as_str(get(intent, "arguments_sha256")) {
        return Err(StoreError::Conflict);
    }
    insert_validated(insert_cas, args.get("arguments_json"), intent, env, view)
}

fn insert_validated(
    insert_cas: &Value,
    arguments_json: Option<&Value>,
    intent: &Value,
    env: &Env,
    view: &View,
) -> Result<Effect, StoreError> {
    raw_arguments_bind_intent(arguments_json, intent)?;
    let before = get(intent, "transcript_before").unwrap_or(&Value::Null);
    if !ledger_insert_cas(Some(insert_cas))
        || !ledger_row(intent)
        || get(intent, "locator") != get(insert_cas, "locator")
        || get(before, "generation") != get(insert_cas, "expected_transcript_generation")
        || get(before, "transcript_sha256") != get(insert_cas, "expected_transcript_sha256")
        || get(intent, "root_fingerprint_sha256")
            != get(insert_cas, "expected_root_fingerprint_sha256")
        || get(intent, "binding_revision") != get(insert_cas, "expected_binding_revision")
        || !string_eq(get(intent, "state"), "intent")
    {
        return Err(StoreError::InvalidArgument);
    }
    if let Some(existing) = locate_row(view, get(insert_cas, "locator")) {
        let same = canonical_json(existing).ok() == canonical_json(intent).ok();
        if same {
            return Ok(Effect {
                commit: false,
                output: json!({ "schema_version": 1, "status": "existing_identical", "row": existing }),
                ..Default::default()
            });
        }
        return Err(StoreError::Conflict);
    }
    if env.attempt_row_count >= MAX_LEDGER_ROWS_PER_ATTEMPT as u64 {
        return Err(StoreError::Capacity);
    }
    transcript_bound(view.transcript.as_ref(), intent)?;
    let precondition = get(intent, "precondition").unwrap_or(&Value::Null);
    let reserved = u64_of(get(intent, "reserved_write_bytes"));
    let content_bytes = u64_of(get(precondition, "content_bytes"));
    if content_bytes > 0 || reserved > 0 {
        let locator = get(intent, "locator").unwrap_or(&Value::Null);
        let found = view.reservations.iter().any(|entry| {
            let record = &entry.record;
            get(record, "attempt_id") == get(locator, "attempt_id")
                && matches!(get(record, "keys"), Some(Value::Array(keys)) if keys.iter().any(|key| {
                    get(key, "idempotency_key") == get(locator, "idempotency_key")
                        && string_eq(get(key, "state"), "active")
                        && u64_of(get(key, "content_bytes")) == content_bytes
                        && get(key, "content_bytes").and_then(Value::as_u64).is_some()
                        && reserved == content_bytes
                        && get(key, "content_sha256") == get(precondition, "content_sha256")
                        && get(key, "relative_path_sha256") == get(precondition, "relative_path_sha256")
                }))
        });
        if !found {
            return Err(StoreError::Conflict);
        }
    }
    let marker = json!({
        "schema_version": 1, "kind": "execution",
        "locator": get(intent, "locator"), "dispatch_state": "not_dispatched",
    });
    Ok(Effect {
        commit: true,
        output: json!({ "schema_version": 1, "status": "inserted", "row": intent }),
        changes: vec![
            Change::InsertLedgerRow(intent.clone()),
            Change::InsertDispatchMarker(marker),
        ],
        commit_operation: None,
    })
}

/// The shared CAS core. `Err(Conflict)` after the row was located becomes the
/// ObjC `{ok:false, conflict:true, row}` envelope.
fn cas(
    cas_value: &Value,
    patch: &Value,
    allow_reconcile: bool,
    env: &Env,
    view: &View,
) -> Result<Effect, StoreError> {
    if !ledger_cas(Some(cas_value)) || !patch_keys_allowed(patch) {
        return Err(StoreError::InvalidArgument);
    }
    let patch_map = object_map(patch);
    if patch_map
        .get("state")
        .is_some_and(|state| !state.is_string())
    {
        return Err(StoreError::InvalidArgument);
    }
    let patch_state = as_str(patch_map.get("state"));
    if !allow_reconcile && matches!(patch_state, Some("settled" | "cancelled")) {
        return Err(StoreError::Conflict);
    }
    let Some(row) = locate_row(view, get(cas_value, "locator")) else {
        return Err(StoreError::Conflict);
    };
    match cas_transaction(row, cas_value, &patch_map, allow_reconcile, env, view) {
        Ok(effect) => Ok(effect),
        Err(StoreError::Conflict) => Ok(Effect {
            commit: false,
            output: json!({ "ok": false, "conflict": true, "row": row }),
            ..Default::default()
        }),
        Err(other) => Err(other),
    }
}

fn cas_transaction(
    row: &Value,
    cas_value: &Value,
    patch: &Map<String, Value>,
    allow_reconcile: bool,
    env: &Env,
    view: &View,
) -> Result<Effect, StoreError> {
    if !cas_matches_row(row, cas_value) {
        return Err(StoreError::Conflict);
    }
    let state = as_str(get(row, "state"));
    if !allow_reconcile && matches!(state, Some("settled" | "cancelled")) {
        return Err(StoreError::Conflict);
    }
    transcript_bound(view.transcript.as_ref(), row)?;
    if state == Some("intent")
        && as_str(patch.get("state")) == Some("running")
        && !ledger_row_executable(row)
    {
        return Err(StoreError::Conflict);
    }
    let mut updated = object_map(row);
    for (key, value) in patch {
        set(&mut updated, key, value.clone());
    }
    let Some(next_state) = as_str(updated.get("state")).map(str::to_owned) else {
        return Err(StoreError::InvalidArgument);
    };
    if matches!(next_state.as_str(), "cancelled" | "unknown" | "ambiguous") {
        let marker = dispatch_state(view, get(row, "locator"));
        if next_state == "cancelled" && marker != Some("not_dispatched") {
            return Err(StoreError::Conflict);
        }
        if matches!(next_state.as_str(), "unknown" | "ambiguous") && !allow_reconcile {
            return Err(StoreError::Conflict);
        }
    }
    let owner = updated.get("owner");
    if !is_null(owner) {
        let owner_ok = owner.is_some_and(|o| o.is_object())
            && owner.and_then(|o| get(o, "task_id"))
                == get(row, "locator").and_then(|l| get(l, "task_id"))
            && as_str(owner.and_then(|o| get(o, "launch_id"))) == Some(env.launch_id.as_str())
            && view.arg_owner_alive;
        if !owner_ok {
            return Err(StoreError::OwnerLost);
        }
    }
    if !transition_allowed(state, Some(next_state.as_str()), allow_reconcile) {
        return Err(StoreError::Conflict);
    }
    let revision = u64_of(get(row, "row_revision"));
    if revision == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    if !ledger_row(&Value::Object(updated.clone())) {
        return Err(StoreError::InvalidArgument);
    }
    set(&mut updated, "row_revision", Value::from(revision + 1));
    set(&mut updated, "updated_at", Value::from(env.now.as_str()));
    let updated = Value::Object(updated);
    if !ledger_row(&updated) {
        return Err(StoreError::InvalidArgument);
    }
    let Some(transcript) = view.transcript.as_ref() else {
        return Err(StoreError::Conflict);
    };
    let current = transcript_reference_of(transcript);
    let locator = get(row, "locator").unwrap_or(&Value::Null);
    let authority = advance_authority(
        view,
        get(locator, "task_id"),
        get(locator, "attempt_id"),
        &row_root_expectation(row),
        &current,
        &current,
        None,
        None,
        None,
        false,
        &env.now,
    )?;
    let mut changes = vec![Change::ReplaceLedgerRow(updated.clone())];
    changes.extend(authority);
    Ok(Effect {
        commit: true,
        output: json!({ "ok": true, "row": updated }),
        changes,
        commit_operation: None,
    })
}

fn claim(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let locator = args.get("locator").unwrap_or(&Value::Null);
    let revision = args.get("expected_row_revision");
    let owner = args.get("owner").unwrap_or(&Value::Null);
    if !ledger_locator(Some(locator))
        || safe_integer(revision, MAX_SAFE_INTEGER, false).is_none()
        || !owner_shape(Some(owner))
        || get(owner, "task_id") != get(locator, "task_id")
        || as_str(get(owner, "launch_id")) != Some(env.launch_id.as_str())
        || !view.arg_owner_alive
    {
        return Err(StoreError::InvalidArgument);
    }
    let Some(row) = locate_row(view, Some(locator)) else {
        return Err(StoreError::NotFound);
    };
    let before = get(row, "transcript_before").unwrap_or(&Value::Null);
    let cas_value = json!({
        "schema_version": 2,
        "locator": locator,
        "expected_row_revision": revision,
        "expected_state": "intent",
        "expected_owner_generation": null,
        "expected_launch_id": null,
        "expected_native_task_id": null,
        "expected_transcript_generation": get(before, "generation"),
        "expected_transcript_sha256": get(before, "transcript_sha256"),
        "expected_root_fingerprint_sha256": get(row, "root_fingerprint_sha256"),
        "expected_binding_revision": get(row, "binding_revision"),
    });
    cas(
        &cas_value,
        &json!({ "state": "running", "owner": owner }),
        false,
        env,
        view,
    )
}

fn heartbeat(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let cas_value = args.get("cas").unwrap_or(&Value::Null);
    let owner = args.get("owner").unwrap_or(&Value::Null);
    if !ledger_cas(Some(cas_value))
        || !owner_shape(Some(owner))
        || get(owner, "task_id") != get(cas_value, "locator").and_then(|l| get(l, "task_id"))
        || as_str(get(owner, "launch_id")) != Some(env.launch_id.as_str())
        || !view.arg_owner_alive
    {
        return Err(StoreError::OwnerLost);
    }
    cas(cas_value, &json!({ "owner": owner }), false, env, view)
}

fn mark_dispatched(
    args: &Map<String, Value>,
    env: &Env,
    view: &View,
) -> Result<Effect, StoreError> {
    let cas_value = args.get("cas").unwrap_or(&Value::Null);
    if !ledger_cas(Some(cas_value)) {
        return Err(StoreError::InvalidArgument);
    }
    let row = locate_row(view, get(cas_value, "locator"));
    let Some(row) = row.filter(|row| {
        cas_matches_row(row, cas_value)
            && matches!(
                as_str(get(row, "state")),
                Some("running" | "cancel_requested")
            )
            && !is_null(get(row, "owner"))
            && view.row_owner_alive
    }) else {
        return Err(StoreError::Conflict);
    };
    transcript_bound(view.transcript.as_ref(), row)?;
    let precondition = get(row, "precondition").unwrap_or(&Value::Null);
    if string_eq(get(precondition, "kind"), "write_file")
        && string_eq(
            get(precondition, "prior").and_then(|p| get(p, "kind")),
            "unknown",
        )
    {
        return Err(StoreError::Conflict);
    }
    if !write_batch_effect_gate_open(view, row) {
        return Err(StoreError::Conflict);
    }
    match dispatch_state(view, get(row, "locator")) {
        None => return Err(StoreError::Corrupt),
        Some("dispatched") => {
            return Ok(Effect {
                commit: false,
                output: json!({ "schema_version": 1, "status": "already_dispatched", "row": row }),
                ..Default::default()
            })
        }
        Some(_) => {}
    }
    let mut updated = object_map(row);
    bump_revision(&mut updated, true)?;
    set(&mut updated, "updated_at", Value::from(env.now.as_str()));
    let updated = Value::Object(updated);
    if !ledger_row(&updated) {
        return Err(StoreError::InvalidArgument);
    }
    let Some(transcript) = view.transcript.as_ref() else {
        return Err(StoreError::Conflict);
    };
    let current = transcript_reference_of(transcript);
    let locator = get(row, "locator").unwrap_or(&Value::Null);
    let authority = advance_authority(
        view,
        get(locator, "task_id"),
        get(locator, "attempt_id"),
        &row_root_expectation(row),
        &current,
        &current,
        None,
        None,
        None,
        false,
        &env.now,
    )?;
    let mut changes = vec![
        Change::MarkDispatched(locator.clone()),
        Change::ReplaceLedgerRow(updated.clone()),
    ];
    changes.extend(authority);
    Ok(Effect {
        commit: true,
        output: json!({ "schema_version": 1, "status": "dispatched", "row": updated }),
        changes,
        commit_operation: None,
    })
}

fn query(args: &Map<String, Value>, view: &View) -> Result<Effect, StoreError> {
    let locator = args.get("locator").unwrap_or(&Value::Null);
    let transcript = args.get("expected_transcript");
    let root = args.get("root").unwrap_or(&Value::Null);
    let binding = get(root, "binding_revision").or_else(|| get(root, "workspace_binding_revision"));
    if !ledger_locator(Some(locator))
        || !transcript_reference(transcript)
        || !(root_expectation(Some(root)) || root_full(Some(root)))
        || !canonical_sha256(get(root, "root_fingerprint_sha256"))
        || safe_integer(binding, MAX_SAFE_INTEGER, false).is_none()
    {
        return Err(StoreError::InvalidArgument);
    }
    let Some(row) = locate_row(view, Some(locator)) else {
        return Ok(Effect {
            commit: false,
            output: json!({ "schema_version": 2, "status": "not_started" }),
            ..Default::default()
        });
    };
    if get(row, "root_fingerprint_sha256") != get(root, "root_fingerprint_sha256")
        || get(row, "binding_revision") != binding
        || get(row, "transcript_before") != transcript
    {
        return Err(StoreError::Conflict);
    }
    let status = as_str(get(row, "state")).unwrap_or_default();
    let mapped = if status == "settled" {
        match as_str(get(row, "receipt").and_then(|r| get(r, "outcome"))) {
            Some("ok") => "completed",
            Some("denied") => "denied",
            _ => "failed",
        }
    } else {
        status
    };
    Ok(Effect {
        commit: false,
        output: json!({ "schema_version": 2, "status": mapped, "row": row }),
        ..Default::default()
    })
}

fn release(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let cas_value = args.get("cas").unwrap_or(&Value::Null);
    if !ledger_cas(Some(cas_value)) {
        return Err(StoreError::InvalidArgument);
    }
    let Some(target) = locate_row(view, get(cas_value, "locator")).filter(|row| {
        cas_matches_row(row, cas_value)
            && string_eq(get(row, "state"), "intent")
            && u64_of(get(row, "reserved_write_bytes")) != 0
            && dispatch_state(view, get(row, "locator")) == Some("not_dispatched")
    }) else {
        return Err(StoreError::Conflict);
    };
    transcript_bound(view.transcript.as_ref(), target)?;
    let locator = get(target, "locator").unwrap_or(&Value::Null);
    let amount = u64_of(get(target, "reserved_write_bytes"));
    let Some(reservation) = view
        .reservations
        .iter()
        .find(|entry| get(&entry.record, "attempt_id") == get(locator, "attempt_id"))
    else {
        return Err(StoreError::NotFound);
    };
    let mut record = object_map(&reservation.record);
    let reserved = u64_of(record.get("reserved_write_bytes"));
    let mut keys = match record.get("keys") {
        Some(Value::Array(keys)) => keys.clone(),
        _ => Vec::new(),
    };
    let Some(position) = keys
        .iter()
        .position(|key| get(key, "idempotency_key") == get(locator, "idempotency_key"))
    else {
        return Err(StoreError::Conflict);
    };
    if !string_eq(get(&keys[position], "state"), "active")
        || u64_of(get(&keys[position], "content_bytes")) != amount
        || get(&keys[position], "content_bytes")
            .and_then(Value::as_u64)
            .is_none()
    {
        return Err(StoreError::Conflict);
    }
    let mut released_key = object_map(&keys[position]);
    set(&mut released_key, "state", Value::from("released"));
    keys[position] = Value::Object(released_key);
    let version = u64_of(record.get("reservation_version"));
    if version == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    set(&mut record, "reservation_version", Value::from(version + 1));
    set(
        &mut record,
        "reserved_write_bytes",
        Value::from(reserved.saturating_sub(amount)),
    );
    set(&mut record, "keys", Value::Array(keys));
    let mut updated = object_map(target);
    if u64_of(updated.get("row_revision")) == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    set(&mut updated, "reserved_write_bytes", Value::from(0u64));
    bump_revision(&mut updated, false)?;
    set(&mut updated, "updated_at", Value::from(env.now.as_str()));
    let updated = Value::Object(updated);
    if !ledger_row(&updated) {
        return Err(StoreError::InvalidArgument);
    }
    let mut changes = vec![
        Change::ReplaceLedgerRow(updated.clone()),
        Change::ReplaceReservation {
            slot: reservation.slot,
            record: Value::Object(record.clone()),
        },
    ];
    for entry in &view.batches {
        if !batch_matches_row(&entry.record, target) {
            continue;
        }
        let mut batch = object_map(&entry.record);
        let batch_reserved = u64_of(batch.get("reserved_write_bytes"));
        set(
            &mut batch,
            "reserved_write_bytes",
            Value::from(batch_reserved.saturating_sub(amount)),
        );
        if string_eq(batch.get("effect_gate"), "closed")
            && mutation_batch_proves_no_dispatch(view, &entry.record)
        {
            set(&mut batch, "effect_gate", Value::from("released"));
        }
        set(&mut batch, "updated_at", Value::from(env.now.as_str()));
        changes.push(Change::ReplaceBatch {
            slot: entry.slot,
            record: Value::Object(batch),
        });
    }
    Ok(Effect {
        commit: true,
        output: json!({
            "schema_version": 1, "status": "released",
            "reserved_write_bytes": record.get("reserved_write_bytes"), "row": updated,
        }),
        changes,
        commit_operation: None,
    })
}

fn settle(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let cas_value = args.get("cas").unwrap_or(&Value::Null);
    let patch = args.get("patch").unwrap_or(&Value::Null);
    let message = args.get("message").unwrap_or(&Value::Null);
    let operation = args.get("operation").filter(|o| !o.is_null());
    let receipt = get(patch, "receipt").unwrap_or(&Value::Null);
    let operation_ok = operation.is_none_or(|operation| {
        exact_keys(
            Some(operation),
            &["operation_id", "request_sha256", "effect_may_have_occurred"],
        )
        .is_some()
            && canonical_uuid(get(operation, "operation_id"))
            && canonical_sha256(get(operation, "request_sha256"))
            && matches!(
                get(operation, "effect_may_have_occurred"),
                Some(Value::Bool(_))
            )
    });
    if !ledger_cas(Some(cas_value))
        || !patch_keys_allowed(patch)
        || !message.is_object()
        || as_str(get(message, "role")) != Some("tool")
        || !receipt_shape(Some(receipt))
        || !(matches!(as_str(get(patch, "state")), Some("settled" | "ambiguous"))
            || (as_str(get(receipt, "name")).is_some_and(|name| {
                crate::runtime_tools::is_runtime(name) || crate::assistant_tools::is_assistant(name)
            }) && as_str(get(patch, "state")) == Some("cancelled")
                && as_str(get(receipt, "outcome")) == Some("cancelled")))
        || !operation_ok
    {
        return Err(StoreError::InvalidArgument);
    }
    let Some(feedback_bytes) = canonical_feedback_bytes(Some(message)) else {
        return Err(StoreError::InvalidArgument);
    };
    let content = as_str(get(message, "content")).unwrap_or_default();
    if feedback_string_valid(content).is_err() {
        return Err(StoreError::InvalidArgument);
    }
    let feedback_digest = hash_bytes("tool-result", &feedback_bytes);
    if feedback_digest.as_deref() != as_str(get(receipt, "result_sha256"))
        || u64_of(get(receipt, "result_bytes")) != feedback_bytes.len() as u64
        || get(receipt, "truncated") != get(message, "truncated")
    {
        return Err(StoreError::Conflict);
    }
    let feedback: Value =
        serde_json::from_slice(&feedback_bytes).map_err(|_| StoreError::Conflict)?;
    if !feedback.is_object()
        || get(&feedback, "name") != get(receipt, "name")
        || get(&feedback, "outcome") != get(receipt, "outcome")
        || get(message, "call_id") != get(receipt, "call_id")
    {
        return Err(StoreError::Conflict);
    }
    let feedback_outcome = as_str(get(&feedback, "outcome"));
    let payload = get(&feedback, "payload");
    if !payload.is_some_and(|p| p.is_object())
        || (feedback_outcome == Some("ok") && !is_null(get(receipt, "failure_code")))
        || (feedback_outcome != Some("ok")
            && payload.and_then(|p| get(p, "failure_code")) != get(receipt, "failure_code"))
    {
        return Err(StoreError::Conflict);
    }
    if feedback_outcome == Some("ok")
        && matches!(
            as_str(get(&feedback, "name")),
            Some("read_file" | "list_dir")
        )
        && payload.and_then(|p| get(p, "truncated")) != get(message, "truncated")
    {
        return Err(StoreError::Conflict);
    }

    // Transaction phase.
    let row = locate_row(view, get(cas_value, "locator"));
    let locator_of = |row: &Value| get(row, "locator").cloned().unwrap_or(Value::Null);
    let Some(row) = row.filter(|row| {
        let locator = locator_of(row);
        let question = row["name"] == crate::user_question::NAME && row["state"] == "intent";
        cas_matches_row(row, cas_value)
            && (question
                || matches!(
                    as_str(get(row, "state")),
                    Some("running" | "cancel_requested")
                ))
            && get(message, "round_index") == get(&locator, "round_index")
            && get(message, "call_id") == get(&locator, "call_id")
            && get(receipt, "call_id") == get(&locator, "call_id")
            && get(receipt, "name") == get(row, "name")
            && get(receipt, "arguments_sha256") == get(row, "arguments_sha256")
            && as_str(get(receipt, "outcome")) == feedback_outcome
            && dispatch_state(view, Some(&locator))
                == Some(if question {
                    "not_dispatched"
                } else {
                    "dispatched"
                })
    }) else {
        return Err(StoreError::Conflict);
    };
    if !settled_facts_match_feedback(row, &feedback, get(patch, "settled_facts")) {
        return Err(StoreError::Conflict);
    }
    transcript_bound(view.transcript.as_ref(), row)?;
    let before = get(row, "transcript_before").unwrap_or(&Value::Null);
    let Some(transcript) = view.transcript.as_ref() else {
        return Err(StoreError::Conflict);
    };
    let current_generation = u64_of(get(transcript, "generation"));
    let before_generation = u64_of(get(before, "generation"));
    if current_generation < before_generation
        || (current_generation == before_generation
            && (get(transcript, "transcript_sha256") != get(before, "transcript_sha256")
                || get(transcript, "transcript_bytes") != get(before, "transcript_bytes")))
        || !string_eq(get(transcript, "state"), "open")
    {
        return Err(StoreError::Conflict);
    }
    let authority_before = transcript_reference_of(transcript);
    let mut messages = match get(transcript, "messages") {
        Some(Value::Array(messages)) => messages.clone(),
        _ => Vec::new(),
    };
    messages.push(message.clone());
    let generation = current_generation + 1;
    let (digest, bytes) = transcript_digest(transcript, &messages, generation)?;
    let mut next_transcript = object_map(transcript);
    set(&mut next_transcript, "messages", Value::Array(messages));
    set(&mut next_transcript, "generation", Value::from(generation));
    set(
        &mut next_transcript,
        "transcript_sha256",
        Value::from(digest.as_str()),
    );
    set(&mut next_transcript, "transcript_bytes", Value::from(bytes));
    set(
        &mut next_transcript,
        "updated_at",
        Value::from(env.now.as_str()),
    );
    let after = transcript_reference_value(
        get(transcript, "transcript_ref"),
        generation,
        &digest,
        bytes,
    );
    let mut updated = object_map(row);
    for (key, value) in object_map(patch) {
        set(&mut updated, &key, value);
    }
    set(&mut updated, "owner", Value::Null);
    set(&mut updated, "transcript_after", after.clone());
    let revision = u64_of(get(row, "row_revision"));
    if revision == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    set(&mut updated, "row_revision", Value::from(revision + 1));
    set(&mut updated, "updated_at", Value::from(env.now.as_str()));
    let updated = Value::Object(updated);
    if !ledger_row(&updated) {
        return Err(StoreError::InvalidArgument);
    }
    let locator = get(row, "locator").unwrap_or(&Value::Null);
    let authority = advance_authority(
        view,
        get(locator, "task_id"),
        get(locator, "attempt_id"),
        &row_root_expectation(row),
        &authority_before,
        &after,
        None,
        None,
        None,
        false,
        &env.now,
    )?;
    let mut changes = vec![
        Change::ReplaceLedgerRow(updated.clone()),
        Change::ReplaceTranscript(Value::Object(next_transcript)),
    ];
    changes.extend(authority);
    let commit_operation = operation.map(|operation| {
        let receipt_outcome = as_str(get(&updated, "receipt").and_then(|r| get(r, "outcome"))).unwrap_or_default();
        let public_status = if receipt_outcome == "ok" { "completed" } else { receipt_outcome };
        let updated_locator = get(&updated, "locator").cloned().unwrap_or(Value::Null);
        let result = json!({
            "schema_version": 2, "status": public_status,
            "operation_id": get(operation, "operation_id"),
            "task_id": get(&updated_locator, "task_id"),
            "attempt_id": get(&updated_locator, "attempt_id"),
            "round_id": get(&updated_locator, "round_id"),
            "round_index": get(&updated_locator, "round_index"),
            "call_index": get(&updated_locator, "call_index"),
            "call_id": get(&updated_locator, "call_id"),
            "name": get(&updated, "name"),
            "idempotency_key": get(&updated_locator, "idempotency_key"),
            "result_execution_revision": get(&updated, "row_revision"),
            "transcript": after, "receipt": get(&updated, "receipt"),
            "effect_may_have_occurred": get(operation, "effect_may_have_occurred"),
        });
        CommitOperation {
            operation_id: get(operation, "operation_id").cloned().unwrap_or(Value::Null),
            request_sha256: get(operation, "request_sha256").cloned().unwrap_or(Value::Null),
            task_id: get(&updated_locator, "task_id").cloned().unwrap_or(Value::Null),
            attempt_id: get(&updated_locator, "attempt_id").cloned().unwrap_or(Value::Null),
            terminal_state: if public_status == "ambiguous" { "ambiguous".to_string() } else { "committed".to_string() },
            result_status: public_status.to_string(),
            result_ref: json!({
                "schema_version": 2, "kind": "tool",
                "task_id": get(&updated_locator, "task_id"),
                "attempt_id": get(&updated_locator, "attempt_id"),
                "round_id": get(&updated_locator, "round_id"),
                "round_index": get(&updated_locator, "round_index"),
                "call_index": get(&updated_locator, "call_index"),
                "call_id": get(&updated_locator, "call_id"),
                "execution_revision": get(&updated, "row_revision"),
            }),
            result_revision: get(&updated, "row_revision").cloned().unwrap_or(Value::Null),
            safe_result: json!({ "schema_version": 2, "result_kind": "execute_agent_tool", "result": result }),
        }
    });
    Ok(Effect {
        commit: true,
        output: json!({ "schema_version": 1, "row": updated, "transcript": after, "operation_result": null }),
        changes,
        commit_operation,
    })
}

/// The cancellation transaction shared by `cancel` and `reconcile(cancelled)`.
/// Preflight (dispatch proof through the WAL query) stays with the facade.
fn cancel(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let cas_value = args.get("cas").unwrap_or(&Value::Null);
    let patch = args.get("patch").unwrap_or(&Value::Null);
    if !ledger_cas(Some(cas_value))
        || exact_keys(Some(patch), &["state"]).is_none()
        || as_str(get(patch, "state")) != Some("cancelled")
        || !matches!(
            as_str(get(cas_value, "expected_state")),
            Some("intent" | "cancel_requested")
        )
    {
        return Err(StoreError::InvalidArgument);
    }
    if dispatch_state(view, get(cas_value, "locator")) != Some("not_dispatched") {
        return Err(StoreError::Conflict);
    }
    let Some(row) = locate_row(view, get(cas_value, "locator")) else {
        return Err(StoreError::Conflict);
    };
    if !cas_matches_row(row, cas_value) || get(row, "state") != get(cas_value, "expected_state") {
        return Err(StoreError::Conflict);
    }
    transcript_bound(view.transcript.as_ref(), row)?;
    if string_eq(get(row, "state"), "intent") && !is_null(get(row, "owner")) {
        return Err(StoreError::Corrupt);
    }
    let before = get(row, "transcript_before").unwrap_or(&Value::Null);
    let Some(transcript) = view.transcript.as_ref() else {
        return Err(StoreError::Conflict);
    };
    let current_generation = u64_of(get(transcript, "generation"));
    let before_generation = u64_of(get(before, "generation"));
    if current_generation < before_generation
        || (current_generation == before_generation
            && (get(transcript, "transcript_sha256") != get(before, "transcript_sha256")
                || get(transcript, "transcript_bytes") != get(before, "transcript_bytes")))
        || !string_eq(get(transcript, "state"), "open")
    {
        return Err(StoreError::Conflict);
    }
    let authority_before = transcript_reference_of(transcript);
    let locator = get(row, "locator").unwrap_or(&Value::Null);
    let feedback = json!({
        "schema_version": 1, "name": get(row, "name"), "outcome": "cancelled",
        "payload": { "schema_version": 1, "failure_code": "E_AGENT_CANCELLED" },
    });
    let feedback_bytes = canonical_json(&feedback).map_err(|_| StoreError::InvalidArgument)?;
    let feedback_string =
        String::from_utf8(feedback_bytes.clone()).map_err(|_| StoreError::InvalidArgument)?;
    feedback_string_valid(&feedback_string)?;
    let mut messages = match get(transcript, "messages") {
        Some(Value::Array(messages)) => messages.clone(),
        _ => return Err(StoreError::Capacity),
    };
    if messages.len() >= 1024 || current_generation == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    messages.push(json!({
        "schema_version": 1, "role": "tool",
        "round_index": get(locator, "round_index"), "call_id": get(locator, "call_id"),
        "content": feedback_string, "truncated": false,
    }));
    let generation = current_generation + 1;
    let (digest, bytes) = transcript_digest(transcript, &messages, generation)?;
    let result_digest =
        hash_bytes("tool-result", &feedback_bytes).ok_or(StoreError::InvalidArgument)?;
    let mut next_transcript = object_map(transcript);
    set(&mut next_transcript, "messages", Value::Array(messages));
    set(&mut next_transcript, "generation", Value::from(generation));
    set(
        &mut next_transcript,
        "transcript_sha256",
        Value::from(digest.as_str()),
    );
    set(&mut next_transcript, "transcript_bytes", Value::from(bytes));
    set(
        &mut next_transcript,
        "updated_at",
        Value::from(env.now.as_str()),
    );
    let after = transcript_reference_value(
        get(transcript, "transcript_ref"),
        generation,
        &digest,
        bytes,
    );
    let mut updated = object_map(row);
    set(&mut updated, "state", Value::from("cancelled"));
    set(&mut updated, "owner", Value::Null);
    set(&mut updated, "settled_facts", Value::Null);
    set(&mut updated, "transcript_after", after.clone());
    set(
        &mut updated,
        "receipt",
        json!({
            "schema_version": 1, "call_id": get(locator, "call_id"), "name": get(row, "name"),
            "arguments_sha256": get(row, "arguments_sha256"), "result_sha256": result_digest,
            "result_bytes": feedback_bytes.len() as u64, "truncated": false, "duration_ms": 0,
            "outcome": "cancelled", "failure_code": "E_AGENT_CANCELLED", "approval_reference": null,
        }),
    );
    let revision = u64_of(get(row, "row_revision"));
    if revision == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    let amount = u64_of(updated.get("reserved_write_bytes"));
    let mut changes: Vec<Change> = Vec::new();
    let mut batch_updates: Vec<(u64, Map<String, Value>)> = Vec::new();
    let mut authority_reserved: Option<(Value, Value)> = None;
    if amount > 0 {
        let mut released = false;
        for entry in &view.reservations {
            if get(&entry.record, "attempt_id") != get(locator, "attempt_id") {
                continue;
            }
            let mut record = object_map(&entry.record);
            let reserved = u64_of(record.get("reserved_write_bytes"));
            let mut keys = match record.get("keys") {
                Some(Value::Array(keys)) => keys.clone(),
                _ => Vec::new(),
            };
            let Some(position) = keys
                .iter()
                .position(|key| get(key, "idempotency_key") == get(locator, "idempotency_key"))
            else {
                continue;
            };
            if !string_eq(get(&keys[position], "state"), "active")
                || u64_of(get(&keys[position], "content_bytes")) != amount
                || get(&keys[position], "content_bytes")
                    .and_then(Value::as_u64)
                    .is_none()
            {
                return Err(StoreError::Conflict);
            }
            let mut key = object_map(&keys[position]);
            set(&mut key, "state", Value::from("released"));
            keys[position] = Value::Object(key);
            let version = u64_of(record.get("reservation_version"));
            if version == MAX_SAFE_INTEGER {
                return Err(StoreError::Capacity);
            }
            set(&mut record, "reservation_version", Value::from(version + 1));
            let next_reserved = reserved.saturating_sub(amount);
            set(
                &mut record,
                "reserved_write_bytes",
                Value::from(next_reserved),
            );
            authority_reserved = Some((Value::from(reserved), Value::from(next_reserved)));
            set(&mut record, "keys", Value::Array(keys));
            changes.push(Change::ReplaceReservation {
                slot: entry.slot,
                record: Value::Object(record),
            });
            released = true;
            break;
        }
        if !released {
            return Err(StoreError::Conflict);
        }
        if let Some(entry) = view
            .batches
            .iter()
            .find(|entry| batch_matches_row(&entry.record, row))
        {
            let mut batch = object_map(&entry.record);
            let batch_reserved = u64_of(batch.get("reserved_write_bytes"));
            set(
                &mut batch,
                "reserved_write_bytes",
                Value::from(batch_reserved.saturating_sub(amount)),
            );
            set(&mut batch, "updated_at", Value::from(env.now.as_str()));
            batch_updates.push((entry.slot, batch));
        }
        set(&mut updated, "reserved_write_bytes", Value::from(0u64));
    }
    if let Some(entry) = view
        .batches
        .iter()
        .find(|entry| batch_matches_row(&entry.record, row))
    {
        let already = batch_updates
            .iter_mut()
            .find(|(slot, _)| *slot == entry.slot);
        let mut batch = match already {
            Some((_, batch)) => batch.clone(),
            None => object_map(&entry.record),
        };
        if string_eq(batch.get("effect_gate"), "closed")
            && mutation_batch_proves_no_dispatch(view, &entry.record)
        {
            set(&mut batch, "effect_gate", Value::from("released"));
            set(&mut batch, "updated_at", Value::from(env.now.as_str()));
        }
        match batch_updates
            .iter_mut()
            .find(|(slot, _)| *slot == entry.slot)
        {
            Some(existing) => existing.1 = batch,
            None => batch_updates.push((entry.slot, batch)),
        }
    }
    set(&mut updated, "row_revision", Value::from(revision + 1));
    set(&mut updated, "updated_at", Value::from(env.now.as_str()));
    let updated = Value::Object(updated);
    if !ledger_row(&updated) {
        return Err(StoreError::InvalidArgument);
    }
    let (reserved_before, reserved_after) = match &authority_reserved {
        Some((before, after)) => (Some(before), Some(after)),
        None => (None, None),
    };
    let authority = advance_authority(
        view,
        get(locator, "task_id"),
        get(locator, "attempt_id"),
        &row_root_expectation(row),
        &authority_before,
        &after,
        None,
        reserved_before,
        reserved_after,
        false,
        &env.now,
    )?;
    for (slot, batch) in batch_updates {
        changes.push(Change::ReplaceBatch {
            slot,
            record: Value::Object(batch),
        });
    }
    changes.push(Change::ReplaceLedgerRow(updated.clone()));
    changes.push(Change::ReplaceTranscript(Value::Object(next_transcript)));
    changes.extend(authority);
    Ok(Effect {
        commit: true,
        output: json!({ "ok": true, "row": updated }),
        changes,
        commit_operation: None,
    })
}

fn reconcile(args: &Map<String, Value>, env: &Env, view: &View) -> Result<Effect, StoreError> {
    let cas_value = args.get("cas").unwrap_or(&Value::Null);
    let patch = args.get("patch").unwrap_or(&Value::Null);
    if !ledger_cas(Some(cas_value)) || !patch.is_object() {
        return Err(StoreError::InvalidArgument);
    }
    let Some(state) = as_str(get(patch, "state")) else {
        return Err(StoreError::InvalidArgument);
    };
    if state != "unknown" && state != "cancelled" {
        return Err(StoreError::InvalidArgument);
    }
    if state == "cancelled" {
        if !matches!(
            as_str(get(cas_value, "expected_state")),
            Some("intent" | "cancel_requested")
        ) || dispatch_state(view, get(cas_value, "locator")) != Some("not_dispatched")
        {
            return Err(StoreError::Conflict);
        }
        let mut cancel_args = Map::new();
        cancel_args.insert("cas".to_string(), cas_value.clone());
        cancel_args.insert("patch".to_string(), json!({ "state": "cancelled" }));
        return cancel(&cancel_args, env, view);
    }
    let Some(row) = locate_row(view, get(cas_value, "locator")) else {
        return Err(StoreError::NotFound);
    };
    let owner = get(row, "owner");
    if !matches!(
        as_str(get(row, "state")),
        Some("running" | "cancel_requested")
    ) || is_null(owner)
        || !owner_shape(owner)
    {
        return Err(StoreError::Conflict);
    }
    if view.row_owner_alive {
        return Err(StoreError::Conflict);
    }
    if dispatch_state(view, get(row, "locator")) != Some("not_dispatched")
        || !is_null(get(patch, "owner"))
        || !is_null(get(patch, "settled_facts"))
        || !is_null(get(patch, "transcript_after"))
        || !is_null(get(patch, "receipt"))
    {
        return Err(StoreError::Conflict);
    }
    cas(cas_value, patch, true, env, view)
}

// MARK: - In-state helpers (caller-owned candidate)

#[allow(clippy::too_many_arguments)]
fn append_denial_feedback_effect(
    view: &View,
    task_id: Option<&Value>,
    attempt_id: Option<&Value>,
    root: &Value,
    expected_transcript: &Value,
    policy: &Value,
    expected_reserved: Option<&Value>,
    call_id: Option<&Value>,
    round_index: Option<&Value>,
    feedback_json: &str,
    timestamp: &str,
) -> Result<(Value, Vec<Change>), StoreError> {
    let Some(transcript) = view
        .expected_transcript
        .as_ref()
        .filter(|t| get(t, "transcript_ref") == get(expected_transcript, "transcript_ref"))
    else {
        return Err(StoreError::Conflict);
    };
    if get(transcript, "generation") != get(expected_transcript, "generation")
        || get(transcript, "transcript_sha256") != get(expected_transcript, "transcript_sha256")
        || get(transcript, "transcript_bytes") != get(expected_transcript, "transcript_bytes")
        || !string_eq(get(transcript, "state"), "open")
    {
        return Err(StoreError::Conflict);
    }
    let mut messages = match get(transcript, "messages") {
        Some(Value::Array(messages)) => messages.clone(),
        _ => Vec::new(),
    };
    messages.push(json!({
        "schema_version": 1, "role": "tool", "round_index": round_index, "call_id": call_id,
        "content": feedback_json, "truncated": false,
    }));
    let generation = u64_of(get(transcript, "generation"));
    if generation == MAX_SAFE_INTEGER {
        return Err(StoreError::Capacity);
    }
    let generation = generation + 1;
    let (digest, bytes) = transcript_digest(transcript, &messages, generation)?;
    let mut next_transcript = object_map(transcript);
    set(&mut next_transcript, "messages", Value::Array(messages));
    set(&mut next_transcript, "generation", Value::from(generation));
    set(
        &mut next_transcript,
        "transcript_sha256",
        Value::from(digest.as_str()),
    );
    set(&mut next_transcript, "transcript_bytes", Value::from(bytes));
    set(&mut next_transcript, "updated_at", Value::from(timestamp));
    let after = transcript_reference_value(
        get(transcript, "transcript_ref"),
        generation,
        &digest,
        bytes,
    );
    let mut changes = vec![Change::ReplaceTranscript(Value::Object(next_transcript))];
    let authority = advance_authority(
        view,
        task_id,
        attempt_id,
        root,
        expected_transcript,
        &after,
        Some(policy),
        expected_reserved,
        expected_reserved,
        false,
        timestamp,
    )?;
    changes.extend(authority);
    Ok((after, changes))
}

fn append_denial_feedback(args: &Map<String, Value>, view: &View) -> Result<Effect, StoreError> {
    let null = null();
    let root = args.get("root").unwrap_or(&null);
    let expected_transcript = args.get("expected_transcript").unwrap_or(&null);
    let policy = args.get("policy").unwrap_or(&null);
    let feedback_json = as_str(args.get("feedback_json"));
    let timestamp = as_str(args.get("timestamp"));
    if !canonical_uuid(args.get("task_id"))
        || !canonical_uuid(args.get("attempt_id"))
        || !root.is_object()
        || !transcript_reference(Some(expected_transcript))
        || !policy.is_object()
        || safe_integer(
            args.get("expected_reserved_write_bytes"),
            MAX_ATTEMPT_WRITE_BYTES,
            true,
        )
        .is_none()
        || bounded_utf8(args.get("call_id"), 128, false).is_none()
        || safe_integer(args.get("round_index"), 7, true).is_none()
        || bounded_utf8(args.get("feedback_json"), 8 * 1024, false).is_none()
        || feedback_json.is_none_or(|text| feedback_string_valid(text).is_err())
        || !canonical_timestamp(args.get("timestamp"))
    {
        return Err(StoreError::InvalidArgument);
    }
    let (after, changes) = append_denial_feedback_effect(
        view,
        args.get("task_id"),
        args.get("attempt_id"),
        root,
        expected_transcript,
        policy,
        args.get("expected_reserved_write_bytes"),
        args.get("call_id"),
        args.get("round_index"),
        feedback_json.expect("validated"),
        timestamp.expect("validated"),
    )?;
    Ok(Effect {
        commit: true,
        output: after,
        changes,
        commit_operation: None,
    })
}

fn settle_denied_approval(args: &Map<String, Value>, view: &View) -> Result<Effect, StoreError> {
    let null = null();
    let locator = args.get("locator").unwrap_or(&null);
    let root = args.get("root").unwrap_or(&null);
    let expected_transcript = args.get("expected_transcript").unwrap_or(&null);
    let policy = args.get("policy").unwrap_or(&null);
    let feedback_json = as_str(args.get("feedback_json"));
    let timestamp = as_str(args.get("timestamp"));
    if !ledger_locator(Some(locator))
        || !root_full(Some(root))
        || !transcript_reference(Some(expected_transcript))
        || !policy.is_object()
        || safe_integer(
            args.get("expected_reserved_write_bytes"),
            MAX_ATTEMPT_WRITE_BYTES,
            true,
        )
        .is_none()
        || bounded_utf8(args.get("feedback_json"), 8 * 1024, false).is_none()
        || feedback_json.is_none_or(|text| feedback_string_valid(text).is_err())
        || !canonical_timestamp(args.get("timestamp"))
    {
        return Err(StoreError::InvalidArgument);
    }
    let feedback_json = feedback_json.expect("validated");
    let timestamp = timestamp.expect("validated");
    let feedback: Value =
        serde_json::from_str(feedback_json).map_err(|_| StoreError::InvalidArgument)?;
    if !feedback.is_object()
        || as_str(get(&feedback, "outcome")) != Some("denied")
        || as_str(get(&feedback, "payload").and_then(|p| get(p, "failure_code")))
            != Some("E_AGENT_DENIED_BY_USER")
        || bounded_utf8(get(&feedback, "name"), 64, false).is_none()
    {
        return Err(StoreError::InvalidArgument);
    }
    let Some(row) = locate_row(view, Some(locator)) else {
        return Err(StoreError::Conflict);
    };
    if !string_eq(get(row, "state"), "intent")
        || get(row, "row_revision").and_then(Value::as_u64) != Some(1)
        || !is_null(get(row, "owner"))
        || !is_null(get(row, "settled_facts"))
        || !is_null(get(row, "transcript_after"))
        || !is_null(get(row, "receipt"))
        || get(row, "name") != get(&feedback, "name")
        || dispatch_state(view, Some(locator)) != Some("not_dispatched")
        || transcript_bound(view.transcript.as_ref(), row).is_err()
    {
        return Err(StoreError::Conflict);
    }
    let row_locator = get(row, "locator").unwrap_or(&null);
    let (after, mut changes) = append_denial_feedback_effect(
        view,
        get(locator, "task_id"),
        get(locator, "attempt_id"),
        root,
        expected_transcript,
        policy,
        args.get("expected_reserved_write_bytes"),
        get(row_locator, "call_id"),
        get(row_locator, "round_index"),
        feedback_json,
        timestamp,
    )?;
    let result_sha =
        hash_bytes("tool-result", feedback_json.as_bytes()).ok_or(StoreError::InvalidArgument)?;
    let receipt = json!({
        "schema_version": 1, "call_id": get(row_locator, "call_id"), "name": get(row, "name"),
        "arguments_sha256": get(row, "arguments_sha256"), "result_sha256": result_sha,
        "result_bytes": feedback_json.len() as u64, "truncated": false, "duration_ms": 0,
        "outcome": "denied", "failure_code": "E_AGENT_DENIED_BY_USER", "approval_reference": null,
    });
    let mut updated = object_map(row);
    set(&mut updated, "row_revision", Value::from(2u64));
    set(&mut updated, "state", Value::from("settled"));
    set(&mut updated, "settled_facts", Value::Null);
    set(&mut updated, "transcript_after", after.clone());
    set(&mut updated, "receipt", receipt.clone());
    set(&mut updated, "updated_at", Value::from(timestamp));
    let updated = Value::Object(updated);
    if !ledger_row(&updated) {
        return Err(StoreError::Corrupt);
    }
    changes.push(Change::ReplaceLedgerRow(updated));
    Ok(Effect {
        commit: true,
        output: json!({ "receipt": receipt, "transcript": after }),
        changes,
        commit_operation: None,
    })
}

/// Runs one ledger operation. `op` is one of `insert`, `claim`, `heartbeat`,
/// `cas`, `mark_dispatched`, `query`, `release`, `settle`, `cancel`,
/// `reconcile`, `append_denial_feedback`, `settle_denied_approval`.
pub fn reduce(
    op: &str,
    args: &Map<String, Value>,
    env: &Env,
    view: &View,
) -> Result<Effect, StoreError> {
    match op {
        "insert" => insert(args, env, view),
        "claim" => claim(args, env, view),
        "heartbeat" => heartbeat(args, env, view),
        "cas" => cas(
            args.get("cas").unwrap_or(&Value::Null),
            args.get("patch").unwrap_or(&Value::Null),
            args.get("allow_reconcile") == Some(&Value::Bool(true)),
            env,
            view,
        ),
        "mark_dispatched" => mark_dispatched(args, env, view),
        "query" => query(args, view),
        "release" => release(args, env, view),
        "settle" => settle(args, env, view),
        "cancel" => cancel(args, env, view),
        "reconcile" => reconcile(args, env, view),
        "append_denial_feedback" => append_denial_feedback(args, view),
        "settle_denied_approval" => settle_denied_approval(args, view),
        _ => Err(StoreError::InvalidArgument),
    }
}

// MARK: - JSON envelope

pub(crate) fn change_json(change: &Change) -> Value {
    match change {
        Change::InsertReservation(record) => {
            json!({ "kind": "insert_reservation", "record": record })
        }
        Change::InsertBatch(record) => json!({ "kind": "insert_batch", "record": record }),
        Change::InsertDeniedCall(record) => {
            json!({ "kind": "insert_denied_call", "record": record })
        }
        Change::InsertLedgerRow(row) => json!({ "kind": "insert_ledger_row", "row": row }),
        Change::ReplaceLedgerRow(row) => json!({ "kind": "replace_ledger_row", "row": row }),
        Change::InsertDispatchMarker(marker) => {
            json!({ "kind": "insert_dispatch_marker", "marker": marker })
        }
        Change::MarkDispatched(locator) => json!({ "kind": "mark_dispatched", "locator": locator }),
        Change::ReplaceTranscript(row) => json!({ "kind": "replace_transcript", "row": row }),
        Change::ReplaceReservation { slot, record } => {
            json!({ "kind": "replace_reservation", "slot": slot, "record": record })
        }
        Change::ReplaceBatch { slot, record } => {
            json!({ "kind": "replace_batch", "slot": slot, "record": record })
        }
        Change::ReplaceAuthority { slot, record } => {
            json!({ "kind": "replace_authority", "slot": slot, "record": record })
        }
    }
}

/// `{"op","args","env","view"}` in; `{"ok":true,"commit","output","changes",
/// "commit_operation"}` or `{"ok":false,"error":<code>}` out. A malformed
/// envelope is a host bug and reports as `Corrupt`.
pub fn reduce_json(input: &str) -> String {
    let value = match reduce_json_inner(input) {
        Ok(effect) => json!({
            "ok": true,
            "commit": effect.commit,
            "output": effect.output,
            "changes": effect.changes.iter().map(change_json).collect::<Vec<_>>(),
            "commit_operation": effect.commit_operation.map(|op| json!({
                "operation_id": op.operation_id,
                "request_sha256": op.request_sha256,
                "task_id": op.task_id,
                "attempt_id": op.attempt_id,
                "terminal_state": op.terminal_state,
                "result_status": op.result_status,
                "result_ref": op.result_ref,
                "result_revision": op.result_revision,
                "safe_result": op.safe_result,
            })),
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

fn reduce_json_inner(input: &str) -> Result<Effect, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = as_str(get(&envelope, "op")).ok_or(StoreError::Corrupt)?;
    let args = match get(&envelope, "args") {
        Some(Value::Object(map)) => map,
        _ => return Err(StoreError::Corrupt),
    };
    let env_value = get(&envelope, "env").ok_or(StoreError::Corrupt)?;
    let view_value = get(&envelope, "view").ok_or(StoreError::Corrupt)?;
    let env = Env {
        launch_id: as_str(get(env_value, "launch_id"))
            .ok_or(StoreError::Corrupt)?
            .to_owned(),
        now: as_str(get(env_value, "now"))
            .ok_or(StoreError::Corrupt)?
            .to_owned(),
        attempt_row_count: get(env_value, "attempt_row_count")
            .and_then(Value::as_u64)
            .unwrap_or(0),
    };
    let optional = |value: Option<&Value>| -> Option<Value> {
        match value {
            None | Some(Value::Null) => None,
            Some(other) => Some(other.clone()),
        }
    };
    let view = View {
        row: optional(get(view_value, "row")),
        dispatch: match get(view_value, "dispatch") {
            Some(Value::Array(items)) => items.clone(),
            _ => Vec::new(),
        },
        transcript: optional(get(view_value, "transcript")),
        expected_transcript: optional(get(view_value, "expected_transcript")),
        reservations: slotted_list(get(view_value, "reservations")),
        batches: slotted_list(get(view_value, "batches")),
        authorities: match get(view_value, "authorities") {
            None | Some(Value::Null) => None,
            Some(list) => Some(slotted_list(Some(list))),
        },
        arg_owner_alive: get(view_value, "arg_owner_alive") == Some(&Value::Bool(true)),
        row_owner_alive: get(view_value, "row_owner_alive") == Some(&Value::Bool(true)),
    };
    reduce(op, args, &env, &view)
}
