use super::*;

#[test]
fn personal_identity_and_manual_memory_commands_keep_one_durable_record() {
    let directory =
        std::env::temp_dir().join(format!("rish-personal-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&directory).unwrap();
    let directory = std::fs::canonicalize(directory).unwrap();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: directory.clone(),
    });
    driver.outbox.clear();
    driver.command(RunnerCommand::EnsureConversation {
        expected_revision: 0,
    });
    let first = driver.saved.clone().unwrap();
    assert!(first.conversation_id.is_some());
    driver.command(RunnerCommand::EnsureConversation {
        expected_revision: 0,
    });
    assert_eq!(driver.saved.as_ref().unwrap(), &first);
    let id = uuid::Uuid::new_v4().to_string();
    let create = RunnerCommand::CreateMemory {
        expected_revision: first.revision,
        memory_id: id.clone(),
        title: "回答偏好".into(),
        content: "请用简短中文回答".into(),
        kind: AssistantMemoryKind::Preference,
    };
    driver.command(create.clone());
    let created = driver.saved.clone().unwrap();
    driver.command(create);
    assert_eq!(driver.saved.as_ref().unwrap(), &created);
    assert_eq!(created.memories.len(), 1);
    driver.command(RunnerCommand::RememberMemory {
        expected_revision: created.revision,
        memory_id: Some(id.clone()),
        title: "回答偏好".into(),
        content: "请先给结论".into(),
        kind: AssistantMemoryKind::Preference,
    });
    let updated = driver.saved.clone().unwrap();
    driver.command(RunnerCommand::ForgetMemory {
        expected_revision: updated.revision,
        memory_id: id,
    });
    let reopened = AssistantStore::open(&directory).unwrap().load().unwrap();
    assert!(reopened.memories.is_empty());
    assert_eq!(reopened.conversation_id, first.conversation_id);
    assert_eq!(reopened.profile.soul, first.profile.soul);
    assert!(
        driver.outbox.is_empty(),
        "metadata edits never perform provider/tool work"
    );
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn stable_creation_id_confirms_lost_ack_without_duplicating_or_rewriting_task() {
    let directory = std::env::temp_dir().join(format!("rish-create-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&directory).unwrap();
    let directory = std::fs::canonicalize(directory).unwrap();
    let mut driver = driver::Driver::new();
    driver.command(RunnerCommand::Initialize {
        directory: directory.clone(),
    });
    driver.outbox.clear();
    let task_id = uuid::Uuid::new_v4().to_string();
    let mut config = tests::config();
    config.interval_minutes = Some(15);
    let command = RunnerCommand::CreateTask {
        expected_revision: 0,
        task_id: task_id.clone(),
        config: config.clone(),
    };
    driver.command(command.clone());
    let first = driver.saved.clone().unwrap();
    assert_eq!(first.tasks.len(), 1);
    assert_eq!(first.tasks[0].id, task_id);
    let conversation_id = first.tasks[0].conversation_id.clone();
    // Another legitimate write can happen while the creation acknowledgment
    // is lost. Retrying the same identity only confirms the existing task.
    driver.command(RunnerCommand::SetProfile {
        expected_revision: first.revision,
        profile: AssistantProfile {
            name: "Updated name".into(),
            notes: String::new(),
            ..Default::default()
        },
    });
    let before_retry = driver.saved.clone().unwrap();
    driver.command(command);
    assert_eq!(driver.saved.as_ref().unwrap(), &before_retry);
    assert_eq!(
        driver.saved.as_ref().unwrap().tasks[0].conversation_id,
        conversation_id
    );
    assert!(driver.outbox.is_empty());
    assert!(
        driver.pending.is_none(),
        "creation alone does not schedule execution now"
    );
    // Reusing an ID cannot sneak in different instructions after a lost ack.
    config.instructions = "A different task".into();
    driver.events.clear();
    driver.command(RunnerCommand::CreateTask {
        expected_revision: 0,
        task_id,
        config,
    });
    assert!(
        driver
            .events
            .iter()
            .any(|event| matches!(event, RunnerEvent::Error(_)))
    );
    assert_eq!(
        AssistantStore::open(&directory).unwrap().load().unwrap(),
        before_retry
    );
    std::fs::remove_dir_all(directory).unwrap();
}
