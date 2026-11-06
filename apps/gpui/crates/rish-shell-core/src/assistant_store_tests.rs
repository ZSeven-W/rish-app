#![cfg(unix)]

use super::*;
use serde_json::json;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::PathBuf;
use std::sync::{Arc, Barrier};

#[path = "assistant_store_runtime_tests.rs"]
mod runtime;

const NOW: u64 = 1_700_000_000_000;
const INTERVAL: u64 = 15 * 60_000;

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-assistant-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn store(&self) -> AssistantStore {
        AssistantStore::open(&self.0).unwrap()
    }

    fn state_bytes(&self) -> Vec<u8> {
        fs::read(self.0.join("assistant-v1.json")).unwrap()
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn config(interval_minutes: Option<u32>) -> AssistantTaskConfig {
    AssistantTaskConfig {
        title: "Follow up".into(),
        instructions: "Review the saved task and report changes.".into(),
        workspace_binding: json!({"workspace_id": "workspace-1"}),
        workspace_descriptor: json!({"id": "workspace-1", "display_name": "Project"}),
        model_id: "deepseek-v4-flash".into(),
        interval_minutes,
        enabled: true,
        runtime: None,
    }
}

fn completed(summary: &str) -> AssistantRunOutcome {
    AssistantRunOutcome {
        status: AssistantRunStatus::Completed,
        result_summary: Some(summary.into()),
        failure_code: None,
    }
}

fn create(store: &AssistantStore, interval: Option<u32>) -> (AssistantSnapshot, String) {
    let revision = store.load().unwrap().revision;
    let state = store.create_task(revision, config(interval), NOW).unwrap();
    let id = state.tasks.last().unwrap().id.clone();
    (state, id)
}

#[test]
fn empty_store_is_manual_and_does_not_touch_native_session() {
    let directory = TestDirectory::new();
    let native = directory.0.join("session-v9.json");
    fs::write(&native, b"native-session-fixture").unwrap();
    let store = directory.store();
    let empty = store.load().unwrap();
    assert_eq!(empty, AssistantSnapshot::default());
    assert!(empty.due_task_ids(u64::MAX).is_empty());
    let (state, _) = create(&store, None);
    assert!(state.tasks[0].next_due_ms.is_none());
    assert!(state.due_task_ids(u64::MAX).is_empty());
    assert_eq!(fs::read(native).unwrap(), b"native-session-fixture");
    assert_eq!(
        fs::metadata(directory.0.join("assistant-v1.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert!(!fs::read_dir(&directory.0).unwrap().any(|entry| {
        entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp")
    }));
}

#[test]
fn restart_retains_claimed_ids_and_immutable_context() {
    let directory = TestDirectory::new();
    let store = directory.store();
    store
        .set_profile(
            0,
            AssistantProfile {
                name: "Dot".into(),
                notes: "Use concise reports.".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let (state, id) = create(&store, None);
    let claim = store
        .claim(state.revision, &id, AssistantClaimMode::Manual, NOW + 1)
        .unwrap();
    drop(store);

    let restarted = directory.store().load().unwrap();
    assert_eq!(restarted, claim.snapshot);
    assert_eq!(restarted.running_tasks().len(), 1);
    let task = &restarted.tasks[0];
    assert_eq!(task.conversation_id, claim.conversation_id);
    assert_eq!(task.last_run.as_ref(), Some(&claim.run));
    assert_eq!(claim.run.snapshot.name, "Dot");
    assert_eq!(claim.run.snapshot.notes, "Use concise reports.");
    let ids = claim.run.ids.to_turn_ids();
    let all_ids = [
        ids.turn_id,
        ids.attempt_id,
        ids.round_id,
        ids.user_message_id,
        ids.assistant_message_id,
    ];
    assert!(all_ids.iter().all(|id| uuid::Uuid::parse_str(id).is_ok()));
    assert_eq!(all_ids.iter().collect::<HashSet<_>>().len(), 5);
}

#[test]
fn stale_revision_preserves_newer_state_and_bytes() {
    let directory = TestDirectory::new();
    let first = directory.store();
    let second = directory.store();
    let stale = second.load().unwrap();
    let current = first
        .set_profile(
            0,
            AssistantProfile {
                name: "Dot".into(),
                notes: "Saved".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let before = directory.state_bytes();
    assert_eq!(
        second.set_profile(stale.revision, AssistantProfile::default()),
        Err(AssistantStoreError::Conflict {
            expected: 0,
            actual: current.revision
        })
    );
    assert_eq!(directory.state_bytes(), before);
    assert_eq!(second.load().unwrap(), current);
}

#[test]
fn corrupt_or_unsupported_state_is_preserved() {
    for bad in [
        b"{truncated".to_vec(),
        serde_json::to_vec(&json!({"schema_version": 2, "revision": 1})).unwrap(),
        serde_json::to_vec(&json!({
            "schema_version": 1, "revision": 0, "clock_high_water_ms": 0,
            "profile": {"name": "Dot", "notes": "", "unexpected": true}, "tasks": []
        }))
        .unwrap(),
    ] {
        let directory = TestDirectory::new();
        fs::write(directory.0.join("assistant-v1.json"), &bad).unwrap();
        assert!(matches!(
            AssistantStore::open(&directory.0),
            Err(AssistantStoreError::Corrupt)
        ));
        assert_eq!(directory.state_bytes(), bad);
    }
}

#[test]
fn symlink_directory_state_and_lock_are_rejected() {
    let directory = TestDirectory::new();
    let target = TestDirectory::new();
    let link = directory.0.join("linked-directory");
    symlink(&target.0, &link).unwrap();
    assert!(matches!(
        AssistantStore::open(&link),
        Err(AssistantStoreError::UnsafePath)
    ));
    fs::create_dir(target.0.join("child")).unwrap();
    assert!(matches!(
        AssistantStore::open(link.join("child")),
        Err(AssistantStoreError::UnsafePath)
    ));

    for name in ["assistant-v1.json", ".assistant-v1.lock"] {
        let root = TestDirectory::new();
        let outside = directory.0.join(format!("outside-{name}"));
        fs::write(&outside, b"outside-data").unwrap();
        symlink(&outside, root.0.join(name)).unwrap();
        assert!(matches!(
            AssistantStore::open(&root.0),
            Err(AssistantStoreError::UnsafePath)
        ));
        assert_eq!(fs::read(&outside).unwrap(), b"outside-data");
    }
}

#[test]
fn running_claim_never_expires_or_is_deleted() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, Some(15));
    let claim = store
        .claim(state.revision, &id, AssistantClaimMode::Due, NOW + INTERVAL)
        .unwrap();
    let far_future = NOW + 365 * 24 * 60 * 60_000;
    let reopened = directory.store();
    let current = reopened.load().unwrap();
    assert!(current.due_task_ids(far_future).is_empty());
    for mode in [AssistantClaimMode::Due, AssistantClaimMode::Manual] {
        assert_eq!(
            reopened.claim(current.revision, &id, mode, far_future),
            Err(AssistantStoreError::Running)
        );
    }
    assert_eq!(
        reopened.remove_task(current.revision, &id),
        Err(AssistantStoreError::Running)
    );
    assert_eq!(reopened.load().unwrap(), claim.snapshot);
}

#[test]
fn finish_requires_exact_token_and_duplicate_outcome_is_idempotent() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, Some(15));
    let claim = store
        .claim(state.revision, &id, AssistantClaimMode::Manual, NOW)
        .unwrap();
    assert_eq!(
        store.finish(
            claim.snapshot.revision,
            &id,
            "wrong-run",
            completed("Done"),
            NOW + 1
        ),
        Err(AssistantStoreError::StaleClaim)
    );
    assert_eq!(store.load().unwrap(), claim.snapshot);
    let finished = store
        .finish(
            claim.snapshot.revision,
            &id,
            &claim.run.run_id,
            completed("Done"),
            NOW + 100,
        )
        .unwrap();
    let before = directory.state_bytes();
    let duplicate = store
        .finish(
            claim.snapshot.revision,
            &id,
            &claim.run.run_id,
            completed("Done"),
            NOW + 999,
        )
        .unwrap();
    assert_eq!(duplicate, finished);
    assert_eq!(directory.state_bytes(), before);
    assert_eq!(finished.tasks[0].next_due_ms, Some(NOW + 100 + INTERVAL));
    assert_eq!(
        store.finish(
            finished.revision,
            &id,
            &claim.run.run_id,
            completed("Different"),
            NOW + 999
        ),
        Err(AssistantStoreError::StaleClaim)
    );
    let next = store
        .claim(
            finished.revision,
            &id,
            AssistantClaimMode::Manual,
            NOW + 1_000,
        )
        .unwrap();
    assert_ne!(next.run.run_id, claim.run.run_id);
    assert_eq!(
        store.finish(
            next.snapshot.revision,
            &id,
            &claim.run.run_id,
            completed("Done"),
            NOW + 1_001
        ),
        Err(AssistantStoreError::StaleClaim)
    );
}

#[test]
fn paused_task_stops_scheduling_while_existing_run_can_finish() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, Some(15));
    let claim = store
        .claim(state.revision, &id, AssistantClaimMode::Manual, NOW)
        .unwrap();
    let paused = store
        .set_enabled(claim.snapshot.revision, &id, false, NOW + 1)
        .unwrap();
    assert!(paused.tasks[0].is_running());
    assert!(paused.due_task_ids(u64::MAX).is_empty());
    let finished = store
        .finish(
            paused.revision,
            &id,
            &claim.run.run_id,
            completed("Done"),
            NOW + 2,
        )
        .unwrap();
    assert!(!finished.tasks[0].enabled);
    assert!(finished.tasks[0].next_due_ms.is_none());
    assert_eq!(
        store.claim(
            finished.revision,
            &id,
            AssistantClaimMode::Due,
            NOW + INTERVAL * 2
        ),
        Err(AssistantStoreError::NotDue)
    );
    let resumed = store
        .set_enabled(finished.revision, &id, true, NOW + INTERVAL * 2)
        .unwrap();
    assert_eq!(resumed.tasks[0].next_due_ms, Some(NOW + INTERVAL * 3));
    assert!(resumed.due_task_ids(NOW + INTERVAL * 3 - 1).is_empty());
    assert_eq!(resumed.due_task_ids(NOW + INTERVAL * 3), vec![id]);
}

