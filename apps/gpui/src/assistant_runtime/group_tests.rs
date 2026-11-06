//! Group tests use the real actor, shared controller, store and CAS flow with
//! deterministic native replies. They never use real credentials or inference.
use super::*;
#[path = "group_decision_tests.rs"]
mod decisions;
#[path = "group_end_tests.rs"]
mod native_end;

struct GroupHarness {
    h: Harness,
    group_id: String,
    bot_id: String,
    round_id: String,
}

impl GroupHarness {
    fn new() -> Self {
        let h = Harness::new();
        let store = AssistantStore::open(&h.directory).unwrap();
        let bot_id = uuid::Uuid::new_v4().to_string();
        let group_id = uuid::Uuid::new_v4().to_string();
        let created = store
            .create_bot_with_id(
                store.load().unwrap().revision,
                &bot_id,
                AssistantProfile {
                    name: "Planning Bot".into(),
                    ..Default::default()
                },
            )
            .unwrap();
        store
            .create_group_with_id(
                created.revision,
                &group_id,
                "Project group",
                &[DEFAULT_BOT_ID.into(), bot_id.clone()],
            )
            .unwrap();
        h.command(RunnerCommand::RefreshStore);
        wait_for(|| {
            h.handle
                .snapshot()
                .directory
                .as_ref()
                .is_some_and(|s| s.groups.len() == 1)
        });
        Self {
            h,
            group_id,
            bot_id,
            round_id: uuid::Uuid::new_v4().to_string(),
        }
    }

    fn start(&mut self, target: Option<String>) -> Request {
        self.h.command(RunnerCommand::SendGroup {
            group_id: self.group_id.clone(),
            turn_id: self.round_id.clone(),
            target_bot_id: target,
            text: "请一起给我一个计划".into(),
            model_id: "deepseek-v4-flash".into(),
            workspace_descriptor: descriptor(),
        });
        wait_for(|| self.h.handle.snapshot().status == RunnerStatus::WaitingForForeground);
        let mut state = ShellState::with_test_models();
        state
            .load_snapshot(json!({"schema_version":1,"status":"missing"}))
            .unwrap();
        state.set_default_workspace(descriptor()).unwrap();
        self.h.command(RunnerCommand::Grant {
            task_id: self.group_id.clone(),
            state,
            foreground: true,
        });
        self.until_round()
    }

