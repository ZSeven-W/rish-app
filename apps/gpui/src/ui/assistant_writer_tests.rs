use super::*;
use crate::assistant_runtime::test_fixture::*;
use crate::assistant_runtime::{RunnerSnapshot, RunnerStatus};
use gpui::{TestAppContext, size};
use rish_shell_core::assistant_store::*;

fn with_shell(test: impl FnOnce(&mut Shell, &mut Context<Shell>)) {
    let mut cx = TestAppContext::single();
    let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    window
        .update(&mut cx, |shell, _, cx| {
            shell.page = Page::Settings;
            shell.state = loaded();
            test(shell, cx);
        })
        .unwrap();
}

fn owned_snapshot(state: ShellState) -> RunnerSnapshot {
    let a = &state.raw_session()["conversations"][0]["attempts"][0];
    let run: AssistantRun = serde_json::from_value(json!({
        "run_id":"run-1", "ids":{
            "turn_id":a["turn_id"], "attempt_id":a["attempt_id"],
            "round_id":a["agent"]["round_lineage"]["round_id"],
            "user_message_id":state.raw_session()["conversations"][0]["turns"][0]["user_message_id"], "assistant_message_id":"assistant-message"
        }, "started_at_ms":1, "status":"running", "finished_at_ms":null,
        "result_summary":null,"failure_code":null,
        "snapshot":{"name":"Rish","notes":"","instructions":"测试",
            "model_id":"deepseek-v4-flash", "workspace_binding":{},"workspace_descriptor":{}}
    }))
    .unwrap();
    let config =
        AssistantTaskConfig::manual("Task", "测试", "deepseek-v4-flash", json!({}), json!({}));
    RunnerSnapshot {
        state: Some(state),
        active_task_id: Some("task-1".into()),
        owns_writer: true,
        foreground: true,
        status: RunnerStatus::NeedsAttention,
        store: Some(AssistantSnapshot {
            tasks: vec![AssistantTask {
                id: "task-1".into(),
                title: config.title,
                instructions: config.instructions,
                conversation_id: CHAT.into(),
                workspace_binding: config.workspace_binding,
                workspace_descriptor: config.workspace_descriptor,
                model_id: config.model_id,
                interval_minutes: None,
                runtime: None,
                enabled: true,
                next_due_ms: None,
                pending_manual: false,
                last_run: Some(run),
            }],
            ..Default::default()
        }),
        ..Default::default()
    }
}
fn deliver(shell: &mut Shell, snapshot: RunnerSnapshot, cx: &mut Context<Shell>) {
    shell.accept_assistant_event(RunnerEvent::Snapshot(snapshot), cx);
}

#[test]
fn handoff_freezes_before_delivery_and_only_returned_releases_the_writer() {
    with_shell(|shell, cx| {
        let (handle, mut commands) = RunnerHandle::test_client(RunnerSnapshot::default());
        shell.assistant_runner = Some(handle);
        shell.assistant.snapshot.foreground = true;
        shell.assistant_handoff = Some("task-1".into());
        shell.try_assistant_handoff(cx);
        assert!(shell.assistant_writer_lease);
        assert!(shell.assistant_handoff_state.is_some());
        let RunnerCommand::Grant {
            task_id,
            state,
            foreground,
        } = commands.try_recv().unwrap()
        else {
            panic!("no Grant")
        };
        assert_eq!(task_id, "task-1");
        assert!(foreground);
        assert!(!state.is_busy());
        let before = shell.state.raw_session().clone();
        deliver(
            shell,
            RunnerSnapshot {
                state: Some(ShellState::new()),
                ..Default::default()
            },
            cx,
        );
        assert!(
            shell.assistant_writer_lease,
            "queued idle snapshot cannot return authority"
        );
        assert_eq!(shell.state.raw_session(), &before);
        assert!(shell.conversation_switch_blocked(true, cx));
        // Existing controls may build a mutation before calling commit. The
        // handoff copy must roll it back even before the actor publishes state.
        let command = shell.state.rename_conversation(CHAT, "must not save");
        assert!(shell.state.is_busy());
        shell.commit(command, cx);
        assert!(!shell.state.is_busy());
        assert_eq!(shell.state.raw_session(), &before);
        assert!(commands.try_recv().is_err());
        shell.accept_assistant_event(RunnerEvent::Returned { state }, cx);
        assert!(!shell.assistant_writer_lease);
        assert!(shell.assistant_handoff_state.is_none());
    });
}

