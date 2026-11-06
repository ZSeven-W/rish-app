use rish_agent_core::canonical::{canonical_json, hash_json};
use rish_agent_core::runtime_coordinator::query_attempt_base_conflict_with_state;
use serde_json::{json, Value};

const TASK: &str = "11111111-1111-4111-8111-111111111111";
const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
const REFERENCE: &str = "33333333-3333-4333-8333-333333333333";

fn handle(messages: &[Value], generation: u64) -> Value {
    let value = json!({"schema_version":1,"transcript_ref":REFERENCE,"attempt_id":ATTEMPT,
        "root_fingerprint_sha256":"a".repeat(64),"generation":generation,"messages":messages});
    json!({"schema_version":1,"transcript_ref":REFERENCE,"generation":generation,
        "transcript_sha256":hash_json("agent-transcript", &value).unwrap(),
        "transcript_bytes":canonical_json(&value).unwrap().len()})
}

fn fixture() -> (Value, Value, Value, Value) {
    let messages = vec![
        json!({"schema_version":1,"role":"user","content":"创建文件"}),
        json!({"schema_version":1,"role":"assistant","round_index":0,"content":"","tool_calls":[
            {"call_id":"write_0","name":"write_file","arguments_json":"{}"},
            {"call_id":"read_1","name":"read_file","arguments_json":"{}"}]}),
        json!({"schema_version":1,"role":"tool","round_index":0,"call_id":"write_0","content":"written","truncated":false}),
        json!({"schema_version":1,"role":"tool","round_index":0,"call_id":"read_1","content":"read","truncated":false}),
    ];
    let initial = handle(&messages[..1], 1);
    let prepared = handle(&messages[..2], 2);
    let first = handle(&messages[..3], 3);
    let current = handle(&messages, 4);
    let root = json!({"schema_version":1,"kind":"workspace","workspace_id":TASK,
        "project_id":null,"root_fingerprint_sha256":"a".repeat(64),"workspace_binding_revision":1,
        "capabilities":["file_read","file_write"]});
    let base = json!({"task_id":TASK,"attempt_id":ATTEMPT,"conversation_id":"chat","root":root,"transcript":current});
    let request = json!({"task_id":TASK,"attempt_id":ATTEMPT,"conversation_id":"chat",
        "expected_transcript":prepared,"expected_root_fingerprint_sha256":"a".repeat(64),
        "expected_workspace_binding_revision":1});
    let proof = json!({"journal_transcript":prepared});
    let row = |id: &str, after: &Value| {
        json!({"locator":{"task_id":TASK,"attempt_id":ATTEMPT,"round_index":0,"call_id":id},
        "root_fingerprint_sha256":"a".repeat(64),"binding_revision":1,"state":"settled",
        "transcript_before":prepared,"transcript_after":after})
    };
    let state = json!({"authorities":[base],"transcripts":[{
        "schema_version":1,"transcript_ref":REFERENCE,"attempt_id":ATTEMPT,"root_fingerprint_sha256":"a".repeat(64),
        "generation":4,"transcript_sha256":current["transcript_sha256"],"transcript_bytes":current["transcript_bytes"],"messages":messages}],
      "rounds":[{"locator":{"task_id":TASK,"attempt_id":ATTEMPT,"round_index":0},
        "root_fingerprint_sha256":"a".repeat(64),"binding_revision":1,"state":"completed",
        "transcript_before":initial,"transcript_after":prepared}],
      "ledger":[row("write_0", &first),row("read_1", &current)],"denied_calls":[]});
    (base, request, proof, state)
}

#[test]
fn lost_native_tool_reply_recovers_from_exact_committed_prefix_and_complete_wal_chain() {
    let (base, mut request, mut proof, state) = fixture();
    assert!(query_attempt_base_conflict_with_state(&base, &request, &proof, &state).is_none());
    // A prepared batch shares its original before handle; the UI might have
    // persisted one tool response and lost the next one.
    request["expected_transcript"] = state["ledger"][0]["transcript_after"].clone();
    proof["journal_transcript"] = request["expected_transcript"].clone();
    assert!(query_attempt_base_conflict_with_state(&base, &request, &proof, &state).is_none());
    // Initial history followed by a completed round is the same append proof.
    request["expected_transcript"] = state["rounds"][0]["transcript_before"].clone();
    proof["journal_transcript"] = request["expected_transcript"].clone();
    assert!(query_attempt_base_conflict_with_state(&base, &request, &proof, &state).is_none());
}

