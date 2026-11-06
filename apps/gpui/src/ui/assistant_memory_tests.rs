use super::{
    assistant_forms::{AssistantUi, ProfileDraft},
    assistant_memory_state::*,
    *,
};
use crate::assistant_runtime::{RunnerCommand, RunnerSnapshot, test_fixture};
use gpui::{Bounds, Modifiers, Pixels, TestAppContext, VisualTestContext, WindowHandle, size};
use rish_shell_core::assistant_store::*;

fn memory() -> AssistantMemory {
    AssistantMemory {
        id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into(),
        title: "回答偏好".into(),
        content: "请用中文回答，并说明验证依据。".into(),
        kind: AssistantMemoryKind::Preference,
        created_at_ms: 10,
        updated_at_ms: 10,
        source_conversation_id: Some(test_fixture::CHAT.into()),
    }
}
fn snapshot() -> AssistantSnapshot {
    AssistantSnapshot {
        revision: 7,
        conversation_id: Some(test_fixture::CHAT.into()),
        memories: vec![memory()],
        ..Default::default()
    }
}
fn apply_command(store: &AssistantStore, command: RunnerCommand) -> AssistantSnapshot {
    match command {
        RunnerCommand::CreateMemory {
            expected_revision,
            memory_id,
            title,
            content,
            kind,
        } => store
            .create_memory_with_id(expected_revision, &memory_id, &title, &content, kind, 100)
            .unwrap(),
        RunnerCommand::RememberMemory {
            expected_revision,
            memory_id,
            title,
            content,
            kind,
        } => store
            .remember_memory(
                expected_revision,
                memory_id.as_deref(),
                &title,
                &content,
                kind,
                101,
            )
            .unwrap(),
        _ => panic!("unexpected command"),
    }
}

