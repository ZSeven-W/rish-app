//! Render the complete Shell so navigation width and header height are already
//! deducted before the personal conversation chooses its task panel layout.
use super::assistant_forms::{AssistantUi, TaskEditor};
use super::*;
use crate::assistant_runtime::{RunnerSnapshot, RunnerStatus, test_fixture};
use gpui::{Bounds, Modifiers, Pixels, TestAppContext, VisualTestContext, WindowHandle, size};
use rish_shell_core::assistant_store::*;

struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
}
impl Fixture {
    fn new(width: f32, height: f32, locale: Locale) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(height)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                shell.page = Page::Assistant;
                shell.locale = locale;
                shell.loading = false;
                shell.state = test_fixture::loaded();
                shell.notice = None;
                shell.assistant = AssistantUi {
                    snapshot: RunnerSnapshot {
                        store: Some(AssistantSnapshot {
                            conversation_id: Some(test_fixture::CHAT.into()),
                            profile: AssistantProfile {
                                name: if locale == Locale::Zh {
                                    "与你一起把每天安排好的本机私人助理".repeat(3)
                                } else {
                                    "My thoughtful everyday personal assistant ".repeat(3)
                                },
                                ..Default::default()
                            },
                            tasks: vec![task()],
                            ..Default::default()
                        }),
                        ..Default::default()
                    },
                    ..Default::default()
                };
                shell.assistant_platform =
                    Some(json!({"preferences":{"background":true,"completed":true},
                "backgroundAvailable":true,"notifications":"denied"}));
                shell.update_placeholders(cx);
                shell.sync_transcript(cx);
                cx.notify();
            })
            .unwrap();
        let mut fixture = Self { window, cx };
        fixture.draw();
        fixture
    }
    fn draw(&mut self) {
        self.cx.run_until_parked();
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
    }
    fn bounds(&mut self, selector: &'static str) -> Bounds<Pixels> {
        self.cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"))
    }
    fn inside(&mut self, selector: &'static str, width: f32, height: f32) -> Bounds<Pixels> {
        let b = self.bounds(selector);
        assert!(
            b.left() >= px(0.) && b.right() <= px(width),
            "{selector} escaped width: {b:?}"
        );
        assert!(
            b.top() >= px(0.) && b.bottom() <= px(height),
            "{selector} escaped height: {b:?}"
        );
        b
    }
    fn click(&mut self, selector: &'static str) {
        let point = self.bounds(selector).center();
        self.cx.simulate_click(point, Modifiers::none());
        self.draw();
    }
}
fn task() -> AssistantTask {
    AssistantTask {
        id: "task-1".into(),
        title: "检查工作空间里的变更".into(),
        instructions: "逐条说明检查结果。".repeat(30),
        conversation_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into(),
        workspace_binding: json!({"workspace_id":"workspace-1"}),
        workspace_descriptor: json!({"workspace_id":"workspace-1","display_name":"中文工作空间"}),
        model_id: "deepseek-v4-flash".into(),
        runtime: None,
        interval_minutes: None,
        enabled: true,
        next_due_ms: None,
        pending_manual: false,
        last_run: None,
    }
}

#[test]
fn assistant_starts_with_real_chat_and_reserves_only_a_secondary_task_panel() {
    for locale in [Locale::Zh, Locale::En] {
        for (width, height) in [(320., 568.), (393., 852.), (1024., 768.), (1366., 1024.)] {
            let mut f = Fixture::new(width, height, locale);
            f.inside("assistant-page", width, height);
            f.inside("assistant-chat-identity", width, height);
            f.inside("assistant-profile-name", width, height);
            f.inside("assistant-welcome", width, height);
            let chat = f.inside("assistant-chat-pane", width, height);
            let composer = f.inside("composer-card", width, height);
            assert!(composer.left() >= chat.left() && composer.right() <= chat.right());
            assert!(f.cx.debug_bounds("assistant-hero").is_none());
            if width < 720. {
                assert!(f.cx.debug_bounds("assistant-task-panel").is_none());
                let toggle = f.inside("assistant-tasks-toggle", width, height);
                assert!(toggle.size.height >= px(44.) && toggle.size.width >= px(44.));
            } else {
                let panel = f.inside("assistant-task-panel", width, height);
                assert!((280.0..=320.0).contains(&f32::from(panel.size.width)));
                assert!(chat.size.width >= px(340.));
                assert!(panel.left() > chat.right());
                assert!(f.cx.debug_bounds("assistant-tasks-toggle").is_none());
            }
            f.window
                .read_with(&f.cx, |shell, _| {
                    assert!(shell.assistant_personal_chat_ready());
                    assert!(shell.chat_input_visible(width, false));
                    assert!(shell.page == Page::Assistant);
                    assert_eq!(
                        shell.composer_placeholder(),
                        if locale == Locale::Zh {
                            "想聊什么，或者有什么想交给我？"
                        } else {
                            "Tell me what you have in mind…"
                        }
                    );
                })
                .unwrap();
        }
    }
}

