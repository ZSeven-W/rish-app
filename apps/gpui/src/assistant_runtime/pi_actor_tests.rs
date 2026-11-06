use super::*;
use crate::assistant_runtime::test_fixture;

impl Harness {
    fn runtime(&self, source: &str) {
        let store = AssistantStore::open(&self.directory).unwrap();
        let saved = store.load().unwrap();
        let mut profile = saved.profile;
        profile.runtime = RuntimeSpec::custom("Contract test", source).unwrap();
        store.set_profile(saved.revision, profile).unwrap();
    }
    fn start_intent(&self) {
        self.command(RunnerCommand::RunNow {
            task_id: self.task_id.clone(),
        });
        wait_for(|| self.handle.snapshot().status == RunnerStatus::WaitingForForeground);
        self.grant();
    }
    fn until_cancel_without_effect(&mut self) -> Request {
        for _ in 0..24 {
            let request = self.next();
            match request.command.method.as_str() {
                "handle" => {
                    request.reply.send(Ok(json!(true))).unwrap();
                }
                "resolve" => {
                    request
                        .reply
                        .send(Ok(json!({"schema_version":1,"workspace":descriptor()})))
                        .unwrap();
                }
                "casPersistSession" => self.persist(request),
                "prepare_agent_attempt" => {
                    let value = prepared(&request.command.args[0]);
                    request.reply.send(Ok(value)).unwrap();
                }
                "cancel_agent_attempt" => return request,
                other => panic!("runtime stop leaked effect or stuck: {other}"),
            }
        }
        panic!("Runtime did not reach native cancellation")
    }
    pub(super) fn tool_batch(&mut self, round: Request, name: &str) {
        let mut value = model_result(self, &round.command.args[0]);
        value["outcome"]["kind"] = json!("tool_batch");
        value["outcome"]["finish_reason"] = json!("tool_calls");
        value["outcome"]["completion_receipt"]["finish_reason"] = json!("tool_calls");
        value["outcome"]["calls"] = json!([{"call_id":"call-1","name":name}]);
        round.reply.send(Ok(value)).unwrap();
        let checkpoint = self.next();
        self.persist(checkpoint);
        let batch = self.next();
        assert_eq!(batch.command.method, "prepare_agent_tool_batch");
        batch
            .reply
            .send(Ok(test_fixture::batch_result(&batch.command.args[0], name)))
            .unwrap();
        let checkpoint = self.next();
        self.persist(checkpoint);
    }
}

pub(super) fn model_result(harness: &Harness, q: &Value) -> Value {
    let mut v = test_fixture::final_result(q);
    v["outcome"]["completion_receipt"]["visible_history_sha256"] =
        json!(harness.visible_history_digest(q));
    v
}
pub(super) fn tool_receipt(q: &Value, outcome: &str) -> Value {
    json!({"schema_version":1,"call_id":q["call_id"],"name":q["name"],"arguments_sha256":q["arguments_sha256"],
        "result_sha256":"2".repeat(64),"result_bytes":20,"truncated":false,"duration_ms":1,
        "outcome":outcome,"failure_code":if outcome=="denied"{json!("E_AGENT_DENIED_BY_USER")}else{Value::Null},"approval_reference":q["approval_reference"]})
}
pub(super) fn executed(q: &Value) -> Value {
    let mut transcript = q["transcript"].clone();
    transcript["generation"] = json!(transcript["generation"].as_u64().unwrap() + 1);
    transcript["transcript_sha256"] = json!("1".repeat(64));
    transcript["transcript_bytes"] = json!(200);
    json!({"schema_version":2,"status":"completed","operation_id":q["operation_id"],"task_id":q["task_id"],
        "attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"call_index":q["call_index"],
        "call_id":q["call_id"],"name":q["name"],"idempotency_key":q["idempotency_key"],"result_execution_revision":2,
        "transcript":transcript,"effect_may_have_occurred":false,"receipt":tool_receipt(q,"ok")})
}

