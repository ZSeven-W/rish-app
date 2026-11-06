use crate::*;
const A: &str = "845d980b-8acd-4710-a54c-7975b6839024";
const B: &str = "e8ab9203-333e-4eb4-82a1-6423e90dc042";
const CHAT: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const CHAT2: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const NOW: &str = "2026-10-15T01:00:00.000Z";
fn descriptor(id: &str) -> Value {
    json!({"schema_version":2,"workspace_id":id,"binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})
}
fn ready() -> ShellState {
    let mut s = ShellState::with_test_models();
    s.load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    s
}
fn install(s: &mut ShellState) -> Option<RuntimeCommand> {
    let p = s.pending.as_ref().unwrap();
    let proof = json!({"status":"committed","snapshot":{"schema_version":1,"generation":s.authority["snapshot"]["generation"].as_u64().unwrap_or(0)+1,"session_sha256":p.digest}});
    s.accept_persist(proof).unwrap()
}
fn chat() -> ShellState {
    let mut s = ready();
    s.set_default_workspace(descriptor(A)).unwrap();
    s.create_conversation(CHAT, NOW, "deepseek-v4-flash")
        .unwrap();
    install(&mut s);
    s
}
fn load(raw: Value) -> ShellState {
    let bytes = raw.to_string();
    let mut s = ShellState::with_test_models();
    s.load_snapshot(json!({"schema_version":1,"status":"present","session_json":bytes,"snapshot":{"schema_version":1,"generation":4,"session_sha256":session_schema::candidate_digest(bytes.as_bytes()).unwrap()}})).unwrap();
    s
}
fn legacy_unbound(c: &mut Value) {
    c["workspace_id"] = Value::Null;
    c["workspace_binding"] = Value::Null;
    for a in c["attempts"].as_array_mut().unwrap() {
        a["workspace_id"] = Value::Null;
        a["workspace_binding_revision"] = Value::Null;
    }
}

#[test]
fn creation_requires_native_default_and_publishes_binding_in_the_same_cas() {
    let mut s = ready();
    assert!(s
        .create_conversation(CHAT, NOW, "deepseek-v4-flash")
        .is_err());
    assert!(s.pending.is_none());
    let mut workspace = descriptor(A);
    workspace["project_id"] = json!(CHAT2);
    s.set_default_workspace(workspace).unwrap();
    let command = s
        .create_conversation(CHAT, NOW, "deepseek-v4-flash")
        .unwrap();
    let candidate: Value =
        serde_json::from_str(command.args[0]["candidate_json"].as_str().unwrap()).unwrap();
    assert_eq!(
        candidate["conversations"][0]["workspace_binding"],
        workspace_binding(&descriptor(A)).unwrap()
    );
    assert!(candidate["conversations"][0]["project_id"].is_null());
    assert!(s.active_workspace_binding().is_none());
    install(&mut s);
    assert_eq!(
        s.active_workspace_binding(),
        Some(&workspace_binding(&descriptor(A)).unwrap())
    );
}
#[test]
fn task_title_is_bounded_and_committed_with_workspace_before_first_agent_message() {
    let mut s = ready();
    s.set_default_workspace(descriptor(A)).unwrap();
    let raw_title = format!("  检查项目\n{}\u{0}  ", "长期跟进".repeat(30));
    let expected = rish_agent_core::name_policy::automatic_title(&raw_title);
    let command = s
        .create_task_conversation(CHAT, NOW, "deepseek-v4-flash", &raw_title)
        .unwrap();
    let candidate: Value =
        serde_json::from_str(command.args[0]["candidate_json"].as_str().unwrap()).unwrap();
    assert_eq!(candidate["conversations"][0]["title"], expected);
    assert_eq!(candidate["conversations"][0]["title_source"], "manual");
    assert_eq!(
        candidate["conversations"][0]["workspace_binding"],
        workspace_binding(&descriptor(A)).unwrap()
    );
    assert!(expected.len() <= 120);
    assert!(!expected.chars().any(char::is_control));
    assert!(
        s.conversations().is_empty(),
        "creation is not visible before CAS"
    );
    install(&mut s);
    let prompt = "Assistant: 本机助手\nUser-provided context:\n这是长期记忆。\n\nTask:\n请检查项目";
    s.prepare_agent_send(prompt, &TurnIds::new(), NOW).unwrap();
    assert_eq!(
        s.pending.as_ref().unwrap().candidate["conversations"][0]["title"],
        expected
    );
    install(&mut s);
    let saved = &s.raw_session()["conversations"][0];
    assert_eq!(saved["title"], expected);
    assert_eq!(saved["title_source"], "manual");
    assert_eq!(saved["messages"][0]["text"], prompt);
}
#[test]
fn ordinary_new_chat_still_derives_its_title_from_the_first_agent_message() {
    let mut s = chat();
    assert_eq!(s.raw_session()["conversations"][0]["title"], "New chat");
    let body = "普通对话仍然从第一条消息生成标题。";
    s.prepare_agent_send(body, &TurnIds::new(), NOW).unwrap();
    install(&mut s);
    assert_eq!(s.raw_session()["conversations"][0]["title"], body);
    assert_eq!(s.raw_session()["conversations"][0]["title_source"], "auto");
}
#[test]
fn task_creation_cannot_overwrite_an_existing_conversation_title() {
    let mut s = chat();
    s.rename_conversation(CHAT, "用户修改的标题").unwrap();
    install(&mut s);
    let before = s.raw_session().clone();
    assert!(s
        .create_task_conversation(CHAT, NOW, "deepseek-v4-flash", "任务名称")
        .is_err());
    assert_eq!(s.raw_session(), &before);
    assert!(s.pending.is_none());
}
#[test]
fn failed_create_cas_never_exposes_an_unsaved_conversation_or_binding() {
    let mut s = ready();
    s.set_default_workspace(descriptor(A)).unwrap();
    let before = s.raw_session().clone();
    s.create_conversation(CHAT, NOW, "deepseek-v4-flash")
        .unwrap();
    assert!(s.accept_persist(json!({"status":"not_committed"})).is_err());
    assert_eq!(s.raw_session(), &before);
    assert!(s.active_workspace_binding().is_none());
}
#[test]
fn legacy_unbound_history_migrates_in_one_cas_without_rewriting_attempts() {
    let mut original = chat();
    original
        .prepare_send("old message", &TurnIds::new(), NOW)
        .unwrap();
    install(&mut original);
    original.fail_send("E_TEST", NOW).unwrap();
    install(&mut original);
    let mut raw = original.raw_session().clone();
    legacy_unbound(&mut raw["conversations"][0]);
    let attempts = raw["conversations"][0]["attempts"].clone();
    let messages = raw["conversations"][0]["messages"].clone();
    let mut s = load(raw.clone());
    s.set_default_workspace(descriptor(A)).unwrap();
    assert!(s.migrate_unbound_workspaces().unwrap().is_some());
    assert_eq!(s.raw_session(), &raw);
    install(&mut s);
    assert_eq!(s.raw_session()["conversations"][0]["attempts"], attempts);
    assert_eq!(s.raw_session()["conversations"][0]["messages"], messages);
    assert_eq!(
        s.active_workspace_binding(),
        Some(&workspace_binding(&descriptor(A)).unwrap())
    );
    assert!(s.migrate_unbound_workspaces().unwrap().is_none());
}
#[test]
fn migration_preserves_bound_conversations_and_uses_one_default_for_all_unbound_chats() {
    let mut original = chat();
    original
        .create_conversation(CHAT2, NOW, "deepseek-v4-flash")
        .unwrap();
    install(&mut original);
    let mut raw = original.raw_session().clone();
    legacy_unbound(&mut raw["conversations"][1]);
    let bound = raw["conversations"][0].clone();
    let mut s = load(raw);
    s.set_default_workspace(descriptor(B)).unwrap();
    s.migrate_unbound_workspaces().unwrap().unwrap();
    install(&mut s);
    assert_eq!(s.raw_session()["conversations"][0], bound);
    assert_eq!(s.raw_session()["conversations"][1]["workspace_id"], B);
}
#[test]
fn failed_migration_cas_leaves_every_original_binding_and_history_unchanged() {
    let mut raw = chat().raw_session().clone();
    legacy_unbound(&mut raw["conversations"][0]);
    let mut s = load(raw.clone());
    s.set_default_workspace(descriptor(A)).unwrap();
    s.migrate_unbound_workspaces().unwrap().unwrap();
    assert!(s.accept_persist(json!({"status":"conflict"})).is_err());
    assert_eq!(s.raw_session(), &raw);
    assert!(!s.is_loaded());
}
#[test]
fn unbound_send_cannot_create_a_message_attempt_or_native_completion() {
    let mut raw = chat().raw_session().clone();
    legacy_unbound(&mut raw["conversations"][0]);
    let mut s = load(raw.clone());
    assert_eq!(
        s.prepare_send("hello", &TurnIds::new(), NOW).unwrap_err(),
        "E_CONVERSATION_WORKSPACE_REQUIRED"
    );
    assert_eq!(s.raw_session(), &raw);
    assert!(s.pending.is_none());
    assert!(s.sending.is_none());
}
#[test]
fn sent_conversation_workspace_cannot_be_rebound() {
    let mut s = chat();
    s.prepare_send("message", &TurnIds::new(), NOW).unwrap();
    install(&mut s);
    s.fail_send("E_TEST", NOW).unwrap();
    install(&mut s);
    let before = s.raw_session().clone();
    assert_eq!(
        s.bind_active_workspace(&descriptor(B)).unwrap_err(),
        "E_CONVERSATION_WORKSPACE_LOCKED"
    );
    assert_eq!(s.raw_session(), &before);
    assert!(s.pending.is_none());
}
#[test]
fn empty_conversation_rebind_is_only_visible_after_cas_and_failure_keeps_old_root() {
    let mut s = chat();
    s.bind_active_workspace(&descriptor(B)).unwrap();
    assert_eq!(s.active_workspace_binding().unwrap()["workspace_id"], A);
    assert!(s.accept_persist(json!({"status":"not_committed"})).is_err());
    assert_eq!(s.active_workspace_binding().unwrap()["workspace_id"], A);
    s.bind_active_workspace(&descriptor(B)).unwrap();
    install(&mut s);
    assert_eq!(s.active_workspace_binding().unwrap()["workspace_id"], B);
    assert!(s.raw_session()["conversations"][0]["project_id"].is_null());
}
#[test]
fn invalid_or_unavailable_default_descriptors_never_replace_verified_identity() {
    let mut s = chat();
    for (key, value) in [
        ("status", json!("missing")),
        ("workspace_id", json!("not-a-uuid")),
        ("binding_revision", json!(0)),
        ("schema_version", json!(1)),
    ] {
        let mut bad = descriptor(B);
        bad[key] = value;
        assert!(s.set_default_workspace(bad).is_err());
        assert_eq!(s.default_workspace().unwrap()["workspace_id"], A);
    }
    let mut bad = descriptor(B);
    bad["capabilities"]["read"] = json!(false);
    assert!(s.set_default_workspace(bad).is_err());
}
#[test]
fn unresolved_legacy_workspace_is_never_silently_redirected_to_default() {
    let mut raw = chat().raw_session().clone();
    raw["conversations"][0]["workspace_binding"] = Value::Null;
    raw["conversations"][0]["workspace_bootstrap_state"] = json!("pending_registry_resolution");
    let mut s = load(raw.clone());
    s.set_default_workspace(descriptor(B)).unwrap();
    assert!(s.migrate_unbound_workspaces().unwrap().is_none());
    assert_eq!(s.raw_session(), &raw);
    assert!(s.pending.is_none());
}

#[test]
fn one_unresolved_legacy_conversation_does_not_block_plain_conversation_migration() {
    let mut original = chat();
    original
        .create_conversation(CHAT2, NOW, "deepseek-v4-flash")
        .unwrap();
    install(&mut original);
    let mut raw = original.raw_session().clone();
    raw["conversations"][0]["workspace_binding"] = Value::Null;
    raw["conversations"][0]["workspace_bootstrap_state"] = json!("pending_registry_resolution");
    legacy_unbound(&mut raw["conversations"][1]);
    let legacy = raw["conversations"][0].clone();
    let mut s = load(raw);
    s.set_default_workspace(descriptor(B)).unwrap();
    assert!(s.has_unbound_workspaces());
    s.migrate_unbound_workspaces().unwrap().unwrap();
    install(&mut s);
    assert_eq!(s.raw_session()["conversations"][0], legacy);
    assert_eq!(s.active_workspace_binding().unwrap()["workspace_id"], B);
    assert!(!s.has_unbound_workspaces());
}
