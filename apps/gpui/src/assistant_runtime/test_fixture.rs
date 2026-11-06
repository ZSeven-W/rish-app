//! Validated controller fixtures: drive native replies and session CAS rather
//! than assigning a receipt or pending flag directly in the UI test.
use rish_shell_core::{RuntimeCommand, ShellState, TurnIds};
use serde_json::{Value, json};
pub(crate) const NOW: &str = "2026-10-16T00:00:00.000Z";
pub(crate) const CHAT: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
pub(crate) fn loaded() -> ShellState {
    let mut state = ShellState::with_test_models();
    state
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    let command = state
        .create_conversation(CHAT, NOW, "deepseek-v4-flash")
        .unwrap();
    persist(&mut state, command);
    state
}
pub(crate) fn persist(state: &mut ShellState, command: RuntimeCommand) -> Option<RuntimeCommand> {
    assert_eq!(command.method, "casPersistSession");
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    let generation = command.args[0]["expected"]["snapshot"]["generation"]
        .as_u64()
        .unwrap_or(0)
        + 1;
    state.accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{"schema_version":1,"generation":generation,"session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()}})).unwrap()
}
pub(crate) fn provider_round() -> (ShellState, RuntimeCommand) {
    let mut state = loaded();
    let command = state
        .prepare_agent_send("请检查文件", &TurnIds::new(), NOW)
        .unwrap();
    let prepare = persist(&mut state, command).unwrap();
    let checkpoint = state
        .accept_agent_result(&prepare, prepared(&prepare.args[0]), NOW)
        .unwrap()
        .unwrap();
    let begin = persist(&mut state, checkpoint).unwrap();
    let round = persist(&mut state, begin).unwrap();
    (state, round)
}
pub(crate) fn question() -> ShellState {
    let (mut state, round) = provider_round();
    let mut value = final_result(&round.args[0]);
    value["outcome"]["kind"] = json!("tool_batch");
    value["outcome"]["finish_reason"] = json!("tool_calls");
    value["outcome"]["completion_receipt"]["finish_reason"] = json!("tool_calls");
    value["outcome"]["calls"] = json!([{"call_id":"call-1","name":"ask_user"}]);
    let checkpoint = state
        .accept_agent_result(&round, value, NOW)
        .unwrap()
        .unwrap();
    let batch = persist(&mut state, checkpoint).unwrap();
    let mut value = batch_result(&batch.args[0], "ask_user");
    value["receipt"]["calls"][0]["approval_preview"]["question"]["input_mode"] = json!("free_text");
    value["receipt"]["calls"][0]["approval_preview"]["question"]["options"] = json!([]);
    let checkpoint = state
        .accept_agent_result(&batch, value, NOW)
        .unwrap()
        .unwrap();
    assert!(persist(&mut state, checkpoint).is_none());
    assert_eq!(
        state.agent_view().unwrap().question.unwrap().input_mode,
        "free_text"
    );
    state
}
pub(crate) fn prepared(q: &Value) -> Value {
    json!({"schema_version":2,"status":"prepared","operation_id":q["operation_id"],"observed_checkpoint":q["committed_checkpoint"],"attempt":{"schema_version":2,"task_id":q["task_id"],"conversation_id":q["conversation_id"],"attempt_id":q["attempt_id"],"phase":"ready_for_round","controller_generation":0,"journal_revision":0,"authority_revision":1,"root":{"schema_version":1,"kind":"workspace","workspace_id":q["workspace_id"],"workspace_binding_revision":q["workspace_binding_revision"],"project_id":null,"root_fingerprint_sha256":"a".repeat(64),"capabilities":["file_read","file_write"]},"policy":{"schema_version":1,"policy_version":"agent-v1","max_single_write_bytes":32768,"max_batch_write_bytes":524288,"max_attempt_write_bytes":4194304},"registry":{"schema_version":2,"registry_version":4,"toolset_sha256":"b".repeat(64),"tools":[]},"transcript":{"schema_version":1,"transcript_ref":uuid::Uuid::new_v4().to_string(),"generation":0,"transcript_sha256":"c".repeat(64),"transcript_bytes":2},"round_index":0,"round_id":null,"round_revision":null,"round_status":null,"batch_kind":null,"batch_revision":null,"manifest_sha256":null,"call_index":null,"batch":[],"frozen_grant_ids":[],"reserved_write_bytes":0,"cancel_source_event_id":null,"cleanup_id":null}})
}

pub(crate) fn final_result(q: &Value) -> Value {
    let mut transcript = q["transcript"].clone();
    transcript["generation"] = json!(q["transcript"]["generation"].as_u64().unwrap() + 1);
    transcript["transcript_sha256"] = json!("d".repeat(64));
    transcript["transcript_bytes"] = json!(100);
    json!({"schema_version":2,"status":"completed","operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"launch_attempt":1,"result_round_revision":2,"transcript":transcript,"outcome":{"schema_version":3,"kind":"final","finish_reason":"stop","transcript":transcript,"text":"检查完成","reasoning":"","completion_receipt":{"schema_version":2,"transport_schema_version":2,"turn_id":q["task_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"provider_request_id":uuid::Uuid::new_v4().to_string(),"provider_response_id":"response-1","harness_id":"dsh","requested_model":q["model"],"model":q["model"],"thinking_mode":q["thinking_mode"],"finish_reason":"stop","latency_ms":1,"visible_history_sha256":rish_agent_core::canonical::sha256_hex(&rish_agent_core::canonical::canonical_json(&json!([{"role":"user","content":"请检查文件","attachments":[]}])).unwrap()),"model_input_sha256":"f".repeat(64),"request_body_sha256":"e".repeat(64),"project_context_receipt":null}}})
}