#[test]
fn custom_model_stop_and_hook_error_cancel_durably_without_a_provider_call() {
    for (source, code, status) in [
        (
            "{beforeModel(){return {stop:'Review first'}}}",
            "E_ASSISTANT_RUNTIME_STOPPED",
            AssistantRunStatus::Cancelled,
        ),
        (
            "{beforeModel(){throw Error('Rejected')}}",
            "E_ASSISTANT_RUNTIME_FAILED",
            AssistantRunStatus::Failed,
        ),
        // Parsing fails while a new-round CAS is already staged: cancellation
        // must still flush that CAS and release the writer after cleanup.
        (
            "{broken",
            "E_ASSISTANT_RUNTIME_FAILED",
            AssistantRunStatus::Failed,
        ),
    ] {
        let mut h = Harness::new();
        h.runtime(source);
        h.start_intent();
        let cancel = h.until_cancel_without_effect();
        h.finish_cancel(cancel);
        let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
        let run = saved.tasks[0].last_run.as_ref().unwrap();
        assert_eq!(run.status, status);
        assert_eq!(run.failure_code.as_deref(), Some(code));
        assert!(!h.handle.snapshot().owns_writer);
    }
}

#[test]
fn custom_tool_stop_rejects_the_exact_frozen_capability_before_execution() {
    let mut h = Harness::new();
    h.runtime("{beforeTool(c){if(c.name!=='read_file'||c.provider_id!=='dsh'||'arguments' in c||'output' in c) throw Error('Context');return {stop:'Read disabled'}}}");
    let round = h.start();
    h.tool_batch(round, "read_file");
    let cancel = h.until_cancel_without_effect();
    h.finish_cancel(cancel);
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    assert_eq!(
        saved.tasks[0]
            .last_run
            .as_ref()
            .unwrap()
            .failure_code
            .as_deref(),
        Some("E_ASSISTANT_RUNTIME_STOPPED")
    );
}

#[test]
fn actual_pi_actor_consumes_read_and_question_receipts_before_second_model() {
    for name in ["read_file", "ask_user"] {
        let mut h = Harness::new();
        let round = h.start();
        assert_eq!(
            h.handle.snapshot().store.unwrap().tasks[0]
                .last_run
                .as_ref()
                .unwrap()
                .snapshot
                .runtime,
            Some(RuntimeSpec::pi())
        );
        h.tool_batch(round, name);
        if name == "ask_user" {
            wait_for(|| h.handle.snapshot().status == RunnerStatus::NeedsAttention);
            let question = h
                .handle
                .snapshot()
                .state
                .unwrap()
                .agent_view()
                .unwrap()
                .question
                .unwrap();
            h.command(RunnerCommand::Answer {
                call_id: question.id,
                answer: Some("a".into()),
            });
        }
        let intent = h.next();
        h.persist(intent);
        let execute = h.next();
        assert_eq!(execute.command.method, "execute_agent_tool");
        assert_eq!(execute.command.args[0]["name"], name);
        let value = executed(&execute.command.args[0]);
        execute.reply.send(Ok(value)).unwrap();
        let result = h.next();
        h.persist(result);
        let begin = h.next();
        h.persist(begin);
        let round = h.next();
        assert_eq!(round.command.method, "complete_agent_round_v2");
        assert_eq!(round.command.args[0]["round_index"], 1);
        let value = model_result(&h, &round.command.args[0]);
        round.reply.send(Ok(value)).unwrap();
        h.finish_cleanup();
        assert_eq!(
            h.handle.snapshot().store.unwrap().tasks[0]
                .last_run
                .as_ref()
                .unwrap()
                .status,
            AssistantRunStatus::Completed
        );
    }
}