#[test]
fn a_disconnected_handoff_restores_local_authority_without_losing_state() {
    with_shell(|shell, cx| {
        let (handle, commands) = RunnerHandle::test_client(RunnerSnapshot::default());
        drop(commands);
        shell.assistant_runner = Some(handle);
        shell.assistant.snapshot.foreground = true;
        shell.assistant_handoff = Some("task-1".into());
        let before = shell.state.raw_session().clone();
        shell.try_assistant_handoff(cx);
        assert!(!shell.assistant_writer_lease);
        assert!(shell.assistant_handoff_state.is_none());
        assert_eq!(shell.state.raw_session(), &before);
        assert!(shell.assistant.error.is_some());
    });
}

#[test]
fn handoff_rejection_preserves_the_other_actor_writer_and_newer_request() {
    with_shell(|shell, cx| {
        let snapshot = owned_snapshot(question());
        let expected = snapshot.state.as_ref().unwrap().raw_session().clone();
        let (handle, _commands) = RunnerHandle::test_client(snapshot);
        shell.assistant_runner = Some(handle);
        shell.assistant_writer_lease = true;
        shell.assistant_handoff = Some("newer-task".into());
        shell.accept_assistant_event(
            RunnerEvent::HandoffRejected {
                task_id: "older-task".into(),
                message: "Already owned".into(),
            },
            cx,
        );
        assert!(shell.assistant_writer_lease);
        assert_eq!(shell.assistant_handoff.as_deref(), Some("newer-task"));
        assert_eq!(shell.state.raw_session(), &expected);
    });
}

#[test]
fn primary_and_agent_callbacks_cannot_mutate_a_leased_session() {
    with_shell(|shell, cx| {
        let (state, round) = provider_round();
        shell.state = state;
        shell.assistant_writer_lease = true;
        let before = shell.state.raw_session().clone();
        shell.notice = Some("current".into());
        for reply in [
            Reply::Catalog,
            Reply::CustomProviderCatalog,
            Reply::Load,
            Reply::Persist,
            Reply::Completion,
            Reply::Cancel,
        ] {
            shell.accept(reply, Err("late callback".into()), cx);
            assert_eq!(shell.notice.as_deref(), Some("current"));
            assert_eq!(shell.state.raw_session(), &before);
        }
        assert!(shell.state.owns_agent_command(&round));
        shell.agent_requests.push(round.clone());
        shell.accept_agent_reply(round.clone(), Err("late Agent callback".into()), cx);
        assert!(shell.state.owns_agent_command(&round));
        assert!(!shell.state.agent_view().unwrap().recoverable);
        assert!(shell.agent_requests.is_empty());
        assert_eq!(shell.notice.as_deref(), Some("current"));
    });
}

#[test]
fn startup_holds_recovery_until_store_is_examined_and_saved_claim_is_reconciled() {
    with_shell(|shell, _| {
        let (handle, _commands) = RunnerHandle::test_client(RunnerSnapshot::default());
        shell.assistant_runner = Some(handle);
        assert!(
            shell.assistant_blocks_session_recovery(),
            "unexamined durable Stop must win startup"
        );
        shell.assistant.snapshot.store = Some(AssistantSnapshot::default());
        assert!(!shell.assistant_blocks_session_recovery());
        shell.assistant_storage_loading = true;
        assert!(shell.assistant_blocks_session_recovery());
        shell.assistant_storage_loading = false;
        let snapshot = owned_snapshot(question());
        shell.state = snapshot.state.clone().unwrap();
        shell.assistant.snapshot = snapshot;
        assert!(shell.assistant_blocks_session_recovery());
        shell.assistant.snapshot.store.as_mut().unwrap().tasks[0]
            .last_run
            .as_mut()
            .unwrap()
            .ids
            .attempt_id = "different-attempt".into();
        assert!(
            !shell.assistant_blocks_session_recovery(),
            "unrelated ordinary chats can recover"
        );
    });
}