#[test]
fn explicit_manual_request_survives_restart_and_runs_while_paused() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, Some(15));
    let paused = store.set_enabled(state.revision, &id, false, NOW).unwrap();
    let requested = store.request_run(paused.revision, &id, NOW + 1).unwrap();
    assert_eq!(requested.pending_task_ids(), vec![id.clone()]);
    assert!(!requested.tasks[0].enabled);
    let reopened = directory.store();
    let persisted = reopened.load().unwrap();
    assert_eq!(persisted, requested);
    assert_eq!(
        reopened.claim(
            persisted.revision,
            &id,
            AssistantClaimMode::Due,
            NOW + INTERVAL
        ),
        Err(AssistantStoreError::NotDue)
    );
    let claim = reopened
        .claim(
            persisted.revision,
            &id,
            AssistantClaimMode::Manual,
            NOW + INTERVAL,
        )
        .unwrap();
    assert!(!claim.snapshot.tasks[0].enabled);
    assert!(!claim.snapshot.tasks[0].pending_manual);
    assert!(claim.snapshot.pending_task_ids().is_empty());
    assert_eq!(
        reopened.request_run(claim.snapshot.revision, &id, NOW + INTERVAL + 1),
        Err(AssistantStoreError::Running)
    );
    let finished = reopened
        .finish(
            claim.snapshot.revision,
            &id,
            &claim.run.run_id,
            completed("Done"),
            NOW + INTERVAL + 2,
        )
        .unwrap();
    assert!(finished.tasks[0].next_due_ms.is_none());
    let pending = reopened
        .request_run(finished.revision, &id, NOW + INTERVAL + 3)
        .unwrap();
    let cancelled = reopened
        .set_enabled(pending.revision, &id, false, NOW + INTERVAL + 4)
        .unwrap();
    assert!(cancelled.pending_task_ids().is_empty());
}

