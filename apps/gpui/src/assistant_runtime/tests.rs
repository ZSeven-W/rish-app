use super::*;
use futures::channel::oneshot;
use serde_json::json;
use std::{
    sync::mpsc as sync,
    time::{Duration, Instant},
};
#[path = "group_tests.rs"]
mod groups;
#[path = "pi_actor_tests.rs"]
mod pi_actor;
#[path = "recovery_tests.rs"]
mod recovery;
#[path = "title_tests.rs"]
mod titles;

struct Request {
    command: RuntimeCommand,
    reply: oneshot::Sender<Result<Value, String>>,
}
struct FakeTransport(sync::Sender<Request>);
impl Transport for FakeTransport {
    fn call(&self, command: RuntimeCommand) -> BoxFuture<'static, Result<Value, String>> {
        let (reply, receiver) = oneshot::channel();
        if self.0.send(Request { command, reply }).is_err() {
            return async { Err("test transport closed".into()) }.boxed();
        }
        async move {
            receiver
                .await
                .unwrap_or_else(|_| Err("fake reply disconnected".into()))
        }
        .boxed()
    }
}
struct Harness {
    handle: RunnerHandle,
    requests: sync::Receiver<Request>,
    directory: PathBuf,
    task_id: String,
    saved_session: Option<Value>,
    authority: Option<Value>,
}
impl Harness {
    fn new() -> Self {
        let directory =
            std::env::temp_dir().join(format!("rish-assistant-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let directory = std::fs::canonicalize(directory).unwrap();
        let store = AssistantStore::open(&directory).unwrap();
        let snapshot = store.create_task(0, config(), now_ms()).unwrap();
        let task_id = snapshot.tasks[0].id.clone();
        let (sender, requests) = sync::channel();
        let handle = RunnerHandle::spawn(Arc::new(FakeTransport(sender)));
        handle
            .send(RunnerCommand::Initialize {
                directory: directory.clone(),
            })
            .unwrap();
        let settings = requests.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(settings.command.args[0]["op"], "settings");
        settings.reply.send(Ok(json!({"foreground":true}))).unwrap();
        let drain = requests.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(drain.command.args[0]["op"], "drain");
        drain.reply.send(Ok(json!([]))).unwrap();
        wait_for(|| handle.snapshot().store.is_some());
        Self {
            handle,
            requests,
            directory,
            task_id,
            saved_session: None,
            authority: None,
        }
    }
    fn command(&self, command: RunnerCommand) {
        self.handle.send(command).unwrap();
    }
    fn grant(&self) {
        let mut state = ShellState::with_test_models();
        state
            .load_snapshot(json!({"schema_version":1,"status":"missing"}))
            .unwrap();
        state.set_default_workspace(descriptor()).unwrap();
        self.command(RunnerCommand::Grant {
            task_id: self.task_id.clone(),
            state,
            foreground: true,
        });
    }
    fn next(&self) -> Request {
        loop {
            let request = self
                .requests
                .recv_timeout(Duration::from_secs(3))
                .unwrap_or_else(|e| panic!("{e}; snapshot={:?}", self.handle.snapshot()));
            if request.command.module == "TaskExperience"
                && matches!(
                    request.command.args[0]["op"].as_str(),
                    Some("update" | "end")
                )
            {
                let _ = request.reply.send(Ok(json!(true)));
                continue;
            }
            return request;
        }
    }
    fn persist(&mut self, request: Request) {
        assert_eq!(request.command.method, "casPersistSession");
        let (session, snapshot, proof) = persist_reply(&request.command);
        self.saved_session = Some(session);
        self.authority = Some(snapshot);
        request.reply.send(Ok(proof)).unwrap();
    }
    fn until_round(&mut self) -> Request {
        for _ in 0..20 {
            let request = self.next();
            match request.command.method.as_str() {
                "handle" => {
                    assert_eq!(request.command.args[0]["op"], "begin");
                    request
                        .reply
                        .send(Ok(
                            json!({"started":true,"backgroundAdmission":"notRequested"}),
                        ))
                        .unwrap();
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
                "complete_agent_round_v2" => return request,
                other => panic!("unexpected method {other}"),
            }
        }
        panic!("round was never reached")
    }
    fn start(&mut self) -> Request {
        self.command(RunnerCommand::RunNow {
            task_id: self.task_id.clone(),
        });
        wait_for(|| self.handle.snapshot().status == RunnerStatus::WaitingForForeground);
        self.grant();
        self.until_round()
    }
    fn finish_cancel(&mut self, request: Request) {
        assert_eq!(request.command.method, "cancel_agent_attempt");
        let q = &request.command.args[0];
        let value = json!({"schema_version":2,"status":"cancelled","operation_id":q["operation_id"],
            "target":q["target"],"transcript":q["expected_transcript"],"result_round_revision":2});
        request.reply.send(Ok(value)).unwrap();
        self.finish_cleanup();
    }
    fn finish_cleanup(&mut self) {
        for _ in 0..8 {
            let request = self.next();
            match request.command.method.as_str() {
                "casPersistSession" => {
                    let terminal_cleanup = request.command.args[0]["candidate_json"].as_str().is_some_and(|raw|
                        serde_json::from_str::<Value>(raw).unwrap()["agent_transcript_cleanup_outbox"].as_array().unwrap().is_empty());
                    self.persist(request);
                    if terminal_cleanup {
                        break;
                    }
                }
                "finalize_agent_attempt" => {
                    let q = &request.command.args[0];
                    let value = json!({"schema_version":2,"status":"terminal","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"],"transcript":q["transcript"]});
                    request.reply.send(Ok(value)).unwrap();
                }
                "discard_agent_attempt" => {
                    let q = &request.command.args[0];
                    let value = json!({"schema_version":2,"status":"discarded","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]});
                    request.reply.send(Ok(value)).unwrap();
                }
                other => panic!("unexpected cancel method {other}"),
            }
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while self.handle.snapshot().owns_writer {
            assert!(
                Instant::now() < deadline,
                "Native cleanup did not release the writer"
            );
            if let Ok(request) = self.requests.recv_timeout(Duration::from_millis(10)) {
                assert_eq!(request.command.module, "TaskExperience");
                assert!(matches!(
                    request.command.args[0]["op"].as_str(),
                    Some("update" | "end")
                ));
                request.reply.send(Ok(json!(true))).unwrap();
            }
        }
    }
    fn restart_state(&self) -> ShellState {
        let mut state = ShellState::with_test_models();
        state.load_snapshot(self.snapshot_reply()).unwrap();
        state.set_default_workspace(descriptor()).unwrap();
        state
    }
    fn snapshot_reply(&self) -> Value {
        json!({"schema_version":1,"status":"present","session_json":self.saved_session.as_ref().unwrap().to_string(),"snapshot":self.authority})
    }
    fn visible_history_digest(&self, request: &Value) -> String {
        let conversation = self.saved_session.as_ref().unwrap()["conversations"]
            .as_array()
            .unwrap()
            .iter()
            .find(|conversation| conversation["id"] == request["conversation_id"])
            .unwrap();
        let attempt = conversation["attempts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|attempt| attempt["attempt_id"] == request["attempt_id"])
            .unwrap();
        let ids = attempt["visible_message_ids"].as_array().unwrap();
        let history: Vec<Value> = conversation["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|message| ids.contains(&message["id"]))
            .map(|message| {
                json!({"role":message["role"],"content":message["text"],
                "attachments":message["attachments"]})
            })
            .collect();
        rish_agent_core::canonical::sha256_hex(
            &rish_agent_core::canonical::canonical_json(&json!(history)).unwrap(),
        )
    }
}

#[test]
fn completion_persists_answer_and_cleanup_before_releasing_writer() {
    let mut h = Harness::new();
    let round = h.start();
    let q = &round.command.args[0];
    let mut transcript = q["transcript"].clone();
    transcript["generation"] = json!(q["transcript"]["generation"].as_u64().unwrap() + 1);
    transcript["transcript_sha256"] = json!("d".repeat(64));
    transcript["transcript_bytes"] = json!(100);
    let result = json!({"schema_version":2,"status":"completed","operation_id":q["operation_id"],"task_id":q["task_id"],
        "attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"launch_attempt":1,"result_round_revision":2,
        "transcript":transcript,"outcome":{"schema_version":3,"kind":"final","finish_reason":"stop","transcript":transcript,
        "text":"Local verification complete","reasoning":"","completion_receipt":{"schema_version":2,"transport_schema_version":2,
        "turn_id":q["task_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],
        "provider_request_id":uuid::Uuid::new_v4().to_string(),"provider_response_id":"local-response","harness_id":"dsh","requested_model":q["model"],
        "model":q["model"],"thinking_mode":q["thinking_mode"],"finish_reason":"stop","latency_ms":1,
        "visible_history_sha256":h.visible_history_digest(q),
        "model_input_sha256":"f".repeat(64),"request_body_sha256":"e".repeat(64),"project_context_receipt":null}}});
    round.reply.send(Ok(result)).unwrap();
    h.finish_cleanup();
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    let run = saved.tasks[0].last_run.as_ref().unwrap();
    assert_eq!(run.status, AssistantRunStatus::Completed);
    assert_eq!(
        run.result_summary.as_deref(),
        Some("Local verification complete")
    );
    assert_eq!(
        h.saved_session.as_ref().unwrap()["agent_transcript_cleanup_outbox"],
        json!([])
    );
    assert_eq!(h.handle.snapshot().status, RunnerStatus::Idle);
}
impl Drop for Harness {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
fn wait_for(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "assistant actor did not reach expected state"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn descriptor() -> Value {
    json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Local tests","status":"ok","capabilities":{"read":true,"write":true,"git":true}})
}
pub(super) fn config() -> AssistantTaskConfig {
    AssistantTaskConfig {
        title: "Local test".into(),
        instructions: "Inspect the files".into(),
        workspace_binding: rish_shell_core::workspace_binding(&descriptor()).unwrap(),
        workspace_descriptor: descriptor(),
        model_id: "deepseek-v4-flash".into(),
        interval_minutes: None,
        enabled: true,
        runtime: None,
    }
}
fn persist_reply(command: &RuntimeCommand) -> (Value, Value, Value) {
    let q = &command.args[0];
    let raw = q["candidate_json"].as_str().unwrap();
    let snapshot = json!({"schema_version":1,"generation":q["expected"]["snapshot"]["generation"].as_u64().unwrap_or(0)+1,
        "session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()});
    (
        serde_json::from_str(raw).unwrap(),
        snapshot.clone(),
        json!({"schema_version":1,"status":"committed","snapshot":snapshot}),
    )
}
fn prepared(q: &Value) -> Value {
    json!({"schema_version":2,"status":"prepared","operation_id":q["operation_id"],"observed_checkpoint":q["committed_checkpoint"],"attempt":{
        "schema_version":2,"task_id":q["task_id"],"conversation_id":q["conversation_id"],"attempt_id":q["attempt_id"],"phase":"ready_for_round",
        "controller_generation":0,"journal_revision":0,"authority_revision":1,
        "root":{"schema_version":1,"kind":"workspace","workspace_id":q["workspace_id"],"workspace_binding_revision":q["workspace_binding_revision"],"project_id":null,"root_fingerprint_sha256":"a".repeat(64),"capabilities":["file_read","file_write"]},
        "policy":{"schema_version":1,"policy_version":"agent-v1","max_single_write_bytes":32768,"max_batch_write_bytes":524288,"max_attempt_write_bytes":4194304},
        "registry":{"schema_version":2,"registry_version":q["registry_version"],"toolset_sha256":"b".repeat(64),"tools":[]},
        "transcript":{"schema_version":1,"transcript_ref":uuid::Uuid::new_v4().to_string(),"generation":0,"transcript_sha256":"c".repeat(64),"transcript_bytes":2},
        "round_index":0,"round_id":null,"round_revision":null,"round_status":null,"batch_kind":null,"batch_revision":null,"manifest_sha256":null,
        "call_index":null,"batch":[],"frozen_grant_ids":[],"reserved_write_bytes":0,"cancel_source_event_id":null,"cleanup_id":null}})
}

#[test]
fn manual_request_is_durable_before_handoff_and_claim_precedes_native_begin() {
    let mut h = Harness::new();
    h.command(RunnerCommand::RunNow {
        task_id: h.task_id.clone(),
    });
    wait_for(|| h.handle.snapshot().status == RunnerStatus::WaitingForForeground);
    let snapshot = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    assert!(snapshot.tasks[0].pending_manual);
    assert!(snapshot.tasks[0].last_run.is_none());
    assert!(
        h.requests.try_recv().is_err(),
        "cannot start without UI writer handoff"
    );
    h.grant();
    let begin = h.next();
    assert_eq!(begin.command.args[0]["op"], "begin");
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    let run = saved.tasks[0].last_run.as_ref().unwrap();
    assert_eq!(begin.command.args[0]["runId"], run.run_id);
    assert!(!saved.tasks[0].pending_manual);
    h.command(RunnerCommand::RunNow {
        task_id: h.task_id.clone(),
    });
    begin.reply.send(Ok(json!(true))).unwrap();
    let round = h.until_round();
    h.command(RunnerCommand::Stop);
    let cancel_checkpoint = h.next();
    h.persist(cancel_checkpoint);
    let cancel = h.next();
    h.finish_cancel(cancel);
    let _ = round.reply.send(Err("late old round".into()));
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    assert_eq!(saved.tasks[0].last_run.as_ref().unwrap().run_id, run.run_id);
    assert_eq!(
        saved.tasks[0].last_run.as_ref().unwrap().status,
        AssistantRunStatus::Cancelled
    );
}

#[test]
fn native_expiry_reaches_actor_without_ui_drain_and_fences_late_provider_reply() {
    let mut h = Harness::new();
    assert!(
        PROCESS.set(h.handle.clone()).is_ok(),
        "this is the sole global native ingress test"
    );
    assert!(Arc::ptr_eq(
        &RunnerHandle::process().snapshot,
        &RunnerHandle::process().snapshot,
    ));
    let round = h.start();
    let active = h.handle.snapshot();
    let task = &active.store.as_ref().unwrap().tasks[0];
    let run = task.last_run.as_ref().unwrap();
    crate::runtime::receive_event(
        "taskExperienceAction".into(),
        json!({"schema_version":1,"action":"cancel","runId":"stale-run","conversationId":task.conversation_id,"reason":"user_stop"}),
    );
    crate::runtime::receive_event(
        "taskExperienceAction".into(),
        json!({"schema_version":1,"action":"cancel","runId":run.run_id,"conversationId":task.conversation_id,"reason":"background_expired"}),
    );
    // The provider oneshot has deliberately not been resolved. Cancellation
    // must still publish its CAS and then dispatch native cancel immediately.
    let checkpoint = h.next();
    assert_eq!(checkpoint.command.method, "casPersistSession");
    h.persist(checkpoint);
    let cancel = h.next();
    assert_eq!(cancel.command.method, "cancel_agent_attempt");
    round
        .reply
        .send(Ok(json!({"unexpected":"stale provider result"})))
        .unwrap();
    h.finish_cancel(cancel);
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    assert_eq!(
        saved.tasks[0].last_run.as_ref().unwrap().status,
        AssistantRunStatus::NeedsAttention
    );
    assert_eq!(
        saved.tasks[0]
            .last_run
            .as_ref()
            .unwrap()
            .failure_code
            .as_deref(),
        Some("E_ASSISTANT_BACKGROUND_EXPIRED")
    );
    assert_eq!(h.handle.snapshot().status, RunnerStatus::NeedsAttention);
    assert!(saved.due_task_ids(u64::MAX).is_empty());
}

#[test]
fn restart_queries_existing_claim_without_replaying_and_unknown_checkpoint_blocks_start() {
    let mut h = Harness::new();
    let round = h.start();
    let mut restarted = driver::Driver::new();
    restarted.command(RunnerCommand::Initialize {
        directory: h.directory.clone(),
    });
    restarted.outbox.clear(); // settings is observational
    assert_eq!(restarted.status, RunnerStatus::NeedsAttention);
    assert!(restarted.pending.is_none());
    restarted.command(RunnerCommand::Recover {
        task_id: h.task_id.clone(),
    });
    restarted.command(RunnerCommand::Grant {
        task_id: h.task_id.clone(),
        state: h.restart_state(),
        foreground: true,
    });
    let begin = restarted.outbox.remove(0);
    restarted.reply(begin, Ok(json!(true)));
    let reload = restarted.outbox.remove(0);
    assert_eq!(reload.command.method, "loadSessionSnapshot");
    restarted.reply(reload, Ok(h.snapshot_reply()));
    let workspace = restarted.outbox.remove(0);
    restarted.reply(
        workspace,
        Ok(json!({"schema_version":1,"workspace":descriptor()})),
    );
    let query = restarted
        .outbox
        .iter()
        .find(|op| op.command.module == "AgentRuntime")
        .unwrap();
    assert_eq!(query.command.method, "query_agent_attempt");
    assert_eq!(
        query.command.args[0]["attempt_id"],
        round.command.args[0]["attempt_id"]
    );
    assert!(!restarted.outbox.iter().any(|op| matches!(
        op.command.method.as_str(),
        "complete_agent_round_v2" | "prepare_agent_attempt"
    )));
    // An unknown CAS result cannot authorize provider work or a second claim.
    h.command(RunnerCommand::Stop);
    let pending = h.next();
    pending
        .reply
        .send(Ok(json!({"schema_version":1,"status":"unknown"})))
        .unwrap();
    wait_for(|| h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    let before = h.handle.snapshot().store.unwrap().tasks[0]
        .last_run
        .clone()
        .unwrap();
    h.command(RunnerCommand::RunNow {
        task_id: h.task_id.clone(),
    });
    std::thread::sleep(Duration::from_millis(20));
    let after = h.handle.snapshot().store.unwrap().tasks[0]
        .last_run
        .clone()
        .unwrap();
    assert_eq!(before.run_id, after.run_id);
    assert_eq!(
        after.failure_code.as_deref(),
        Some("E_ASSISTANT_NATIVE_STOP_REQUESTED")
    );
    assert!(h.handle.snapshot().owns_writer);
    let mut interrupted = driver::Driver::new();
    interrupted.command(RunnerCommand::Initialize {
        directory: h.directory.clone(),
    });
    assert_eq!(
        interrupted.pending.as_ref().unwrap().cancel_after_recover,
        Some(false)
    );
}

#[test]
fn due_job_waits_for_foreground_and_job_pause_does_not_cancel_current_attempt() {
    let mut h = Harness::new();
    let round = h.start();
    let revision = h.handle.snapshot().store.unwrap().revision;
    h.command(RunnerCommand::SetEnabled {
        expected_revision: revision,
        task_id: h.task_id.clone(),
        enabled: false,
    });
    wait_for(|| !h.handle.snapshot().store.as_ref().unwrap().tasks[0].enabled);
    assert!(
        h.handle
            .snapshot()
            .state
            .unwrap()
            .owns_agent_command(&round.command)
    );
    h.command(RunnerCommand::Stop);
    let checkpoint = h.next();
    h.persist(checkpoint);
    let cancel = h.next();
    h.finish_cancel(cancel);
    let _ = round.reply.send(Err("late".into()));

    let store = AssistantStore::open(&h.directory).unwrap();
    let saved = store.load().unwrap();
    let mut scheduled = config();
    scheduled.interval_minutes = Some(15);
    let saved = store.create_task(saved.revision, scheduled, 1).unwrap();
    let task = saved.tasks.last().unwrap();
    // Store's clock high-water protects against regression; explicit here
    // writes a due time relative to its trusted latest clock.
    assert!(task.next_due_ms.is_some());
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: h.directory.clone(),
    });
    driver.outbox.clear();
    driver.command(RunnerCommand::RevokeForeground);
    driver.poll_due_at(task.next_due_ms.unwrap()).unwrap();
    assert_eq!(driver.status, RunnerStatus::WaitingForForeground);
    assert!(driver.pending.as_ref().unwrap().due);
    assert!(driver.active.is_none());
    assert!(driver.outbox.is_empty());
}

#[test]
fn cold_start_drains_native_open_and_stop_without_a_ui_consumer() {
    let mut h = Harness::new();
    let _round = h.start();
    let saved = h.handle.snapshot().store.unwrap();
    let task = &saved.tasks[0];
    let run = task.last_run.as_ref().unwrap();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: h.directory.clone(),
    });
    let drain = driver
        .outbox
        .iter()
        .find(|op| matches!(op.kind, driver::OperationKind::Drain))
        .unwrap()
        .clone();
    driver.outbox.clear();
    driver.reply(drain, Ok(json!([
        {"schema_version":1,"action":"open","runId":run.run_id,"conversationId":task.conversation_id},
        {"schema_version":1,"action":"cancel","runId":run.run_id,"conversationId":task.conversation_id,"reason":"user_stop"}
    ])));
    assert!(driver.events.iter().any(|event| matches!(event, RunnerEvent::OpenConversation { conversation_id } if conversation_id == &task.conversation_id)));
    assert_eq!(
        driver.pending.as_ref().unwrap().cancel_after_recover,
        Some(false)
    );
    assert!(driver.outbox.is_empty());
    driver.command(RunnerCommand::Grant {
        task_id: h.task_id.clone(),
        state: h.restart_state(),
        foreground: true,
    });
    let begin = driver.outbox.remove(0);
    assert_eq!(begin.command.args[0]["backgroundEligible"], false);
    driver.reply(begin, Ok(json!(true)));
    let reload = driver.outbox.remove(0);
    driver.reply(reload, Ok(h.snapshot_reply()));
    let resolve = driver.outbox.remove(0);
    driver.reply(
        resolve,
        Ok(json!({"schema_version":1,"workspace":descriptor()})),
    );
    assert!(driver.active.as_ref().unwrap().stopped);
    assert!(
        driver
            .outbox
            .iter()
            .any(|op| op.command.method == "query_agent_attempt")
    );
    assert!(
        !driver
            .outbox
            .iter()
            .any(|op| op.command.method == "complete_agent_round_v2")
    );
}

#[test]
fn fresh_absence_closes_prestart_claim_and_stale_handoff_cannot_start_a_different_task() {
    let h = Harness::new();
    let store = AssistantStore::open(&h.directory).unwrap();
    let saved = store.load().unwrap();
    let claim = store
        .claim(
            saved.revision,
            &h.task_id,
            AssistantClaimMode::Manual,
            now_ms(),
        )
        .unwrap();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: h.directory.clone(),
    });
    driver.outbox.clear();
    driver.command(RunnerCommand::Recover {
        task_id: h.task_id.clone(),
    });
    let mut state = ShellState::with_test_models();
    state
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    driver.command(RunnerCommand::Grant {
        task_id: "stale-other-task".into(),
        state: state.clone(),
        foreground: true,
    });
    assert!(driver.state.is_none());
    assert!(
        driver
            .events
            .iter()
            .any(|e| matches!(e, RunnerEvent::Returned { .. }))
    );
    assert!(driver.outbox.is_empty());
    driver.command(RunnerCommand::Grant {
        task_id: h.task_id.clone(),
        state,
        foreground: true,
    });
    let begin = driver.outbox.remove(0);
    driver.reply(begin, Ok(json!(true)));
    assert_eq!(
        store.load().unwrap().tasks[0]
            .last_run
            .as_ref()
            .unwrap()
            .status,
        AssistantRunStatus::Running
    );
    let reload = driver.outbox.remove(0);
    assert_eq!(reload.command.method, "loadSessionSnapshot");
    driver.reply(reload, Ok(json!({"schema_version":1,"status":"missing"})));
    let saved = store.load().unwrap();
    let run = saved.tasks[0].last_run.as_ref().unwrap();
    assert_eq!(run.run_id, claim.run.run_id);
    assert_eq!(run.status, AssistantRunStatus::Failed);
    assert_eq!(
        run.failure_code.as_deref(),
        Some("E_ASSISTANT_START_INTERRUPTED")
    );
    assert!(driver.state.is_none());
    assert!(!driver.outbox.iter().any(|op| matches!(
        op.command.module.as_str(),
        "AgentRuntime" | "SessionSnapshots" | "LocalWorkspaces"
    )));
    assert!(
        store
            .request_run(saved.revision, &h.task_id, now_ms())
            .is_ok()
    );
}

#[test]
fn terminal_claim_does_not_recover_or_cancel_newer_ordinary_attempt() {
    let mut h = Harness::new();
    let round = h.start();
    h.command(RunnerCommand::Stop);
    let checkpoint = h.next();
    h.persist(checkpoint);
    let cancel = h.next();
    h.finish_cancel(cancel);
    let _ = round.reply.send(Err("late".into()));
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    let task = &saved.tasks[0];
    let claim = AssistantClaim {
        snapshot: saved.clone(),
        task_id: task.id.clone(),
        conversation_id: task.conversation_id.clone(),
        run: task.last_run.clone().unwrap(),
    };
    let mut state = h.restart_state();
    let foreign_ids = rish_shell_core::TurnIds::new();
    let command = state
        .prepare_agent_send("A later ordinary chat", &foreign_ids, &now())
        .unwrap();
    let (_, _, proof) = persist_reply(&command);
    state.accept_persist(proof).unwrap();
    // Reload clears the temporary driver exactly as a real process restart.
    let raw = state.raw_session().to_string();
    let mut reloaded = ShellState::with_test_models();
    reloaded.load_snapshot(json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":{
        "schema_version":1,"generation":99,"session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()}})).unwrap();
    assert!(!flow::needs_claim_recovery(reloaded.raw_session(), &claim).unwrap());
    let mut driver = driver::Driver::new();
    driver.store = Some(AssistantStore::open(&h.directory).unwrap());
    driver.saved = Some(saved);
    driver.state = Some(reloaded);
    driver.active = Some(driver::Active {
        claim,
        recover: true,
        stopped: false,
        stop_persist_failed: false,
        expired: false,
        setup_pending: false,
        validated: false,
        sent: false,
        reconciled: true,
        cancel_after_recover: Some(false),
    });
    driver.continue_setup().unwrap();
    assert!(driver.active.is_none());
    assert!(
        !driver
            .outbox
            .iter()
            .any(|op| op.command.module == "AgentRuntime")
    );
    let returned = driver
        .events
        .iter()
        .find_map(|e| {
            if let RunnerEvent::Returned { state } = e {
                Some(state)
            } else {
                None
            }
        })
        .unwrap();
    assert!(
        returned.raw_session()["conversations"][0]["attempts"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a["attempt_id"] == foreign_ids.attempt_id && a["status"] == "prepared")
    );
}

#[test]
fn expiry_intent_survives_unknown_cancel_checkpoint_and_explicit_recovery() {
    let mut h = Harness::new();
    let _round = h.start();
    let saved = h.handle.snapshot().store.unwrap();
    let task = &saved.tasks[0];
    let run = task.last_run.as_ref().unwrap();
    h.command(RunnerCommand::NativeEvent {
        name: "taskExperienceAction".into(),
        payload: json!({"schema_version":1,"action":"cancel",
        "runId":run.run_id,"conversationId":task.conversation_id,"reason":"background_expired"}),
    });
    let checkpoint = h.next();
    checkpoint
        .reply
        .send(Ok(json!({"schema_version":1,"status":"unknown"})))
        .unwrap();
    wait_for(|| h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    assert_eq!(
        saved.tasks[0]
            .last_run
            .as_ref()
            .unwrap()
            .failure_code
            .as_deref(),
        Some("E_ASSISTANT_BACKGROUND_EXPIRED")
    );
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: h.directory.clone(),
    });
    driver.command(RunnerCommand::Recover {
        task_id: h.task_id.clone(),
    });
    assert_eq!(
        driver.pending.as_ref().unwrap().cancel_after_recover,
        Some(true)
    );
}
