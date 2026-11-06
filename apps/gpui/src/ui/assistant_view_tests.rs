use super::assistant_forms::{
    AssistantUi, TaskEditor, parse_interval, prepare_task_save, validate_draft,
};
use super::*;
use crate::assistant_runtime::{RunnerCommand, RunnerSnapshot, RunnerStatus};
use gpui::{Bounds, Modifiers, Pixels, TestAppContext, VisualTestContext, WindowHandle, size};
use rish_shell_core::assistant_store::*;

struct Panel {
    shell: Entity<Shell>,
}

impl Render for Panel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let size = window.viewport_size();
        self.shell.update(cx, |shell, cx| {
            shell.assistant_task_panel(size.height.into(), true, cx)
        })
    }
}

struct Fixture {
    window: WindowHandle<Panel>,
    cx: VisualTestContext,
}

impl Fixture {
    fn new(width: f32, height: f32, assistant: AssistantUi) -> Self {
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(width), px(height)), |_, cx| {
            let shell = cx.new(|cx| {
                let mut shell = Shell::new(cx);
                shell.locale = Locale::Zh;
                shell.assistant = assistant;
                shell
            });
            Panel { shell }
        });
        let mut cx = VisualTestContext::from_window(window.into(), &cx);
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        Self { window, cx }
    }

    fn bounds(&mut self, selector: &'static str) -> Bounds<Pixels> {
        self.cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"))
    }

    fn assert_horizontal_bounds(&mut self, selector: &'static str, width: f32) {
        let bounds = self.bounds(selector);
        assert!(
            bounds.origin.x >= px(0.),
            "{selector} starts outside the viewport"
        );
        assert!(
            bounds.right() <= px(width),
            "{selector} overflows the viewport"
        );
    }

    fn assert_touch_target(&mut self, selector: &'static str, width: f32) {
        self.assert_horizontal_bounds(selector, width);
        let bounds = self.bounds(selector);
        assert!(bounds.size.height >= px(44.), "{selector} is too short");
        assert!(bounds.size.width >= px(44.), "{selector} is too narrow");
    }

    fn reveal_in_scroll(&mut self, selector: &'static str, viewport: Bounds<Pixels>) {
        let target = self.bounds(selector);
        let delta = if target.bottom() > viewport.bottom() {
            viewport.bottom() - target.bottom() - px(2.)
        } else if target.top() < viewport.top() {
            viewport.top() - target.top() + px(2.)
        } else {
            return;
        };
        // The outer edge avoids the nested instructions/outcome scroll views.
        self.cx.simulate_event(gpui::ScrollWheelEvent {
            position: gpui::point(viewport.left() + px(1.), viewport.center().y),
            delta: gpui::ScrollDelta::Pixels(gpui::point(px(0.), delta)),
            modifiers: Modifiers::none(),
            touch_phase: gpui::TouchPhase::Moved,
        });
        self.cx.run_until_parked();
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
        let target = self.bounds(selector);
        assert!(
            target.top() >= viewport.top() && target.bottom() <= viewport.bottom(),
            "{selector} cannot be fully revealed by scrolling: {target:?}, {viewport:?}"
        );
    }
}

fn config() -> AssistantTaskConfig {
    AssistantTaskConfig::manual(
        "核对发布前的本地构建结果与待办事项".repeat(3),
        "阅读工作空间里的变更，逐条说明构建结果与需要人工确认的问题。".repeat(25),
        "configured-model",
        json!({"workspace_id":"workspace-1"}),
        json!({"schema_version":2,"workspace_id":"workspace-1","display_name":"手机上的中文工作空间"}),
    )
}

fn task(config: AssistantTaskConfig) -> AssistantTask {
    AssistantTask {
        id: "task-1".into(),
        title: config.title,
        instructions: config.instructions,
        conversation_id: "conversation-1".into(),
        workspace_binding: config.workspace_binding,
        workspace_descriptor: config.workspace_descriptor,
        model_id: config.model_id,
        runtime: None,
        interval_minutes: config.interval_minutes,
        enabled: config.enabled,
        next_due_ms: None,
        pending_manual: false,
        last_run: None,
    }
}