    fn until_round(&mut self) -> Request {
        for _ in 0..32 {
            let request = self.h.next();
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
                "casPersistSession" => self.h.persist(request),
                "prepare_agent_attempt" => {
                    assert_eq!(
                        request.command.args[0]["registry_version"], 5,
                        "Each group lane keeps the Bot's real task/memory tools"
                    );
                    let reply = prepared(&request.command.args[0]);
                    request.reply.send(Ok(reply)).unwrap();
                }
                "finalize_agent_attempt" => {
                    let q = &request.command.args[0];
                    let reply = json!({"schema_version":2,"status":"terminal","operation_id":q["operation_id"],
                        "cleanup_id":q["cleanup_id"],"transcript":q["transcript"]});
                    request.reply.send(Ok(reply)).unwrap();
                }
                "discard_agent_attempt" => {
                    let q = &request.command.args[0];
                    let reply = json!({"schema_version":2,"status":"discarded","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]});
                    request.reply.send(Ok(reply)).unwrap();
                }
                "complete_agent_round_v2" => return request,
                other => panic!("Unexpected group operation: {other}"),
            }
        }
        panic!("Group round was never reached");
    }

    fn reply(&mut self, request: Request, text: &str) {
        let mut result = test_fixture::final_result(&request.command.args[0]);
        result["outcome"]["text"] = json!(text);
        result["outcome"]["completion_receipt"]["visible_history_sha256"] =
            json!(self.h.visible_history_digest(&request.command.args[0]));
        request.reply.send(Ok(result)).unwrap();
    }

    fn saved(&self) -> AssistantSnapshot {
        AssistantStore::open(&self.h.directory)
            .unwrap()
            .load()
            .unwrap()
    }

    fn stop(&mut self, pending: Request) {
        self.h.command(RunnerCommand::StopGroup {
            group_id: self.group_id.clone(),
        });
        let checkpoint = self.h.next();
        self.h.persist(checkpoint);
        let cancel = self.h.next();
        self.h.finish_cancel(cancel);
        let _ = pending
            .reply
            .send(Err("Late provider reply after explicit stop".into()));
    }
}

#[test]
fn group_delivers_one_reply_each_in_order_and_selection_cannot_change_speaker() {
    let mut group = GroupHarness::new();
    let first = group.start(None);
    let first_lane = first.command.args[0]["conversation_id"].clone();
    assert_eq!(
        group.h.handle.snapshot().active_bot_id.as_deref(),
        Some(DEFAULT_BOT_ID)
    );
    group.h.command(RunnerCommand::SelectBot {
        bot_id: group.bot_id.clone(),
    });
    wait_for(|| group.h.handle.snapshot().selected_bot_id == group.bot_id);
    assert_eq!(
        group.h.handle.snapshot().active_bot_id.as_deref(),
        Some(DEFAULT_BOT_ID)
    );
    assert_eq!(
        group.h.handle.snapshot().store.unwrap().profile.name,
        "Planning Bot"
    );
    group.reply(first, "先确定目标。");
    let second = group.until_round();
    assert_ne!(second.command.args[0]["conversation_id"], first_lane);
    let saved = group.saved();
    let round = &saved.groups[0].rounds[0];
    assert_eq!(
        round.replies[0].run.as_ref().unwrap().status,
        AssistantRunStatus::Completed
    );
    assert_eq!(round.replies[0].text.as_deref(), Some("先确定目标。"));
    let second_claim = round.replies[1].run.as_ref().unwrap();
    assert_eq!(second_claim.snapshot.name, "Planning Bot");
    assert!(second_claim.snapshot.instructions.contains("先确定目标。"));
    assert_eq!(
        group.h.handle.snapshot().active_bot_id.as_deref(),
        Some(group.bot_id.as_str())
    );
    group.reply(second, "然后分三步执行。");
    group.h.finish_cleanup();
    let saved = group.saved();
    assert_eq!(
        saved.groups[0].rounds.len(),
        1,
        "The user message has one canonical group turn"
    );
    let round = &saved.groups[0].rounds[0];
    assert_eq!(round.replies.len(), 2);
    assert!(
        round
            .replies
            .iter()
            .all(|reply| reply.run.as_ref().unwrap().status == AssistantRunStatus::Completed)
    );
    assert_eq!(round.replies[1].text.as_deref(), Some("然后分三步执行。"));
    assert!(!round.is_pending());
    assert!(!group.h.handle.snapshot().owns_writer);
    assert!(group.h.handle.snapshot().active_group_id.is_none());
}

#[test]
fn explicitly_targeted_group_member_does_not_run_other_bots() {
    let mut group = GroupHarness::new();
    let request = group.start(Some(group.bot_id.clone()));
    assert_eq!(
        group.h.handle.snapshot().active_bot_id.as_deref(),
        Some(group.bot_id.as_str())
    );
    group.reply(request, "只有指定助手回答。");
    group.h.finish_cleanup();
    let saved = group.saved();
    let replies = &saved.groups[0].rounds[0].replies;
    assert_eq!(replies.len(), 1);
    assert_eq!(replies[0].bot_id, group.bot_id);
    assert_eq!(
        saved.groups[0].members.len(),
        2,
        "Targeting doesn't alter membership"
    );
}

#[test]
fn stopping_group_cancels_current_native_attempt_and_never_claims_next_bot() {
    let mut group = GroupHarness::new();
    let request = group.start(None);
    group.stop(request);
    let saved = group.saved();
    let round = &saved.groups[0].rounds[0];
    assert!(round.stopped);
    assert_eq!(
        round.replies[0].run.as_ref().unwrap().status,
        AssistantRunStatus::Cancelled
    );
    assert!(round.replies[0].text.is_none());
    assert!(round.replies[1].run.is_none());
    assert!(!round.is_pending());
}

#[test]
fn restart_reconciles_the_same_group_attempt_without_resending_provider_work() {
    let mut group = GroupHarness::new();
    let request = group.start(None);
    let original = group.saved().group_claim(&group.group_id).unwrap();
    let mut restarted = driver::Driver::new();
    restarted.command(RunnerCommand::Initialize {
        directory: group.h.directory.clone(),
    });
    restarted.outbox.clear();
    assert_eq!(restarted.status, RunnerStatus::NeedsAttention);
    assert!(
        restarted.pending.is_none(),
        "Cold start must not replay group sends"
    );
    restarted.command(RunnerCommand::RecoverGroup {
        group_id: group.group_id.clone(),
    });
    restarted.command(RunnerCommand::Grant {
        task_id: group.group_id.clone(),
        state: group.h.restart_state(),
        foreground: true,
    });
    let begin = restarted.outbox.remove(0);
    restarted.reply(begin, Ok(json!(true)));
    let reload = restarted.outbox.remove(0);
    assert_eq!(reload.command.method, "loadSessionSnapshot");
    restarted.reply(reload, Ok(group.h.snapshot_reply()));
    let workspace = restarted.outbox.remove(0);
    restarted.reply(
        workspace,
        Ok(json!({"schema_version":1,"workspace":descriptor()})),
    );
    let query = restarted
        .outbox
        .iter()
        .find(|op| op.command.method == "query_agent_attempt")
        .unwrap();
    assert_eq!(
        query.command.args[0]["attempt_id"],
        original.claim.run.ids.attempt_id
    );
    assert_eq!(
        query.command.args[0]["conversation_id"],
        original.claim.conversation_id
    );
    assert!(!restarted.outbox.iter().any(|op| matches!(
        op.command.method.as_str(),
        "prepare_agent_attempt" | "complete_agent_round_v2"
    )));
    group.stop(request);
}

#[test]
fn queued_group_can_be_stopped_before_writer_handoff_without_native_effects() {
    let group = GroupHarness::new();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: group.h.directory.clone(),
    });
    driver.outbox.clear();
    driver.command(RunnerCommand::SendGroup {
        group_id: group.group_id.clone(),
        turn_id: group.round_id.clone(),
        target_bot_id: None,
        text: "Do not start before handoff".into(),
        model_id: "deepseek-v4-flash".into(),
        workspace_descriptor: descriptor(),
    });
    assert_eq!(
        driver.pending_group_id.as_deref(),
        Some(group.group_id.as_str())
    );
    driver.command(RunnerCommand::StopGroup {
        group_id: group.group_id.clone(),
    });
    assert!(driver.pending.is_none());
    assert!(driver.outbox.is_empty());
    let saved = group.saved();
    assert!(saved.groups[0].rounds[0].stopped);
    assert!(
        saved.groups[0].rounds[0]
            .replies
            .iter()
            .all(|r| r.run.is_none())
    );
}

