use super::*;

#[test]
fn stop_during_recovery_begin_waits_for_fresh_evidence_before_cancelling() {
    let mut h = Harness::new();
    let _old_round = h.start();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: h.directory.clone(),
    });
    driver.outbox.clear();
    driver.command(RunnerCommand::Recover {
        task_id: h.task_id.clone(),
    });
    driver.command(RunnerCommand::Grant {
        task_id: h.task_id.clone(),
        state: h.restart_state(),
        foreground: true,
    });
    let begin = driver.outbox.remove(0);
    driver.command(RunnerCommand::Stop);
    assert!(driver.active.as_ref().unwrap().stopped);
    assert!(driver.state.is_some());
    assert!(
        !driver
            .events
            .iter()
            .any(|event| matches!(event, RunnerEvent::Returned { .. }))
    );
    driver.reply(begin, Ok(json!(true)));
    let reload = driver.outbox.remove(0);
    assert_eq!(reload.command.method, "loadSessionSnapshot");
    driver.reply(reload, Ok(h.snapshot_reply()));
    let workspace = driver.outbox.remove(0);
    assert_eq!(workspace.command.module, "LocalWorkspaces");
    driver.reply(
        workspace,
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
        Some("E_ASSISTANT_NATIVE_STOP_REQUESTED")
    );
}

#[test]
fn bot_store_failure_keeps_stop_fence_and_attention_until_real_session_cancel_settles() {
    let mut h = Harness::new();
    let round = h.start();
    let state_file = h.directory.join("assistant-v1.json");
    let saved = std::fs::read(&state_file).unwrap();
    std::fs::write(&state_file, b"unreadable local store").unwrap();
    h.command(RunnerCommand::Stop);
    let checkpoint = h.next();
    assert_eq!(checkpoint.command.method, "casPersistSession");
    wait_for(|| h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    assert!(
        !h.handle
            .snapshot()
            .state
            .unwrap()
            .owns_agent_command(&round.command)
    );
    assert!(h.handle.snapshot().message.is_some());
    // Restoring the disk here does not prove cancellation. Only the session
    // CAS and native cancellation/finalize replies below can settle the run.
    std::fs::write(&state_file, saved).unwrap();
    h.persist(checkpoint);
    let cancel = h.next();
    assert_eq!(cancel.command.method, "cancel_agent_attempt");
    round
        .reply
        .send(Ok(json!({"untrusted":"late provider result"})))
        .unwrap();
    h.finish_cancel(cancel);
    let saved = AssistantStore::open(&h.directory).unwrap().load().unwrap();
    assert_eq!(
        saved.tasks[0].last_run.as_ref().unwrap().status,
        AssistantRunStatus::Cancelled
    );
}
