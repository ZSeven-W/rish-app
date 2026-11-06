#![cfg(unix)]

use crate::assistant_store::*;
use rish_agent_core::canonical::{canonical_json, hash_json};
use serde_json::{json, Value};
use std::{fs, path::PathBuf};

const NOW: u64 = 1_700_000_000_000;

struct Directory(PathBuf);

impl Directory {
    fn new() -> Self {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-assistant-memory-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        Self(root)
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

fn request(state: &AssistantSnapshot, name: &str, arguments: Value) -> Value {
    json!({
        "action":"prepare","conversation_id":state.conversation_id,"name":name,
        "arguments":arguments,
        "arguments_sha256":hash_json("tool-arguments", &json!({"name":name,"arguments":arguments})).unwrap(),
        "locator":{"schema_version":2,"task_id":crate::model::id(),"attempt_id":crate::model::id(),
            "round_id":crate::model::id(),"round_index":0,"call_index":0,"call_id":"call-memory-1",
            "idempotency_key":hash_json("memory-test-operation", &json!(crate::model::id())).unwrap()},
        "context":{"conversation_id":state.conversation_id,"model_id":"deepseek-v4-flash",
            "workspace_binding":{"workspace_id":"native-workspace","binding_revision":1},
            "workspace_descriptor":{"id":"native-workspace","display_name":"Native workspace"}},
        "now_ms":NOW
    })
}

fn prepare_apply(store: &AssistantStore, request: &mut Value) -> Value {
    let precondition = store.task_tool(request).unwrap();
    request["expected_revision"] = precondition["expected_store_revision"].clone();
    request["action"] = json!("apply");
    let effect = store.task_tool(request).unwrap();
    let row = json!({"name":request["name"],"conversation_id":request["conversation_id"],
        "arguments_sha256":request["arguments_sha256"],"locator":request["locator"],
        "precondition":precondition});
    assert!(rish_agent_core::assistant_tools::effect_valid(
        &row, &effect
    ));
    effect
}

fn payload(effect: &Value) -> Value {
    serde_json::from_str::<Value>(effect["feedback"].as_str().unwrap()).unwrap()["payload"].clone()
}

fn remember_request(state: &AssistantSnapshot) -> Value {
    request(
        state,
        "remember_assistant_memory",
        json!({"title":"Preferred language","content":"Use Chinese in replies.","kind":"preference"}),
    )
}

fn avatar() -> AssistantAvatar {
    AssistantAvatar {
        id: crate::model::id(),
        sha256: "a".repeat(64),
        mime_type: "image/png".into(),
        width: 16,
        height: 16,
        byte_length: 64,
    }
}

#[test]
fn legacy_schema_one_load_adds_default_soul_and_empty_memories_without_rewriting_profile() {
    let directory = Directory::new();
    let store = directory.store();
    let profile = AssistantProfile {
        name: "My assistant".into(),
        notes: "These are the existing manual notes.".into(),
        avatar: Some(avatar()),
        runtime: RuntimeSpec::custom("Personal engine", "{}").unwrap(),
        ..Default::default()
    };
    let saved = store.set_profile(0, profile.clone()).unwrap();
    let saved = store
        .create_task(
            saved.revision,
            AssistantTaskConfig::manual(
                "Existing task",
                "Keep its settings",
                "deepseek-v4-flash",
                json!({}),
                json!({}),
            ),
            NOW,
        )
        .unwrap();
    let mut legacy = serde_json::to_value(&saved).unwrap();
    legacy["profile"].as_object_mut().unwrap().remove("soul");
    legacy.as_object_mut().unwrap().remove("memories");
    fs::write(
        directory.0.join("assistant-v1.json"),
        serde_json::to_vec(&legacy).unwrap(),
    )
    .unwrap();
    let before = directory.bytes();

    let loaded = directory.store().load().unwrap();
    assert_eq!(loaded.schema_version, 1);
    assert_eq!(loaded.revision, saved.revision);
    assert_eq!(loaded.tasks, saved.tasks);
    assert_eq!(loaded.profile.name, profile.name);
    assert_eq!(loaded.profile.notes, profile.notes);
    assert_eq!(loaded.profile.avatar, profile.avatar);
    assert_eq!(loaded.profile.runtime, profile.runtime);
    assert_eq!(loaded.profile.soul, AssistantProfile::default().soul);
    assert!(!loaded.profile.soul.trim().is_empty());
    assert!(loaded.memories.is_empty());
    assert_eq!(directory.bytes(), before);
}

#[test]
fn soul_edits_remain_independent_of_name_notes_runtime_avatar_and_memory_records() {
    let directory = Directory::new();
    let store = directory.store();
    let profile = AssistantProfile {
        name: "Mira".into(),
        notes: "Manual context is distinct from memory.".into(),
        soul: "Be warm, concise, and ask when uncertain.".into(),
        runtime: RuntimeSpec::custom("Custom", "{}").unwrap(),
        avatar: Some(avatar()),
    };
    let saved = store.set_profile(0, profile.clone()).unwrap();
    let saved = store
        .remember_memory(
            saved.revision,
            None,
            "Language",
            "I prefer Chinese.",
            AssistantMemoryKind::Preference,
            NOW,
        )
        .unwrap();
    let mut renamed = profile.clone();
    renamed.name = "Nova".into();
    let saved = store.set_profile(saved.revision, renamed.clone()).unwrap();
    assert_eq!(saved.profile.soul, profile.soul);
    let mut soul_edit = renamed;
    soul_edit.soul = "Explain clearly and respect the user's explicit choices.".into();
    let edited = store
        .set_profile(saved.revision, soul_edit.clone())
        .unwrap();
    assert_eq!(edited.profile, soul_edit);
    assert_eq!(edited.profile.notes, profile.notes);
    assert_eq!(edited.profile.runtime, profile.runtime);
    assert_eq!(edited.profile.avatar, profile.avatar);
    assert_eq!(edited.memories, saved.memories);
    assert_eq!(directory.store().load().unwrap(), edited);
}

#[test]
fn manual_memory_create_edit_and_explicit_delete_survive_restart() {
    let directory = Directory::new();
    let store = directory.store();
    let created = store
        .remember_memory(
            0,
            None,
            "  Cafe\u{301}  ",
            "The preferred place is Café.",
            AssistantMemoryKind::Fact,
            NOW,
        )
        .unwrap();
    assert_eq!(created.memories.len(), 1);
    let memory = &created.memories[0];
    assert_eq!(memory.title, "Café");
    assert_eq!(memory.content, "The preferred place is Café.");
    assert_eq!(memory.kind, AssistantMemoryKind::Fact);
    assert_eq!(memory.created_at_ms, NOW);
    assert_eq!(memory.updated_at_ms, NOW);
    assert!(memory.source_conversation_id.is_none());
    let memory_id = memory.id.clone();
    assert_eq!(directory.store().load().unwrap(), created);
    let edited = directory
        .store()
        .remember_memory(
            created.revision,
            Some(&memory_id),
            "Choice",
            "Choose the earlier option.",
            AssistantMemoryKind::Decision,
            NOW + 5,
        )
        .unwrap();
    assert_eq!(edited.memories.len(), 1);
    assert_eq!(edited.memories[0].id, memory_id);
    assert_eq!(edited.memories[0].created_at_ms, NOW);
    assert_eq!(edited.memories[0].updated_at_ms, NOW + 5);
    assert_eq!(edited.memories[0].kind, AssistantMemoryKind::Decision);
    assert!(edited.memories[0].source_conversation_id.is_none());
    let deleted = directory
        .store()
        .forget_memory(edited.revision, &memory_id)
        .unwrap();
    assert!(deleted.memories.is_empty());
    assert_eq!(directory.store().load().unwrap(), deleted);
}

#[test]
fn manual_memory_changes_require_current_revision_and_existing_update_target() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store
        .remember_memory(
            0,
            None,
            "Preference",
            "Use short replies.",
            AssistantMemoryKind::Preference,
            NOW,
        )
        .unwrap();
    let id = state.memories[0].id.clone();
    let before = directory.bytes();
    assert!(matches!(
        store.remember_memory(
            0,
            Some(&id),
            "Changed",
            "Changed content",
            AssistantMemoryKind::Fact,
            NOW + 1
        ),
        Err(AssistantStoreError::Conflict { .. })
    ));
    assert!(matches!(
        store.forget_memory(0, &id),
        Err(AssistantStoreError::Conflict { .. })
    ));
    assert!(store
        .remember_memory(
            state.revision,
            Some(&crate::model::id()),
            "Missing",
            "Must not create implicitly",
            AssistantMemoryKind::Fact,
            NOW + 1
        )
        .is_err());
    assert!(store
        .forget_memory(state.revision, &crate::model::id())
        .is_err());
    assert_eq!(directory.bytes(), before);
}

#[test]
fn oversized_or_invalid_memory_and_soul_preserve_saved_bytes() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.set_profile(0, AssistantProfile::default()).unwrap();
    let before = directory.bytes();
    let invalid = [
        (" ".to_owned(), "content".to_owned()),
        ("a".repeat(121), "content".to_owned()),
        ("汉".repeat(41), "content".to_owned()),
        ("Bad\nTitle".to_owned(), "content".to_owned()),
        ("Title".to_owned(), " ".to_owned()),
        ("Title".to_owned(), "a".repeat(8193)),
        ("Title".to_owned(), "a\0b".to_owned()),
    ];
    for (title, content) in invalid {
        assert!(store
            .remember_memory(
                state.revision,
                None,
                &title,
                &content,
                AssistantMemoryKind::Fact,
                NOW
            )
            .is_err());
        assert_eq!(directory.bytes(), before);
    }
    for soul in ["a".repeat(16 * 1024 + 1), "bad\0soul".into()] {
        let mut profile = state.profile.clone();
        profile.soul = soul;
        assert!(store.set_profile(state.revision, profile).is_err());
        assert_eq!(directory.bytes(), before);
    }
}

