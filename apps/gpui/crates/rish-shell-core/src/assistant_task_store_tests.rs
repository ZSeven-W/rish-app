#![cfg(unix)]
use super::*;
use std::{
    fs,
    path::PathBuf,
    sync::{Arc, Barrier},
};

const NOW: u64 = 1_700_000_000_000;

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-assistant-tools-{}", uuid::Uuid::new_v4()));
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

fn request(state: &AssistantSnapshot, name: &str, args: Value) -> Value {
    json!({"action":"prepare","conversation_id":state.conversation_id,
        "name":name,"arguments":args,
        "arguments_sha256":hash_json("tool-arguments", &json!({"name":name,"arguments":args})).unwrap(),
        "locator":{"schema_version":2,"task_id":crate::model::id(),"attempt_id":crate::model::id(),
            "round_id":crate::model::id(),"round_index":0,"call_index":0,"call_id":"call-1",
            "idempotency_key":hash_json("test-idempotency", &json!(crate::model::id())).unwrap()},
        "context":{"conversation_id":state.conversation_id,"model_id":"deepseek-v4-flash",
            "workspace_binding":{"workspace_id":"workspace-native","binding_revision":3},
            "workspace_descriptor":{"id":"workspace-native","display_name":"Trusted workspace"}},
        "now_ms":NOW})
}
fn create_request(state: &AssistantSnapshot) -> Value {
    request(
        state,
        "create_assistant_task",
        json!({"title":"Research","instructions":"Check project changes.","follow_up_minutes":30}),
    )
}
fn prepare_apply(store: &AssistantStore, request: &mut Value) -> Value {
    let precondition = store.task_tool(request).unwrap();
    request["expected_revision"] = precondition["expected_store_revision"].clone();
    request["action"] = json!("apply");
    store.task_tool(request).unwrap()
}
fn payload(effect: &Value) -> Value {
    serde_json::from_str::<Value>(effect["feedback"].as_str().unwrap()).unwrap()["payload"].clone()
}

#[test]
fn schema_one_migration_preserves_profile_and_tasks_without_allocating_a_chat() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store
        .set_profile(
            0,
            AssistantProfile {
                name: "Personal".into(),
                notes: "Private notes".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let state = store
        .create_task(
            state.revision,
            AssistantTaskConfig::manual(
                "Existing",
                "Keep this",
                "deepseek-v4-flash",
                json!({}),
                json!({}),
            ),
            NOW,
        )
        .unwrap();
    let mut legacy = serde_json::to_value(&state).unwrap();
    legacy.as_object_mut().unwrap().remove("conversation_id");
    legacy.as_object_mut().unwrap().remove("tool_receipts");
    fs::write(
        directory.0.join("assistant-v1.json"),
        serde_json::to_vec(&legacy).unwrap(),
    )
    .unwrap();
    let before = directory.bytes();
    let loaded = directory.store().load().unwrap();
    assert_eq!(loaded, state);
    assert!(loaded.conversation_id.is_none());
    assert_eq!(directory.bytes(), before);
    let allocated = store.ensure_conversation(loaded.revision).unwrap();
    assert_eq!(allocated.tasks, loaded.tasks);
    assert_eq!(allocated.profile, loaded.profile);
    assert_eq!(allocated.schema_version, 1);
    assert_eq!(allocated.revision, loaded.revision + 1);
    assert_eq!(directory.store().ensure_conversation(0).unwrap(), allocated);
}

#[test]
fn conversation_allocation_is_cas_and_concurrent_callers_get_one_identity() {
    let directory = Directory::new();
    let state = directory
        .store()
        .set_profile(0, AssistantProfile::default())
        .unwrap();
    assert!(matches!(
        directory.store().ensure_conversation(0),
        Err(AssistantStoreError::Conflict { .. })
    ));
    let barrier = Arc::new(Barrier::new(2));
    let handles: Vec<_> = (0..2)
        .map(|_| {
            let root = directory.0.clone();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                let store = AssistantStore::open(root).unwrap();
                barrier.wait();
                store.ensure_conversation(state.revision).unwrap()
            })
        })
        .collect();
    let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    assert_eq!(results[0], results[1]);
    assert_eq!(results[0].revision, 2);
    assert!(results[0].conversation_id.is_some());
}

#[test]
fn ordinary_conversation_and_forged_context_are_denied_without_effects() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let before = directory.bytes();
    let mut request = create_request(&state);
    request["conversation_id"] = json!(crate::model::id());
    assert!(store.task_tool(&request).is_err());
    assert_eq!(
        store
            .task_tool(&json!({"action":"authorize","conversation_id":request["conversation_id"]}))
            .unwrap(),
        json!({"authorized":false})
    );
    request["conversation_id"] = json!(state.conversation_id);
    request["context"]["conversation_id"] = json!(crate::model::id());
    assert!(store.task_tool(&request).is_err());
    assert_eq!(directory.bytes(), before);
}

