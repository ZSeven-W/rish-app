use super::assistant_forms::{AssistantUi, Picker, TaskEditor, prepare_task_save};
use super::*;
use crate::assistant_runtime::{RunnerCommand, RunnerSnapshot};
use gpui::{TestAppContext, size};
use rish_shell_core::assistant_store::*;

fn task(status: Option<AssistantRunStatus>) -> AssistantTask {
    let config = AssistantTaskConfig::manual(
        "检查工作空间",
        "阅读文件并汇报结果",
        "configured-model",
        json!({"workspace_id":"workspace-1"}),
        json!({"workspace_id":"workspace-1", "display_name":"我的空间"}),
    );
    let run = status.map(|status| AssistantRun {
        run_id: "run-1".into(),
        ids: AssistantTurnIds {
            turn_id: "turn-1".into(),
            attempt_id: "attempt-1".into(),
            round_id: "round-1".into(),
            user_message_id: "message-1".into(),
            assistant_message_id: "message-2".into(),
        },
        started_at_ms: 1,
        finished_at_ms: (!status.is_active()).then_some(2),
        status,
        result_summary: None,
        failure_code: None,
        snapshot: AssistantRunSnapshot {
            soul: String::new(),
            name: "Rish".into(),
            notes: String::new(),
            instructions: config.instructions.clone(),
            model_id: config.model_id.clone(),
            runtime: None,
            workspace_binding: config.workspace_binding.clone(),
            workspace_descriptor: config.workspace_descriptor.clone(),
        },
    });
    AssistantTask {
        id: "task-1".into(),
        title: config.title,
        instructions: config.instructions,
        conversation_id: "kept-conversation".into(),
        workspace_binding: config.workspace_binding,
        workspace_descriptor: config.workspace_descriptor,
        model_id: config.model_id,
        runtime: None,
        interval_minutes: None,
        enabled: true,
        next_due_ms: None,
        pending_manual: false,
        last_run: run,
    }
}

fn snapshot(task: Option<AssistantTask>, revision: u64) -> RunnerSnapshot {
    RunnerSnapshot {
        store: Some(AssistantSnapshot {
            revision,
            tasks: task.into_iter().collect(),
            ..Default::default()
        }),
        ..Default::default()
    }
}
fn ui(status: Option<AssistantRunStatus>) -> AssistantUi {
    AssistantUi {
        snapshot: snapshot(Some(task(status)), 7),
        selected_task_id: Some("task-1".into()),
        ..Default::default()
    }
}
fn editor(task: &AssistantTask) -> TaskEditor {
    TaskEditor {
        id: "editor-1".into(),
        task_id: Some(task.id.clone()),
        expected_revision: 7,
        config: task.config(),
        picker: None,
        saving: false,
        base_config: Some(task.config()),
        conflicted: false,
    }
}

#[test]
fn delete_requires_confirmation_and_waits_for_observed_removal() {
    let mut ui = ui(None);
    assert!(ui.prepare_deletion(Locale::Zh).is_err());
    ui.begin_deletion("task-1", Locale::Zh).unwrap();
    assert!(!ui.deletion.as_ref().unwrap().saving);
    assert_eq!(ui.snapshot.store.as_ref().unwrap().tasks.len(), 1);
    let command = ui.prepare_deletion(Locale::Zh).unwrap();
    assert!(
        matches!(command, RunnerCommand::RemoveTask { expected_revision: 7, task_id } if task_id == "task-1")
    );
    assert!(ui.form_busy());
    assert!(
        ui.prepare_deletion(Locale::Zh).is_err(),
        "double click cannot dispatch a second remove"
    );
    ui.apply_snapshot(snapshot(Some(task(None)), 7));
    assert!(ui.deletion.is_some());
    ui.apply_snapshot(snapshot(None, 7));
    assert!(
        ui.deletion.is_some(),
        "an older snapshot cannot acknowledge deletion"
    );
    ui.apply_snapshot(snapshot(None, 8));
    assert!(ui.deletion.is_none());
    assert!(ui.selected_task_id.is_none());
    assert!(!ui.form_busy());
}

#[test]
fn changed_revision_requires_new_delete_confirmation() {
    let mut ui = ui(None);
    ui.begin_deletion("task-1", Locale::Zh).unwrap();
    let mut changed = task(None);
    changed.title = "用户后来修改的任务".into();
    ui.apply_snapshot(snapshot(Some(changed), 8));
    let error = ui.prepare_deletion(Locale::Zh).unwrap_err();
    assert!(error.contains("已变更"));
    ui.accept_error(&error);
    let deletion = ui.deletion.as_ref().unwrap();
    assert_eq!(
        deletion.expected_revision, 7,
        "do not silently adopt a new delete revision"
    );
    assert!(!deletion.saving);
    assert_eq!(ui.selected_task_id.as_deref(), Some("task-1"));
}