fn snapshot(tasks: Vec<AssistantTask>, revision: u64) -> RunnerSnapshot {
    RunnerSnapshot {
        store: Some(AssistantSnapshot {
            revision,
            profile: AssistantProfile {
                name: "我的本机助手".into(),
                notes: "请用中文回答，保留未提交的改动，结论需要说明验证依据。".repeat(8),
                ..Default::default()
            },
            tasks,
            ..Default::default()
        }),
        ..Default::default()
    }
}

fn editor(config: AssistantTaskConfig, saving: bool) -> TaskEditor {
    TaskEditor {
        id: "editor-1".into(),
        task_id: Some("task-1".into()),
        expected_revision: 7,
        base_config: Some(config.clone()),
        config,
        picker: None,
        saving,
        conflicted: false,
    }
}

fn last_run(status: AssistantRunStatus) -> AssistantRun {
    let config = config();
    AssistantRun {
        run_id: "run-1".into(),
        ids: AssistantTurnIds {
            turn_id: "turn-1".into(),
            attempt_id: "attempt-1".into(),
            round_id: "round-1".into(),
            user_message_id: "user-1".into(),
            assistant_message_id: "assistant-1".into(),
        },
        started_at_ms: 1_790_000_000_000,
        status,
        finished_at_ms: None,
        result_summary: None,
        failure_code: None,
        snapshot: AssistantRunSnapshot {
            soul: String::new(),
            name: "本机助手".into(),
            notes: String::new(),
            instructions: config.instructions,
            model_id: config.model_id,
            runtime: None,
            workspace_binding: config.workspace_binding,
            workspace_descriptor: config.workspace_descriptor,
        },
    }
}

#[test]
fn desktop_empty_preview_has_no_seeded_task_and_cannot_create_one() {
    let mut fixture = Fixture::new(390., 844., AssistantUi::default());
    fixture.bounds("assistant-preview");
    fixture.bounds("assistant-empty");
    assert!(fixture.cx.debug_bounds("assistant-last-run").is_none());
    fixture
        .window
        .update(&mut fixture.cx, |panel, _, cx| {
            panel.shell.update(cx, |shell, cx| {
                assert!(!shell.runtime.is_native());
                shell.assistant_begin_task(None, cx);
                assert!(shell.assistant.editor.is_none());
                assert!(shell.assistant.snapshot.store.is_none());
                assert!(!shell.assistant.snapshot.owns_writer);
            });
        })
        .unwrap();
}

#[test]
fn task_management_panel_is_secondary_and_fits_phone_widths() {
    for (width, height) in [(280., 480.), (320., 480.), (390., 844.)] {
        let ui = AssistantUi {
            snapshot: snapshot(vec![task(config())], 7),
            ..Default::default()
        };
        let mut fixture = Fixture::new(width, height, ui);
        for selector in [
            "assistant-task-panel",
            "assistant-task-list",
            "assistant-task-task-1",
        ] {
            fixture.assert_horizontal_bounds(selector, width);
        }
        fixture.assert_touch_target("assistant-tasks-close", width);
        assert!(fixture.cx.debug_bounds("assistant-hero").is_none());
        assert!(fixture.cx.debug_bounds("assistant-profile-name").is_none());
    }
}