#[test]
fn approval_denial_is_a_real_pi_receipt_and_never_dispatches_the_write() {
    let mut h = Harness::new();
    let round = h.start();
    h.tool_batch(round, "write_file");
    wait_for(|| h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    let approval = h
        .handle
        .snapshot()
        .state
        .unwrap()
        .agent_view()
        .unwrap()
        .approval
        .unwrap();
    h.command(RunnerCommand::Approval {
        approval_id: approval.approval_id,
        decision: "denied".into(),
    });
    let checkpoint = h.next();
    h.persist(checkpoint);
    let bind = h.next();
    assert_eq!(bind.command.method, "bind_agent_approval");
    let q = &bind.command.args[0];
    let call =
        &h.saved_session.as_ref().unwrap()["conversations"][0]["attempts"][0]["agent"]["batch"][0];
    let mut transcript =
        h.saved_session.as_ref().unwrap()["conversations"][0]["attempts"][0]["agent"]["transcript"]
            .clone();
    transcript["generation"] = json!(2);
    transcript["transcript_sha256"] = json!("9".repeat(64));
    transcript["transcript_bytes"] = json!(300);
    let value = json!({"schema_version":2,"status":"bound","operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],
        "round_id":q["round_id"],"call_index":0,"call_id":"call-1","decision":"denied","approval_reference":null,"grant":null,
        "result_batch_revision":1,"observed_checkpoint":q["committed_checkpoint"],"receipt":tool_receipt(call,"denied"),"transcript":transcript});
    bind.reply.send(Ok(value)).unwrap();
    let checkpoint = h.next();
    h.persist(checkpoint);
    let begin = h.next();
    h.persist(begin);
    let round = h.next();
    assert_eq!(round.command.method, "complete_agent_round_v2");
    assert_eq!(round.command.args[0]["round_index"], 1);
    let value = model_result(&h, &round.command.args[0]);
    round.reply.send(Ok(value)).unwrap();
    h.finish_cleanup();
}

fn hydrate_driver(h: &Harness) -> driver::Driver {
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    let task = &saved.tasks[0];
    let claim = AssistantClaim {
        snapshot: saved.clone(),
        task_id: task.id.clone(),
        conversation_id: task.conversation_id.clone(),
        run: task.last_run.clone().unwrap(),
    };
    let mut d = driver::Driver::new();
    d.state = Some(h.restart_state());
    d.active = Some(driver::Active {
        claim,
        recover: true,
        stopped: false,
        stop_persist_failed: false,
        expired: false,
        setup_pending: false,
        validated: true,
        sent: true,
        reconciled: true,
        cancel_after_recover: None,
    });
    d
}

#[test]
fn hydration_uses_only_committed_frontier_and_rejects_phantom_effect_identity() {
    let mut h = Harness::new();
    let round = h.start();
    h.tool_batch(round, "read_file");
    let intent = h.next();
    h.persist(intent);
    let execute = h.next();
    let mut d = hydrate_driver(&h);
    assert_eq!(
        d.sync_pi(Some(&execute.command)).unwrap(),
        rish_pi_runtime::Admission::Allow
    );
    let events = d.pi.as_ref().unwrap().state().events;
    assert!(
        events.contains(&"tool_execution_start".into()),
        "actual upstream Pi emitted the tool intent"
    );
    assert!(d.outbox.is_empty(), "hydration must have no host effect");
    let mut forged = execute.command.clone();
    forged.args[0]["round_id"] = json!(uuid::Uuid::new_v4().to_string());
    assert!(d.sync_pi(Some(&forged)).is_err());
    forged = execute.command.clone();
    forged.args[0]["arguments_sha256"] = json!("0".repeat(64));
    assert!(d.sync_pi(Some(&forged)).is_err());
    assert!(d.outbox.is_empty());
    let value = executed(&execute.command.args[0]);
    execute.reply.send(Ok(value)).unwrap();
    let receipt = h.next();
    // Before CAS, replay still waits for the exact tool: candidate_json is
    // never ingested into Pi even if the host reply claimed completion.
    let mut before = hydrate_driver(&h);
    before.sync_pi(None).unwrap();
    assert!(matches!(
        before.pi.as_ref().unwrap().state().intent,
        Some(rish_pi_runtime::Intent::Tool { .. })
    ));
    h.persist(receipt);
    let begin = h.next();
    let mut after = hydrate_driver(&h);
    after.sync_pi(None).unwrap();
    assert_eq!(
        after.pi.as_ref().unwrap().state().intent,
        Some(rish_pi_runtime::Intent::Model { round_index: 1 })
    );
    assert!(after.outbox.is_empty());
    h.persist(begin);
    let round = h.next();
    assert_eq!(round.command.args[0]["round_index"], 1);
    let mut frontier = hydrate_driver(&h);
    frontier.sync_pi(Some(&round.command)).unwrap();
    assert_eq!(
        frontier.pi.as_ref().unwrap().state().intent,
        Some(rish_pi_runtime::Intent::Model { round_index: 1 })
    );
    assert!(
        !frontier
            .pi
            .as_ref()
            .unwrap()
            .state()
            .events
            .contains(&"tool_execution_start".into())
    );
    assert!(frontier.outbox.is_empty());
    let value = model_result(&h, &round.command.args[0]);
    round.reply.send(Ok(value)).unwrap();
    h.finish_cleanup();
}