#[test]
fn clock_rollback_defers_due_until_persisted_high_water() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, Some(15));
    // Preserve its original due time while recording a later observation.
    let future = NOW + INTERVAL * 4;
    let later = store
        .update_task(state.revision, &id, config(Some(15)), future)
        .unwrap();
    assert_eq!(later.tasks[0].next_due_ms, Some(NOW + INTERVAL));
    let restart = directory.store();
    let saved = restart.load().unwrap();
    assert!(saved.due_task_ids(NOW + INTERVAL * 2).is_empty());
    assert_eq!(
        restart.claim(saved.revision, &id, AssistantClaimMode::Due, future - 1),
        Err(AssistantStoreError::NotDue)
    );
    assert_eq!(saved.due_task_ids(future), vec![id.clone()]);
    let claim = restart
        .claim(saved.revision, &id, AssistantClaimMode::Due, future)
        .unwrap();
    let finished = restart
        .finish(
            claim.snapshot.revision,
            &id,
            &claim.run.run_id,
            completed("Done"),
            NOW,
        )
        .unwrap();
    assert_eq!(finished.tasks[0].next_due_ms, Some(future + INTERVAL));
    assert_eq!(
        finished.tasks[0].last_run.as_ref().unwrap().finished_at_ms,
        Some(future)
    );
}