#[test]
fn queued_snapshot_and_intent_do_not_clear_answer_before_its_committed_receipt() {
    with_shell(|shell, cx| {
        let mut state = question();
        let question = state.agent_view().unwrap().question.unwrap();
        let snapshot = owned_snapshot(state.clone());
        let (handle, _commands) = RunnerHandle::test_client(snapshot.clone());
        shell.assistant_runner = Some(handle);
        shell.state = state.clone();
        shell.assistant.apply_snapshot(snapshot.clone());
        shell.assistant_writer_lease = true;
        shell.composer.update(cx, |input, cx| {
            input.set_text("必须保留的中文回答".into(), cx)
        });
        assert!(shell.mark_assistant_answer(&question));
        // This snapshot was queued before the actor consumed Answer.
        assert!(state.may_clear_sent_draft());
        deliver(shell, snapshot.clone(), cx);
        assert_eq!(shell.composer.read(cx).text(), "必须保留的中文回答");
        shell.accept_assistant_event(
            RunnerEvent::AnswerAccepted {
                task_id: "task-1".into(),
                run_id: "run-1".into(),
                call_id: question.id.clone(),
            },
            cx,
        );
        deliver(shell, snapshot.clone(), cx);
        assert_eq!(
            shell.composer.read(cx).text(),
            "必须保留的中文回答",
            "intake alone is not a save"
        );
        let checkpoint = state
            .answer_agent_question(&question.id, Some("必须保留的中文回答"), NOW)
            .unwrap()
            .unwrap();
        deliver(shell, owned_snapshot(state.clone()), cx);
        assert_eq!(shell.composer.read(cx).text(), "必须保留的中文回答");
        let execute = persist(&mut state, checkpoint).unwrap();
        deliver(shell, owned_snapshot(state.clone()), cx);
        assert_eq!(
            shell.composer.read(cx).text(),
            "必须保留的中文回答",
            "intent contains no answer bytes"
        );
        let receipt = state
            .accept_agent_result(&execute, executed(&execute.args[0], "ok"), NOW)
            .unwrap()
            .unwrap();
        deliver(shell, owned_snapshot(state.clone()), cx);
        assert_eq!(
            shell.composer.read(cx).text(),
            "必须保留的中文回答",
            "receipt candidate is not committed"
        );
        persist(&mut state, receipt);
        deliver(shell, owned_snapshot(state), cx);
        assert_eq!(shell.composer.read(cx).text(), "");
        assert!(shell.assistant_answer.is_none());
    });
}

#[test]
fn an_ack_for_another_run_or_question_never_accepts_this_answer() {
    with_shell(|shell, cx| {
        let state = question();
        let question = state.agent_view().unwrap().question.unwrap();
        shell
            .assistant
            .apply_snapshot(owned_snapshot(state.clone()));
        shell.assistant_writer_lease = true;
        assert!(shell.mark_assistant_answer(&question));
        for (task_id, run_id, call_id) in [
            ("task-2", "run-1", question.id.as_str()),
            ("task-1", "run-2", question.id.as_str()),
            ("task-1", "run-1", "stale-question"),
        ] {
            shell.accept_assistant_event(
                RunnerEvent::AnswerAccepted {
                    task_id: task_id.into(),
                    run_id: run_id.into(),
                    call_id: call_id.into(),
                },
                cx,
            );
            assert!(!shell.assistant_answer.as_ref().unwrap().accepted);
        }
        shell
            .composer
            .update(cx, |input, cx| input.set_text("保留回答".into(), cx));
        shell.accept_assistant_event(RunnerEvent::Returned { state: loaded() }, cx);
        assert_eq!(shell.composer.read(cx).text(), "保留回答");
    });
}

#[test]
fn actor_controls_forward_exact_ids_without_mutating_the_display_copy() {
    with_shell(|shell, cx| {
        let snapshot = owned_snapshot(question());
        let (handle, mut commands) = RunnerHandle::test_client(snapshot.clone());
        shell.assistant_runner = Some(handle);
        shell.assistant.apply_snapshot(snapshot.clone());
        shell.state = snapshot.state.unwrap();
        shell.assistant_writer_lease = true;
        let before = shell.state.raw_session().clone();
        shell.decide_agent("approval-token", "denied", cx);
        assert!(
            matches!(commands.try_recv().unwrap(), RunnerCommand::Approval {approval_id, decision} if approval_id=="approval-token" && decision=="denied")
        );
        shell.answer_agent("exact-question", Some("回答"), cx);
        assert!(
            matches!(commands.try_recv().unwrap(), RunnerCommand::Answer {call_id, answer} if call_id=="exact-question" && answer.as_deref()==Some("回答"))
        );
        shell.stop_agent_task(cx);
        assert!(matches!(commands.try_recv().unwrap(), RunnerCommand::Stop));
        assert_eq!(shell.state.raw_session(), &before);
    });
}

