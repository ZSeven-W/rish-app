use rish_agent_core::{
    canonical::{canonical_json, hash_bytes, hash_json},
    execution_ledger, schema,
    session_schema::Env,
    user_question,
    wal_state::{self, StateVerdict},
};
use serde_json::{json, Value};
const ID: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const NOW: &str = "2026-10-16T00:00:00.000Z";

fn reference(transcript: &Value) -> Value {
    json!({"schema_version":1,"transcript_ref":transcript["transcript_ref"],
      "generation":transcript["generation"],"transcript_sha256":transcript["transcript_sha256"],
      "transcript_bytes":transcript["transcript_bytes"]})
}
fn seal_transcript(transcript: &mut Value) {
    let canonical = json!({"schema_version":1,"transcript_ref":transcript["transcript_ref"],
      "attempt_id":transcript["attempt_id"],"root_fingerprint_sha256":transcript["root_fingerprint_sha256"],
      "generation":transcript["generation"],"messages":transcript["messages"]});
    transcript["transcript_sha256"] = json!(hash_json("agent-transcript", &canonical).unwrap());
    transcript["transcript_bytes"] = json!(canonical_json(&canonical).unwrap().len());
}
fn state(response: Value) -> Value {
    let args = json!({"question":"选择平台","input_mode":"options","options":[
      {"id":"ios","label":"iOS"},{"id":"android","label":"Android"}]});
    let args_json = args.to_string();
    let args_sha =
        schema::arguments_sha256(Some(&json!("ask_user")), Some(&json!(args_json))).unwrap();
    let effect = user_question::effect(&args, &response).unwrap();
    let feedback = effect["feedback"].as_str().unwrap();
    let mut transcript = json!({"schema_version":1,"transcript_ref":ID,"attempt_id":ID,
      "root_fingerprint_sha256":"a".repeat(64),"generation":1,
      "messages":[{"schema_version":1,"role":"assistant","round_index":0,
        "content":"","reasoning_content":"","tool_calls":[{"schema_version":1,
          "call_id":"q0","name":"ask_user","arguments_json":args_json}]}],
      "state":"open","retention_until":null,"created_at":NOW,"updated_at":NOW});
    seal_transcript(&mut transcript);
    let before = reference(&transcript);
    transcript["generation"] = json!(2);
    transcript["messages"]
        .as_array_mut()
        .unwrap()
        .push(json!({"schema_version":1,
      "role":"tool","round_index":0,"call_id":"q0","content":feedback,"truncated":false}));
    seal_transcript(&mut transcript);
    let after = reference(&transcript);
    let mut locator = json!({"schema_version":2,"task_id":ID,"attempt_id":ID,"round_id":ID,
        "round_index":0,"call_index":0,"call_id":"q0","idempotency_key":"0".repeat(64)});
    locator["idempotency_key"] = json!(schema::idempotency_key_for_locator(
        Some(&locator),
        Some(&json!("a".repeat(64))),
        Some(&json!(args_sha))
    )
    .unwrap());
    let row = json!({"schema_version":2,"locator":locator,"row_revision":2,
      "root_fingerprint_sha256":"a".repeat(64),"binding_revision":1,
      "transcript_before":before,"name":"ask_user","arguments_sha256":args_sha,
      "precondition":user_question::prepared(&args).unwrap()["precondition"],"reserved_write_bytes":0,
      "state":"settled","owner":null,"settled_facts":effect["settled_facts"],"transcript_after":after,
      "receipt":{"schema_version":1,"call_id":"q0","name":"ask_user","arguments_sha256":args_sha,
        "result_sha256":hash_bytes("tool-result",feedback.as_bytes()).unwrap(),
        "result_bytes":feedback.len(),"truncated":false,"duration_ms":0,"outcome":"ok",
        "failure_code":null,"approval_reference":null},"created_at":NOW,"updated_at":NOW});
    assert!(execution_ledger::ledger_row(&row));
    json!({"schema_version":2,"generation":1,"authorities":[],"operations":[],"operation_results":[],
      "transcripts":[transcript],"rounds":[],"ledger":[row],"reservations":[],"cleanup":[],
      "dispatch":[{"schema_version":1,"kind":"execution","locator":locator,"dispatch_state":"not_dispatched"}],
      "batches":[],"denied_calls":[]})
}
fn valid(state: &Value) -> bool {
    // Keep the host's typed-row flag true to exercise the WAL's independent
    // cross-store binding even when a mutation would also fail typed validation.
    matches!(
        wal_state::state_basic_validation(state, &Env::default(), &[], &[true]),
        StateVerdict::Valid
    )
}
fn reseal(state: &mut Value) {
    seal_transcript(&mut state["transcripts"][0]);
    state["ledger"][0]["transcript_after"] = reference(&state["transcripts"][0]);
}