#[test]
fn profile_and_task_edits_do_not_rewrite_running_snapshot() {
    let directory = TestDirectory::new();
    let store = directory.store();
    store
        .set_profile(
            0,
            AssistantProfile {
                name: "Before".into(),
                notes: "Old memory".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let (state, id) = create(&store, None);
    let claim = store
        .claim(state.revision, &id, AssistantClaimMode::Manual, NOW)
        .unwrap();
    let updated = store
        .set_profile(
            claim.snapshot.revision,
            AssistantProfile {
                name: "After".into(),
                notes: "New memory".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let mut edited_config = config(Some(30));
    edited_config.instructions = "New instructions".into();
    edited_config.workspace_descriptor =
        json!({"id": "workspace-1", "display_name": "Renamed project"});
    let edited = store
        .update_task(updated.revision, &id, edited_config, NOW + 1)
        .unwrap();
    assert_eq!(edited.profile.notes, "New memory");
    assert_eq!(edited.tasks[0].instructions, "New instructions");
    assert_eq!(edited.tasks[0].last_run.as_ref(), Some(&claim.run));
    assert_eq!(directory.store().load().unwrap(), edited);
}

#[test]
fn attention_retains_claim_for_reconciliation_and_cannot_replay() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, Some(15));
    let claim = store
        .claim(state.revision, &id, AssistantClaimMode::Manual, NOW)
        .unwrap();
    let attention = store
        .mark_attention(
            claim.snapshot.revision,
            &id,
            &claim.run.run_id,
            "E_RECONCILE",
            NOW + 1,
        )
        .unwrap();
    let restarted = directory.store().load().unwrap();
    assert_eq!(restarted, attention);
    assert_eq!(restarted.running_tasks().len(), 1);
    let run = restarted.tasks[0].last_run.as_ref().unwrap();
    assert_eq!(run.status, AssistantRunStatus::NeedsAttention);
    assert_eq!(run.ids, claim.run.ids);
    assert!(run.finished_at_ms.is_none());
    assert!(restarted.due_task_ids(u64::MAX).is_empty());
    assert_eq!(
        store.claim(
            restarted.revision,
            &id,
            AssistantClaimMode::Manual,
            NOW + INTERVAL
        ),
        Err(AssistantStoreError::Running)
    );
    let finished = store
        .finish(
            restarted.revision,
            &id,
            &run.run_id,
            completed("Recovered"),
            NOW + 2,
        )
        .unwrap();
    assert!(finished.running_tasks().is_empty());
    assert_eq!(
        finished.tasks[0].last_run.as_ref().unwrap().status,
        AssistantRunStatus::Completed
    );
}

#[test]
fn concurrent_store_claims_have_one_durable_winner() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, None);
    let barrier = Arc::new(Barrier::new(2));
    let handles: Vec<_> = (0..2)
        .map(|_| {
            let path = directory.0.clone();
            let id = id.clone();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                let competing = AssistantStore::open(path).unwrap();
                barrier.wait();
                competing.claim(state.revision, &id, AssistantClaimMode::Manual, NOW)
            })
        })
        .collect();
    let results: Vec<_> = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect();
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|result| matches!(result, Err(AssistantStoreError::Conflict { .. })))
            .count(),
        1
    );
    let winner = results.into_iter().find_map(Result::ok).unwrap();
    assert_eq!(directory.store().load().unwrap(), winner.snapshot);
}