#[test]
fn memory_capacity_refuses_new_entries_but_allows_edit_and_explicit_removal() {
    let directory = Directory::new();
    let store = directory.store();
    let mut state = store.load().unwrap();
    for index in 0..256 {
        state = store
            .remember_memory(
                state.revision,
                None,
                &format!("Fact {index}"),
                "Explicit remembered fact.",
                AssistantMemoryKind::Fact,
                NOW + index,
            )
            .unwrap();
    }
    let before = directory.bytes();
    assert!(store
        .remember_memory(
            state.revision,
            None,
            "Over capacity",
            "Must be refused",
            AssistantMemoryKind::Fact,
            NOW + 256
        )
        .is_err());
    assert_eq!(directory.bytes(), before);
    let id = state.memories[0].id.clone();
    state = store
        .remember_memory(
            state.revision,
            Some(&id),
            "Edited",
            "Still allowed",
            AssistantMemoryKind::Fact,
            NOW + 257,
        )
        .unwrap();
    assert_eq!(state.memories.len(), 256);
    state = store.forget_memory(state.revision, &id).unwrap();
    state = store
        .remember_memory(
            state.revision,
            None,
            "Replacement",
            "User freed one slot",
            AssistantMemoryKind::Fact,
            NOW + 258,
        )
        .unwrap();
    assert_eq!(state.memories.len(), 256);
    assert!(!state.memories.iter().any(|memory| memory.id == id));
}

