use super::*;

#[test]
fn first_run_uses_task_title_without_exposing_profile_context_as_conversation_name() {
    let mut h = Harness::new();
    let store = AssistantStore::open(&h.directory).unwrap();
    let initial = store.load().unwrap();
    let profile = store
        .set_profile(
            initial.revision,
            AssistantProfile {
                name: "本机验证助手".into(),
                notes: "请使用中文汇报。".into(),
                avatar: Some(AssistantAvatar {
                    id: "c0417c3a-2161-4d6b-8aac-84611d677ad6".into(),
                    sha256: "a".repeat(64),
                    mime_type: "image/png".into(),
                    width: 512,
                    height: 512,
                    byte_length: 1024,
                }),
                runtime: RuntimeSpec::pi(),
                ..Default::default()
            },
        )
        .unwrap();
    let mut task = profile.tasks[0].config();
    task.title = "跟进项目".repeat(9);
    let saved = store
        .update_task(profile.revision, &h.task_id, task.clone(), now_ms())
        .unwrap();
    let conversation_id = saved.tasks[0].conversation_id.clone();
    let round = h.start();
    let conversation = h.saved_session.as_ref().unwrap()["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|conversation| conversation["id"] == conversation_id)
        .unwrap();
    assert_eq!(conversation["title"], task.title);
    assert_eq!(conversation["title_source"], "manual");
    let prompt = conversation["messages"][0]["text"].as_str().unwrap();
    assert!(prompt.ends_with("Assistant: 本机验证助手\nUser-provided context:\n请使用中文汇报。\n\nTask:\nInspect the files"));
    assert!(prompt.contains(&profile.profile.soul));
    h.command(RunnerCommand::Stop);
    let checkpoint = h.next();
    h.persist(checkpoint);
    let cancel = h.next();
    h.finish_cancel(cancel);
    let _ = round
        .reply
        .send(Err("late round after cancellation".into()));
}