#[test]
fn invalid_limits_and_shared_name_rules_leave_state_unchanged() {
    let directory = TestDirectory::new();
    let store = directory.store();
    let profile = store
        .set_profile(
            0,
            AssistantProfile {
                name: "  Cafe\u{301}  ".into(),
                notes: "".into(),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(profile.profile.name, "Café");
    let before = directory.state_bytes();
    let mut invalid = config(Some(14));
    assert!(matches!(
        store.create_task(profile.revision, invalid.clone(), NOW),
        Err(AssistantStoreError::Invalid(_))
    ));
    invalid.interval_minutes = None;
    invalid.instructions = "x".repeat(MAX_TEXT_BYTES + 1);
    assert!(matches!(
        store.create_task(profile.revision, invalid, NOW),
        Err(AssistantStoreError::Invalid(_))
    ));
    assert!(matches!(
        store.set_profile(
            profile.revision,
            AssistantProfile {
                name: "Dot\nOther".into(),
                notes: "".into(),
                ..Default::default()
            }
        ),
        Err(AssistantStoreError::Invalid(_))
    ));
    assert!(matches!(
        store.set_profile(
            profile.revision,
            AssistantProfile {
                name: "Dot".into(),
                notes: "x".repeat(MAX_TEXT_BYTES + 1),
                ..Default::default()
            }
        ),
        Err(AssistantStoreError::Invalid(_))
    ));
    assert_eq!(directory.state_bytes(), before);
    let mut revision = profile.revision;
    for _ in 0..MAX_TASKS {
        revision = store
            .create_task(revision, config(None), NOW)
            .unwrap()
            .revision;
    }
    assert!(matches!(
        store.create_task(revision, config(None), NOW),
        Err(AssistantStoreError::Invalid(_))
    ));
    assert_eq!(store.load().unwrap().tasks.len(), MAX_TASKS);
}

#[test]
#[ignore = "subprocess helper invoked by competing_processes_claim_once"]
fn process_claim_worker() {
    let Ok(root) = std::env::var("RISH_ASSISTANT_STORE_TEST_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    let token = std::env::var("RISH_ASSISTANT_STORE_TEST_TOKEN").unwrap();
    let task_id = std::env::var("RISH_ASSISTANT_STORE_TEST_TASK").unwrap();
    let revision = std::env::var("RISH_ASSISTANT_STORE_TEST_REVISION")
        .unwrap()
        .parse()
        .unwrap();
    let store = AssistantStore::open(&root).unwrap();
    fs::write(root.join(format!("ready-{token}")), b"ready").unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !root.join("start-process-claim").exists() {
        assert!(
            std::time::Instant::now() < deadline,
            "parent did not release workers"
        );
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    match store.claim(revision, &task_id, AssistantClaimMode::Manual, NOW) {
        Ok(claim) => println!("ASSISTANT_CLAIM_WON:{}", claim.run.run_id),
        Err(AssistantStoreError::Conflict { expected, actual }) => {
            assert_eq!(expected, revision);
            assert_eq!(actual, revision + 1);
            println!("ASSISTANT_CLAIM_CONFLICT");
        }
        other => panic!("unexpected process claim result: {other:?}"),
    }
}

#[test]
fn competing_processes_claim_once() {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    let directory = TestDirectory::new();
    let store = directory.store();
    let (state, id) = create(&store, None);
    let mut children: Vec<_> = (0..2)
        .map(|token| {
            Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "assistant_store::tests::process_claim_worker",
                    "--ignored",
                    "--nocapture",
                ])
                .env("RISH_ASSISTANT_STORE_TEST_ROOT", &directory.0)
                .env("RISH_ASSISTANT_STORE_TEST_TOKEN", token.to_string())
                .env("RISH_ASSISTANT_STORE_TEST_TASK", &id)
                .env(
                    "RISH_ASSISTANT_STORE_TEST_REVISION",
                    state.revision.to_string(),
                )
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !(0..2).all(|token| directory.0.join(format!("ready-{token}")).exists()) {
        if Instant::now() >= deadline {
            for child in &mut children {
                let _ = child.kill();
                let _ = child.wait();
            }
            panic!("assistant process workers did not become ready");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    fs::write(directory.0.join("start-process-claim"), b"start").unwrap();
    while children
        .iter_mut()
        .any(|child| child.try_wait().unwrap().is_none())
    {
        if Instant::now() >= deadline {
            for child in &mut children {
                let _ = child.kill();
                let _ = child.wait();
            }
            panic!("assistant process workers did not settle");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let outputs: Vec<_> = children
        .into_iter()
        .map(|child| child.wait_with_output().unwrap())
        .collect();
    for output in &outputs {
        assert!(
            output.status.success(),
            "worker failed: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let stdout: Vec<_> = outputs
        .iter()
        .map(|output| String::from_utf8_lossy(&output.stdout))
        .collect();
    assert_eq!(
        stdout
            .iter()
            .filter(|text| text.contains("ASSISTANT_CLAIM_WON:"))
            .count(),
        1
    );
    assert_eq!(
        stdout
            .iter()
            .filter(|text| text.contains("ASSISTANT_CLAIM_CONFLICT"))
            .count(),
        1
    );
    let saved = directory.store().load().unwrap();
    assert_eq!(saved.revision, state.revision + 1);
    assert_eq!(saved.running_tasks().len(), 1);
    let run_id = &saved.tasks[0].last_run.as_ref().unwrap().run_id;
    assert!(stdout
        .iter()
        .any(|text| text.contains(&format!("ASSISTANT_CLAIM_WON:{run_id}"))));
}