#[test]
fn ordinary_conversation_cannot_search_write_or_forget_assistant_memories() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let state = store
        .remember_memory(
            state.revision,
            None,
            "Private preference",
            "Private remembered content",
            AssistantMemoryKind::Preference,
            NOW,
        )
        .unwrap();
    let before = directory.bytes();
    for (name, arguments) in [
        ("search_assistant_memory", json!({"query":"Private"})),
        (
            "remember_assistant_memory",
            json!({"title":"Other","content":"Must not save","kind":"fact"}),
        ),
        (
            "forget_assistant_memory",
            json!({"memory_id":state.memories[0].id}),
        ),
    ] {
        let mut call = request(&state, name, arguments);
        let ordinary_id = crate::model::id();
        call["conversation_id"] = json!(ordinary_id);
        call["context"]["conversation_id"] = json!(ordinary_id);
        assert!(store.task_tool(&call).is_err());
    }
    let authorized = store
        .task_tool(&json!({"action":"authorize","conversation_id":state.conversation_id}))
        .unwrap();
    assert!(!authorized
        .to_string()
        .contains("Private remembered content"));
    let denied = store
        .task_tool(&json!({"action":"authorize","conversation_id":crate::model::id()}))
        .unwrap();
    assert_eq!(denied, json!({"authorized":false}));
    assert_eq!(directory.bytes(), before);
}

