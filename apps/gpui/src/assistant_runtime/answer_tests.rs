use super::test_fixture as fixture;
use super::*;

#[test]
fn only_the_current_valid_answer_emits_a_claim_bound_intake_ack() {
    let directory = std::env::temp_dir().join(format!("rish-answer-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&directory).unwrap();
    let directory = std::fs::canonicalize(directory).unwrap();
    let store = AssistantStore::open(&directory).unwrap();
    let created = store.create_task(0, tests::config(), now_ms()).unwrap();
    let task_id = created.tasks[0].id.clone();
    let requested = store
        .request_run(created.revision, &task_id, now_ms())
        .unwrap();
    let claim = store
        .claim(
            requested.revision,
            &task_id,
            AssistantClaimMode::Manual,
            now_ms(),
        )
        .unwrap();
    let mut driver = driver::Driver::new();
    driver.store = Some(store);
    driver.saved = Some(claim.snapshot.clone());
    driver.state = Some(fixture::question());
    driver.active = Some(driver::Active {
        claim: claim.clone(),
        recover: false,
        stopped: false,
        stop_persist_failed: false,
        expired: false,
        setup_pending: false,
        validated: true,
        sent: true,
        reconciled: true,
        cancel_after_recover: None,
    });
    let question = driver
        .state
        .as_ref()
        .unwrap()
        .agent_view()
        .unwrap()
        .question
        .unwrap();
    for (call_id, answer) in [("stale-question", "回答"), (question.id.as_str(), " ")] {
        driver.command(RunnerCommand::Answer {
            call_id: call_id.into(),
            answer: Some(answer.into()),
        });
        assert!(
            !driver
                .events
                .iter()
                .any(|event| matches!(event, RunnerEvent::AnswerAccepted { .. }))
        );
        assert!(driver.outbox.is_empty());
        driver.events.clear();
    }
    driver.command(RunnerCommand::Answer {
        call_id: question.id.clone(),
        answer: Some("回答".into()),
    });
    assert!(driver.events.iter().any(|event| matches!(event,
        RunnerEvent::AnswerAccepted {task_id:actual_task, run_id, call_id}
            if actual_task == &task_id && run_id == &claim.run.run_id && call_id == &question.id
    )));
    assert!(!driver.state.as_ref().unwrap().may_clear_sent_draft());
    assert_eq!(driver.outbox[0].command.method, "casPersistSession");
    assert!(
        driver
            .outbox
            .iter()
            .all(|operation| operation.command.method != "execute_agent_tool")
    );
    std::fs::remove_dir_all(directory).unwrap();
}