#[test]
fn scoped_mutations_and_due_tasks_follow_owner_instead_of_selected_bot() {
    let group = GroupHarness::new();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: group.h.directory.clone(),
    });
    driver.outbox.clear();
    driver.command(RunnerCommand::SelectBot {
        bot_id: group.bot_id.clone(),
    });
    let mut default_profile = driver.saved.as_ref().unwrap().profile.clone();
    default_profile.name = "Renamed default".into();
    driver.command(RunnerCommand::ForBot {
        bot_id: DEFAULT_BOT_ID.into(),
        command: Box::new(RunnerCommand::SetProfile {
            expected_revision: driver.revision().unwrap(),
            profile: default_profile,
        }),
    });
    assert_eq!(
        driver.snapshot().store.unwrap().profile.name,
        "Planning Bot"
    );
    assert_eq!(
        driver.saved.as_ref().unwrap().profile.name,
        "Renamed default"
    );
    let id = uuid::Uuid::new_v4().to_string();
    let mut task = config();
    task.interval_minutes = Some(15);
    driver.command(RunnerCommand::ForBot {
        bot_id: group.bot_id.clone(),
        command: Box::new(RunnerCommand::CreateTask {
            expected_revision: driver.revision().unwrap(),
            task_id: id.clone(),
            config: task,
        }),
    });
    driver.command(RunnerCommand::SelectBot {
        bot_id: DEFAULT_BOT_ID.into(),
    });
    let due = driver.saved.as_ref().unwrap().bots[0].tasks[0]
        .next_due_ms
        .unwrap();
    driver.poll_due_at(due).unwrap();
    assert_eq!(driver.pending.as_ref().unwrap().task_id, id);
    driver.command(RunnerCommand::RunNow {
        task_id: id.clone(),
    });
    assert!(!driver.pending.as_ref().unwrap().due);
    let mut state = ShellState::with_test_models();
    state
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    state.set_default_workspace(descriptor()).unwrap();
    driver.command(RunnerCommand::Grant {
        task_id: id,
        state,
        foreground: true,
    });
    // Direct driver invocation has not run a real transport; the frozen owner
    // is already durable before native Begin could execute.
    assert_eq!(
        driver.active.as_ref().unwrap().claim.run.snapshot.name,
        "Planning Bot"
    );
    assert_eq!(
        driver.snapshot().active_bot_id.as_deref(),
        Some(group.bot_id.as_str())
    );
}