#[test]
fn memory_creation_retry_reuses_identity_and_confirms_an_uncertain_actual_store_save() {
    let directory = std::env::temp_dir().join(format!("rish-memory-ui-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&directory).unwrap();
    let directory = std::fs::canonicalize(directory).unwrap();
    let store = AssistantStore::open(&directory).unwrap();
    let original = store.load().unwrap();
    let mut draft = MemoryDraft::new(&original, None);
    draft.title = "沟通方式".into();
    draft.content = "给我简洁的结论。".into();
    draft.kind = AssistantMemoryKind::Preference;
    let id = draft.id.clone();
    let first = apply_command(
        &store,
        draft.prepare_save(&original, Locale::Zh, false).unwrap(),
    );
    let mut ui = MemoryUi {
        editor: Some(draft),
        ..Default::default()
    };
    ui.accept_error();
    assert_eq!(ui.editor.as_ref().unwrap().id, id);
    let retry = ui
        .editor
        .as_mut()
        .unwrap()
        .prepare_save(&original, Locale::Zh, false)
        .unwrap();
    let second = apply_command(&store, retry);
    assert_eq!(first, second);
    assert_eq!(second.memories.len(), 1);
    ui.apply_snapshot(&second);
    assert!(ui.editor.is_none());
    assert_eq!(ui.selected_id.as_deref(), Some(id.as_str()));
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn memory_cas_conflict_keeps_all_draft_fields_until_explicit_overwrite() {
    let initial = snapshot();
    let mut editor = MemoryDraft::new(&initial, Some(&initial.memories[0]));
    editor.title = "自己的新标题".into();
    editor.content = "自己的未保存内容".into();
    editor.kind = AssistantMemoryKind::Decision;
    let mut changed = initial.clone();
    changed.revision += 1;
    changed.memories[0].content = "聊天工具保存的新内容".into();
    changed.memories[0].updated_at_ms = 20;
    assert!(editor.prepare_save(&changed, Locale::Zh, false).is_err());
    assert!(editor.conflicted);
    assert_eq!(editor.content, "自己的未保存内容");
    assert_eq!(editor.title, "自己的新标题");
    assert_eq!(editor.kind, AssistantMemoryKind::Decision);
    let command = editor.prepare_save(&changed, Locale::Zh, true).unwrap();
    assert!(matches!(
        command,
        RunnerCommand::RememberMemory {
            expected_revision: 8,
            memory_id: Some(_),
            ..
        }
    ));
    let mut ui = MemoryUi {
        editor: Some(editor),
        ..Default::default()
    };
    ui.accept_error();
    let draft = ui.editor.as_ref().unwrap();
    assert!(!draft.saving);
    assert_eq!(draft.content, "自己的未保存内容");
    assert_eq!(
        draft.baseline.as_ref().unwrap().source_conversation_id,
        Some(test_fixture::CHAT.into())
    );
}

#[test]
fn unrelated_memory_revision_does_not_block_edit_and_external_removal_never_recreates_it() {
    let mut saved = snapshot();
    let mut draft = MemoryDraft::new(&saved, Some(&saved.memories[0]));
    draft.content = "updated".into();
    saved.revision += 1;
    assert!(draft.prepare_save(&saved, Locale::En, false).is_ok());
    draft.saving = false;
    saved.memories.clear();
    saved.revision += 1;
    assert!(draft.prepare_save(&saved, Locale::En, false).is_err());
    assert!(draft.prepare_save(&saved, Locale::En, true).is_err());
    assert_eq!(draft.content, "updated");
    assert!(draft.memory_id.is_some());
}

#[test]
fn memory_snapshot_only_acknowledges_matching_content_and_delete_waits_for_durable_absence() {
    let mut saved = snapshot();
    let mut editor = MemoryDraft::new(&saved, Some(&saved.memories[0]));
    editor.content = "draft".into();
    editor.prepare_save(&saved, Locale::En, false).unwrap();
    let mut ui = MemoryUi {
        editor: Some(editor),
        ..Default::default()
    };
    ui.apply_snapshot(&saved);
    assert!(ui.editor.as_ref().unwrap().saving);
    saved.revision += 1;
    saved.memories[0].content = "another saved value".into();
    ui.apply_snapshot(&saved);
    assert!(ui.editor.as_ref().unwrap().conflicted);
    assert!(!ui.editor.as_ref().unwrap().saving);
    assert_eq!(ui.editor.as_ref().unwrap().content, "draft");
    ui.editor = None;
    ui.begin_delete(&saved, &memory().id, Locale::En).unwrap();
    let unchanged = saved.clone();
    ui.prepare_delete(&saved, Locale::En).unwrap();
    ui.apply_snapshot(&unchanged);
    assert!(ui.deletion.is_some());
    ui.accept_error();
    saved.revision += 1;
    assert!(ui.prepare_delete(&saved, Locale::En).is_err());
    assert!(ui.deletion.is_some());
    saved.memories.clear();
    ui.apply_snapshot(&saved);
    assert!(ui.deletion.is_none());
}

#[test]
fn memory_validation_is_utf8_bounded_and_does_not_discard_the_draft() {
    let saved = snapshot();
    let mut draft = MemoryDraft::new(&saved, None);
    draft.title = "中".repeat(41);
    draft.content = "keep".into();
    assert!(draft.prepare_save(&saved, Locale::Zh, false).is_err());
    assert_eq!(draft.title, "中".repeat(41));
    draft.title = "title".into();
    draft.content = "中".repeat(2731);
    assert!(draft.prepare_save(&saved, Locale::Zh, false).is_err());
    assert_eq!(draft.content.len(), 8193);
    draft.content = "中".repeat(2730);
    assert!(draft.prepare_save(&saved, Locale::Zh, false).is_ok());
}

#[test]
fn profile_soul_merge_preserves_independently_changed_notes_name_avatar_and_runtime() {
    let baseline = AssistantProfile::default();
    let mut profile = baseline.clone();
    profile.soul = "温和、务实，先理清想法，再安排跟进。".into();
    let draft = ProfileDraft {
        baseline: baseline.clone(),
        profile,
        expected_revision: 1,
        saving: false,
    };
    let mut latest = baseline.clone();
    latest.name = "新的名字".into();
    latest.notes = "独立更新的备注".into();
    latest.runtime = RuntimeSpec::custom(
        "Other engine",
        "({ beforeModel(ctx) { return { allow: true }; } })",
    )
    .unwrap();
    latest.avatar = Some(AssistantAvatar {
        id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc".into(),
        sha256: "a".repeat(64),
        mime_type: "image/png".into(),
        width: 64,
        height: 64,
        byte_length: 42,
    });
    let merged = draft.merged_profile(&latest);
    assert_eq!(merged.soul, draft.profile.soul);
    assert_eq!(merged.name, latest.name);
    assert_eq!(merged.notes, latest.notes);
    assert_eq!(merged.avatar, latest.avatar);
    assert_eq!(merged.runtime, latest.runtime);
    let mut note_draft = ProfileDraft {
        baseline: baseline.clone(),
        profile: baseline,
        expected_revision: 1,
        saving: false,
    };
    note_draft.profile.notes = "我的备注".into();
    latest.soul = "外部修改后的性格".into();
    assert_eq!(note_draft.merged_profile(&latest).soul, latest.soul);
}

struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
}
impl Fixture {
    fn new(width: f32, height: f32, locale: Locale, editor: bool) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(height)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                shell.page = Page::Assistant;
                shell.locale = locale;
                shell.loading = false;
                shell.notice = None;
                shell.state = test_fixture::loaded();
                let mut store = snapshot();
                store.profile.soul = "温和、务实，先理清想法，再安排跟进。".repeat(30);
                store.memories[0].title = "需要逐条核对并保留验证证据的长期记忆".repeat(4);
                store.memories[0].content =
                    "这是一条很长的记忆，查看和编辑时都应该可以滚动阅读，且不会挤走保存按钮。"
                        .repeat(50);
                shell.state.bind_assistant_snapshot(&store);
                shell.assistant = AssistantUi {
                    panel: AssistantPanel::Memory,
                    tasks_open: true,
                    snapshot: RunnerSnapshot {
                        store: Some(store.clone()),
                        ..Default::default()
                    },
                    ..Default::default()
                };
                if editor {
                    shell.assistant.memory.editor =
                        Some(MemoryDraft::new(&store, Some(&store.memories[0])));
                }
                shell
                    .composer
                    .update(cx, |input, cx| input.set_text("我的聊天草稿".into(), cx));
                cx.notify();
            })
            .unwrap();
        let mut f = Self { window, cx };
        f.draw();
        f
    }
    fn draw(&mut self) {
        self.cx.run_until_parked();
        self.cx.update(|w, cx| w.draw(cx).clear(cx));
    }
    fn bounds(&mut self, id: &'static str) -> Bounds<Pixels> {
        self.cx
            .debug_bounds(id)
            .unwrap_or_else(|| panic!("missing {id}"))
    }
    fn inside(&mut self, id: &'static str, width: f32, height: f32) {
        let b = self.bounds(id);
        assert!(
            b.left() >= px(0.)
                && b.right() <= px(width)
                && b.top() >= px(0.)
                && b.bottom() <= px(height),
            "{id} escaped: {b:?}"
        );
    }
}

