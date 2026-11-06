use super::*;

impl GroupHarness {
    fn until_native_end(&mut self) -> Request {
        for _ in 0..32 {
            let request = self
                .h
                .requests
                .recv_timeout(Duration::from_secs(3))
                .unwrap();
            match request.command.method.as_str() {
                "handle" if request.command.args[0]["op"] == "end" => return request,
                "handle" if request.command.args[0]["op"] == "update" => {
                    request.reply.send(Ok(json!(true))).unwrap();
                }
                "casPersistSession" => self.h.persist(request),
                "finalize_agent_attempt" => {
                    let q = &request.command.args[0];
                    let value = json!({"schema_version":2,"status":"terminal","operation_id":q["operation_id"],
                        "cleanup_id":q["cleanup_id"],"transcript":q["transcript"]});
                    request.reply.send(Ok(value)).unwrap();
                }
                "discard_agent_attempt" => {
                    let q = &request.command.args[0];
                    let value = json!({"schema_version":2,"status":"discarded","operation_id":q["operation_id"],"cleanup_id":q["cleanup_id"]});
                    request.reply.send(Ok(value)).unwrap();
                }
                other => panic!("Unexpected operation before native end: {other}"),
            }
        }
        panic!("Native end was never reached")
    }

    fn assert_native_end_fenced(&self) {
        // Transport dispatch can wake the test receiver before the actor
        // publishes the snapshot from that same loop iteration.
        wait_for(|| self.h.handle.snapshot().active_task_id.is_none());
        let snapshot = self.h.handle.snapshot();
        assert!(snapshot.owns_writer);
        assert_eq!(
            snapshot.active_group_id.as_deref(),
            Some(self.group_id.as_str())
        );
        assert!(snapshot.active_task_id.is_none());
        let saved = self.saved();
        assert_eq!(
            saved.groups[0].rounds[0].replies[0]
                .run
                .as_ref()
                .unwrap()
                .status,
            AssistantRunStatus::Completed
        );
        assert!(saved.groups[0].rounds[0].replies[1].run.is_none());
        for request in self.h.requests.try_iter() {
            assert_eq!(request.command.module, "TaskExperience");
            assert_eq!(
                request.command.args[0]["op"], "update",
                "Next begin must await previous end"
            );
            request.reply.send(Ok(json!(true))).unwrap();
        }
    }
}

#[test]
fn next_member_waits_for_previous_native_end_acknowledgment() {
    let mut group = GroupHarness::new();
    let first = group.start(None);
    group.reply(first, "第一位回复已保存。");
    let end = group.until_native_end();
    group.assert_native_end_fenced();
    let prior_run = end.command.args[0]["runId"].clone();
    end.reply.send(Ok(json!(true))).unwrap();
    let second = group.until_round();
    assert_ne!(
        group.h.handle.snapshot().directory.unwrap().groups[0].rounds[0].replies[1]
            .run
            .as_ref()
            .unwrap()
            .run_id,
        prior_run.as_str().unwrap()
    );
    group.reply(second, "上一位 native end 确认后才开始。");
    group.h.finish_cleanup();
}

#[test]
fn failed_native_end_retries_same_run_without_repeating_provider_or_releasing_writer() {
    let mut group = GroupHarness::new();
    let first = group.start(None);
    group.reply(first, "已完成的回复不重发。");
    let end = group.until_native_end();
    let command = end.command.clone();
    end.reply
        .send(Err("Native display end reply unavailable".into()))
        .unwrap();
    wait_for(|| group.h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    group.assert_native_end_fenced();
    group.h.command(RunnerCommand::RecoverGroup {
        group_id: group.group_id.clone(),
    });
    let retry = group.until_native_end();
    assert_eq!(retry.command, command);
    // A completed native end can be acknowledged idempotently as false.
    retry.reply.send(Ok(json!(false))).unwrap();
    let second = group.until_round();
    group.reply(second, "第二位回复。");
    group.h.finish_cleanup();
}

#[test]
fn stopping_while_native_end_is_pending_never_starts_remaining_member() {
    let mut group = GroupHarness::new();
    let first = group.start(None);
    group.reply(first, "第一位回复。");
    let end = group.until_native_end();
    group.h.command(RunnerCommand::StopGroup {
        group_id: group.group_id.clone(),
    });
    wait_for(|| group.saved().groups[0].rounds[0].stopped);
    group.assert_native_end_fenced();
    end.reply.send(Ok(json!(true))).unwrap();
    wait_for(|| !group.h.handle.snapshot().owns_writer);
    assert!(group.saved().groups[0].rounds[0].replies[1].run.is_none());
}

#[test]
fn bot_scoped_active_task_fast_paths_cannot_recover_or_run_another_bots_task() {
    let group = GroupHarness::new();
    let store = AssistantStore::open(&group.h.directory).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    store
        .for_bot(&group.bot_id)
        .unwrap()
        .create_task_with_id(store.load().unwrap().revision, &id, config(), now_ms())
        .unwrap();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: group.h.directory.clone(),
    });
    driver.outbox.clear();
    driver.command(RunnerCommand::RunNow {
        task_id: id.clone(),
    });
    let mut state = ShellState::with_test_models();
    state
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    state.set_default_workspace(descriptor()).unwrap();
    driver.command(RunnerCommand::Grant {
        task_id: id.clone(),
        state,
        foreground: true,
    });
    let before = driver.outbox.len();
    for command in [
        RunnerCommand::Recover {
            task_id: id.clone(),
        },
        RunnerCommand::RunNow {
            task_id: id.clone(),
        },
    ] {
        driver.events.clear();
        driver.command(RunnerCommand::ForBot {
            bot_id: DEFAULT_BOT_ID.into(),
            command: Box::new(command),
        });
        assert!(driver.events.iter().any(|event|matches!(event,RunnerEvent::Error(message) if message == "This task belongs to another Bot")));
        assert_eq!(driver.outbox.len(), before);
        assert_eq!(driver.active.as_ref().unwrap().claim.task_id, id);
    }
}

