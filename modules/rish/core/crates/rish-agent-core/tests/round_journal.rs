//! Scenario tests for the schema-3 round-journal reducer. Fixtures mirror the
//! ObjC `AgentProviderRoundServiceTests` smoke identities so the same rows
//! are exercised on both sides.

use rish_agent_core::canonical::hash_json;
use rish_agent_core::round_journal::{reduce, reduce_json, DispatchEffect, Env, StoreError, View};
use serde_json::{json, Map, Value};

const TASK: &str = "11111111-1111-4111-8111-111111111111";
const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
const ROUND: &str = "33333333-3333-4333-8333-333333333333";
const LAUNCH: &str = "44444444-4444-4444-8444-444444444444";
const NATIVE: &str = "55555555-5555-4555-8555-555555555555";
const TRANSCRIPT_REF: &str = "88888888-8888-4888-8888-888888888888";
const ROOT_DIGEST: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const REQUEST_DIGEST: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const ANY_DIGEST: &str = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3";
const NOW: &str = "2023-11-14T22:13:20.000Z";
const LATER: &str = "2023-11-14T22:13:21.000Z";

fn env() -> Env {
    Env {
        launch_id: LAUNCH.to_string(),
        now: LATER.to_string(),
        round_count: 0,
        supported_models: vec!["deepseek-v4-flash".to_string()],
        receipt_harness_id: Some("dsh".to_string()),
        receipt_binding_valid: false,
    }
}

fn locator() -> Value {
    json!({ "schema_version": 1, "task_id": TASK, "attempt_id": ATTEMPT, "round_id": ROUND, "round_index": 0 })
}

fn owner() -> Value {
    json!({
        "schema_version": 1, "task_id": TASK, "launch_id": LAUNCH, "native_task_id": NATIVE,
        "owner_generation": 1, "heartbeat_at": NOW,
    })
}

fn empty_transcript_digest() -> (String, u64) {
    let input = json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "attempt_id": ATTEMPT,
        "root_fingerprint_sha256": ROOT_DIGEST, "generation": 0, "messages": [],
    });
    let bytes = rish_agent_core::canonical::canonical_json(&input)
        .unwrap()
        .len() as u64;
    (hash_json("agent-transcript", &input).unwrap(), bytes)
}