#[test]
fn committed_receipt_cannot_clear_a_different_run_or_reused_call_in_another_round() {
    with_shell(|shell, cx| {
        let mut state = question();
        let question = state.agent_view().unwrap().question.unwrap();
        shell
            .assistant
            .apply_snapshot(owned_snapshot(state.clone()));
        assert!(shell.mark_assistant_answer(&question));
        shell.assistant_answer.as_mut().unwrap().accepted = true;
        let checkpoint = state
            .answer_agent_question(&question.id, Some("回答"), NOW)
            .unwrap()
            .unwrap();
        let execute = persist(&mut state, checkpoint).unwrap();
        let checkpoint = state
            .accept_agent_result(&execute, executed(&execute.args[0], "ok"), NOW)
            .unwrap()
            .unwrap();
        persist(&mut state, checkpoint);
        let mut snapshot = owned_snapshot(state);
        assert!(
            shell
                .assistant_answer
                .as_ref()
                .unwrap()
                .is_committed(&snapshot)
        );
        shell.assistant_answer.as_mut().unwrap().round += 1;
        assert!(
            !shell
                .assistant_answer
                .as_ref()
                .unwrap()
                .is_committed(&snapshot)
        );
        shell.assistant_answer.as_mut().unwrap().round -= 1;
        snapshot.store.as_mut().unwrap().tasks[0]
            .last_run
            .as_mut()
            .unwrap()
            .run_id = "newer-run".into();
        assert!(
            !shell
                .assistant_answer
                .as_ref()
                .unwrap()
                .is_committed(&snapshot)
        );
        shell
            .composer
            .update(cx, |input, cx| input.set_text("保留回答".into(), cx));
        deliver(shell, snapshot, cx);
        assert_eq!(shell.composer.read(cx).text(), "保留回答");
    });
}

#[test]
fn pending_user_send_or_workspace_intent_keeps_handoff_waiting() {
    with_shell(|shell, cx| {
        let (handle, mut commands) = RunnerHandle::test_client(RunnerSnapshot::default());
        shell.assistant_runner = Some(handle);
        shell.assistant.snapshot.foreground = true;
        shell.assistant_handoff = Some("task-1".into());
        shell.send_after_create = true;
        shell.try_assistant_handoff(cx);
        assert!(!shell.assistant_writer_lease);
        assert!(commands.try_recv().is_err());
        shell.send_after_create = false;
        shell.conversation_workspace.intent = Some(conversation_workspace::WorkspaceIntent::Send);
        shell.try_assistant_handoff(cx);
        assert!(!shell.assistant_writer_lease);
        assert!(commands.try_recv().is_err());
        shell.conversation_workspace.intent = None;
        shell.try_assistant_handoff(cx);
        assert!(shell.assistant_writer_lease);
        assert!(matches!(
            commands.try_recv().unwrap(),
            RunnerCommand::Grant { .. }
        ));
    });
}

fn executed(q: &Value, outcome: &str) -> Value {
    let mut t = q["transcript"].clone();
    t["generation"] = json!(t["generation"].as_u64().unwrap() + 1);
    t["transcript_sha256"] = json!("1".repeat(64));
    t["transcript_bytes"] = json!(200);
    json!({"schema_version":2,"status":if outcome=="ok"{"completed"}else{outcome},"operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],"round_id":q["round_id"],"round_index":q["round_index"],"call_index":q["call_index"],"call_id":q["call_id"],"name":q["name"],"idempotency_key":q["idempotency_key"],"result_execution_revision":2,"transcript":t,"effect_may_have_occurred":true,"receipt":{"schema_version":1,"call_id":q["call_id"],"name":q["name"],"arguments_sha256":q["arguments_sha256"],"result_sha256":"2".repeat(64),"result_bytes":20,"truncated":false,"duration_ms":1,"outcome":outcome,"failure_code":null,"approval_reference":q["approval_reference"]}})
}