#[test]
fn long_chinese_detail_keeps_primary_controls_inside_phone_and_ipad() {
    for (width, height) in [(320., 480.), (390., 844.), (1024., 768.)] {
        let ui = AssistantUi {
            snapshot: snapshot(vec![task(config())], 7),
            selected_task_id: Some("task-1".into()),
            ..Default::default()
        };
        let mut fixture = Fixture::new(width, height, ui);
        fixture.assert_horizontal_bounds("assistant-detail-pane", width);
        fixture.assert_horizontal_bounds("assistant-detail-scroll", width);
        let scroll = fixture.bounds("assistant-detail-scroll");
        assert!(scroll.top() >= px(0.) && scroll.bottom() <= px(height));
        for selector in ["assistant-run", "assistant-open-conversation"] {
            if height < 600. {
                fixture.reveal_in_scroll(selector, scroll);
            }
            fixture.assert_touch_target(selector, width);
            let bounds = fixture.bounds(selector);
            assert!(
                bounds.origin.y >= px(0.),
                "{selector} is above the viewport"
            );
            assert!(
                bounds.bottom() <= px(height),
                "{selector} is below the viewport"
            );
        }
        fixture.reveal_in_scroll("assistant-more", scroll);
        fixture.assert_touch_target("assistant-more", width);
        let more = fixture.bounds("assistant-more").center();
        fixture.cx.simulate_click(more, Modifiers::none());
        fixture.cx.run_until_parked();
        fixture.cx.update(|window, cx| window.draw(cx).clear(cx));
        for selector in ["assistant-edit", "assistant-delete"] {
            fixture.reveal_in_scroll(selector, scroll);
            fixture.assert_touch_target(selector, width);
            let bounds = fixture.bounds(selector);
            assert!(
                bounds.top() >= scroll.top() && bounds.bottom() <= scroll.bottom(),
                "{selector} must be reachable inside the task viewport"
            );
            assert!(bounds.top() >= px(0.) && bounds.bottom() <= px(height));
        }
        assert!(fixture.bounds("assistant-detail-scroll").size.height > px(0.));
        if width < 760. {
            if height < 600. {
                fixture.reveal_in_scroll("assistant-back", scroll);
            }
            fixture.assert_touch_target("assistant-back", width);
            assert!(fixture.cx.debug_bounds("assistant-list-pane").is_none());
        }
    }
}

#[test]
fn running_and_attention_runs_display_the_saved_state_without_fake_completion() {
    for status in [
        AssistantRunStatus::Running,
        AssistantRunStatus::NeedsAttention,
    ] {
        let mut task = task(config());
        task.last_run = Some(last_run(status));
        assert_eq!(
            assistant_copy::task_status(Locale::Zh, &task),
            if status == AssistantRunStatus::Running {
                "执行中"
            } else {
                "需要核对"
            }
        );
        let mut snapshot = snapshot(vec![task], 7);
        snapshot.status = if status == AssistantRunStatus::Running {
            RunnerStatus::Running
        } else {
            RunnerStatus::NeedsAttention
        };
        let ui = AssistantUi {
            snapshot,
            selected_task_id: Some("task-1".into()),
            ..Default::default()
        };
        let mut fixture = Fixture::new(390., 844., ui);
        fixture.bounds("assistant-last-run");
        if status == AssistantRunStatus::NeedsAttention {
            fixture.bounds("assistant-needs-attention");
            fixture.assert_touch_target("assistant-reconcile", 390.);
        } else {
            assert!(fixture.cx.debug_bounds("assistant-reconcile").is_none());
        }
        let point = fixture.bounds("assistant-run").center();
        fixture.cx.simulate_click(point, Modifiers::none());
        fixture.cx.run_until_parked();
        fixture
            .window
            .update(&mut fixture.cx, |panel, _, cx| {
                panel.shell.update(cx, |shell, _| {
                    let task = shell.assistant.selected_task().unwrap();
                    let run = task.last_run.as_ref().unwrap();
                    assert_eq!(run.status, status);
                    assert!(run.result_summary.is_none());
                    assert!(run.finished_at_ms.is_none());
                    assert!(!task.pending_manual);
                });
            })
            .unwrap();
    }
}