#[test]
fn storage_failure_after_native_end_preserves_retry_identity_and_writer() {
    let mut group = GroupHarness::new();
    let first = group.start(None);
    group.reply(first, "第一位已完成，后续存储暂时不可读。");
    let end = group.until_native_end();
    group.assert_native_end_fenced();
    let command = end.command.clone();
    let file = group.h.directory.join("assistant-v1.json");
    let backup = group.h.directory.join("assistant-v1.held");
    std::fs::rename(&file, &backup).unwrap();
    std::fs::create_dir(&file).unwrap();
    end.reply.send(Ok(json!(true))).unwrap();
    wait_for(|| group.h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    let snapshot = group.h.handle.snapshot();
    assert!(snapshot.owns_writer);
    assert_eq!(
        snapshot.active_group_id.as_deref(),
        Some(group.group_id.as_str())
    );
    assert!(snapshot.active_task_id.is_none());
    std::fs::remove_dir(&file).unwrap();
    std::fs::rename(&backup, &file).unwrap();
    group.h.command(RunnerCommand::RecoverGroup {
        group_id: group.group_id.clone(),
    });
    let retry = group.until_native_end();
    assert_eq!(
        retry.command, command,
        "Retry the ended native run, not the model turn"
    );
    retry.reply.send(Ok(json!(false))).unwrap();
    let second = group.until_round();
    assert_eq!(
        group.saved().groups[0].rounds[0].replies[0].text.as_deref(),
        Some("第一位已完成，后续存储暂时不可读。")
    );
    group.reply(second, "第二位继续。");
    group.h.finish_cleanup();
}

#[test]
fn group_workspace_failure_waits_for_native_end_before_releasing_or_recovering() {
    let mut group = GroupHarness::new();
    group.h.command(RunnerCommand::SendGroup {
        group_id: group.group_id.clone(),
        turn_id: group.round_id.clone(),
        target_bot_id: None,
        text: "工作空间解析失败时保留群聊身份。".into(),
        model_id: "deepseek-v4-flash".into(),
        workspace_descriptor: descriptor(),
    });
    wait_for(|| group.h.handle.snapshot().status == RunnerStatus::WaitingForForeground);
    let mut state = ShellState::with_test_models();
    state
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    state.set_default_workspace(descriptor()).unwrap();
    group.h.command(RunnerCommand::Grant {
        task_id: group.group_id.clone(),
        state,
        foreground: true,
    });
    let begin = group.h.next();
    assert_eq!(begin.command.args[0]["op"], "begin");
    begin.reply.send(Ok(json!(true))).unwrap();
    let resolve = group.h.next();
    assert_eq!(resolve.command.method, "resolve");
    resolve
        .reply
        .send(Err("Workspace temporarily unavailable".into()))
        .unwrap();
    let end = group.until_native_end();
    wait_for(|| group.h.handle.snapshot().active_task_id.is_none());
    let snapshot = group.h.handle.snapshot();
    assert!(snapshot.owns_writer);
    assert_eq!(
        snapshot.active_group_id.as_deref(),
        Some(group.group_id.as_str())
    );
    assert_eq!(
        group
            .saved()
            .group_claim(&group.group_id)
            .unwrap()
            .claim
            .run
            .status,
        AssistantRunStatus::NeedsAttention
    );
    group.h.command(RunnerCommand::RecoverGroup {
        group_id: group.group_id.clone(),
    });
    wait_for(|| group.h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    for request in group.h.requests.try_iter() {
        assert_eq!(
            request.command.args[0]["op"], "update",
            "Pending end forbids a new begin or duplicate end"
        );
        request.reply.send(Ok(json!(true))).unwrap();
    }
    end.reply.send(Ok(json!(true))).unwrap();
    wait_for(|| !group.h.handle.snapshot().owns_writer);
    assert!(group.saved().groups[0].rounds[0].replies[1].run.is_none());
}

#[test]
fn foreground_loss_during_native_end_does_not_start_next_member() {
    let mut group = GroupHarness::new();
    let first = group.start(None);
    group.reply(first, "离开前第一位已完成。");
    let end = group.until_native_end();
    group.h.command(RunnerCommand::RevokeForeground);
    wait_for(|| !group.h.handle.snapshot().foreground);
    end.reply.send(Ok(json!(true))).unwrap();
    wait_for(|| !group.h.handle.snapshot().owns_writer);
    let saved = group.saved();
    assert!(saved.groups[0].rounds[0].is_pending());
    assert!(saved.groups[0].rounds[0].replies[1].run.is_none());
    assert!(
        group
            .h
            .handle
            .snapshot()
            .message
            .unwrap()
            .contains("Return to the group")
    );
}
