#![cfg(unix)]

use super::*;
use serde_json::json;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Barrier};

const NOW: u64 = 1_700_000_000_000;
const TASK_ID: &str = "c0417c3a-2161-4d6b-8aac-84611d677ad6";

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "rish-assistant-idempotency-{}",
            uuid::Uuid::new_v4()
        ));
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

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn config() -> AssistantTaskConfig {
    AssistantTaskConfig {
        title: "Follow up".into(),
        instructions: "Check the project for changes.".into(),
        workspace_binding: json!({"workspace_id": "workspace-1"}),
        workspace_descriptor: json!({"id": "workspace-1", "display_name": "Project"}),
        model_id: "deepseek-v4-flash".into(),
        interval_minutes: Some(15),
        enabled: true,
        runtime: None,
    }
}

#[test]
fn lost_create_ack_retry_keeps_one_task_conversation_and_due_time() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let created = store
        .create_task_with_id(0, TASK_ID, config(), NOW)
        .unwrap();
    let before = directory.bytes();
    drop(store);

    // The caller retained its original revision and task ID after losing ACK.
    let reopened = directory.store();
    let retried = reopened
        .create_task_with_id(0, TASK_ID, config(), NOW + 24 * 60 * 60_000)
        .unwrap();
    assert_eq!(retried, created);
    assert_eq!(retried.revision, 1);
    assert_eq!(retried.tasks.len(), 1);
    assert_eq!(retried.tasks[0].id, TASK_ID);
    assert_eq!(
        retried.tasks[0].conversation_id,
        created.tasks[0].conversation_id
    );
    assert_eq!(retried.tasks[0].next_due_ms, Some(NOW + 15 * 60_000));
    assert_eq!(retried.clock_high_water_ms, NOW);
    assert_eq!(directory.bytes(), before);
}

#[test]
fn concurrent_identical_create_retries_both_return_same_single_task() {
    let directory = TestDirectory::new();
    let barrier = Arc::new(Barrier::new(2));
    let handles: Vec<_> = (0..2)
        .map(|_| {
            let root = directory.0.clone();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                let store = AssistantStore::open(root).unwrap();
                barrier.wait();
                store.create_task_with_id(0, TASK_ID, config(), NOW)
            })
        })
        .collect();
    let results: Vec<_> = handles
        .into_iter()
        .map(|handle| handle.join().unwrap().unwrap())
        .collect();
    assert_eq!(results[0], results[1]);
    assert_eq!(results[0].revision, 1);
    assert_eq!(results[0].tasks.len(), 1);
    assert_eq!(directory.store().load().unwrap(), results[0]);
}

#[test]
fn reused_task_id_with_different_payload_never_overwrites_current_state() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let created = store
        .create_task_with_id(0, TASK_ID, config(), NOW)
        .unwrap();
    let before = directory.bytes();
    let variants = [
        AssistantTaskConfig {
            title: "Different task".into(),
            ..config()
        },
        AssistantTaskConfig {
            instructions: "Different instructions".into(),
            ..config()
        },
        AssistantTaskConfig {
            workspace_binding: json!({"workspace_id": "workspace-2"}),
            ..config()
        },
        AssistantTaskConfig {
            workspace_descriptor: json!({"id": "workspace-2"}),
            ..config()
        },
        AssistantTaskConfig {
            model_id: "different-model".into(),
            ..config()
        },
        AssistantTaskConfig {
            interval_minutes: Some(30),
            ..config()
        },
        AssistantTaskConfig {
            enabled: false,
            ..config()
        },
    ];
    for variant in variants {
        for revision in [0, created.revision] {
            assert!(matches!(
                store.create_task_with_id(revision, TASK_ID, variant.clone(), NOW + 1),
                Err(AssistantStoreError::Invalid(_))
            ));
            assert_eq!(directory.bytes(), before);
        }
    }
    assert_eq!(store.load().unwrap(), created);
}

