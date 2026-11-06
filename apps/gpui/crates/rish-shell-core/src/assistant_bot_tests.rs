#![cfg(unix)]
use super::*;
use rish_agent_core::canonical::hash_json;
use serde_json::json;
use std::{fs, path::PathBuf};
const NOW: u64 = 1_700_000_000_000;
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let p = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-bots-{}", crate::model::id()));
        fs::create_dir(&p).unwrap();
        Self(p)
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
fn add_bot(store: &AssistantStore, name: &str) -> String {
    let id = crate::model::id();
    store
        .create_bot_with_id(
            store.load().unwrap().revision,
            &id,
            AssistantProfile {
                name: name.into(),
                soul: format!("Soul for {name}"),
                ..Default::default()
            },
        )
        .unwrap();
    id
}
fn config() -> AssistantTaskConfig {
    AssistantTaskConfig::manual(
        "Group work",
        "Respond to the user",
        "deepseek-v4-flash",
        json!({"workspace_id":"native-workspace","binding_revision":1}),
        json!({"id":"native-workspace","display_name":"Default"}),
    )
}
fn complete() -> AssistantRunOutcome {
    AssistantRunOutcome {
        status: AssistantRunStatus::Completed,
        result_summary: Some("Done".into()),
        failure_code: None,
    }
}
fn request(conversation: &str, name: &str, arguments: Value) -> Value {
    json!({"action":"prepare","conversation_id":conversation,"name":name,"arguments":arguments,
    "arguments_sha256":hash_json("tool-arguments",&json!({"name":name,"arguments":arguments})).unwrap(),
    "locator":{"schema_version":2,"task_id":crate::model::id(),"attempt_id":crate::model::id(),"round_id":crate::model::id(),"round_index":0,"call_index":0,"call_id":"call-1","idempotency_key":hash_json("test-call",&json!(crate::model::id())).unwrap()},
    "context":{"conversation_id":conversation,"model_id":"deepseek-v4-flash","workspace_binding":config().workspace_binding,"workspace_descriptor":config().workspace_descriptor},"now_ms":NOW})
}
fn apply(store: &AssistantStore, req: &mut Value) -> Value {
    let p = store.task_tool(req).unwrap();
    req["expected_revision"] = p["expected_store_revision"].clone();
    req["action"] = json!("apply");
    store.task_tool(req).unwrap()
}
fn payload(effect: &Value) -> Value {
    serde_json::from_str::<Value>(effect["feedback"].as_str().unwrap()).unwrap()["payload"].clone()
}
fn group(store: &AssistantStore, bot: &str) -> String {
    let id = crate::model::id();
    store
        .create_group_with_id(
            store.load().unwrap().revision,
            &id,
            "Team",
            &[DEFAULT_BOT_ID.into(), bot.into()],
        )
        .unwrap();
    id
}
fn start(store: &AssistantStore, group: &str, targets: &[String], text: &str) {
    store
        .start_group_round(
            store.load().unwrap().revision,
            group,
            &crate::model::id(),
            text,
            targets,
            &config(),
            NOW,
        )
        .unwrap();
}

#[test]
fn legacy_file_loads_without_rewrite_and_new_bot_leaves_default_data_intact() {
    let dir = Directory::new();
    let store = dir.store();
    let s = store.ensure_conversation(0).unwrap();
    let s = store.create_task(s.revision, config(), NOW).unwrap();
    let s = store
        .remember_memory(
            s.revision,
            None,
            "Preference",
            "Chinese",
            AssistantMemoryKind::Preference,
            NOW,
        )
        .unwrap();
    let bytes = dir.bytes();
    assert!(!String::from_utf8(bytes.clone())
        .unwrap()
        .contains("\"bots\""));
    assert_eq!(dir.store().load().unwrap(), s);
    assert_eq!(dir.bytes(), bytes);
    let bot = add_bot(&store, "Second");
    let full = store.load().unwrap();
    assert_eq!(full.profile, s.profile);
    assert_eq!(full.tasks, s.tasks);
    assert_eq!(full.memories, s.memories);
    assert_eq!(full.conversation_id, s.conversation_id);
    assert_eq!(full.schema_version, 1);
    assert_eq!(full.bot_ids(), vec![DEFAULT_BOT_ID, bot.as_str()]);
    assert_eq!(full.bot_snapshot(&bot).unwrap().profile.name, "Second");
}

