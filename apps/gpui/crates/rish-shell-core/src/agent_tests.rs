use super::*;
use serde_json::{json, Value};
const NOW: &str = "2026-10-16T00:00:00.000Z";
fn chat() -> ShellState {
    let mut s = ShellState::with_test_models();
    s.load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    s.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    s.create_conversation(&model::id(), NOW, "deepseek-v4-flash")
        .unwrap();
    persist(&mut s);
    s
}
fn persist(s: &mut ShellState) -> Option<RuntimeCommand> {
    let p = s.pending.as_ref().unwrap();
    s.accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{"schema_version":1,"generation":s.authority["snapshot"]["generation"].as_u64().unwrap_or(0)+1,"session_sha256":p.digest}})).unwrap()
}
fn prepared(q: &Value) -> Value {
    json!({"schema_version":2,"status":"prepared","operation_id":q["operation_id"],"observed_checkpoint":q["committed_checkpoint"],"attempt":{"schema_version":2,"task_id":q["task_id"],"conversation_id":q["conversation_id"],"attempt_id":q["attempt_id"],"phase":"ready_for_round","controller_generation":0,"journal_revision":0,"authority_revision":1,"root":{"schema_version":1,"kind":"workspace","workspace_id":q["workspace_id"],"workspace_binding_revision":q["workspace_binding_revision"],"project_id":null,"root_fingerprint_sha256":"a".repeat(64),"capabilities":["file_read","file_write"]},"policy":{"schema_version":1,"policy_version":"agent-v1","max_single_write_bytes":32768,"max_batch_write_bytes":524288,"max_attempt_write_bytes":4194304},"registry":{"schema_version":2,"registry_version":4,"toolset_sha256":"b".repeat(64),"tools":[]},"transcript":{"schema_version":1,"transcript_ref":model::id(),"generation":0,"transcript_sha256":"c".repeat(64),"transcript_bytes":2},"round_index":0,"round_id":null,"round_revision":null,"round_status":null,"batch_kind":null,"batch_revision":null,"manifest_sha256":null,"call_index":null,"batch":[],"frozen_grant_ids":[],"reserved_write_bytes":0,"cancel_source_event_id":null,"cleanup_id":null}})
}
fn start(s: &mut ShellState) -> RuntimeCommand {
    s.prepare_agent_send("请检查文件", &TurnIds::new(), NOW)
        .unwrap();
    let prepare = persist(s).unwrap();
    assert_eq!(prepare.method, "prepare_agent_attempt");
    let q = &prepare.args[0];
    assert!(rish_agent_core::prepared_attempt::session_attempt_matches(
        q,
        s.selected()
    ));
    s.accept_agent_result(&prepare, prepared(q), NOW).unwrap();
    let begin = persist(s).unwrap();
    assert_eq!(begin.method, "casPersistSession");
    let round = persist(s).unwrap();
    assert_eq!(round.method, "complete_agent_round_v2");
    round
}
fn final_result(q: &Value) -> Value {
    let mut transcript = q["transcript"].clone();
    transcript["generation"] = json!(q["transcript"]["generation"].as_u64().unwrap() + 1);
    transcript["transcript_sha256"] = json!("d".repeat(64));
    transcript["transcript_bytes"] = json!(100);
    json!({"schema_version":2,"status":"completed","operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"launch_attempt":1,"result_round_revision":2,"transcript":transcript,"outcome":{"schema_version":3,"kind":"final","finish_reason":"stop","transcript":transcript,"text":"检查完成","reasoning":"","completion_receipt":{"schema_version":2,"transport_schema_version":2,"turn_id":q["task_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"provider_request_id":model::id(),"provider_response_id":"response-1","harness_id":"dsh","requested_model":q["model"],"model":q["model"],"thinking_mode":q["thinking_mode"],"finish_reason":"stop","latency_ms":1,"visible_history_sha256":rish_agent_core::canonical::sha256_hex(&rish_agent_core::canonical::canonical_json(&json!([{"role":"user","content":"请检查文件","attachments":[]}])).unwrap()),"model_input_sha256":"f".repeat(64),"request_body_sha256":"e".repeat(64),"project_context_receipt":null}}})
}
#[test]
fn durable_agent_finalizes_only_after_saved_answer() {
    let mut s = chat();
    let round = start(&mut s);
    let final_value = final_result(&round.args[0]);
    s.accept_agent_result(&round, final_value, NOW).unwrap();
    assert_eq!(s.messages().len(), 1);
    let finalize = persist(&mut s).unwrap();
    assert_eq!(s.messages().len(), 2);
    assert_eq!(finalize.method, "finalize_agent_attempt");
    let q = &finalize.args[0];
    s.accept_agent_result(&finalize,json!({"schema_version":2,"status":"terminal","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"],"transcript":q["transcript"]}),NOW).unwrap();
    let discard = s.agent_run.as_ref().unwrap().in_flight.clone().unwrap();
    let q = &discard.args[0];
    s.accept_agent_result(&discard,json!({"schema_version":2,"status":"discarded","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]}),NOW).unwrap();
    persist(&mut s);
    assert!(!s.is_busy());
    assert_eq!(s.messages()[1].text, "检查完成");
    assert!(model::rows(s.raw_session(), "agent_transcript_cleanup_outbox").is_empty());
}
#[test]
fn agent_unknown_user_checkpoint_never_launches_provider() {
    let mut s = chat();
    s.prepare_agent_send("hello", &TurnIds::new(), NOW).unwrap();
    assert!(s
        .accept_persist(json!({"schema_version":1,"status":"unknown"}))
        .is_err());
    assert!(s.agent_run.as_ref().unwrap().in_flight.is_none());
    assert!(s
        .prepare_agent_send("duplicate", &TurnIds::new(), NOW)
        .is_err());
    let command = persist(&mut s).unwrap();
    assert_eq!(command.method, "prepare_agent_attempt");
}
#[test]
fn stale_agent_callback_cannot_settle_new_operation() {
    let mut s = chat();
    let round = start(&mut s);
    let mut wrong = round.clone();
    wrong.args[0]["operation_id"] = json!(model::id());
    assert!(s
        .accept_agent_result(&wrong, final_result(&wrong.args[0]), NOW)
        .is_err());
    assert!(s.owns_agent_command(&round));
    assert_eq!(s.messages().len(), 1);
}
#[test]
fn correlated_but_wrong_model_never_publishes_answer() {
    let mut s = chat();
    let round = start(&mut s);
    let mut value = final_result(&round.args[0]);
    value["outcome"]["completion_receipt"]["model"] = json!("deepseek-v4-pro");
    assert!(s.accept_agent_result(&round, value, NOW).is_err());
    assert_eq!(s.messages().len(), 1);
    assert!(s.agent_view().unwrap().recoverable);
}
fn tool_round(s: &mut ShellState, round: &RuntimeCommand, name: &str) -> RuntimeCommand {
    let mut v = final_result(&round.args[0]);
    v["outcome"]["kind"] = json!("tool_batch");
    v["outcome"]["finish_reason"] = json!("tool_calls");
    v["outcome"]["completion_receipt"]["finish_reason"] = json!("tool_calls");
    v["outcome"]["calls"] = json!([{"call_id":"call-1","name":name}]);
    s.accept_agent_result(round, v, NOW).unwrap();
    let batch = persist(s).unwrap();
    assert_eq!(batch.method, "prepare_agent_tool_batch");
    batch
}
fn batch_result(q: &Value, name: &str) -> Value {
    let gated = name == "write_file";
    let args = "d".repeat(64);
    let idem = "e".repeat(64);
    let manifest = "f".repeat(64);
    let token = if gated {
        json!({"schema_version":2,"token":model::id(),"controller_cas":q["controller_cas"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"batch_call_ids":["call-1"],"batch_arguments_sha256":[args],"batch_revision":q["expected_batch_revision"].as_u64().unwrap_or(0)+1,"manifest_sha256":manifest,"call_index":0,"call_id":"call-1","name":name,"arguments_sha256":args,"idempotency_key":idem,"root_fingerprint_sha256":q["root"]["root_fingerprint_sha256"],"binding_revision":q["root"]["workspace_binding_revision"],"policy_version":"agent-v1","registry_version":4,"access":"conversation_confirm","allowed_decisions":["denied","allow_once","allow_conversation","cancelled"]})
    } else {
        Value::Null
    };
    json!({"schema_version":2,"status":"prepared","operation_id":q["operation_id"],"observed_checkpoint":q["committed_checkpoint"],"receipt":{"schema_version":2,"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"batch_kind":if gated{"write_batch"}else{"read_only_batch"},"batch_revision":q["expected_batch_revision"].as_u64().unwrap_or(0)+1,"manifest_sha256":if gated{json!(manifest)}else{Value::Null},"transcript":q["transcript"],"calls":[{"schema_version":2,"call_index":0,"call_id":"call-1","name":name,"arguments_sha256":args,"idempotency_key":idem,"safe_summary_key":format!("agent.{name}"),"approval_preview":if name=="ask_user"{json!({"schema_version":1,"kind":"ask_user","question":{"question":"选择方案？","input_mode":"options","options":[{"id":"a","label":"方案 A"},{"id":"b","label":"方案 B"}]}})}else{Value::Null},"access":if gated{"conversation_confirm"}else{"auto"},"approval_state":if gated{"pending"}else{"not_required"},"approval_token":token,"approval_reference":null,"execution_state":"intent","execution_revision":1,"native_row_revision":1,"receipt":null}],"batch_new_write_bytes":if gated{12}else{0},"reserved_write_bytes":if gated{12}else{0},"effect_gate":if gated{"closed"}else{"not_applicable"}}})
}
fn executed(q: &Value, outcome: &str) -> Value {
    let mut t = q["transcript"].clone();
    t["generation"] = json!(t["generation"].as_u64().unwrap() + 1);
    t["transcript_sha256"] = json!("1".repeat(64));
    t["transcript_bytes"] = json!(200);
    json!({"schema_version":2,"status":if outcome=="ok"{"completed"}else{outcome},"operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"call_index":q["call_index"],"call_id":q["call_id"],"name":q["name"],"idempotency_key":q["idempotency_key"],"result_execution_revision":2,"transcript":t,"effect_may_have_occurred":true,"receipt":{"schema_version":1,"call_id":q["call_id"],"name":q["name"],"arguments_sha256":q["arguments_sha256"],"result_sha256":"2".repeat(64),"result_bytes":20,"truncated":false,"duration_ms":1,"outcome":outcome,"failure_code":null,"approval_reference":q["approval_reference"]}})
}
#[test]
fn read_tool_executes_only_after_durable_intent_then_advances_once() {
    let mut s = chat();
    let round = start(&mut s);
    let batch = tool_round(&mut s, &round, "read_file");
    s.accept_agent_result(&batch, batch_result(&batch.args[0], "read_file"), NOW)
        .unwrap();
    let intent = persist(&mut s).unwrap();
    assert_eq!(intent.method, "casPersistSession");
    assert!(s.agent_run.as_ref().unwrap().in_flight.is_none());
    let execute = persist(&mut s).unwrap();
    assert_eq!(execute.method, "execute_agent_tool");
    assert!(rish_agent_core::tool_execution::committed_session_matches(
        &execute.args[0],
        s.selected(),
        true
    ));
    let receipt = executed(&execute.args[0], "ok");
    s.accept_agent_result(&execute, receipt.clone(), NOW)
        .unwrap();
    assert!(s.accept_agent_result(&execute, receipt, NOW).is_err());
    let begin = persist(&mut s).unwrap();
    assert_eq!(begin.method, "casPersistSession");
    let next = persist(&mut s).unwrap();
    assert_eq!(next.method, "complete_agent_round_v2");
    assert_eq!(next.args[0]["round_index"], 1);
    assert_ne!(next.args[0]["round_id"], round.args[0]["round_id"]);
}
#[test]
fn write_approval_requires_persisted_decision_and_native_binding() {
    let mut s = chat();
    let round = start(&mut s);
    let batch = tool_round(&mut s, &round, "write_file");
    s.accept_agent_result(&batch, batch_result(&batch.args[0], "write_file"), NOW)
        .unwrap();
    assert!(persist(&mut s).is_none());
    let view = s.agent_view().unwrap();
    assert_eq!(view.approval.unwrap().name, "write_file");
    assert!(s.recover_agent(NOW).unwrap().is_none());
    assert!(s
        .decide_agent_approval("allow_conversation", None, NOW)
        .is_err());
    s.decide_agent_approval("allow_once", None, NOW).unwrap();
    assert!(s.agent_run.as_ref().unwrap().in_flight.is_none());
    let bind = persist(&mut s).unwrap();
    assert_eq!(bind.method, "bind_agent_approval");
    assert_eq!(
        s.agent_attempt().unwrap()["agent"]["batch"][0]["approval_reference"],
        bind.args[0]["operation_id"]
    );
    let q = &bind.args[0];
    let response = json!({"schema_version":2,"status":"bound","operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"call_index":q["call_index"],"call_id":q["call_id"],"decision":"allow_once","approval_reference":q["operation_id"],"grant":null,"result_batch_revision":1,"observed_checkpoint":q["committed_checkpoint"],"receipt":null,"transcript":null});
    s.accept_agent_result(&bind, response, NOW).unwrap();
    let intent = persist(&mut s).unwrap();
    assert_eq!(intent.method, "casPersistSession");
    let execute = persist(&mut s).unwrap();
    assert!(rish_agent_core::tool_execution::committed_session_matches(
        &execute.args[0],
        s.selected(),
        true
    ));
    assert_eq!(
        execute.args[0]["approval_reference"],
        bind.args[0]["operation_id"]
    );
}
#[test]
fn cancellation_proof_is_saved_before_native_and_old_round_cannot_win() {
    let mut s = chat();
    let round = start(&mut s);
    let command = s.cancel_agent(NOW).unwrap().unwrap();
    assert_eq!(command.method, "casPersistSession");
    assert!(s
        .accept_agent_result(&round, final_result(&round.args[0]), NOW)
        .is_err());
    let cancel = persist(&mut s).unwrap();
    assert_eq!(cancel.method, "cancel_agent_attempt");
    assert!(rish_agent_core::runtime_coordinator::cancel_source_proof(
        s.raw_session(),
        &cancel.args[0]
    ));
}
#[test]
fn unknown_native_operation_requires_reconcile_not_automatic_retry() {
    let mut s = chat();
    let round = start(&mut s);
    s.fail_agent_command(&round, "transport disconnected", NOW)
        .unwrap();
    let query = s.recover_agent(NOW).unwrap().unwrap();
    assert_eq!(query.method, "query_agent_attempt");
    assert_ne!(query.method, "complete_agent_round_v2");
    assert!(s.prepare_agent_send("retry", &TurnIds::new(), NOW).is_err());
}
#[test]
fn structured_question_answers_validate_and_wait_for_durable_execution() {
    let mut s = chat();
    let round = start(&mut s);
    let batch = tool_round(&mut s, &round, "ask_user");
    s.accept_agent_result(&batch, batch_result(&batch.args[0], "ask_user"), NOW)
        .unwrap();
    assert!(persist(&mut s).is_none());
    let question = s.agent_view().unwrap().question.unwrap();
    assert_eq!(question.question, "选择方案？");
    assert!(s.answer_agent_question("stale", Some("a"), NOW).is_err());
    assert!(s
        .answer_agent_question(&question.id, Some("not-a-choice"), NOW)
        .is_err());
    s.answer_agent_question(&question.id, Some("b"), NOW)
        .unwrap();
    let execute = persist(&mut s).unwrap();
    assert_eq!(
        execute.args[0]["user_response"],
        json!({"status":"answered","answer":"b"})
    );
    assert!(rish_agent_core::tool_execution::committed_session_matches(
        &execute.args[0],
        s.selected(),
        true
    ));
}
#[test]
fn stream_is_ephemeral_correlated_and_fenced_after_end() {
    let mut s = chat();
    let round = start(&mut s);
    let q = &round.args[0];
    let mut e = json!({"schema_version":1,"kind":"delta","task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"operation_id":q["operation_id"],"harness_id":q["harness_id"],"provider_request_id":"preview-provider","seq":1,"text":"你好"});
    let before = s.raw_session().clone();
    assert!(s.accept_agent_preview(e.clone()));
    assert!(!s.accept_agent_preview(e.clone()));
    e["seq"] = json!(3);
    e["text"] = json!("世界");
    assert!(s.accept_agent_preview(e.clone()));
    assert!(s.agent_view().unwrap().preview_incomplete);
    e["seq"] = json!(4);
    e["provider_request_id"] = json!("other-provider");
    assert!(!s.accept_agent_preview(e.clone()));
    e["provider_request_id"] = json!("preview-provider");
    e["kind"] = json!("end");
    e["status"] = json!("validated");
    e["truncated"] = json!(false);
    assert!(s.accept_agent_preview(e.clone()));
    e["kind"] = json!("delta");
    e["seq"] = json!(5);
    assert!(!s.accept_agent_preview(e));
    assert_eq!(s.raw_session(), &before);
    assert_eq!(s.agent_view().unwrap().preview_text, "你好世界");
}
#[test]
fn denied_write_is_feedback_without_any_execution_command() {
    let mut s = chat();
    let round = start(&mut s);
    let batch = tool_round(&mut s, &round, "write_file");
    s.accept_agent_result(&batch, batch_result(&batch.args[0], "write_file"), NOW)
        .unwrap();
    persist(&mut s);
    s.decide_agent_approval("denied", Some("请先解释原因"), NOW)
        .unwrap();
    let bind = persist(&mut s).unwrap();
    let q = &bind.args[0];
    let call = s.agent_attempt().unwrap()["agent"]["batch"][0].clone();
    let mut t = s.agent_attempt().unwrap()["agent"]["transcript"].clone();
    t["generation"] = json!(2);
    t["transcript_sha256"] = json!("9".repeat(64));
    t["transcript_bytes"] = json!(300);
    let receipt = json!({"schema_version":1,"call_id":call["call_id"],"name":call["name"],"arguments_sha256":call["arguments_sha256"],"result_sha256":"8".repeat(64),"result_bytes":30,"truncated":false,"duration_ms":0,"outcome":"denied","failure_code":"E_AGENT_DENIED_BY_USER","approval_reference":null});
    let result = json!({"schema_version":2,"status":"bound","operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"call_index":0,"call_id":"call-1","decision":"denied","approval_reference":null,"grant":null,"result_batch_revision":1,"observed_checkpoint":q["committed_checkpoint"],"receipt":receipt,"transcript":t});
    s.accept_agent_result(&bind, result, NOW).unwrap();
    let begin = persist(&mut s).unwrap();
    assert_eq!(begin.method, "casPersistSession");
    let next = persist(&mut s).unwrap();
    assert_eq!(next.method, "complete_agent_round_v2");
    assert_eq!(next.args[0]["round_index"], 1);
    assert_eq!(s.agent_view().unwrap().tools[0].status, "denied");
}
#[test]
fn malformed_correlated_json_retains_recovery_and_never_publishes() {
    let mut s = chat();
    let round = start(&mut s);
    assert!(s
        .accept_agent_result(&round, json!("not-json"), NOW)
        .is_err());
    assert!(s.agent_view().unwrap().recoverable);
    assert!(!s.owns_agent_command(&round));
    assert_eq!(s.messages().len(), 1);
    assert_eq!(
        s.recover_agent(NOW).unwrap().unwrap().method,
        "query_agent_attempt"
    );
}
fn finish(s: &mut ShellState, round: &RuntimeCommand) {
    let mut v = final_result(&round.args[0]);
    v["outcome"]["completion_receipt"]["visible_history_sha256"] =
        json!(s.agent_transport_digest().unwrap());
    s.accept_agent_result(round, v, NOW).unwrap();
    let finalize = persist(s).unwrap();
    let q = &finalize.args[0];
    let discard=s.accept_agent_result(&finalize,json!({"schema_version":2,"status":"terminal","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"],"transcript":q["transcript"]}),NOW).unwrap().unwrap();
    let q = &discard.args[0];
    s.accept_agent_result(&discard,json!({"schema_version":2,"status":"discarded","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]}),NOW).unwrap();
    persist(s);
}
#[test]
fn agent_history_after_96_messages_freezes_the_exact_contiguous_suffix() {
    let mut s = chat();
    for _ in 0..49 {
        let round = start(&mut s);
        finish(&mut s, &round);
    }
    assert_eq!(s.messages().len(), 98);
    s.prepare_agent_send("继续", &TurnIds::new(), NOW).unwrap();
    let prepare = persist(&mut s).unwrap();
    assert_eq!(prepare.args[0]["visible_message_count"], 96);
    let a = s.agent_attempt().unwrap();
    let c = s.selected().unwrap();
    assert_eq!(a["visible_message_ids"][0], c["messages"][3]["id"]);
    let mut forged = s.raw_session().clone();
    let a = forged["conversations"][0]["attempts"]
        .as_array_mut()
        .unwrap()
        .last_mut()
        .unwrap();
    a["visible_message_ids"][0] = json!("00000000-0000-4000-8000-000000000000");
    assert!(
        session_schema::validate_candidate(forged.to_string().as_bytes(), &s.environment).is_err()
    );
}
#[test]
fn terminal_cleanup_resumes_after_controller_restart() {
    let mut s = chat();
    let round = start(&mut s);
    s.accept_agent_result(&round, final_result(&round.args[0]), NOW)
        .unwrap();
    let _finalize = persist(&mut s).unwrap();
    let raw = s.session.to_string();
    let mut restarted = ShellState::with_test_models();
    restarted.load_snapshot(json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":s.authority["snapshot"]})).unwrap();
    let query = restarted.recover_agent(NOW).unwrap().unwrap();
    assert_eq!(query.method, "query_agent_cleanup");
    let finalize = restarted
        .accept_agent_result(
            &query,
            json!({"schema_version":2,"cleanup_id":query.args[0]["cleanup_id"],"status":"unknown"}),
            NOW,
        )
        .unwrap()
        .unwrap();
    assert_eq!(finalize.method, "finalize_agent_attempt");
    assert_eq!(restarted.messages().len(), 2);
    assert_eq!(
        finalize.args[0]["cleanup_id"],
        s.agent_run.as_ref().unwrap().cleanup["cleanup_id"]
    );
}
fn presentation(command: &RuntimeCommand, round: &RuntimeCommand, kind: &str) -> Value {
    json!({"schema_version":1,"conversation_id":command.args[0]["conversation_id"],"attempt_id":command.args[0]["attempt_id"],"rounds":[{"round_id":round.args[0]["round_id"],"round_index":round.args[0]["round_index"],"kind":kind,"text":"检查完成","reasoning":"思考","assistant_text_sha256":rish_agent_core::canonical::sha256_hex("检查完成".as_bytes()),"reasoning_text_sha256":rish_agent_core::canonical::sha256_hex("思考".as_bytes())}]})
}
#[test]
fn presentations_verify_hash_without_touching_authority_and_hide_duplicate_final() {
    let mut s = chat();
    let round = start(&mut s);
    finish(&mut s, &round);
    let command = s.read_agent_presentations_command().unwrap();
    let v = presentation(&command, &round, "final");
    let before = s.raw_session().clone();
    let mut corrupt = v.clone();
    corrupt["rounds"][0]["text"] = json!("伪造");
    assert!(s.accept_agent_presentations(&command, corrupt).is_err());
    assert!(s.agent_presentations().is_empty());
    s.accept_agent_presentations(&command, v).unwrap();
    assert!(
        s.agent_presentations().is_empty(),
        "persisted final assistant already displays this answer"
    );
    assert_eq!(s.raw_session(), &before);
}
#[test]
fn intermediate_presentation_is_anchored_to_its_user_message() {
    let mut s = chat();
    let round = start(&mut s);
    let _batch = tool_round(&mut s, &round, "read_file");
    let command = s.read_agent_presentations_command().unwrap();
    s.accept_agent_presentations(&command, presentation(&command, &round, "tool_batch"))
        .unwrap();
    let rows = s.agent_presentations();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].user_message_id, s.messages()[0].id);
    assert_eq!(rows[0].attempt_id, round.args[0]["attempt_id"]);
    let mut swapped = presentation(&command, &round, "tool_batch");
    swapped["attempt_id"] = json!(model::id());
    assert!(s.accept_agent_presentations(&command, swapped).is_err());
    assert_eq!(s.agent_presentations(), rows);
}
#[test]
fn question_draft_survives_intent_and_native_failure_until_receipt_is_durable() {
    for fail in [false, true] {
        let mut s = chat();
        let round = start(&mut s);
        let batch = tool_round(&mut s, &round, "ask_user");
        s.accept_agent_result(&batch, batch_result(&batch.args[0], "ask_user"), NOW)
            .unwrap();
        persist(&mut s);
        let question = s.agent_view().unwrap().question.unwrap();
        s.answer_agent_question(&question.id, Some("b"), NOW)
            .unwrap();
        assert!(
            !s.may_clear_sent_draft(),
            "memory-only answer cannot clear the native editor"
        );
        let execute = persist(&mut s).unwrap();
        assert!(
            !s.may_clear_sent_draft(),
            "redacted intent contains no answer bytes"
        );
        if fail {
            s.fail_agent_command(&execute, "lost native reply", NOW)
                .unwrap();
            assert!(!s.may_clear_sent_draft());
        } else {
            s.accept_agent_result(&execute, executed(&execute.args[0], "ok"), NOW)
                .unwrap();
            assert!(
                !s.may_clear_sent_draft(),
                "receipt candidate is not yet committed"
            );
            persist(&mut s);
            assert!(s.may_clear_sent_draft());
        }
    }
}
#[test]
fn provider_call_ids_can_repeat_in_distinct_rounds_without_merging_activity() {
    let mut s = chat();
    let round = start(&mut s);
    let batch = tool_round(&mut s, &round, "read_file");
    s.accept_agent_result(&batch, batch_result(&batch.args[0], "read_file"), NOW)
        .unwrap();
    persist(&mut s);
    let execute = persist(&mut s).unwrap();
    s.accept_agent_result(&execute, executed(&execute.args[0], "ok"), NOW)
        .unwrap();
    persist(&mut s);
    let second_round = persist(&mut s).unwrap();
    let batch = tool_round(&mut s, &second_round, "read_file");
    s.accept_agent_result(&batch, batch_result(&batch.args[0], "read_file"), NOW)
        .unwrap();
    persist(&mut s);
    let _execute_again = persist(&mut s).unwrap();
    let tools = s.agent_view().unwrap().tools;
    assert_eq!(tools.len(), 2);
    assert_eq!(tools[0].call_id, tools[1].call_id);
    assert_eq!(tools[0].round_index, 0);
    assert_eq!(tools[1].round_index, 1);
    assert_eq!(tools[0].status, "ok");
    assert_eq!(tools[1].status, "execution_intent");
}
#[test]
fn cancelling_unsubmitted_question_answer_keeps_its_draft() {
    let mut s = chat();
    let round = start(&mut s);
    let batch = tool_round(&mut s, &round, "ask_user");
    s.accept_agent_result(&batch, batch_result(&batch.args[0], "ask_user"), NOW)
        .unwrap();
    persist(&mut s);
    let question = s.agent_view().unwrap().question.unwrap();
    s.answer_agent_question(&question.id, Some("a"), NOW)
        .unwrap();
    assert!(s.cancel_agent(NOW).unwrap().is_none());
    let cancel_checkpoint = persist(&mut s).unwrap();
    assert_eq!(cancel_checkpoint.method, "casPersistSession");
    assert!(!s.may_clear_sent_draft());
    assert_eq!(s.agent_view().unwrap().phase, "cancelling");
}
#[test]
fn native_settled_write_recovery_records_receipt_without_executing_again() {
    // Captured from the actual iOS facade after a real successful write whose
    // callback was deliberately dropped. The native projection omits its UI
    // cursor; the controller reconstructs it only from proved settled calls.
    let fixture: Value =
        serde_json::from_str(include_str!("../tests/fixtures/recovered-write.json")).unwrap();
    let raw = fixture["session"].to_string();
    let digest = session_schema::candidate_digest(raw.as_bytes()).unwrap();
    let mut s = ShellState::with_test_models();
    s.load_snapshot(json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":{"schema_version":1,"generation":9,"session_sha256":digest}})).unwrap();
    let query = s
        .recover_agent("2026-10-16T08:00:00.000Z")
        .unwrap()
        .unwrap();
    let recover = s
        .accept_agent_result(
            &query,
            json!({"schema_version":2,"status":"active","attempt":fixture["result"]["attempt"]}),
            "2026-10-16T08:00:00.000Z",
        )
        .unwrap()
        .unwrap();
    assert_eq!(recover.method, "recover_agent_attempt");
    assert_eq!(recover.args[0]["expected_execution_revision"], 1);
    let mut result = fixture["result"].clone();
    result["operation_id"] = recover.args[0]["operation_id"].clone();
    let save = s
        .accept_agent_result(&recover, result, "2026-10-16T08:00:00.000Z")
        .unwrap()
        .unwrap();
    assert_eq!(save.method, "casPersistSession");
    let begin = persist(&mut s).unwrap();
    assert_eq!(begin.method, "casPersistSession");
    let next = persist(&mut s).unwrap();
    assert_eq!(next.method, "complete_agent_round_v2");
    assert_eq!(next.args[0]["round_index"], 1);
    assert!(model::rows(s.raw_session(), "session_events")
        .iter()
        .any(|event| event["kind"] == "tool_result" && event["status"] == "ok"));
}
#[test]
fn startup_keeps_the_committed_agent_user_turn_for_native_preparation() {
    let mut original = chat();
    original
        .prepare_agent_send("继续准备", &TurnIds::new(), NOW)
        .unwrap();
    let prepare = persist(&mut original).unwrap();
    let raw = original.raw_session().to_string();
    let mut restarted = ShellState::with_test_models();
    restarted.load_snapshot(json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":original.authority["snapshot"],"writer_launch_instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","current_launch_instance_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"})).unwrap();
    assert!(
        restarted.recovery_command(NOW).unwrap().is_none(),
        "plain-chat startup recovery must not erase a prepared Agent intent"
    );
    let recovered = restarted.recover_agent(NOW).unwrap().unwrap();
    assert_eq!(recovered.method, "prepare_agent_attempt");
    assert_eq!(
        recovered.args[0]["attempt_id"],
        prepare.args[0]["attempt_id"]
    );
    assert_eq!(restarted.messages().len(), 1);
}
#[test]
fn native_preflight_refusal_stops_cleanly_with_a_persisted_actionable_code() {
    for code in ["E_AGENT_PROVIDER_CREDENTIAL", "E_AGENT_CAPABILITY"] {
        let mut s = chat();
        let round = start(&mut s);
        let q = &round.args[0];
        s.accept_agent_result(&round,json!({"schema_version":2,"status":"failed_retryable","operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"launch_attempt":1,"result_round_revision":2,"transcript":q["transcript"],"failure_code":code}),NOW).unwrap();
        let finalize = persist(&mut s).unwrap();
        assert_eq!(finalize.method, "finalize_agent_attempt");
        assert_eq!(s.agent_view().unwrap().failure_code.as_deref(), Some(code));
        assert_eq!(s.agent_view().unwrap().phase, "failed");
        let q = &finalize.args[0];
        let discard=s.accept_agent_result(&finalize,json!({"schema_version":2,"status":"terminal","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"],"transcript":q["transcript"]}),NOW).unwrap().unwrap();
        let q = &discard.args[0];
        s.accept_agent_result(&discard,json!({"schema_version":2,"status":"discarded","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]}),NOW).unwrap();
        persist(&mut s);
        assert!(!s.is_busy());
        assert!(!s.has_agent_task());
        assert!(!s.agent_view().unwrap().recoverable);
        assert_eq!(s.messages().len(), 1);
        assert_eq!(s.agent_view().unwrap().failure_code.as_deref(), Some(code));
        assert!(s
            .prepare_agent_send("配置完成后再试", &TurnIds::new(), NOW)
            .is_ok());
    }
}

#[path = "agent_recovery_tests.rs"]
mod recovery_tests;

#[path = "agent_cleanup_recovery_tests.rs"]
mod cleanup_recovery_tests;
