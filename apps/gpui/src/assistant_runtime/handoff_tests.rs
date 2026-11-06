use super::*;
use serde_json::json;
use std::time::{Duration, Instant};

struct ObservationsOnly;
impl Transport for ObservationsOnly {
    fn call(&self, command: RuntimeCommand) -> BoxFuture<'static, Result<Value, String>> {
        async move {
            match command.args.first().and_then(|q| q["op"].as_str()) {
                Some("settings") => Ok(json!({"foreground":true})),
                Some("drain") => Ok(json!([])),
                _ => Err("No native execution is allowed before writer handoff".into()),
            }
        }
        .boxed()
    }
}

#[test]
fn lost_ui_consumer_and_repeated_poll_reoffer_same_unclaimed_handoff() {
    let directory =
        std::env::temp_dir().join(format!("rish-handoff-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&directory).unwrap();
    let directory = std::fs::canonicalize(directory).unwrap();
    let store = AssistantStore::open(&directory).unwrap();
    let created = store.create_task(0, tests::config(), now_ms()).unwrap();
    let task_id = created.tasks[0].id.clone();
    let handle = RunnerHandle::spawn(Arc::new(ObservationsOnly));
    let mut initial_ui = handle.subscribe();
    handle
        .send(RunnerCommand::Initialize {
            directory: directory.clone(),
        })
        .unwrap();
    handle
        .send(RunnerCommand::RunNow {
            task_id: task_id.clone(),
        })
        .unwrap();
    receive_handoff(&mut initial_ui, &task_id);
    drop(initial_ui); // The view disappears after receiving, before granting.
    let pending_snapshot = store.load().unwrap();
    assert!(pending_snapshot.tasks[0].pending_manual);
    assert!(pending_snapshot.tasks[0].last_run.is_none());
    let mut replacement_ui = handle.subscribe();
    receive_handoff(&mut replacement_ui, &task_id);
    handle.send(RunnerCommand::PollDue).unwrap();
    receive_handoff(&mut replacement_ui, &task_id);
    handle
        .send(RunnerCommand::Initialize {
            directory: directory.clone(),
        })
        .unwrap();
    receive_handoff(&mut replacement_ui, &task_id);
    assert_eq!(store.load().unwrap(), pending_snapshot);
    assert_eq!(handle.snapshot().status, RunnerStatus::WaitingForForeground);
    assert!(!handle.snapshot().owns_writer);
    assert!(handle.snapshot().active_task_id.is_none());
    drop(replacement_ui);
    std::fs::remove_dir_all(directory).unwrap();
}

fn receive_handoff(events: &mut mpsc::UnboundedReceiver<RunnerEvent>, expected_id: &str) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        while let Ok(event) = events.try_recv() {
            if let RunnerEvent::HandoffNeeded { task_id } = event {
                assert_eq!(task_id, expected_id);
                return;
            }
        }
        assert!(
            Instant::now() < deadline,
            "replacement UI never received pending handoff"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