#[test]
fn prepare_without_locator_is_readonly_and_checks_update_target() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let before = directory.bytes();
    let mut create = create_request(&state);
    create.as_object_mut().unwrap().remove("locator");
    assert_eq!(
        store.task_tool(&create).unwrap()["expected_store_revision"],
        state.revision
    );
    let missing = request(
        &state,
        "update_assistant_task",
        json!({"task_id":crate::model::id(),"paused":true}),
    );
    assert_eq!(
        store.task_tool(&missing),
        Err(AssistantStoreError::NotFound)
    );
    assert_eq!(directory.bytes(), before);
    create["action"] = json!("apply");
    create["expected_revision"] = json!(state.revision);
    assert!(store.task_tool(&create).is_err());
}

#[test]
fn create_inherits_native_model_workspace_and_profile_runtime_without_leaking_private_context() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let state = store
        .set_profile(
            state.revision,
            AssistantProfile {
                name: "My helper".into(),
                notes: "Secret user notes".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let mut create = create_request(&state);
    let effect = prepare_apply(&store, &mut create);
    let saved = store.load().unwrap();
    let task = &saved.tasks[0];
    assert_eq!(
        task.workspace_binding,
        create["context"]["workspace_binding"]
    );
    assert_eq!(
        task.workspace_descriptor,
        create["context"]["workspace_descriptor"]
    );
    assert_eq!(task.model_id, "deepseek-v4-flash");
    assert!(task.runtime.is_none());
    assert_ne!(
        Some(task.conversation_id.as_str()),
        saved.conversation_id.as_deref()
    );
    assert_eq!(payload(&effect)["task_id"], task.id);
    let claim = store
        .claim(
            saved.revision,
            &task.id,
            AssistantClaimMode::Manual,
            NOW + 1,
        )
        .unwrap();
    assert_eq!(claim.run.snapshot.notes, saved.profile.notes);
    assert_eq!(claim.run.snapshot.runtime, Some(saved.profile.runtime));
    let current = store.load().unwrap();
    let mut list = request(&current, "list_assistant_tasks", json!({}));
    let listed = prepare_apply(&store, &mut list);
    assert_eq!(store.load().unwrap(), current);
    assert_eq!(payload(&listed)["tasks"].as_array().unwrap().len(), 1);
    let wire = listed.to_string();
    for secret in [
        "Secret user notes",
        "Check project changes.",
        "Trusted workspace",
        "deepseek-v4-flash",
    ] {
        assert!(!wire.contains(secret));
    }
}

#[test]
fn create_and_update_retry_after_lost_reply_return_original_effect_without_mutation() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let mut create = create_request(&state);
    let created = prepare_apply(&store, &mut create);
    let state = store.load().unwrap();
    let task_id = payload(&created)["task_id"].clone();
    let mut update = request(
        &state,
        "update_assistant_task",
        json!({"task_id":task_id,"title":"Changed","follow_up_minutes":null,"paused":true}),
    );
    let updated = prepare_apply(&store, &mut update);
    let state = store.load().unwrap();
    let state = store
        .set_profile(
            state.revision,
            AssistantProfile {
                notes: "Later edit".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let before = directory.bytes();
    for (mut call, result) in [(create, created), (update, updated)] {
        call["now_ms"] = json!(NOW + 86_400_000);
        assert_eq!(directory.store().task_tool(&call).unwrap(), result);
        call["action"] = json!("recover");
        assert_eq!(directory.store().task_tool(&call).unwrap(), result);
    }
    assert_eq!(directory.bytes(), before);
    assert_eq!(store.load().unwrap(), state);
    assert_eq!(state.tasks.len(), 1);
    assert_eq!(state.tasks[0].title, "Changed");
    assert!(!state.tasks[0].enabled);
    assert!(state.tasks[0].interval_minutes.is_none());
    assert_eq!(state.tool_receipts.len(), 2);
}

#[test]
fn concurrent_update_or_profile_edit_invalidates_prepared_revision() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let mut create = create_request(&state);
    let effect = prepare_apply(&store, &mut create);
    let state = store.load().unwrap();
    let mut update = request(
        &state,
        "update_assistant_task",
        json!({"task_id":payload(&effect)["task_id"],"instructions":"New instructions"}),
    );
    let precondition = store.task_tool(&update).unwrap();
    let state = store
        .set_profile(state.revision, AssistantProfile::default())
        .unwrap();
    let before = directory.bytes();
    update["expected_revision"] = precondition["expected_store_revision"].clone();
    update["action"] = json!("apply");
    assert!(matches!(
        store.task_tool(&update),
        Err(AssistantStoreError::Conflict { .. })
    ));
    assert_eq!(directory.bytes(), before);
    update["action"] = json!("recover");
    assert_eq!(store.task_tool(&update).unwrap(), Value::Null);
    assert_eq!(store.load().unwrap(), state);
}

#[test]
fn replayed_locator_with_different_arguments_or_identity_fails_closed() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let mut create = create_request(&state);
    prepare_apply(&store, &mut create);
    let before = directory.bytes();
    let mut changed = create.clone();
    changed["arguments"]["title"] = json!("Another task");
    assert!(store.task_tool(&changed).is_err());
    changed["arguments_sha256"] = json!(hash_json(
        "tool-arguments",
        &json!({"name":changed["name"],"arguments":changed["arguments"]})
    )
    .unwrap());
    assert!(store.task_tool(&changed).is_err());
    changed["locator"]["idempotency_key"] = json!("f".repeat(64));
    assert!(store.task_tool(&changed).is_err());
    let mut override_request = create_request(&store.load().unwrap());
    override_request["arguments"]["workspace_binding"] = json!({"workspace_id":"injected"});
    override_request["arguments_sha256"] = json!(hash_json(
        "tool-arguments",
        &json!({"name":override_request["name"],"arguments":override_request["arguments"]})
    )
    .unwrap());
    assert!(store.task_tool(&override_request).is_err());
    assert_eq!(directory.bytes(), before);
}