#[test]
fn scoped_profiles_tasks_memories_and_retry_results_preserve_other_bots() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    let scoped = store.for_bot(&bot).unwrap();
    let full = scoped
        .ensure_conversation(store.load().unwrap().revision)
        .unwrap();
    assert!(full.conversation_id.is_none());
    assert!(full.bots[0].conversation_id.is_some());
    assert_eq!(scoped.ensure_conversation(0).unwrap(), full);
    let task_id = crate::model::id();
    let full = scoped
        .create_task_with_id(full.revision, &task_id, config(), NOW)
        .unwrap();
    assert_eq!(
        scoped
            .create_task_with_id(0, &task_id, config(), NOW)
            .unwrap(),
        full
    );
    assert!(full.tasks.is_empty());
    assert_eq!(full.task_bot_id(&task_id), Some(bot.as_str()));
    let memory_id = crate::model::id();
    let full = scoped
        .create_memory_with_id(
            full.revision,
            &memory_id,
            "Private",
            "Bot-only",
            AssistantMemoryKind::Fact,
            NOW,
        )
        .unwrap();
    assert_eq!(
        scoped
            .create_memory_with_id(
                0,
                &memory_id,
                "Private",
                "Bot-only",
                AssistantMemoryKind::Fact,
                NOW
            )
            .unwrap(),
        full
    );
    assert!(store.forget_memory(full.revision, &memory_id).is_err());
    assert!(store
        .update_task(full.revision, &task_id, config(), NOW)
        .is_err());
    let full = scoped
        .set_profile(
            full.revision,
            AssistantProfile {
                name: "Renamed".into(),
                soul: "Second soul".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let claim = scoped
        .claim(full.revision, &task_id, AssistantClaimMode::Manual, NOW)
        .unwrap();
    assert_eq!(claim.run.snapshot.name, "Renamed");
    assert_eq!(claim.run.snapshot.soul, "Second soul");
    assert_eq!(claim.snapshot.running_tasks().len(), 1);
    assert_eq!(claim.snapshot.profile.name, "Rish");
    let full = scoped
        .finish(
            claim.snapshot.revision,
            &task_id,
            &claim.run.run_id,
            complete(),
            NOW + 1,
        )
        .unwrap();
    assert_eq!(
        scoped
            .finish(0, &task_id, &claim.run.run_id, complete(), NOW + 1)
            .unwrap(),
        full
    );
    assert_eq!(dir.store().load().unwrap(), full);
}

#[test]
fn bot_tools_cannot_list_update_or_forget_another_bots_records() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    store
        .ensure_conversation(store.load().unwrap().revision)
        .unwrap();
    let scoped = store.for_bot(&bot).unwrap();
    let full = scoped
        .ensure_conversation(store.load().unwrap().revision)
        .unwrap();
    let a = full.conversation_id.clone().unwrap();
    let b = full.bots[0].conversation_id.clone().unwrap();
    let mut create = request(
        &b,
        "create_assistant_task",
        json!({"title":"Private task","instructions":"Do something"}),
    );
    let result = apply(&store, &mut create);
    let task_id = payload(&result)["task_id"].clone();
    let mut memory = request(
        &b,
        "remember_assistant_memory",
        json!({"title":"Private","content":"Other bot only","kind":"fact"}),
    );
    let result = apply(&store, &mut memory);
    let memory_id = payload(&result)["memory_id"].clone();
    let mut list = request(&a, "list_assistant_tasks", json!({}));
    assert_eq!(payload(&apply(&store, &mut list))["tasks"], json!([]));
    let mut search = request(&a, "search_assistant_memory", json!({"query":"Other"}));
    assert_eq!(payload(&apply(&store, &mut search))["memories"], json!([]));
    assert!(store
        .task_tool(&request(
            &a,
            "update_assistant_task",
            json!({"task_id":task_id,"title":"Stolen"})
        ))
        .is_err());
    assert!(store
        .task_tool(&request(
            &a,
            "forget_assistant_memory",
            json!({"memory_id":memory_id})
        ))
        .is_err());
    assert_eq!(store.load().unwrap().tool_receipts.len(), 2);
    create["action"] = json!("recover");
    assert!(store.task_tool(&create).unwrap().is_object());
    create["conversation_id"] = json!(a);
    create["context"]["conversation_id"] = json!(a);
    assert!(store.task_tool(&create).is_err());
    let full = dir.store().load().unwrap();
    assert!(full.tasks.is_empty());
    assert_eq!(full.bots[0].tasks.len(), 1);
    assert_eq!(full.bots[0].memories.len(), 1);
}

#[test]
fn all_bot_scheduling_and_global_cas_are_not_selected_bot_state() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    let scoped = store.for_bot(&bot).unwrap();
    let stale = store.load().unwrap().revision;
    let mut cfg = config();
    cfg.interval_minutes = Some(15);
    let full = scoped.create_task(stale, cfg, NOW).unwrap();
    let task_id = full.bots[0].tasks[0].id.clone();
    assert!(matches!(
        store.set_profile(stale, AssistantProfile::default()),
        Err(AssistantStoreError::Conflict { .. })
    ));
    assert_eq!(full.due_task_ids(NOW + 900_000), vec![task_id.clone()]);
    let full = scoped.request_run(full.revision, &task_id, NOW).unwrap();
    assert_eq!(full.pending_task_ids(), vec![task_id]);
}

#[test]
fn cross_bot_and_group_identity_collisions_are_rejected_atomically() {
    let dir = Directory::new();
    let store = dir.store();
    let s = store.ensure_conversation(0).unwrap();
    let bot = add_bot(&store, "Other");
    let before = dir.bytes();
    let rev = store.load().unwrap().revision;
    assert!(store
        .create_bot_with_id(
            rev,
            s.conversation_id.as_ref().unwrap(),
            AssistantProfile::default()
        )
        .is_err());
    assert!(store
        .for_bot(&bot)
        .unwrap()
        .create_task_with_id(rev, DEFAULT_BOT_ID, config(), NOW)
        .is_err());
    assert!(store
        .create_group_with_id(
            rev,
            &bot,
            "Collision",
            &[DEFAULT_BOT_ID.into(), bot.clone()]
        )
        .is_err());
    assert_eq!(dir.bytes(), before);
}

#[path = "assistant_group_tests.rs"]
mod groups;