#[test]
fn remember_and_forget_exact_replay_never_resurrects_deleted_memory() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let mut remember = remember_request(&state);
    let remembered = prepare_apply(&store, &mut remember);
    let state = store.load().unwrap();
    let memory_id = payload(&remembered)["memory_id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(state.memories.len(), 1);
    assert_eq!(
        state.memories[0].source_conversation_id,
        state.conversation_id
    );
    let mut update = request(
        &state,
        "remember_assistant_memory",
        json!({"memory_id":memory_id,"title":"Language","content":"Use English when requested.","kind":"preference"}),
    );
    update["now_ms"] = json!(NOW + 10);
    let updated = prepare_apply(&store, &mut update);
    let state = store.load().unwrap();
    assert_eq!(state.memories.len(), 1);
    assert_eq!(state.memories[0].id, memory_id);
    assert_eq!(state.memories[0].created_at_ms, NOW);
    let mut forget = request(
        &state,
        "forget_assistant_memory",
        json!({"memory_id":memory_id}),
    );
    let forgotten = prepare_apply(&store, &mut forget);
    let deleted = store.load().unwrap();
    assert!(deleted.memories.is_empty());
    let before = directory.bytes();
    for (mut call, effect) in [
        (remember, remembered),
        (update, updated),
        (forget, forgotten),
    ] {
        call["now_ms"] = json!(NOW + 86_400_000);
        assert_eq!(directory.store().task_tool(&call).unwrap(), effect);
        call["action"] = json!("recover");
        assert_eq!(directory.store().task_tool(&call).unwrap(), effect);
    }
    assert_eq!(directory.bytes(), before);
    assert_eq!(store.load().unwrap(), deleted);
    assert_eq!(deleted.tool_receipts.len(), 3);
}

#[test]
fn memory_source_attribution_is_native_and_manual_edit_preserves_it() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let before = directory.bytes();
    for key in [
        "source_conversation_id",
        "runtime",
        "soul",
        "workspace_binding",
        "created_at_ms",
    ] {
        let mut call = remember_request(&state);
        call["arguments"][key] = json!("model-controlled");
        call["arguments_sha256"] = json!(hash_json(
            "tool-arguments",
            &json!({"name":call["name"],"arguments":call["arguments"]})
        )
        .unwrap());
        assert!(store.task_tool(&call).is_err());
        assert_eq!(directory.bytes(), before);
    }
    let mut call = remember_request(&state);
    prepare_apply(&store, &mut call);
    let state = store.load().unwrap();
    let id = state.memories[0].id.clone();
    let edited = store
        .remember_memory(
            state.revision,
            Some(&id),
            "Edited in UI",
            "User corrected the remembered preference.",
            AssistantMemoryKind::Preference,
            NOW + 1,
        )
        .unwrap();
    assert_eq!(
        edited.memories[0].source_conversation_id,
        state.conversation_id
    );
    assert_eq!(edited.profile, state.profile);
}

#[test]
fn prepared_memory_update_conflicts_after_manual_edit_and_recovery_is_readonly() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let state = store
        .remember_memory(
            state.revision,
            None,
            "Existing",
            "Original content",
            AssistantMemoryKind::Fact,
            NOW,
        )
        .unwrap();
    let id = state.memories[0].id.clone();
    let mut call = request(&state, "forget_assistant_memory", json!({"memory_id":id}));
    let precondition = store.task_tool(&call).unwrap();
    let edited = store
        .remember_memory(
            state.revision,
            Some(&id),
            "User correction",
            "Keep the newer content",
            AssistantMemoryKind::Fact,
            NOW + 1,
        )
        .unwrap();
    let before = directory.bytes();
    call["expected_revision"] = precondition["expected_store_revision"].clone();
    call["action"] = json!("apply");
    assert!(matches!(
        store.task_tool(&call),
        Err(AssistantStoreError::Conflict { .. })
    ));
    call["action"] = json!("recover");
    assert_eq!(store.task_tool(&call).unwrap(), Value::Null);
    assert_eq!(directory.bytes(), before);
    assert_eq!(store.load().unwrap(), edited);
}