#[test]
fn phone_tasks_panel_is_dismissible_and_preserves_personal_draft() {
    let mut f = Fixture::new(393., 852., Locale::Zh);
    f.window
        .update(&mut f.cx, |shell, _, cx| {
            shell.composer.update(cx, |input, cx| {
                input.set_text("还没有发出的私人消息".into(), cx)
            });
        })
        .unwrap();
    f.click("assistant-tasks-toggle");
    f.inside("assistant-task-panel", 393., 852.);
    assert!(f.cx.debug_bounds("composer-card").is_none());
    f.window
        .read_with(&f.cx, |shell, _| {
            assert!(!shell.chat_input_visible(393., false))
        })
        .unwrap();
    f.click("assistant-tasks-close");
    f.inside("composer-card", 393., 852.);
    f.window
        .read_with(&f.cx, |shell, cx| {
            assert!(shell.chat_input_visible(393., false));
            assert_eq!(shell.composer.read(cx).text(), "还没有发出的私人消息");
            assert_eq!(
                shell.state.active_conversation_id(),
                Some(test_fixture::CHAT)
            );
        })
        .unwrap();
}

#[test]
fn assistant_overlays_hide_inline_input_and_restore_the_same_draft() {
    let mut f = Fixture::new(393., 852., Locale::En);
    f.window
        .update(&mut f.cx, |shell, _, cx| {
            shell
                .composer
                .update(cx, |input, cx| input.set_text("Keep this draft".into(), cx));
            for overlay in 0..4 {
                shell.drawer_open = overlay == 0;
                shell.model_picker = overlay == 1;
                shell.assistant.profile_menu_open = overlay == 2;
                shell.native_form_active = overlay == 3;
                assert!(!shell.chat_input_visible(393., false));
            }
            shell.drawer_open = false;
            shell.model_picker = false;
            shell.assistant.profile_menu_open = false;
            shell.native_form_active = false;
            assert!(shell.chat_input_visible(393., false));
            assert_eq!(shell.composer.read(cx).text(), "Keep this draft");
        })
        .unwrap();
}

#[test]
fn coding_or_task_conversation_is_never_rendered_under_personal_assistant_identity() {
    for lease in [false, true] {
        let mut f = Fixture::new(393., 852., Locale::Zh);
        f.window
            .update(&mut f.cx, |shell, _, cx| {
                shell
                    .assistant
                    .snapshot
                    .store
                    .as_mut()
                    .unwrap()
                    .conversation_id = Some("cccccccc-cccc-4ccc-8ccc-cccccccccccc".into());
                if lease {
                    shell.assistant_writer_lease = true;
                    shell.state = test_fixture::question();
                    shell.assistant.snapshot.state = Some(shell.state.clone());
                    shell.assistant.snapshot.active_task_id = Some("task-1".into());
                    shell.assistant.snapshot.status = RunnerStatus::NeedsAttention;
                    shell.assistant.snapshot.owns_writer = true;
                }
                shell.sync_transcript(cx);
                cx.notify();
            })
            .unwrap();
        f.draw();
        assert!(f.cx.debug_bounds("chat-page").is_none());
        assert!(f.cx.debug_bounds("composer-card").is_none());
        f.window
            .read_with(&f.cx, |shell, _| {
                assert!(!shell.assistant_personal_chat_ready());
                assert!(!shell.chat_input_visible(393., false));
            })
            .unwrap();
        if lease {
            f.bounds("assistant-task-running");
            f.bounds("assistant-running-open");
            f.bounds("agent-stop");
            assert!(f.cx.debug_bounds("assistant-welcome").is_none());
        } else {
            f.bounds("assistant-chat-preparing");
        }
    }
}

#[test]
fn task_editor_keeps_save_controls_inside_actual_shell_at_phone_and_tablet_widths() {
    for locale in [Locale::Zh, Locale::En] {
        for (width, height) in [(320., 568.), (393., 852.), (1024., 768.), (1366., 1024.)] {
            let mut f = Fixture::new(width, height, locale);
            f.window
                .update(&mut f.cx, |shell, _, cx| {
                    let config = task().config();
                    shell.assistant.tasks_open = true;
                    shell.assistant.editor = Some(TaskEditor {
                        id: "task-1".into(),
                        task_id: Some("task-1".into()),
                        expected_revision: 0,
                        base_config: Some(config.clone()),
                        config,
                        picker: None,
                        saving: false,
                        conflicted: false,
                    });
                    cx.notify();
                })
                .unwrap();
            f.draw();
            for id in [
                "assistant-save",
                "assistant-cancel",
                "assistant-editor-scroll",
            ] {
                let b = f.inside(id, width, height);
                assert!(b.size.height > px(0.));
            }
        }
    }
}

#[test]
fn coding_recents_hide_only_the_dedicated_personal_conversation() {
    let mut f = Fixture::new(1024., 768., Locale::Zh);
    f.window
        .update(&mut f.cx, |shell, _, cx| {
            for id in [
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            ] {
                let command = shell
                    .state
                    .create_conversation(id, test_fixture::NOW, "deepseek-v4-flash")
                    .unwrap();
                test_fixture::persist(&mut shell.state, command);
            }
            cx.notify();
        })
        .unwrap();
    f.draw();
    assert!(
        f.cx.debug_bounds("conversation-row-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            .is_none()
    );
    f.bounds("conversation-row-cccccccc-cccc-4ccc-8ccc-cccccccccccc");
    f.bounds("conversation-row-dddddddd-dddd-4ddd-8ddd-dddddddddddd");
    f.window
        .read_with(&f.cx, |shell, _| {
            assert_eq!(shell.state.conversations().len(), 3)
        })
        .unwrap();
}
