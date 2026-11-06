use super::*;

fn assert_waiting_on_first_member(group: &GroupHarness) {
    wait_for(|| group.h.handle.snapshot().status == RunnerStatus::NeedsAttention);
    let saved = group.saved();
    let round = &saved.groups[0].rounds[0];
    assert!(round.replies[0].run.as_ref().unwrap().status.is_active());
    assert!(round.replies[1].run.is_none());
    assert!(round.replies.iter().all(|r| r.text.is_none()));
    for request in group.h.requests.try_iter() {
        assert_eq!(
            request.command.module, "TaskExperience",
            "No model or tool may pass the decision gate"
        );
        assert_eq!(request.command.args[0]["op"], "update");
        request.reply.send(Ok(json!(true))).unwrap();
    }
}

#[test]
fn group_question_holds_other_members_until_answer_and_current_reply_are_committed() {
    let mut group = GroupHarness::new();
    let request = group.start(None);
    let first_lane = request.command.args[0]["conversation_id"].clone();
    group.h.tool_batch(request, "ask_user");
    assert_waiting_on_first_member(&group);
    let question = group
        .h
        .handle
        .snapshot()
        .state
        .unwrap()
        .agent_view()
        .unwrap()
        .question
        .unwrap();
    group.h.command(RunnerCommand::Answer {
        call_id: question.id,
        answer: Some("a".into()),
    });
    let intent = group.h.next();
    group.h.persist(intent);
    let execute = group.h.next();
    assert_eq!(execute.command.method, "execute_agent_tool");
    assert_eq!(execute.command.args[0]["conversation_id"], first_lane);
    execute
        .reply
        .send(Ok(super::super::pi_actor::executed(
            &execute.command.args[0],
        )))
        .unwrap();
    let checkpoint = group.h.next();
    group.h.persist(checkpoint);
    let begin = group.h.next();
    group.h.persist(begin);
    let follow_up = group.h.next();
    assert_eq!(follow_up.command.method, "complete_agent_round_v2");
    assert_eq!(follow_up.command.args[0]["round_index"], 1);
    assert_eq!(follow_up.command.args[0]["conversation_id"], first_lane);
    assert!(group.saved().groups[0].rounds[0].replies[1].run.is_none());
    group.reply(follow_up, "确认采用方案 A。");
    let second = group.until_round();
    assert_ne!(second.command.args[0]["conversation_id"], first_lane);
    group.reply(second, "我会基于已确认的方案继续。");
    group.h.finish_cleanup();
    assert!(!group.saved().groups[0].rounds[0].is_pending());
}