#[test]
fn editor_scrolls_long_instructions_but_keeps_save_and_cancel_reachable() {
    for (width, height) in [(320., 480.), (390., 844.), (1024., 768.)] {
        let ui = AssistantUi {
            snapshot: snapshot(vec![task(config())], 7),
            editor: Some(editor(config(), false)),
            ..Default::default()
        };
        let mut fixture = Fixture::new(width, height, ui);
        for selector in [
            "assistant-editor",
            "assistant-editor-scroll",
            "assistant-editor-title",
            "assistant-editor-instructions",
        ] {
            fixture.assert_horizontal_bounds(selector, width);
        }
        for selector in [
            "assistant-save",
            "assistant-cancel",
            "assistant-editor-back",
        ] {
            fixture.assert_touch_target(selector, width);
            assert!(fixture.bounds(selector).bottom() <= px(height));
        }
        assert!(fixture.bounds("assistant-editor-scroll").size.height > px(0.));
    }
}

#[test]
fn cancelling_task_editor_preserves_the_main_composer_draft() {
    let ui = AssistantUi {
        snapshot: snapshot(vec![task(config())], 7),
        editor: Some(editor(config(), false)),
        ..Default::default()
    };
    let mut fixture = Fixture::new(390., 844., ui);
    fixture
        .window
        .update(&mut fixture.cx, |panel, _, cx| {
            panel.shell.update(cx, |shell, cx| {
                shell.composer.update(cx, |input, cx| {
                    input.set_text("主聊天中尚未发送的草稿".into(), cx)
                });
                shell.assistant.editor.as_mut().unwrap().config.instructions =
                    "独立的任务编辑内容".into();
            });
        })
        .unwrap();
    let point = fixture.bounds("assistant-cancel").center();
    fixture.cx.simulate_click(point, Modifiers::none());
    fixture.cx.run_until_parked();
    fixture
        .window
        .update(&mut fixture.cx, |panel, _, cx| {
            panel.shell.update(cx, |shell, cx| {
                assert!(shell.assistant.editor.is_none());
                assert_eq!(shell.composer.read(cx).text(), "主聊天中尚未发送的草稿");
                assert_eq!(
                    shell.assistant.snapshot.store.as_ref().unwrap().tasks[0].instructions,
                    config().instructions
                );
            });
        })
        .unwrap();
}

#[test]
fn editor_waits_for_confirmed_saved_config_and_retains_draft_on_conflict() {
    let draft = config();
    let mut ui = AssistantUi {
        snapshot: snapshot(Vec::new(), 7),
        editor: Some(editor(draft.clone(), true)),
        ..Default::default()
    };
    ui.apply_snapshot(snapshot(vec![task(draft.clone())], 7));
    assert!(
        ui.editor.as_ref().unwrap().saving,
        "same revision is not an acknowledgement"
    );
    let mut unrelated = draft.clone();
    unrelated.instructions = "另一处写入的内容".into();
    ui.apply_snapshot(snapshot(vec![task(unrelated)], 8));
    assert_eq!(ui.editor.as_ref().unwrap().config, draft);
    assert!(!ui.editor.as_ref().unwrap().saving);
    ui.accept_error("revision conflict");
    assert_eq!(ui.error.as_deref(), Some("revision conflict"));
    ui.editor.as_mut().unwrap().saving = true;
    ui.apply_snapshot(snapshot(vec![task(draft)], 9));
    assert!(ui.editor.is_none());
    assert_eq!(ui.selected_task_id.as_deref(), Some("task-1"));
    assert!(ui.error.is_none());
}

#[test]
fn unrelated_store_writes_do_not_trap_a_task_editor_on_an_old_revision() {
    let mut editor = editor(config(), false);
    editor.config.instructions = "用户尚未保存的新要求".into();
    let saved = snapshot(vec![task(config())], 42).store.unwrap();
    let command = prepare_task_save(&mut editor, &saved, Locale::Zh).unwrap();
    match command {
        RunnerCommand::UpdateTask {
            expected_revision,
            task_id,
            config,
        } => {
            assert_eq!(expected_revision, 42);
            assert_eq!(task_id, "task-1");
            assert_eq!(config.instructions, "用户尚未保存的新要求");
        }
        other => panic!("unexpected task save command: {other:?}"),
    }
    assert_eq!(editor.expected_revision, 42);
    assert!(!editor.conflicted);
    assert_eq!(editor.config.instructions, "用户尚未保存的新要求");
}