fn transcript_before() -> Value {
    let (digest, bytes) = empty_transcript_digest();
    json!({ "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "generation": 0, "transcript_sha256": digest, "transcript_bytes": bytes })
}

fn transcript_row() -> Value {
    let (digest, bytes) = empty_transcript_digest();
    json!({
        "schema_version": 1, "transcript_ref": TRANSCRIPT_REF, "attempt_id": ATTEMPT, "state": "open",
        "root_fingerprint_sha256": ROOT_DIGEST, "generation": 0, "transcript_sha256": digest,
        "transcript_bytes": bytes, "messages": [], "created_at": NOW, "updated_at": NOW,
    })
}

fn root() -> Value {
    json!({
        "schema_version": 1, "kind": "workspace", "workspace_id": "77777777-7777-4777-8777-777777777777",
        "workspace_binding_revision": 7, "project_id": null, "root_fingerprint_sha256": ROOT_DIGEST,
        "capabilities": ["file_read", "file_write"],
    })
}

fn in_flight_row() -> Value {
    json!({
        "schema_version": 3, "locator": locator(), "row_revision": 1, "root_fingerprint_sha256": ROOT_DIGEST,
        "binding_revision": 7, "request_sha256": REQUEST_DIGEST, "transcript_before": transcript_before(),
        "launch_attempt": 1, "state": "in_flight", "owner": owner(), "failure_code": null,
        "completion_receipt": null, "transcript_after": null, "calls": [], "batch_class": null,
        "executable_call_count": 0, "denied_call_count": 0, "terminal_kind": null,
        "created_at": NOW, "updated_at": NOW,
    })
}

fn insert_cas() -> Value {
    let before = transcript_before();
    json!({
        "schema_version": 1, "locator": locator(), "expected_absent": true,
        "expected_transcript_generation": 0, "expected_transcript_sha256": before["transcript_sha256"],
        "expected_root_fingerprint_sha256": ROOT_DIGEST, "expected_binding_revision": 7,
    })
}

fn cas_for(row: &Value) -> Value {
    let owner = &row["owner"];
    let before = &row["transcript_before"];
    json!({
        "schema_version": 2, "locator": row["locator"], "expected_row_revision": row["row_revision"],
        "expected_state": row["state"],
        "expected_owner_generation": if owner.is_null() { Value::Null } else { owner["owner_generation"].clone() },
        "expected_launch_id": if owner.is_null() { Value::Null } else { owner["launch_id"].clone() },
        "expected_native_task_id": if owner.is_null() { Value::Null } else { owner["native_task_id"].clone() },
        "expected_transcript_generation": before["generation"], "expected_transcript_sha256": before["transcript_sha256"],
        "expected_root_fingerprint_sha256": row["root_fingerprint_sha256"], "expected_binding_revision": row["binding_revision"],
    })
}

fn receipt(finish_reason: &str) -> Value {
    json!({
        "schema_version": 1, "transport_schema_version": 3, "turn_id": TASK, "attempt_id": ATTEMPT,
        "round_id": ROUND, "round_index": 0, "provider_request_id": "req-1", "provider_response_id": "resp-1",
        "requested_model": "deepseek-v4-flash", "model": "deepseek-v4-flash", "thinking_mode": "off",
        "finish_reason": finish_reason, "latency_ms": 12, "visible_history_sha256": ANY_DIGEST,
        "model_input_sha256": ANY_DIGEST, "request_body_sha256": ANY_DIGEST, "project_context_receipt": null,
    })
}

fn args(pairs: Value) -> Map<String, Value> {
    pairs.as_object().unwrap().clone()
}

fn view(row: Option<Value>, dispatch: Option<&str>) -> View {
    View {
        row,
        dispatch_state: dispatch.map(str::to_owned),
        transcript: None,
        arg_owner_alive: true,
        row_owner_alive: true,
    }
}

#[test]
fn create_inserts_and_replays_identically() {
    let row = in_flight_row();
    let effect = reduce(
        "create",
        &args(json!({ "insert_cas": insert_cas(), "round": row })),
        &env(),
        &view(None, None),
    )
    .unwrap();
    assert!(effect.commit);
    assert_eq!(effect.dispatch, Some(DispatchEffect::InsertNotDispatched));
    assert_eq!(effect.output["status"], "inserted");
    assert_eq!(effect.row.as_ref(), Some(&row));

    let replay = reduce(
        "create",
        &args(json!({ "insert_cas": insert_cas(), "round": row })),
        &env(),
        &view(Some(row.clone()), Some("not_dispatched")),
    )
    .unwrap();
    assert!(!replay.commit);
    assert_eq!(replay.output["status"], "already_present");

    let mut different = row.clone();
    different["request_sha256"] = json!(ANY_DIGEST);
    let conflict = reduce(
        "create",
        &args(json!({ "insert_cas": insert_cas(), "round": different })),
        &env(),
        &view(Some(row.clone()), Some("not_dispatched")),
    );
    assert_eq!(conflict.unwrap_err(), StoreError::Conflict);

    let mut dead = view(None, None);
    dead.arg_owner_alive = false;
    assert_eq!(
        reduce(
            "create",
            &args(json!({ "insert_cas": insert_cas(), "round": row })),
            &env(),
            &dead
        )
        .unwrap_err(),
        StoreError::OwnerLost
    );

    let mut full = env();
    full.round_count = 1024;
    assert_eq!(
        reduce(
            "create",
            &args(json!({ "insert_cas": insert_cas(), "round": row })),
            &full,
            &view(None, None)
        )
        .unwrap_err(),
        StoreError::Capacity
    );
}

#[test]
fn dispatch_then_complete_updates_row_and_transcript() {
    let row = in_flight_row();
    let dispatched = reduce(
        "mark_dispatched",
        &args(json!({ "cas": cas_for(&row) })),
        &env(),
        &view(Some(row.clone()), Some("not_dispatched")),
    )
    .unwrap();
    assert_eq!(dispatched.dispatch, Some(DispatchEffect::MarkDispatched));
    let row = dispatched.row.unwrap();
    assert_eq!(row["row_revision"], json!(2));
    assert_eq!(row["updated_at"], json!(LATER));

    let again = reduce(
        "mark_dispatched",
        &args(json!({ "cas": cas_for(&row) })),
        &env(),
        &view(Some(row.clone()), Some("dispatched")),
    )
    .unwrap();
    assert!(!again.commit);
    assert_eq!(again.output["status"], "already_dispatched");

    let mut complete_view = view(Some(row.clone()), Some("dispatched"));
    complete_view.transcript = Some(transcript_row());
    let arguments_json = "{\"path\":\"README.md\"}";
    let digest = rish_agent_core::schema::arguments_sha256(
        Some(&json!("read_file")),
        Some(&json!(arguments_json)),
    )
    .unwrap();
    let messages = json!([{
        "schema_version": 1, "role": "assistant", "round_index": 0, "content": "", "reasoning_content": "",
        "tool_calls": [{ "schema_version": 1, "call_id": "call_0", "name": "read_file", "arguments_json": arguments_json }],
    }]);
    let calls = json!([{
        "schema_version": 3, "call_index": 0, "call_id": "call_0", "name": "read_file", "arguments_sha256": digest,
        "safe_summary_key": "agent.read_file", "access": "auto", "approval_state": "deferred",
    }]);
    let effect = reduce(
        "complete",
        &args(json!({
            "locator": locator(), "cas": cas_for(&row), "messages": messages, "receipt": receipt("tool_calls"),
            "terminal_kind": "tool_batch", "calls": calls, "root": root(),
        })),
        &env(),
        &complete_view,
    )
    .unwrap();
    assert!(effect.commit);
    let completed = effect.row.unwrap();
    assert_eq!(completed["state"], "completed");
    assert_eq!(completed["batch_class"], "executable");
    assert_eq!(completed["executable_call_count"], json!(1));
    assert_eq!(completed["row_revision"], json!(3));
    let transcript = effect.transcript.unwrap();
    assert_eq!(transcript["generation"], json!(1));
    assert_eq!(transcript["messages"].as_array().unwrap().len(), 1);
    assert_eq!(
        completed["transcript_after"]["transcript_sha256"],
        transcript["transcript_sha256"]
    );
    assert_eq!(effect.output["transcript"], completed["transcript_after"]);

    // A presentation whose digest does not match the tool call is a conflict,
    // not an invalid argument.
    let mut wrong_calls = calls.clone();
    wrong_calls[0]["arguments_sha256"] = json!(ANY_DIGEST);
    let conflict = reduce(
        "complete",
        &args(json!({
            "locator": locator(), "cas": cas_for(&row), "messages": messages, "receipt": receipt("tool_calls"),
            "terminal_kind": "tool_batch", "calls": wrong_calls, "root": root(),
        })),
        &env(),
        &complete_view,
    );
    assert_eq!(conflict.unwrap_err(), StoreError::Conflict);

    // Completion before dispatch is refused.
    let mut undispatched = complete_view.clone();
    undispatched.dispatch_state = Some("not_dispatched".to_string());
    let refused = reduce(
        "complete",
        &args(json!({
            "locator": locator(), "cas": cas_for(&row), "messages": messages, "receipt": receipt("tool_calls"),
            "terminal_kind": "tool_batch", "calls": calls, "root": root(),
        })),
        &env(),
        &undispatched,
    );
    assert_eq!(refused.unwrap_err(), StoreError::Conflict);
}

#[test]
fn final_completion_requires_no_calls() {
    let row = in_flight_row();
    let mut complete_view = view(Some(row.clone()), Some("dispatched"));
    complete_view.transcript = Some(transcript_row());
    let messages = json!([{ "schema_version": 1, "role": "assistant", "round_index": 0, "content": "done", "reasoning_content": "", "tool_calls": [] }]);
    let effect = reduce(
        "complete",
        &args(json!({
            "locator": locator(), "cas": cas_for(&row), "messages": messages, "receipt": receipt("stop"),
            "terminal_kind": "final", "calls": [], "root": root(),
        })),
        &env(),
        &complete_view,
    )
    .unwrap();
    assert_eq!(effect.row.unwrap()["terminal_kind"], "final");

    let mismatch = reduce(
        "complete",
        &args(json!({
            "locator": locator(), "cas": cas_for(&row), "messages": messages, "receipt": receipt("stop"),
            "terminal_kind": "tool_batch", "calls": [], "root": root(),
        })),
        &env(),
        &complete_view,
    );
    assert_eq!(mismatch.unwrap_err(), StoreError::InvalidArgument);
}

#[test]
fn cancel_is_proof_gated() {
    let row = in_flight_row();
    let requested = reduce(
        "cancel",
        &args(json!({ "cas": cas_for(&row) })),
        &env(),
        &view(Some(row.clone()), Some("not_dispatched")),
    )
    .unwrap();
    assert_eq!(requested.output["status"], "cancel_requested");
    let row = requested.row.unwrap();
    assert_eq!(row["state"], "cancel_requested");
    assert_eq!(row["owner"], owner());

    // Dispatched work cannot be cancelled outright.
    let blocked = reduce(
        "cancel",
        &args(json!({ "cas": cas_for(&row) })),
        &env(),
        &view(Some(row.clone()), Some("dispatched")),
    );
    assert_eq!(blocked.unwrap_err(), StoreError::Conflict);

    let cancelled = reduce(
        "cancel",
        &args(json!({ "cas": cas_for(&row) })),
        &env(),
        &view(Some(row.clone()), Some("not_dispatched")),
    )
    .unwrap();
    let row = cancelled.row.unwrap();
    assert_eq!(row["state"], "cancelled");
    assert_eq!(row["failure_code"], "E_AGENT_CANCELLED");
    assert_eq!(row["terminal_kind"], "blocked");
    assert_eq!(row["transcript_after"], row["transcript_before"]);
    assert!(row["owner"].is_null());

    let missing_marker = reduce(
        "cancel",
        &args(json!({ "cas": cas_for(&in_flight_row()) })),
        &env(),
        &view(Some(in_flight_row()), None),
    );
    assert_eq!(missing_marker.unwrap_err(), StoreError::Corrupt);
}

#[test]
fn reconcile_follows_dispatch_proof() {
    let row = in_flight_row();
    let mut dead = view(Some(row.clone()), Some("not_dispatched"));
    dead.row_owner_alive = false;
    let retryable = reduce(
        "reconcile",
        &args(json!({ "locator": locator(), "cas": cas_for(&row) })),
        &env(),
        &dead,
    )
    .unwrap();
    let retry_row = retryable.row.unwrap();
    assert_eq!(retry_row["state"], "failed_retryable");
    assert_eq!(retry_row["failure_code"], "E_AGENT_PERSISTENCE");

    let mut dead_dispatched = dead.clone();
    dead_dispatched.dispatch_state = Some("dispatched".to_string());
    let ambiguous = reduce(
        "reconcile",
        &args(json!({ "locator": locator(), "cas": cas_for(&row) })),
        &env(),
        &dead_dispatched,
    )
    .unwrap();
    assert_eq!(
        ambiguous.row.unwrap()["failure_code"],
        "E_AGENT_ROUND_AMBIGUOUS"
    );

    let mut cancel_requested = row.clone();
    cancel_requested["state"] = json!("cancel_requested");
    let mut dead_cancel = dead.clone();
    dead_cancel.row = Some(cancel_requested.clone());
    let cancelled = reduce(
        "reconcile",
        &args(json!({ "locator": locator(), "cas": cas_for(&cancel_requested) })),
        &env(),
        &dead_cancel,
    )
    .unwrap();
    assert_eq!(cancelled.row.unwrap()["state"], "cancelled");

    // A live owner is never reconciled away.
    let alive = reduce(
        "reconcile",
        &args(json!({ "locator": locator(), "cas": cas_for(&row) })),
        &env(),
        &view(Some(row.clone()), Some("not_dispatched")),
    );
    assert_eq!(alive.unwrap_err(), StoreError::Conflict);

    // Claiming the retryable row hands it to a fresh owner.
    let claimed = reduce(
        "claim",
        &args(json!({ "locator": locator(), "expected_row_revision": retry_row["row_revision"], "owner": owner() })),
        &env(),
        &view(Some(retry_row.clone()), Some("not_dispatched")),
    )
    .unwrap();
    let claimed_row = claimed.row.unwrap();
    assert_eq!(claimed_row["state"], "in_flight");
    assert_eq!(claimed_row["launch_attempt"], json!(2));
    assert!(claimed_row["failure_code"].is_null());
}

#[test]
fn query_reports_absence_without_committing() {
    let absent = reduce(
        "query",
        &args(json!({ "locator": locator() })),
        &env(),
        &view(None, None),
    )
    .unwrap();
    assert!(!absent.commit);
    assert_eq!(
        absent.output,
        json!({ "schema_version": 3, "status": "not_started" })
    );
    let present = reduce(
        "query",
        &args(json!({ "locator": locator() })),
        &env(),
        &view(Some(in_flight_row()), None),
    )
    .unwrap();
    assert_eq!(present.output["status"], "in_flight");
    assert_eq!(
        reduce(
            "query",
            &args(json!({ "locator": {} })),
            &env(),
            &view(None, None)
        )
        .unwrap_err(),
        StoreError::InvalidArgument
    );
}

#[test]
fn json_envelope_round_trips_effects_and_errors() {
    let envelope = json!({
        "op": "mark_dispatched",
        "args": { "cas": cas_for(&in_flight_row()) },
        "env": { "launch_id": LAUNCH, "now": LATER, "round_count": 1, "supported_models": ["deepseek-v4-flash"], "receipt_harness_id": null, "receipt_binding_valid": false },
        "view": { "row": in_flight_row(), "dispatch_state": "not_dispatched", "transcript": null, "arg_owner_alive": false, "row_owner_alive": true },
    });
    let output: Value = serde_json::from_str(&reduce_json(&envelope.to_string())).unwrap();
    assert_eq!(output["ok"], true);
    assert_eq!(output["commit"], true);
    assert_eq!(output["dispatch"], "mark_dispatched");
    assert_eq!(output["row"]["row_revision"], json!(2));
    assert!(output["transcript"].is_null());

    let failure: Value = serde_json::from_str(&reduce_json(r#"{"op":"cancel","args":{"cas":{}},"env":{"launch_id":"x","now":"y","round_count":0},"view":{}}"#)).unwrap();
    assert_eq!(failure, json!({ "ok": false, "error": 1 }));
    let malformed: Value = serde_json::from_str(&reduce_json("not json")).unwrap();
    assert_eq!(malformed, json!({ "ok": false, "error": 2 }));
}

/// A round that provably never left the device keeps the reason it did not.
///
/// A refusal raised while the request was being built -- an attachment the
/// transport cannot carry, a dialect that cannot express a round transcript
/// -- is the only account of why the turn ended. Every later reader takes
/// the row's code and recovery after a restart has nothing else, so the row
/// is where the cause has to live. It used to be flattened to
/// E_AGENT_PERSISTENCE, which reads to a person as a save that could not be
/// confirmed, with Retry save as the only advice.
#[test]
fn a_round_settled_before_dispatch_keeps_its_stated_cause() {
    let row = in_flight_row();
    let mut dead = view(Some(row.clone()), Some("not_dispatched"));
    dead.row_owner_alive = false;
    let stated = reduce(
        "reconcile",
        &args(json!({
            "locator": locator(),
            "cas": cas_for(&row),
            "failure_code": "E_AGENT_CAPABILITY",
        })),
        &env(),
        &dead,
    )
    .unwrap();
    let settled = stated.row.unwrap();
    assert_eq!(settled["state"], "failed_retryable");
    assert_eq!(settled["failure_code"], "E_AGENT_CAPABILITY");

    // A dispatched round is ambiguous whatever its writer believes. Letting
    // a caller name a confident cause here would turn an ambiguity into
    // false certainty, which is the one thing the marker exists to prevent.
    let mut dead_dispatched = dead.clone();
    dead_dispatched.dispatch_state = Some("dispatched".to_string());
    let dispatched = reduce(
        "reconcile",
        &args(json!({
            "locator": locator(),
            "cas": cas_for(&row),
            "failure_code": "E_AGENT_CAPABILITY",
        })),
        &env(),
        &dead_dispatched,
    )
    .unwrap();
    assert_eq!(
        dispatched.row.unwrap()["failure_code"],
        "E_AGENT_ROUND_AMBIGUOUS",
    );

    // A cause outside the closed union, and the generic answer restated, are
    // both ignored rather than written.
    for ignored in [json!("not a code"), json!("E_AGENT_PERSISTENCE"), json!(7)] {
        let answer = reduce(
            "reconcile",
            &args(json!({
                "locator": locator(),
                "cas": cas_for(&row),
                "failure_code": ignored,
            })),
            &env(),
            &dead,
        )
        .unwrap();
        assert_eq!(
            answer.row.unwrap()["failure_code"],
            "E_AGENT_PERSISTENCE",
            "{ignored}",
        );
    }
}

// Races around a cancellation that names its round at revision 0 (the reply
// carrying the row's revision is the one being stopped). The plan takes the
// WAL's revision; these pin that it never lets the cancel win what it lost.

fn wal_with(row: &Value) -> Value {
    json!({ "rounds": [row] })
}

fn round_cancel_request(round_id: &str, attempt_id: &str, revision: u64) -> Value {
    json!({
        "target": { "schema_version": 2, "kind": "round", "task_id": TASK, "attempt_id": attempt_id,
                    "round_id": round_id, "round_index": 0 },
        "expected_round_revision": revision,
    })
}

/// The CAS a host builds from a round plan: the row it read, at the revision
/// the plan settled on.
fn cas_at(row: &Value, revision: &Value) -> Value {
    let mut cas = cas_for(row);
    cas["expected_row_revision"] = revision.clone();
    cas
}

fn cancel_planned(row: &Value, revision: u64) -> Result<Value, StoreError> {
    let plan = rish_agent_core::runtime_coordinator::cancel_plan(
        &wal_with(row),
        &round_cancel_request(ROUND, ATTEMPT, revision),
    );
    assert_eq!(plan["plan"], "round");
    reduce(
        "cancel",
        &args(json!({ "cas": cas_at(row, &plan["expected_round_revision"]) })),
        &env(),
        &view(Some(row.clone()), Some("dispatched")),
    )
    .map(|effect| effect.row.unwrap())
}

// The reply finished before the stop arrived: the WAL's revision is the
// completed row's, and a completed row is not cancelled.
#[test]
fn a_completion_that_won_is_not_cancelled_at_the_wal_revision() {
    let mut completed = in_flight_row();
    completed["state"] = json!("completed");
    completed["row_revision"] = json!(2);
    completed["owner"] = Value::Null;
    assert_eq!(
        cancel_planned(&completed, 0).unwrap_err(),
        StoreError::Conflict
    );
}

// The plan read revision 1; the reply completed (revision 2) before the
// cancel committed. The CAS the plan produced no longer matches.
#[test]
fn a_completion_after_the_plan_makes_the_cancel_conflict() {
    let row = in_flight_row();
    let plan = rish_agent_core::runtime_coordinator::cancel_plan(
        &wal_with(&row),
        &round_cancel_request(ROUND, ATTEMPT, 0),
    );
    let cas = cas_at(&row, &plan["expected_round_revision"]);
    let mut moved = row.clone();
    moved["state"] = json!("completed");
    moved["row_revision"] = json!(2);
    let lost = reduce(
        "cancel",
        &args(json!({ "cas": cas })),
        &env(),
        &view(Some(moved), Some("dispatched")),
    );
    assert_eq!(lost.unwrap_err(), StoreError::Conflict);
}

// A nonzero revision is what the controller heard; a stale one is kept and
// refused, never replaced by the WAL's.
#[test]
fn a_stale_nonzero_revision_still_conflicts() {
    let mut row = in_flight_row();
    row["row_revision"] = json!(4);
    let plan = rish_agent_core::runtime_coordinator::cancel_plan(
        &wal_with(&row),
        &round_cancel_request(ROUND, ATTEMPT, 3),
    );
    assert_eq!(plan["expected_round_revision"], json!(3));
    assert_eq!(cancel_planned(&row, 3).unwrap_err(), StoreError::Conflict);
    // The same row at the revision it has is cancelled.
    assert_eq!(
        cancel_planned(&row, 0).unwrap()["state"],
        "cancel_requested"
    );
}

// Revision 0 borrows only from the row the target names: another round or
// another attempt lends it nothing.
#[test]
fn revision_zero_borrows_only_from_the_named_round() {
    let row = in_flight_row();
    let other_round = "99999999-9999-4999-8999-999999999999";
    for (round_id, attempt_id) in [(other_round, ATTEMPT), (ROUND, other_round)] {
        let plan = rish_agent_core::runtime_coordinator::cancel_plan(
            &wal_with(&row),
            &round_cancel_request(round_id, attempt_id, 0),
        );
        assert_ne!(plan["plan"], "round", "{round_id} {attempt_id}");
    }
}

// A provider's refusal heard in full: the transport reports the status and
// the owner it dispatched under; the core names the cause.

fn refused_by(
    row: &Value,
    dispatch: &str,
    status: u64,
    owner: Value,
) -> Result<rish_agent_core::round_journal::Effect, StoreError> {
    let mut dead = view(Some(row.clone()), Some(dispatch));
    dead.row_owner_alive = false;
    reduce(
        "reconcile",
        &args(json!({
            "locator": locator(), "cas": cas_for(row),
            "transport_evidence": { "kind": "http_rejected", "http_status": status, "owner": owner },
        })),
        &env(),
        &dead,
    )
}

#[test]
fn a_refusal_the_provider_answered_is_retryable_with_its_cause() {
    for (status, code) in [
        (401, "E_AGENT_PROVIDER_CREDENTIAL"),
        (403, "E_AGENT_PROVIDER_FORBIDDEN"),
        (404, "E_AGENT_PROVIDER_NOT_FOUND"),
        (429, "E_AGENT_PROVIDER_RATE_LIMITED"),
        (400, "E_AGENT_PROVIDER_REFUSED"),
        (422, "E_AGENT_PROVIDER_REFUSED"),
    ] {
        let effect = refused_by(&in_flight_row(), "dispatched", status, owner()).unwrap();
        let row = effect.row.unwrap();
        assert_eq!(row["state"], "failed_retryable", "{status}");
        assert_eq!(row["failure_code"], code, "{status}");
        assert!(row["owner"].is_null());
        // Recorded and cleared in one commit: failed_retryable beside a
        // dispatched marker is corrupt, and a reclaim needs it clear.
        assert_eq!(
            effect.dispatch,
            Some(DispatchEffect::ResetNotDispatched),
            "{status}"
        );
    }
}

// What a status does not prove stays ambiguous: the server giving up on a
// slow request, a proxy noting the client left, and every 5xx.
#[test]
fn a_status_that_proves_no_refusal_stays_ambiguous() {
    for status in [408, 499, 500, 502, 503, 504, 200, 302] {
        let effect = refused_by(&in_flight_row(), "dispatched", status, owner()).unwrap();
        assert_eq!(effect.row.unwrap()["state"], "ambiguous", "{status}");
        assert_eq!(effect.dispatch, None, "{status}");
    }
}

// Evidence speaks only for the dispatch that produced it.
#[test]
fn a_refusal_is_bound_to_the_dispatch_that_heard_it() {
    // Another owner's refusal.
    let mut stranger = owner();
    stranger["native_task_id"] = json!("66666666-6666-4666-8666-666666666666");
    let effect = refused_by(&in_flight_row(), "dispatched", 401, stranger).unwrap();
    assert_eq!(effect.row.unwrap()["state"], "ambiguous");

    // A round the person stopped meanwhile is not the round that was refused.
    let mut stopping = in_flight_row();
    stopping["state"] = json!("cancel_requested");
    let effect = refused_by(&stopping, "dispatched", 401, owner()).unwrap();
    assert_eq!(effect.row.unwrap()["state"], "ambiguous");

    // Never dispatched: the existing rule decides, and no reset is needed.
    let effect = refused_by(&in_flight_row(), "not_dispatched", 401, owner()).unwrap();
    let row = effect.row.unwrap();
    assert_eq!(row["state"], "failed_retryable");
    assert_eq!(row["failure_code"], "E_AGENT_PERSISTENCE");
    assert_eq!(effect.dispatch, None);
}

// A caller cannot talk a dispatched round out of its ambiguity by naming a
// cause itself, with or without evidence.
#[test]
fn a_stated_cause_never_replaces_the_derived_one() {
    let mut dead = view(Some(in_flight_row()), Some("dispatched"));
    dead.row_owner_alive = false;
    let stated = reduce(
        "reconcile",
        &args(
            json!({ "locator": locator(), "cas": cas_for(&in_flight_row()),
                      "failure_code": "E_AGENT_PROVIDER_CREDENTIAL" }),
        ),
        &env(),
        &dead,
    )
    .unwrap();
    assert_eq!(stated.row.unwrap()["state"], "ambiguous");
}

#[test]
fn malformed_evidence_is_a_host_bug() {
    let mut dead = view(Some(in_flight_row()), Some("dispatched"));
    dead.row_owner_alive = false;
    for evidence in [
        json!({ "kind": "answered", "http_status": 401, "owner": owner() }),
        json!({ "kind": "http_rejected", "http_status": "401", "owner": owner() }),
        json!({ "kind": "http_rejected", "http_status": 401 }),
        json!({ "kind": "http_rejected", "http_status": 401, "owner": owner(), "code": "E" }),
        json!({ "kind": "http_rejected", "http_status": 99, "owner": owner() }),
        json!("http_rejected"),
    ] {
        let result = reduce(
            "reconcile",
            &args(
                json!({ "locator": locator(), "cas": cas_for(&in_flight_row()),
                          "transport_evidence": evidence }),
            ),
            &env(),
            &dead,
        );
        assert_eq!(
            result.unwrap_err(),
            StoreError::InvalidArgument,
            "{evidence}"
        );
    }
}

#[test]
fn the_reset_travels_through_the_json_envelope() {
    let envelope = json!({
        "op": "reconcile",
        "args": { "locator": locator(), "cas": cas_for(&in_flight_row()),
                  "transport_evidence": { "kind": "http_rejected", "http_status": 401, "owner": owner() } },
        "env": { "launch_id": LAUNCH, "now": LATER, "round_count": 1, "supported_models": ["deepseek-v4-flash"], "receipt_harness_id": null, "receipt_binding_valid": false },
        "view": { "row": in_flight_row(), "dispatch_state": "dispatched", "transcript": null, "arg_owner_alive": false, "row_owner_alive": false },
    });
    let output: Value = serde_json::from_str(&reduce_json(&envelope.to_string())).unwrap();
    assert_eq!(output["ok"], true);
    assert_eq!(output["dispatch"], "reset_not_dispatched");
    assert_eq!(output["row"]["failure_code"], "E_AGENT_PROVIDER_CREDENTIAL");
}