pub(crate) fn batch_result(q: &Value, name: &str) -> Value {
    let gated = name == "write_file";
    let args = "d".repeat(64);
    let idem = "e".repeat(64);
    let manifest = "f".repeat(64);
    let token = if gated {
        json!({"schema_version":2,"token":uuid::Uuid::new_v4().to_string(),"controller_cas":q["controller_cas"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"batch_call_ids":["call-1"],"batch_arguments_sha256":[args],"batch_revision":q["expected_batch_revision"].as_u64().unwrap_or(0)+1,"manifest_sha256":manifest,"call_index":0,"call_id":"call-1","name":name,"arguments_sha256":args,"idempotency_key":idem,"root_fingerprint_sha256":q["root"]["root_fingerprint_sha256"],"binding_revision":q["root"]["workspace_binding_revision"],"policy_version":"agent-v1","registry_version":q["registry_version"],"access":"conversation_confirm","allowed_decisions":["denied","allow_once","allow_conversation","cancelled"]})
    } else {
        Value::Null
    };
    json!({"schema_version":2,"status":"prepared","operation_id":q["operation_id"],"observed_checkpoint":q["committed_checkpoint"],"receipt":{"schema_version":2,"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"batch_kind":if gated{"write_batch"}else{"read_only_batch"},"batch_revision":q["expected_batch_revision"].as_u64().unwrap_or(0)+1,"manifest_sha256":if gated{json!(manifest)}else{Value::Null},"transcript":q["transcript"],"calls":[{"schema_version":2,"call_index":0,"call_id":"call-1","name":name,"arguments_sha256":args,"idempotency_key":idem,"safe_summary_key":format!("agent.{name}"),"approval_preview":if name=="ask_user"{json!({"schema_version":1,"kind":"ask_user","question":{"question":"选择方案？","input_mode":"options","options":[{"id":"a","label":"方案 A"},{"id":"b","label":"方案 B"}]}})}else{Value::Null},"access":if gated{"conversation_confirm"}else{"auto"},"approval_state":if gated{"pending"}else{"not_required"},"approval_token":token,"approval_reference":null,"execution_state":"intent","execution_revision":1,"native_row_revision":1,"receipt":null}],"batch_new_write_bytes":if gated{12}else{0},"reserved_write_bytes":if gated{12}else{0},"effect_gate":if gated{"closed"}else{"not_applicable"}}})
}