#[test]
fn changed_task_config_requires_resolution_and_keeps_the_users_draft() {
    let mut editor = editor(config(), false);
    editor.config.instructions = "用户尚未保存的新要求".into();
    let base = editor.base_config.clone();
    let draft = editor.config.clone();
    let mut changed = config();
    changed.instructions = "另一处已保存的不同要求".into();
    let saved = snapshot(vec![task(changed)], 42).store.unwrap();
    assert!(prepare_task_save(&mut editor, &saved, Locale::Zh).is_err());
    assert!(editor.conflicted);
    assert_eq!(editor.config, draft);
    assert_eq!(editor.base_config, base);
    assert!(!editor.saving);
}

#[test]
fn creating_an_identical_task_does_not_mistake_an_existing_task_for_its_save() {
    let mut editor = editor(config(), true);
    editor.task_id = None;
    editor.base_config = None;
    let mut ui = AssistantUi {
        snapshot: snapshot(vec![task(config())], 7),
        editor: Some(editor),
        ..Default::default()
    };
    ui.apply_snapshot(snapshot(vec![task(config())], 8));
    assert!(ui.editor.is_some());
    assert!(ui.selected_task_id.is_none());
    ui.editor.as_mut().unwrap().saving = true;
    let mut created = task(config());
    created.id = "editor-1".into();
    ui.apply_snapshot(snapshot(vec![task(config()), created], 9));
    assert!(ui.editor.is_none());
    assert_eq!(ui.selected_task_id.as_deref(), Some("editor-1"));
}

#[test]
fn retrying_creation_preserves_its_identity_and_conflicting_draft() {
    let mut editor = editor(config(), false);
    editor.task_id = None;
    editor.base_config = None;
    let saved = snapshot(vec![], 7).store.unwrap();
    for _ in 0..2 {
        let command = prepare_task_save(&mut editor, &saved, Locale::Zh).unwrap();
        assert!(
            matches!(command, crate::assistant_runtime::RunnerCommand::CreateTask { task_id, .. } if task_id == "editor-1")
        );
    }
    let mut persisted = task(config());
    persisted.id = editor.id.clone();
    let saved = snapshot(vec![persisted], 8).store.unwrap();
    editor.config.instructions = "确认丢失后用户新写下的要求".into();
    assert!(prepare_task_save(&mut editor, &saved, Locale::Zh).is_err());
    assert!(editor.conflicted);
    assert_eq!(editor.id, "editor-1");
    assert_eq!(editor.config.instructions, "确认丢失后用户新写下的要求");
    editor.task_id = Some(editor.id.clone());
    editor.base_config = Some(saved.tasks[0].config());
    assert!(
        matches!(prepare_task_save(&mut editor, &saved, Locale::Zh).unwrap(), crate::assistant_runtime::RunnerCommand::UpdateTask { task_id, .. } if task_id == "editor-1")
    );
}

#[test]
fn idempotent_creation_acknowledges_the_same_store_revision() {
    let mut editor = editor(config(), true);
    editor.task_id = None;
    editor.base_config = None;
    let mut persisted = task(config());
    persisted.id = editor.id.clone();
    let mut ui = AssistantUi {
        editor: Some(editor),
        ..Default::default()
    };
    ui.apply_snapshot(snapshot(vec![persisted], 7));
    assert!(ui.editor.is_none());
    assert_eq!(ui.selected_task_id.as_deref(), Some("editor-1"));
}