#[test]
fn forged_committed_old_handle_missing_chain_cross_root_and_rollback_are_rejected() {
    let (base, request, proof, state) = fixture();
    let check = |base: &Value, request: &Value, proof: &Value, state: &Value| {
        assert!(query_attempt_base_conflict_with_state(base, request, proof, state).is_some());
    };
    check(&base, &request, &proof, &Value::Null);
    let mut bad_request = request.clone();
    let mut bad_proof = proof.clone();
    bad_request["expected_transcript"]["transcript_sha256"] = json!("b".repeat(64));
    bad_proof["journal_transcript"] = bad_request["expected_transcript"].clone();
    check(&base, &bad_request, &bad_proof, &state);
    let mut missing = state.clone();
    missing["ledger"].as_array_mut().unwrap().remove(0);
    check(&base, &request, &proof, &missing);
    for path in [
        ["ledger", "root_fingerprint_sha256"],
        ["ledger", "binding_revision"],
    ] {
        let mut crossed = state.clone();
        crossed[path[0]][0][path[1]] = json!("wrong");
        check(&base, &request, &proof, &crossed);
    }
    let mut crossed = state.clone();
    crossed["ledger"][0]["locator"]["attempt_id"] = json!(TASK);
    check(&base, &request, &proof, &crossed);
    let mut overwritten = state.clone();
    overwritten["transcripts"][0]["messages"][0]["content"] = json!("tampered");
    check(&base, &request, &proof, &overwritten);
    let mut fork = state.clone();
    fork["ledger"][0]["transcript_after"]["transcript_sha256"] = json!("b".repeat(64));
    check(&base, &request, &proof, &fork);
    // Even a recorded earlier checkpoint must match the protected prefix.
    bad_request = request.clone();
    bad_proof = proof.clone();
    bad_request["expected_transcript"] = fork["ledger"][0]["transcript_after"].clone();
    bad_proof["journal_transcript"] = bad_request["expected_transcript"].clone();
    check(&base, &bad_request, &bad_proof, &fork);
    let mut rollback = base.clone();
    rollback["transcript"] = state["rounds"][0]["transcript_before"].clone();
    check(&rollback, &request, &proof, &state);
    let mut duplicate = state.clone();
    let row = duplicate["ledger"][0].clone();
    duplicate["ledger"].as_array_mut().unwrap().push(row);
    check(&base, &request, &proof, &duplicate);
}

#[test]
fn denied_and_rejected_tool_feedback_are_durable_append_checkpoints() {
    for outcome in ["denied", "rejected"] {
        let (base, request, proof, mut state) = fixture();
        let mut denied = state["ledger"].as_array_mut().unwrap().remove(0);
        let locator = denied.as_object_mut().unwrap().remove("locator").unwrap();
        for (key, value) in locator.as_object().unwrap() {
            denied[key] = value.clone();
        }
        denied["state"] = json!(outcome);
        state["denied_calls"] = json!([denied]);
        assert!(query_attempt_base_conflict_with_state(&base, &request, &proof, &state).is_none());
        state["denied_calls"][0]["transcript_after"]["transcript_sha256"] = json!("d".repeat(64));
        assert!(query_attempt_base_conflict_with_state(&base, &request, &proof, &state).is_some());
    }
}

#[test]
fn atomic_multi_message_rounds_prove_their_boundaries_but_not_unreported_handles() {
    let (mut base, mut request, mut proof, mut state) = fixture();
    let mut messages = state["transcripts"][0]["messages"]
        .as_array()
        .unwrap()
        .clone();
    messages.insert(1,json!({"schema_version":1,"role":"assistant","round_index":0,"content":"计划说明","tool_calls":[]}));
    let initial = handle(&messages[..1], 1);
    let prepared = handle(&messages[..3], 3);
    let first = handle(&messages[..4], 4);
    let current = handle(&messages, 5);
    base["transcript"] = current.clone();
    state["authorities"][0]["transcript"] = current.clone();
    for key in ["generation", "transcript_sha256", "transcript_bytes"] {
        state["transcripts"][0][key] = current[key].clone();
    }
    state["transcripts"][0]["messages"] = json!(messages);
    state["rounds"][0]["transcript_before"] = initial.clone();
    state["rounds"][0]["transcript_after"] = prepared.clone();
    state["ledger"][0]["transcript_before"] = prepared.clone();
    state["ledger"][0]["transcript_after"] = first;
    state["ledger"][1]["transcript_before"] = prepared.clone();
    state["ledger"][1]["transcript_after"] = current;
    for known in [initial, prepared] {
        request["expected_transcript"] = known.clone();
        proof["journal_transcript"] = known;
        assert!(query_attempt_base_conflict_with_state(&base, &request, &proof, &state).is_none());
    }
    let unpublished = handle(&messages[..2], 2);
    request["expected_transcript"] = unpublished.clone();
    proof["journal_transcript"] = unpublished;
    assert!(
        query_attempt_base_conflict_with_state(&base, &request, &proof, &state).is_some(),
        "An internal step of one atomic completion was never a published UI handle"
    );
}