#[test]
fn externally_removed_task_does_not_strand_its_confirmation() {
    let mut ui = ui(None);
    ui.begin_deletion("task-1", Locale::Zh).unwrap();
    ui.apply_snapshot(snapshot(None, 8));
    assert!(ui.deletion.is_none());
    assert!(ui.selected_task_id.is_none());
    assert!(!ui.form_busy());
}

#[test]
fn active_and_attention_runs_cannot_be_deleted_even_after_confirmation_opens() {
    for status in [
        AssistantRunStatus::Running,
        AssistantRunStatus::NeedsAttention,
    ] {
        let mut active = ui(Some(status));
        assert!(active.begin_deletion("task-1", Locale::Zh).is_err());
        assert!(active.deletion.is_none());
        let mut changed = ui(None);
        changed.begin_deletion("task-1", Locale::Zh).unwrap();
        // Revalidate the target, not only the visible button or revision.
        changed.snapshot.store.as_mut().unwrap().tasks[0].last_run = task(Some(status)).last_run;
        assert!(changed.prepare_deletion(Locale::Zh).is_err());
        assert!(!changed.deletion.as_ref().unwrap().saving);
    }
}

#[test]
fn deletion_error_keeps_confirmation_until_durable_absence_is_observed() {
    let mut ui = ui(Some(AssistantRunStatus::Completed));
    ui.begin_deletion("task-1", Locale::Zh).unwrap();
    let _ = ui.prepare_deletion(Locale::Zh).unwrap();
    ui.accept_error("Assistant storage failed");
    assert!(ui.error.is_some());
    assert!(!ui.deletion.as_ref().unwrap().saving);
    assert_eq!(
        ui.selected_task().unwrap().conversation_id,
        "kept-conversation"
    );
    ui.apply_snapshot(snapshot(Some(task(Some(AssistantRunStatus::Completed))), 8));
    assert!(ui.deletion.is_some());
    assert!(ui.error.is_some());
    ui.apply_snapshot(snapshot(None, 9));
    assert!(ui.deletion.is_none());
    assert!(ui.error.is_none());
}

#[test]
fn first_run_locks_existing_and_idempotently_created_task_workspace() {
    let initial = task(None);
    let mut ui = ui(None);
    ui.editor = Some(editor(&initial));
    assert!(!ui.workspace_locked());
    ui.editor.as_mut().unwrap().picker = Some(Picker::Workspace);
    ui.apply_snapshot(snapshot(Some(task(Some(AssistantRunStatus::Failed))), 8));
    assert!(ui.workspace_locked());
    assert!(ui.editor.as_ref().unwrap().picker.is_none());
    // A lost create acknowledgement can leave a new-task draft with an ID
    // already saved and run elsewhere. It has the same binding protection.
    let editor = ui.editor.as_mut().unwrap();
    editor.task_id = None;
    editor.id = "task-1".into();
    assert!(ui.workspace_locked());
}

#[test]
fn frozen_workspace_does_not_prevent_other_task_edits() {
    let saved = task(Some(AssistantRunStatus::Completed));
    let store = snapshot(Some(saved.clone()), 7).store.unwrap();
    let mut editor = editor(&saved);
    editor.config.instructions = "新的任务要求".into();
    assert!(matches!(
        prepare_task_save(&mut editor, &store, Locale::Zh).unwrap(),
        RunnerCommand::UpdateTask { .. }
    ));
    editor.config.workspace_binding = json!({"workspace_id":"workspace-2"});
    assert!(
        prepare_task_save(&mut editor, &store, Locale::Zh)
            .unwrap_err()
            .contains("新建任务")
    );
}

#[test]
fn stale_workspace_picker_actions_cannot_change_a_started_task() {
    let mut cx = TestAppContext::single();
    let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    window
        .update(&mut cx, |shell, _, cx| {
            shell.assistant = ui(Some(AssistantRunStatus::Completed));
            let task = shell.assistant.selected_task().unwrap().clone();
            shell.assistant.editor = Some(editor(&task));
            shell.assistant_pick(Picker::Workspace, cx);
            assert!(shell.assistant.editor.as_ref().unwrap().picker.is_none());
            shell.assistant_choose_workspace(json!({"workspace_id":"workspace-2"}), cx);
            assert_eq!(
                shell
                    .assistant
                    .editor
                    .as_ref()
                    .unwrap()
                    .config
                    .workspace_binding,
                task.workspace_binding
            );
            assert_eq!(
                shell
                    .assistant
                    .editor
                    .as_ref()
                    .unwrap()
                    .config
                    .workspace_descriptor,
                task.workspace_descriptor
            );
        })
        .unwrap();
}