#[test]
fn create_retry_returns_latest_profile_and_running_claim_without_mutation() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let created = store
        .create_task_with_id(0, TASK_ID, config(), NOW)
        .unwrap();
    let claim = store
        .claim(
            created.revision,
            TASK_ID,
            AssistantClaimMode::Manual,
            NOW + 1,
        )
        .unwrap();
    let latest = store
        .set_profile(
            claim.snapshot.revision,
            AssistantProfile {
                name: "Assistant".into(),
                notes: "New memory after the run started".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let before = directory.bytes();
    let retried = directory
        .store()
        .create_task_with_id(0, TASK_ID, config(), NOW + 60_000)
        .unwrap();
    assert_eq!(retried, latest);
    assert_eq!(retried.tasks.len(), 1);
    assert_eq!(retried.tasks[0].last_run.as_ref(), Some(&claim.run));
    assert_eq!(retried.tasks[0].conversation_id, claim.conversation_id);
    assert!(retried.tasks[0].next_due_ms.is_none());
    assert_eq!(retried.profile.notes, "New memory after the run started");
    assert!(claim.run.snapshot.notes.is_empty());
    assert_eq!(directory.bytes(), before);
}

#[test]
fn equivalent_normalized_titles_are_the_same_create_request() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let initial = AssistantTaskConfig {
        title: "  Cafe\u{301}  ".into(),
        ..config()
    };
    let created = store.create_task_with_id(0, TASK_ID, initial, NOW).unwrap();
    assert_eq!(created.tasks[0].title, "Café");
    let before = directory.bytes();
    let normalized = AssistantTaskConfig {
        title: "Café".into(),
        ..config()
    };
    assert_eq!(
        store
            .create_task_with_id(0, TASK_ID, normalized, NOW + 1)
            .unwrap(),
        created
    );
    assert_eq!(directory.bytes(), before);
}

#[test]
fn new_task_id_still_requires_current_revision() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let created = store
        .create_task_with_id(0, TASK_ID, config(), NOW)
        .unwrap();
    let before = directory.bytes();
    let another_id = uuid::Uuid::new_v4().to_string();
    assert_eq!(
        store.create_task_with_id(0, &another_id, config(), NOW + 1),
        Err(AssistantStoreError::Conflict {
            expected: 0,
            actual: created.revision
        })
    );
    assert_eq!(directory.bytes(), before);
    assert_eq!(store.load().unwrap(), created);
}

#[test]
fn workspace_can_change_before_first_claim_but_never_after_any_run() {
    for status in [
        AssistantRunStatus::Running,
        AssistantRunStatus::NeedsAttention,
        AssistantRunStatus::Completed,
        AssistantRunStatus::Failed,
        AssistantRunStatus::Cancelled,
    ] {
        let directory = TestDirectory::new();
        let store = directory.store();
        let created = store
            .create_task_with_id(0, TASK_ID, config(), NOW)
            .unwrap();
        let mut selected = config();
        selected.workspace_binding = json!({"workspace_id": "workspace-2"});
        selected.workspace_descriptor = json!({"id": "workspace-2", "display_name": "Selected"});
        let edited = store
            .update_task(created.revision, TASK_ID, selected.clone(), NOW + 1)
            .unwrap();
        assert_eq!(
            edited.tasks[0].workspace_binding,
            selected.workspace_binding
        );
        assert_eq!(
            edited.tasks[0].conversation_id,
            created.tasks[0].conversation_id
        );
        let claim = store
            .claim(
                edited.revision,
                TASK_ID,
                AssistantClaimMode::Manual,
                NOW + 2,
            )
            .unwrap();
        if status != AssistantRunStatus::Running {
            store
                .finish(
                    claim.snapshot.revision,
                    TASK_ID,
                    &claim.run.run_id,
                    AssistantRunOutcome {
                        status,
                        result_summary: None,
                        failure_code: matches!(
                            status,
                            AssistantRunStatus::Failed | AssistantRunStatus::NeedsAttention
                        )
                        .then(|| "E_TEST_OUTCOME".into()),
                    },
                    NOW + 3,
                )
                .unwrap();
        }
        // Reopen the store to prove the binding restriction survives restart,
        // including a completed task whose conversation is reused on its next run.
        let reopened = directory.store();
        let before = reopened.load().unwrap();
        let bytes = directory.bytes();
        assert_eq!(
            reopened.update_task(before.revision, TASK_ID, config(), NOW + 4),
            Err(AssistantStoreError::Invalid(
                "workspace is fixed after the first run; create a new task"
            )),
            "{status:?}"
        );
        assert_eq!(reopened.load().unwrap(), before);
        assert_eq!(directory.bytes(), bytes);
    }
}

#[test]
fn same_binding_can_refresh_display_metadata_without_changing_claim_context() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let created = store
        .create_task_with_id(0, TASK_ID, config(), NOW)
        .unwrap();
    let claim = store
        .claim(
            created.revision,
            TASK_ID,
            AssistantClaimMode::Manual,
            NOW + 1,
        )
        .unwrap();
    let mut updated = config();
    updated.workspace_descriptor["display_name"] = json!("Renamed project");
    updated.instructions = "Review the renamed project.".into();
    updated.model_id = "deepseek-v4-pro".into();
    let edited = store
        .update_task(claim.snapshot.revision, TASK_ID, updated.clone(), NOW + 2)
        .unwrap();
    assert_eq!(edited.tasks[0].config(), updated);
    assert_eq!(edited.tasks[0].last_run.as_ref(), Some(&claim.run));
    assert_eq!(directory.store().load().unwrap(), edited);
}