#[test]
fn memory_panel_and_editor_fit_actual_phone_and_tablet_shell_without_replacing_chat() {
    for locale in [Locale::Zh, Locale::En] {
        for (width, height) in [(320., 568.), (393., 852.), (1024., 768.), (1366., 1024.)] {
            for editor in [false, true] {
                let mut f = Fixture::new(width, height, locale, editor);
                for id in [
                    "assistant-tab-tasks",
                    "assistant-tab-memory",
                    "assistant-task-panel",
                ] {
                    f.inside(id, width, height);
                }
                if editor {
                    for id in [
                        "assistant-memory-save",
                        "assistant-memory-cancel",
                        "assistant-memory-editor-scroll",
                    ] {
                        f.inside(id, width, height);
                    }
                    assert!(f.bounds("assistant-memory-save").size.height >= px(44.));
                } else {
                    f.inside("assistant-memory-list", width, height);
                }
                if width < 720. {
                    assert!(f.cx.debug_bounds("composer-card").is_none());
                } else {
                    f.inside("composer-card", width, height);
                }
                f.window
                    .read_with(&f.cx, |shell, cx| {
                        assert_eq!(shell.composer.read(cx).text(), "我的聊天草稿")
                    })
                    .unwrap();
            }
        }
    }
}

#[test]
fn memory_tabs_preserve_chat_draft_and_native_forms_hide_inline_input() {
    let mut f = Fixture::new(393., 852., Locale::Zh, false);
    let point = f.bounds("assistant-tab-tasks").center();
    f.cx.simulate_click(point, Modifiers::none());
    f.draw();
    f.window
        .read_with(&f.cx, |shell, _| {
            assert!(shell.assistant.panel == AssistantPanel::Tasks)
        })
        .unwrap();
    let point = f.bounds("assistant-tab-memory").center();
    f.cx.simulate_click(point, Modifiers::none());
    f.draw();
    f.window
        .update(&mut f.cx, |shell, _, cx| {
            assert!(shell.assistant.panel == AssistantPanel::Memory);
            assert!(!shell.chat_input_visible(393., false));
            shell.assistant.tasks_open = false;
            assert!(shell.chat_input_visible(393., false));
            shell.native_form_active = true;
            assert!(!shell.chat_input_visible(393., false));
            shell.native_form_active = false;
            assert_eq!(shell.composer.read(cx).text(), "我的聊天草稿");
            assert!(shell.chat_input_visible(393., false));
        })
        .unwrap();
}

#[test]
fn avatar_memory_entry_closes_profile_overlay_and_opens_memory_without_losing_draft() {
    let mut f = Fixture::new(1024., 1024., Locale::Zh, false);
    f.window
        .update(&mut f.cx, |shell, window, cx| {
            shell.page = Page::Settings;
            shell.assistant.tasks_open = false;
            shell.assistant.panel = AssistantPanel::Tasks;
            shell.assistant.profile_menu_open = true;
            let previous = cx.focus_handle();
            shell.assistant.profile_previous_focus = Some(previous);
            let focus = cx.focus_handle();
            window.focus(&focus, cx);
            shell.assistant.profile_menu_focus = Some(focus);
            cx.notify();
        })
        .unwrap();
    f.draw();
    let point = f.bounds("assistant-profile-memory").center();
    f.cx.simulate_click(point, Modifiers::none());
    f.draw();
    assert!(f.cx.debug_bounds("assistant-profile-menu").is_none());
    f.bounds("assistant-memory-list");
    f.window
        .read_with(&f.cx, |shell, cx| {
            assert!(shell.page == Page::Assistant);
            assert!(shell.assistant.panel == AssistantPanel::Memory);
            assert!(shell.assistant.profile_previous_focus.is_none());
            assert_eq!(shell.composer.read(cx).text(), "我的聊天草稿");
        })
        .unwrap();
}