#[test]
fn manual_default_and_minimum_follow_up_interval_are_explicit() {
    assert_eq!(config().interval_minutes, None);
    assert_eq!(parse_interval(""), Ok(None));
    assert_eq!(parse_interval(" 15 "), Ok(Some(15)));
    assert_eq!(parse_interval("1440"), Ok(Some(1440)));
    for invalid in ["0", "14", "-1", "1.5", "明天", "4294967296"] {
        assert_eq!(parse_interval(invalid), Err(()));
    }
    let mut draft = config();
    assert!(validate_draft(&draft, Locale::Zh).is_ok());
    draft.interval_minutes = Some(14);
    assert!(validate_draft(&draft, Locale::Zh).is_err());
    draft.interval_minutes = None;
    draft.workspace_binding = Value::Null;
    assert!(validate_draft(&draft, Locale::Zh).is_err());
}

#[test]
fn profile_notes_survive_errors_and_only_clear_after_saved_confirmation() {
    let profile = AssistantProfile {
        name: "我的助手".into(),
        notes: "保留这段尚未保存的长期备注".repeat(25),
        ..Default::default()
    };
    let mut ui = AssistantUi {
        profile_draft: Some(assistant_forms::ProfileDraft {
            baseline: AssistantProfile::default(),
            profile: profile.clone(),
            expected_revision: 7,
            saving: true,
        }),
        ..Default::default()
    };
    ui.accept_error("Assistant state changed");
    assert_eq!(ui.profile_draft.as_ref().unwrap().profile, profile);
    assert!(!ui.profile_draft.as_ref().unwrap().saving);
    ui.profile_draft.as_mut().unwrap().saving = true;
    ui.apply_snapshot(snapshot(vec![], 8));
    assert_eq!(ui.profile_draft.as_ref().unwrap().profile, profile);
    ui.profile_draft.as_mut().unwrap().saving = true;
    let mut saved = snapshot(vec![], 9);
    saved.store.as_mut().unwrap().profile = profile;
    ui.apply_snapshot(saved);
    assert!(ui.profile_draft.is_none());
}

#[test]
fn grouped_editor_scrolls_fields_without_moving_its_save_footer() {
    let mut scrolling_cases = 0;
    for (width, height) in [(320., 480.), (390., 844.), (1194., 834.)] {
        let ui = AssistantUi {
            snapshot: snapshot(vec![task(config())], 7),
            editor: Some(editor(config(), false)),
            ..Default::default()
        };
        let mut fixture = Fixture::new(width, height, ui);
        let scroll = fixture.bounds("assistant-editor-scroll");
        let save = fixture.bounds("assistant-save");
        let cancel = fixture.bounds("assistant-cancel");
        let overflowing = fixture.bounds("assistant-schedule-hint").bottom() > scroll.bottom();
        assert!(
            scroll.bottom() <= save.top(),
            "fields overlap the save footer"
        );
        fixture.cx.simulate_event(gpui::ScrollWheelEvent {
            position: scroll.center(),
            delta: gpui::ScrollDelta::Pixels(gpui::point(px(0.), px(-180.))),
            modifiers: Modifiers::none(),
            touch_phase: gpui::TouchPhase::Moved,
        });
        fixture.cx.run_until_parked();
        fixture.cx.update(|window, cx| window.draw(cx).clear(cx));
        assert_eq!(fixture.bounds("assistant-save"), save);
        assert_eq!(fixture.bounds("assistant-cancel"), cancel);
        let offset = fixture
            .window
            .read_with(&fixture.cx, |panel, cx| {
                panel.shell.read(cx).assistant.detail_scroll.offset()
            })
            .unwrap();
        if overflowing {
            assert!(
                offset.y < px(0.),
                "overflowing grouped fields must really scroll"
            );
            scrolling_cases += 1;
        }
        fixture.assert_touch_target("assistant-save", width);
        fixture.assert_touch_target("assistant-cancel", width);
        assert!(save.bottom() <= px(height));
    }
    assert!(
        scrolling_cases > 0,
        "the small phone must exercise real scrolling"
    );
}