#[test]
fn complete_wal_accepts_only_proven_undispatched_question_responses() {
    for response in [
        json!({"status":"answered","answer":"ios"}),
        json!({"status":"cancelled","answer":null}),
    ] {
        let value = state(response);
        assert!(valid(&value));
        let response: Value = serde_json::from_str(&wal_state::reduce_json(
            &json!({
          "op":"state_basic","value":value,"env":{"round_valid":[],"ledger_valid":[true]}})
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response, json!({"ok":true,"valid":true}));
    }
}

#[test]
fn non_dispatch_exception_rejects_other_tools_or_unproven_settlement() {
    let original = state(json!({"status":"answered","answer":"ios"}));
    for (pointer, value) in [
        ("/ledger/0/name", json!("read_file")),
        ("/ledger/0/owner", json!({"unexpected":true})),
        ("/ledger/0/reserved_write_bytes", json!(1)),
        ("/ledger/0/precondition/kind", json!("read_file")),
        (
            "/ledger/0/precondition/question/question",
            json!("另一个问题"),
        ),
        (
            "/ledger/0/settled_facts/response_sha256",
            json!("0".repeat(64)),
        ),
        ("/ledger/0/receipt/name", json!("read_file")),
        ("/ledger/0/receipt/call_id", json!("other")),
        ("/ledger/0/receipt/arguments_sha256", json!("0".repeat(64))),
        ("/ledger/0/receipt/result_sha256", json!("0".repeat(64))),
        ("/ledger/0/receipt/result_bytes", json!(0)),
        ("/ledger/0/receipt/outcome", json!("failed")),
        ("/ledger/0/receipt/failure_code", json!("E_AGENT_INTERNAL")),
        ("/ledger/0/receipt/approval_reference", json!("approval")),
        ("/ledger/0/receipt/truncated", json!(true)),
    ] {
        let mut changed = original.clone();
        *changed.pointer_mut(pointer).unwrap() = value;
        assert!(!valid(&changed), "{pointer}");
    }
}

#[test]
fn protected_response_is_unique_and_bound_to_call_round_and_receipt() {
    let original = state(json!({"status":"answered","answer":"ios"}));
    for (pointer, value) in [
        ("/transcripts/0/messages/1/call_id", json!("other")),
        ("/transcripts/0/messages/1/round_index", json!(1)),
        ("/transcripts/0/messages/1/truncated", json!(true)),
    ] {
        let mut changed = original.clone();
        *changed.pointer_mut(pointer).unwrap() = value;
        reseal(&mut changed);
        assert!(!valid(&changed), "{pointer}");
    }
    let mut missing = original.clone();
    missing["transcripts"][0]["messages"]
        .as_array_mut()
        .unwrap()
        .pop();
    reseal(&mut missing);
    assert!(!valid(&missing));
    let mut duplicate = original.clone();
    let response = duplicate["transcripts"][0]["messages"][1].clone();
    duplicate["transcripts"][0]["messages"]
        .as_array_mut()
        .unwrap()
        .push(response);
    reseal(&mut duplicate);
    assert!(!valid(&duplicate));
    let mut changed = original.clone();
    let mut feedback: Value = serde_json::from_str(
        changed["transcripts"][0]["messages"][1]["content"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    feedback["payload"]["response"]["answer"] = json!("android");
    let bytes = canonical_json(&feedback).unwrap();
    changed["transcripts"][0]["messages"][1]["content"] =
        json!(String::from_utf8(bytes.clone()).unwrap());
    // A matching receipt is insufficient if the settled facts still bind the
    // original answer; recompute both transcript and receipt to isolate it.
    changed["ledger"][0]["receipt"]["result_bytes"] = json!(bytes.len());
    changed["ledger"][0]["receipt"]["result_sha256"] =
        json!(hash_bytes("tool-result", &bytes).unwrap());
    reseal(&mut changed);
    assert!(!valid(&changed));
}