#[test]
fn store_effect_satisfies_shared_native_effect_contract() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let mut create = create_request(&state);
    let precondition = store.task_tool(&create).unwrap();
    let effect = prepare_apply(&store, &mut create);
    let row = json!({"name":create["name"],"conversation_id":create["conversation_id"],
        "arguments_sha256":create["arguments_sha256"],"locator":create["locator"],"precondition":precondition});
    assert!(rish_agent_core::assistant_tools::effect_valid(
        &row, &effect
    ));
}

#[test]
fn authorization_freezes_only_matching_assistant_profile_under_one_revision() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let state = store
        .set_profile(
            state.revision,
            AssistantProfile {
                name: "Named assistant".into(),
                notes: "Private preferences".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let before = directory.bytes();
    let authorized = store
        .task_tool(&json!({"action":"authorize","conversation_id":state.conversation_id}))
        .unwrap();
    assert_eq!(
        authorized,
        json!({"authorized":true,"assistant_context":{
        "schema_version":1,"conversation_id":state.conversation_id,"profile_revision":state.revision,
        "name":"Named assistant","notes":"Private preferences","soul":default_soul()}})
    );
    let denied = store
        .task_tool(&json!({"action":"authorize","conversation_id":crate::model::id()}))
        .unwrap();
    assert_eq!(denied, json!({"authorized":false}));
    assert_eq!(directory.bytes(), before);
}

#[test]
fn concurrent_identical_tool_apply_commits_one_effect_and_receipt() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let mut call = create_request(&state);
    let precondition = store.task_tool(&call).unwrap();
    call["expected_revision"] = precondition["expected_store_revision"].clone();
    call["action"] = json!("apply");
    let barrier = Arc::new(Barrier::new(2));
    let handles: Vec<_> = (0..2)
        .map(|_| {
            let root = directory.0.clone();
            let barrier = Arc::clone(&barrier);
            let call = call.clone();
            std::thread::spawn(move || {
                let store = AssistantStore::open(root).unwrap();
                barrier.wait();
                store.task_tool(&call).unwrap()
            })
        })
        .collect();
    let effects: Vec<_> = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect();
    assert_eq!(effects[0], effects[1]);
    let saved = store.load().unwrap();
    assert_eq!(saved.revision, 2);
    assert_eq!(saved.tasks.len(), 1);
    assert_eq!(saved.tool_receipts.len(), 1);
}

#[test]
fn saturated_receipts_fail_new_mutations_and_preserve_old_recovery_evidence() {
    let directory = Directory::new();
    let store = directory.store();
    let state = store.ensure_conversation(0).unwrap();
    let mut original = create_request(&state);
    let original_effect = prepare_apply(&store, &mut original);
    let mut saved = store.load().unwrap();
    let first = saved.tool_receipts[0].clone();
    // Build a valid historical receipt set without thousands of fsyncs.
    for offset in 1..MAX_TOOL_RECEIPTS {
        let mut call: Request = serde_json::from_value(create_request(&saved)).unwrap();
        call.name = "update_assistant_task".into();
        let mut precondition = first.precondition.clone();
        precondition["kind"] = json!(call.name);
        precondition["expected_store_revision"] = json!(offset + 1);
        let effect = effect(
            &call,
            call.locator.as_ref().unwrap(),
            offset as u64 + 2,
            json!({"schema_version":1,"task_id":saved.tasks[0].id,"store_revision":offset+2}),
            true,
        )
        .unwrap();
        saved.tool_receipts.push(AssistantToolReceipt {
            locator: call.locator.unwrap(),
            conversation_id: call.conversation_id,
            name: call.name,
            arguments_sha256: call.arguments_sha256,
            precondition,
            effect,
        });
    }
    saved.revision = MAX_TOOL_RECEIPTS as u64 + 1;
    validate_snapshot(&saved).unwrap();
    store
        .storage
        .locked(|| store.storage.write(&saved))
        .unwrap();
    let before = directory.bytes();
    let fresh = create_request(&saved);
    assert_eq!(
        store.task_tool(&fresh),
        Err(AssistantStoreError::Invalid("task receipt limit reached"))
    );
    assert_eq!(store.task_tool(&original).unwrap(), original_effect);
    original["action"] = json!("recover");
    assert_eq!(
        directory.store().task_tool(&original).unwrap(),
        original_effect
    );
    assert_eq!(directory.bytes(), before);
}