#[test]
fn memory_search_is_case_insensitive_recent_bounded_and_readonly() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let state = store
        .remember_memory(
            state.revision,
            None,
            "Editor",
            "Use VIM bindings.",
            AssistantMemoryKind::Preference,
            NOW,
        )
        .unwrap();
    let state = store
        .remember_memory(
            state.revision,
            None,
            "Language",
            "Use Chinese replies.",
            AssistantMemoryKind::Preference,
            NOW + 1,
        )
        .unwrap();
    let state = store
        .remember_memory(
            state.revision,
            None,
            "Choice",
            "Ship the smaller version.",
            AssistantMemoryKind::Decision,
            NOW + 2,
        )
        .unwrap();
    let before = directory.bytes();
    for (query, title) in [
        ("vIm", "Editor"),
        ("LANGUAGE", "Language"),
        ("DeCiSiOn", "Choice"),
    ] {
        let mut call = request(
            &state,
            "search_assistant_memory",
            json!({"query":query,"limit":20}),
        );
        let result = payload(&prepare_apply(&store, &mut call));
        assert_eq!(result["store_revision"], state.revision);
        assert_eq!(result["truncated"], false);
        let memories = result["memories"].as_array().unwrap();
        assert_eq!(memories.len(), 1);
        assert_eq!(memories[0]["title"], title);
        assert!(memories[0].get("source_conversation_id").is_none());
    }
    let mut recent = request(&state, "search_assistant_memory", json!({"limit":1}));
    let recent = payload(&prepare_apply(&store, &mut recent));
    assert_eq!(recent["memories"].as_array().unwrap().len(), 1);
    assert_eq!(recent["memories"][0]["title"], "Choice");
    assert_eq!(recent["truncated"], true);
    let mut empty = request(
        &state,
        "search_assistant_memory",
        json!({"query":"unknown text"}),
    );
    let empty = payload(&prepare_apply(&store, &mut empty));
    assert!(empty["memories"].as_array().unwrap().is_empty());
    assert_eq!(empty["truncated"], false);
    assert_eq!(directory.bytes(), before);
    assert_eq!(store.load().unwrap(), state);
}

#[test]
fn memory_search_keeps_full_content_and_caps_the_total_canonical_payload() {
    let directory = Directory::new();
    let store = directory.store();
    let mut state = store.ensure_conversation(0).unwrap();
    let content = "x".repeat(8192);
    for index in 0..8 {
        state = store
            .remember_memory(
                state.revision,
                None,
                &format!("Large memory {index}"),
                &content,
                AssistantMemoryKind::Fact,
                NOW + index,
            )
            .unwrap();
    }
    let before = directory.bytes();
    let mut call = request(&state, "search_assistant_memory", json!({"limit":20}));
    let result = payload(&prepare_apply(&store, &mut call));
    let memories = result["memories"].as_array().unwrap();
    assert!(!memories.is_empty());
    assert!(memories.len() < state.memories.len());
    assert_eq!(result["truncated"], true);
    assert!(canonical_json(&result).unwrap().len() <= 32 * 1024);
    assert!(memories.iter().all(|memory| memory["content"] == content));
    assert_eq!(directory.bytes(), before);
    for arguments in [
        json!({"limit":0}),
        json!({"limit":21}),
        json!({"query":"q".repeat(513)}),
    ] {
        assert!(store
            .task_tool(&request(&state, "search_assistant_memory", arguments))
            .is_err());
    }
    assert_eq!(directory.bytes(), before);
}

#[test]
fn stable_manual_create_identity_retries_without_duplicates_or_schedule_changes() {
    let directory = Directory::new();
    let store = directory.store();
    let memory_id = crate::model::id();
    let created = store
        .create_memory_with_id(
            0,
            &memory_id,
            "Preference",
            "Prefer precise answers.",
            AssistantMemoryKind::Preference,
            NOW,
        )
        .unwrap();
    let latest = store
        .set_profile(
            created.revision,
            AssistantProfile {
                notes: "Later independent edit".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let before = directory.bytes();
    let retried = directory
        .store()
        .create_memory_with_id(
            0,
            &memory_id,
            "Preference",
            "Prefer precise answers.",
            AssistantMemoryKind::Preference,
            NOW + 1000,
        )
        .unwrap();
    assert_eq!(retried, latest);
    assert_eq!(retried.memories.len(), 1);
    assert_eq!(retried.memories[0].created_at_ms, NOW);
    assert_eq!(retried.memories[0].updated_at_ms, NOW);
    assert_eq!(directory.bytes(), before);
    assert!(store
        .create_memory_with_id(
            latest.revision,
            &memory_id,
            "Other",
            "Different content",
            AssistantMemoryKind::Fact,
            NOW + 1000
        )
        .is_err());
    assert_eq!(directory.bytes(), before);
    let deleted = store.forget_memory(latest.revision, &memory_id).unwrap();
    let deleted_bytes = directory.bytes();
    assert!(matches!(
        store.create_memory_with_id(
            0,
            &memory_id,
            "Preference",
            "Prefer precise answers.",
            AssistantMemoryKind::Preference,
            NOW + 1000
        ),
        Err(AssistantStoreError::Conflict { .. })
    ));
    assert_eq!(directory.bytes(), deleted_bytes);
    assert_eq!(directory.store().load().unwrap(), deleted);
}
