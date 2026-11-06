#![cfg(unix)]
use super::*;
use serde_json::json;
use std::{fs, path::PathBuf};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-user-identity-{}", crate::model::id()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn store(&self) -> AssistantStore {
        AssistantStore::open(&self.0).unwrap()
    }
    fn bytes(&self) -> Vec<u8> {
        fs::read(self.0.join("assistant-v1.json")).unwrap()
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn legacy_store_has_no_user_nickname_and_load_does_not_rewrite_it() {
    let dir = Directory::new();
    let old = AssistantSnapshot::default();
    let bytes = serde_json::to_vec(&old).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("user_nickname"));
    fs::write(dir.0.join("assistant-v1.json"), &bytes).unwrap();
    assert_eq!(dir.store().load().unwrap().user_nickname, None);
    assert_eq!(dir.bytes(), bytes);
}

#[test]
fn user_nickname_is_global_and_survives_scoped_bot_writes() {
    let dir = Directory::new();
    let store = dir.store();
    let bot_id = crate::model::id();
    let bot_profile = AssistantProfile {
        name: "Planning Bot".into(),
        ..Default::default()
    };
    let initial = store
        .create_bot_with_id(0, &bot_id, bot_profile.clone())
        .unwrap();
    let group_id = crate::model::id();
    let grouped = store
        .create_group_with_id(
            initial.revision,
            &group_id,
            "Team",
            &[DEFAULT_BOT_ID.into(), bot_id.clone()],
        )
        .unwrap();
    let scoped = store.for_bot(&bot_id).unwrap();
    let named = scoped
        .set_user_nickname(grouped.revision, "  Test Member  ")
        .unwrap();
    assert_eq!(named.user_nickname.as_deref(), Some("Test Member"));
    assert_eq!(named.profile, grouped.profile);
    assert_eq!(named.bots, grouped.bots);
    assert_eq!(named.groups, grouped.groups);
    assert_eq!(
        named.bot_snapshot(&bot_id).unwrap().user_nickname,
        named.user_nickname
    );

    let changed = scoped
        .set_profile(
            named.revision,
            AssistantProfile {
                soul: "Plan carefully.".into(),
                ..bot_profile
            },
        )
        .unwrap();
    let changed = scoped.ensure_conversation(changed.revision).unwrap();
    let changed = scoped
        .remember_memory(
            changed.revision,
            None,
            "Preference",
            "Brief responses",
            AssistantMemoryKind::Preference,
            1_700_000_000_000,
        )
        .unwrap();
    assert_eq!(changed.user_nickname.as_deref(), Some("Test Member"));
    assert_eq!(changed.profile, grouped.profile);
    assert_eq!(changed.groups, grouped.groups);
    assert_eq!(dir.store().load().unwrap(), changed);
}

#[test]
fn nickname_edits_require_global_revision_and_valid_normalized_names() {
    let dir = Directory::new();
    let store = dir.store();
    let saved = store.set_user_nickname(0, "Person").unwrap();
    let bytes = dir.bytes();
    assert!(matches!(
        store.set_user_nickname(0, "Other"),
        Err(AssistantStoreError::Conflict { .. })
    ));
    for invalid in [
        "".to_owned(),
        "   ".into(),
        "a".repeat(1024),
        "bad\0name".into(),
    ] {
        assert!(store.set_user_nickname(saved.revision, &invalid).is_err());
        assert_eq!(dir.bytes(), bytes);
    }
}

#[test]
fn nickname_is_not_in_bot_context_or_an_agent_tool_target() {
    let dir = Directory::new();
    let store = dir.store();
    let saved = store.ensure_conversation(0).unwrap();
    let saved = store
        .set_user_nickname(saved.revision, "Private Sidebar Name")
        .unwrap();
    let context = store
        .task_tool(&json!({"action":"authorize","conversation_id":saved.conversation_id}))
        .unwrap();
    assert!(!context.to_string().contains("Private Sidebar Name"));
    assert!(!context.to_string().contains("user_nickname"));
    let args = json!({"nickname":"Model requested rename"});
    assert!(!rish_agent_core::assistant_tools::arguments_valid(
        "set_user_nickname",
        args.as_object().unwrap()
    ));
    assert!(store
        .task_tool(
            &json!({"action":"set_user_nickname","conversation_id":saved.conversation_id,
        "name":"set_user_nickname","arguments":args})
        )
        .is_err());
    assert_eq!(store.load().unwrap(), saved);
}