#[test]
fn group_approval_blocks_other_members_and_denial_does_not_execute_write() {
    let mut group = GroupHarness::new();
    let request = group.start(None);
    let first_lane = request.command.args[0]["conversation_id"].clone();
    group.h.tool_batch(request, "write_file");
    assert_waiting_on_first_member(&group);
    let approval = group
        .h
        .handle
        .snapshot()
        .state
        .unwrap()
        .agent_view()
        .unwrap()
        .approval
        .unwrap();
    group.h.command(RunnerCommand::Approval {
        approval_id: approval.approval_id,
        decision: "denied".into(),
    });
    let checkpoint = group.h.next();
    group.h.persist(checkpoint);
    let bind = group.h.next();
    assert_eq!(bind.command.method, "bind_agent_approval");
    let q = &bind.command.args[0];
    let conversation = group.h.saved_session.as_ref().unwrap()["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == first_lane)
        .unwrap();
    let attempt = conversation["attempts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["attempt_id"] == q["attempt_id"])
        .unwrap();
    let call = &attempt["agent"]["batch"][0];
    let mut transcript = attempt["agent"]["transcript"].clone();
    transcript["generation"] = json!(2);
    transcript["transcript_sha256"] = json!("9".repeat(64));
    transcript["transcript_bytes"] = json!(300);
    let result = json!({"schema_version":2,"status":"bound","operation_id":q["operation_id"],"task_id":q["task_id"],"attempt_id":q["attempt_id"],
        "round_id":q["round_id"],"call_index":0,"call_id":"call-1","decision":"denied","approval_reference":null,"grant":null,
        "result_batch_revision":1,"observed_checkpoint":q["committed_checkpoint"],"receipt":super::super::pi_actor::tool_receipt(call,"denied"),"transcript":transcript});
    bind.reply.send(Ok(result)).unwrap();
    let checkpoint = group.h.next();
    group.h.persist(checkpoint);
    let begin = group.h.next();
    group.h.persist(begin);
    let follow_up = group.h.next();
    assert_eq!(
        follow_up.command.method, "complete_agent_round_v2",
        "Denied writes must never be dispatched"
    );
    assert_eq!(follow_up.command.args[0]["conversation_id"], first_lane);
    assert!(group.saved().groups[0].rounds[0].replies[1].run.is_none());
    group.reply(follow_up, "已保留文件，没有写入。");
    let second = group.until_round();
    group.reply(second, "继续提供建议。");
    group.h.finish_cleanup();
}

#[test]
fn native_memory_write_during_group_reply_does_not_conflict_or_change_frozen_speaker() {
    let mut group = GroupHarness::new();
    let request = group.start(None);
    let original = group.saved().groups[0].rounds[0].replies[0]
        .run
        .as_ref()
        .unwrap()
        .snapshot
        .clone();
    let store = AssistantStore::open(&group.h.directory).unwrap();
    let memory_id = uuid::Uuid::new_v4().to_string();
    let saved = store
        .create_memory_with_id(
            store.load().unwrap().revision,
            &memory_id,
            "Explicit preference",
            "Reply in Chinese",
            AssistantMemoryKind::Preference,
            now_ms(),
        )
        .unwrap();
    let mut profile = saved.profile.clone();
    profile.name = "Edited while responding".into();
    store.set_profile(saved.revision, profile).unwrap();
    // Intentionally send no RefreshStore: finish must reconcile the latest
    // global revision itself, just as a native tool receipt may arrive first.
    group.reply(request, "仍由本轮冻结的助手发言。");
    let second = group.until_round();
    let saved = group.saved();
    assert_eq!(saved.memories[0].id, memory_id);
    assert!(saved.bots[0].memories.is_empty());
    assert_eq!(
        saved.groups[0].rounds[0].replies[0]
            .run
            .as_ref()
            .unwrap()
            .snapshot,
        original
    );
    assert_eq!(
        saved.groups[0].rounds[0].replies[1]
            .run
            .as_ref()
            .unwrap()
            .snapshot
            .name,
        "Planning Bot"
    );
    group.reply(second, "另一个助手继续。");
    group.h.finish_cleanup();
    assert_eq!(group.saved().profile.name, "Edited while responding");
}

#[test]
fn expired_group_recovery_preserves_expiry_cancellation_intent() {
    for code in [
        "E_ASSISTANT_BACKGROUND_EXPIRED",
        "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED",
    ] {
        let mut group = GroupHarness::new();
        let request = group.start(None);
        let claim = group.saved().group_claim(&group.group_id).unwrap();
        let store = AssistantStore::open(&group.h.directory).unwrap();
        store
            .mark_group_attention(
                store.load().unwrap().revision,
                &group.group_id,
                &claim.claim.run.run_id,
                code,
                now_ms(),
            )
            .unwrap();
        let mut driver = driver::Driver::new();
        driver.command(RunnerCommand::Initialize {
            directory: group.h.directory.clone(),
        });
        driver.outbox.clear();
        driver.command(RunnerCommand::RecoverGroup {
            group_id: group.group_id.clone(),
        });
        assert_eq!(
            driver.pending.as_ref().unwrap().cancel_after_recover,
            Some(true)
        );
        driver.command(RunnerCommand::Grant {
            task_id: group.group_id.clone(),
            state: group.h.restart_state(),
            foreground: true,
        });
        assert!(driver.active.as_ref().unwrap().expired);
        group.stop(request);
    }
}
