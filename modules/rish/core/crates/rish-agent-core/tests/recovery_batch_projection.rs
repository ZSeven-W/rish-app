use rish_agent_core::runtime_coordinator::{latest_batch_calls, recover_tool_plan};
use rish_agent_core::tool_execution::committed_session_matches;
use serde_json::{json, Value};

#[test]
fn lost_tool_receipt_retains_bound_approval_and_committed_execution_revision() {
    let batch = json!({"task_id":"task","attempt_id":"attempt","round_id":"round","round_index":0,
        "kind":"write_batch","batch_revision":1,"manifest_sha256":"manifest"});
    let call = json!({"call_index":0,"call_id":"call","name":"write_file","arguments_sha256":"arguments",
        "idempotency_key":"key","approval_state":"pending","approval_reference":null,"receipt":null});
    let approval = json!({"status":"bound","task_id":"task","attempt_id":"attempt","round_id":"round",
        "call_index":0,"call_id":"call","decision":"allow_once","approval_reference":"human-approval"});
    let receipt = json!({"outcome":"ok","approval_reference":"human-approval"});
    // This is the actual native operation-results shape, not a second nested
    // result object inside the bind payload.
    let wrapper = |kind: &str, payload: Value| json!({"result":{"schema_version":2,"result_kind":kind,"result":payload}});
    let state = json!({"batches":[batch],"operations":[],"operation_results":[
        wrapper("prepare_agent_tool_batch", json!({"receipt":{"task_id":"task","attempt_id":"attempt",
            "round_id":"round","batch_revision":1,"calls":[call]}})),
        wrapper("bind_agent_approval", approval)],
      "ledger":[{"locator":{"task_id":"task","attempt_id":"attempt","round_id":"round","round_index":0,
            "call_index":0,"call_id":"call","idempotency_key":"key"},"name":"write_file",
            "arguments_sha256":"arguments","row_revision":4,"state":"settled","receipt":receipt}]});
    let projected = latest_batch_calls(&state, &batch);
    assert_eq!(projected[0]["approval_reference"], "human-approval");
    assert_eq!(projected[0]["approval_state"], "bound");
    assert_eq!(projected[0]["native_row_revision"], 4);
    let request = json!({"target":state["ledger"][0]["locator"],"controller_cas":{"conversation_id":"conversation"},
      "committed_checkpoint":{"journal_revision":7},"expected_execution_revision":1,
      "expected_transcript":{"generation":1},"root":{"workspace_id":"workspace"}});
    let plan = recover_tool_plan(
        &state,
        &request,
        &json!({"authority_revision":5}),
        "recovery-child",
    )
    .unwrap();
    let execution = &plan["tool_request"];
    assert_eq!(
        execution["expected_execution_revision"], 1,
        "Preserve the committed UI intent until its CAS advances"
    );
    assert_eq!(execution["approval_reference"], "human-approval");
    let conversation = json!({"attempts":[{"attempt_id":"attempt","journal_revision":7,"agent":{
      "phase":"execution_intent","root":request["root"],"transcript":request["expected_transcript"],
      "round_lineage":{"round_id":"round","round_index":0},"batch":[{"call_index":0,"call_id":"call",
        "name":"write_file","arguments_sha256":"arguments","idempotency_key":"key",
        "native_row_revision":1,"approval_reference":"human-approval"}]}}]});
    assert!(committed_session_matches(
        execution,
        Some(&conversation),
        false
    ));
    let mut forged = execution.clone();
    forged["approval_reference"] = Value::Null;
    assert!(!committed_session_matches(
        &forged,
        Some(&conversation),
        false
    ));
    forged = execution.clone();
    forged["expected_execution_revision"] = json!(4);
    assert!(!committed_session_matches(
        &forged,
        Some(&conversation),
        false
    ));
    let mut other = state.clone();
    other["operation_results"][1]["result"]["result"]["round_id"] = json!("other-round");
    assert!(latest_batch_calls(&other, &batch)[0]["approval_reference"].is_null());
}
