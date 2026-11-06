//! Headless GPUI event tests for the shared drawer and sidebar.

use super::*;
use gpui::{
    Bounds, Focusable, Modifiers, Pixels, Point, ScrollDelta, ScrollWheelEvent, TestAppContext,
    TouchPhase, VisualTestContext, WindowHandle, point, size,
};

struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
}

impl Fixture {
    fn new() -> Self {
        // TestAppContext provides bounds selectors and a fully headless TestPlatform.
        // Its mock renderer has no asset-source setter, so SVG paint is intentionally
        // omitted; these tests exercise layout, focus and event dispatch, not pixels.
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
        let cx = VisualTestContext::from_window(window.into(), &cx);
        let mut fixture = Self { window, cx };
        fixture.update(|shell, window, cx| {
            shell.locale = Locale::En;
            shell
                .composer
                .update(cx, |input, cx| input.set_text("Keep this draft".into(), cx));
            window.focus(&shell.composer.read(cx).focus_handle(cx), cx);
            cx.notify();
        });
        fixture.draw();
        fixture
    }

    fn update<R>(
        &mut self,
        f: impl FnOnce(&mut Shell, &mut Window, &mut Context<Shell>) -> R,
    ) -> R {
        self.window.update(&mut self.cx, f).unwrap()
    }

    fn read<R>(&self, f: impl FnOnce(&Shell, &App) -> R) -> R {
        self.window.read_with(&self.cx, f).unwrap()
    }

    fn draw(&mut self) {
        self.cx.run_until_parked();
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
    }

    fn bounds(&mut self, selector: &'static str) -> Bounds<Pixels> {
        self.cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("Missing rendered selector: {selector}"))
    }

    fn click_at(&mut self, position: Point<Pixels>) {
        self.cx.simulate_click(position, Modifiers::none());
        self.draw();
    }

    fn click(&mut self, selector: &'static str) {
        let position = self.bounds(selector).center();
        self.click_at(position);
    }

    fn dismiss_scrim(&mut self) {
        let panel = self.bounds("drawer-panel");
        let scrim = self.bounds("drawer-scrim");
        let position = point(scrim.right() - px(8.), scrim.center().y);
        assert!(
            position.x > panel.right(),
            "the dismissal must target the uncovered scrim"
        );
        self.click_at(position);
    }

    fn resize(&mut self, width: f32) {
        self.cx.simulate_resize(size(px(width), px(844.)));
        self.draw();
    }

    fn load_history(&mut self) {
        let mut state = ShellState::with_test_models();
        state
            .load_snapshot(json!({"schema_version":1,"status":"missing"}))
            .unwrap();
        state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
        for index in 0..32 {
            let command = state
                .create_conversation(
                    &format!("aaaaaaaa-aaaa-4aaa-8aaa-{index:012}"),
                    "2026-10-14T00:00:00.000Z",
                    "deepseek-v4-flash",
                )
                .unwrap();
            commit_candidate(&mut state, command, index + 1);
        }
        let command = state
            .prepare_send(
                "Keep this transcript message",
                &TurnIds::new(),
                "2026-10-14T00:00:01.000Z",
            )
            .unwrap();
        // Publishing the fixture's pending user message mounts the actual transcript.
        // The returned completion command is not dispatched to any native runtime.
        commit_candidate(&mut state, command, 33);
        self.update(|shell, _, cx| {
            shell.state = state;
            shell.sync_transcript(cx);
            cx.notify();
        });
        self.draw();
    }
}

fn commit_candidate(state: &mut ShellState, command: RuntimeCommand, generation: u64) {
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    let digest = rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap();
    state
        .accept_persist(json!({
            "schema_version":1,"status":"committed",
            "snapshot":{"schema_version":1,"generation":generation,"session_sha256":digest}
        }))
        .unwrap();
}

#[test]
fn drawer_scrim_dismisses_without_activating_the_underlying_workspace() {
    let mut fixture = Fixture::new();
    fixture.update(|shell, _, cx| {
        shell.notice = Some("Keep this notice".into());
        cx.notify();
    });
    fixture.draw();
    let workspace = fixture.bounds("workspace-toggle").center();
    fixture.click("drawer-open");
    assert!(fixture.read(|shell, _| shell.drawer_open));
    assert!(fixture.cx.debug_bounds("drawer-close").is_none());
    let panel = fixture.bounds("drawer-panel");
    assert!(workspace.x > panel.right());
    assert!(fixture.bounds("drawer-scrim").contains(&workspace));

    fixture.click_at(workspace);

    fixture.read(|shell, cx| {
        assert!(!shell.drawer_open);
        assert_eq!(shell.composer.read(cx).text(), "Keep this draft");
        assert_eq!(shell.notice.as_deref(), Some("Keep this notice"));
        assert!(shell.page == Page::Chat);
        assert!(!shell.state.is_busy());
    });
    assert!(fixture.cx.debug_bounds("drawer-panel").is_none());
    fixture.update(|shell, window, cx| {
        assert!(shell.composer.read(cx).focus_handle(cx).is_focused(window));
    });
}

#[test]
fn drawer_interior_keeps_it_open_and_settings_navigation_closes_it() {
    let mut fixture = Fixture::new();
    fixture.click("drawer-open");
    let panel = fixture.bounds("drawer-panel");
    fixture.click_at(panel.origin + point(px(4.), px(4.)));
    assert!(fixture.read(|shell, _| shell.drawer_open));
    fixture.update(|shell, window, _| {
        assert!(shell.drawer_focus.is_focused(window));
    });

    fixture.cx.simulate_keystrokes("escape");
    fixture.draw();
    assert!(!fixture.read(|shell, _| shell.drawer_open));
    fixture.update(|shell, window, cx| {
        assert!(shell.composer.read(cx).focus_handle(cx).is_focused(window));
    });
    fixture.click("drawer-open");

    fixture.click("settings");

    fixture.read(|shell, cx| {
        assert!(!shell.drawer_open);
        assert!(shell.page == Page::Settings);
        assert_eq!(shell.composer.read(cx).text(), "Keep this draft");
    });
    assert!(fixture.cx.debug_bounds("drawer-panel").is_none());
}

#[test]
fn drawer_history_scroll_and_entities_survive_close_and_wide_resize() {
    let mut fixture = Fixture::new();
    fixture.load_history();
    let entities =
        fixture.read(|shell, _| (shell.composer.entity_id(), shell.transcript.entity_id()));
    fixture.click("drawer-open");
    let history = fixture.bounds("conversation-list");
    fixture.cx.simulate_event(ScrollWheelEvent {
        position: history.center(),
        delta: ScrollDelta::Pixels(point(px(0.), px(-180.))),
        modifiers: Modifiers::none(),
        touch_phase: TouchPhase::Moved,
    });
    fixture.draw();
    let scroll = fixture.read(|shell, _| shell.conversation_scroll.offset());
    assert!(
        scroll.y < px(0.),
        "history must actually scroll before testing retention"
    );

    assert!(fixture.cx.debug_bounds("drawer-close").is_none());
    fixture.dismiss_scrim();
    fixture.click("drawer-open");
    assert_eq!(
        fixture.read(|shell, _| shell.conversation_scroll.offset()),
        scroll
    );
    fixture.resize(1100.);
    assert!(!fixture.read(|shell, _| shell.drawer_open));
    assert!(fixture.cx.debug_bounds("drawer-panel").is_none());
    assert!(fixture.cx.debug_bounds("drawer-open").is_none());
    assert_eq!(
        fixture.read(|shell, _| shell.conversation_scroll.offset()),
        scroll
    );

    fixture.resize(390.);
    assert!(fixture.cx.debug_bounds("drawer-panel").is_none());
    fixture.click("drawer-open");
    fixture.read(|shell, cx| {
        assert_eq!(
            (shell.composer.entity_id(), shell.transcript.entity_id()),
            entities
        );
        assert_eq!(shell.composer.read(cx).text(), "Keep this draft");
        assert_eq!(shell.state.conversations().len(), 32);
        assert_eq!(
            shell.state.messages()[0].text,
            "Keep this transcript message"
        );
        assert_eq!(shell.conversation_scroll.offset(), scroll);
    });
}

#[test]
fn chat_controls_keep_readable_width_and_stay_visible_when_resizing() {
    let mut fixture = Fixture::new();
    fixture.update(|shell, _, cx| {
        shell.conversation_workspace.descriptor = Some(json!({
            "display_name": "用于验证长名称换行与省略的工作空间"
        }));
        cx.notify();
    });
    let entities =
        fixture.read(|shell, _| (shell.composer.entity_id(), shell.transcript.entity_id()));
    for (width, height, empty_draft) in [
        (320., 568., false),
        (390., 844., false),
        (768., 1024., false),
        (1366., 1024., false),
        (844., 390., false),
        (390., 844., true),
    ] {
        if empty_draft {
            fixture.update(|shell, _, cx| {
                shell
                    .composer
                    .update(cx, |input, cx| input.set_text(String::new(), cx));
                cx.notify();
            });
        }
        fixture.cx.simulate_resize(size(px(width), px(height)));
        fixture.draw();
        let chat = fixture.bounds("chat-page");
        let composer = fixture.bounds("composer-card");
        assert!(composer.size.width <= px(720.));
        assert!(composer.left() >= chat.left());
        assert!(composer.right() <= chat.right());
        assert!(composer.top() >= chat.top());
        assert!(composer.bottom() <= chat.bottom());
        if empty_draft {
            assert!(
                composer.size.height <= px(132.),
                "Empty phone composer must remain compact"
            );
        }
        let controls = [
            "conversation-workspace",
            "model-picker-open",
            "config-thinking-open",
            "composer-send",
        ]
        .map(|selector| (selector, fixture.bounds(selector)));
        for (selector, control) in &controls {
            assert!(
                control.left() >= composer.left() && control.right() <= composer.right(),
                "{selector} must fit horizontally at {width} x {height}"
            );
            assert!(
                control.top() >= composer.top() && control.bottom() <= composer.bottom(),
                "{selector} must fit vertically at {width} x {height}"
            );
            assert!(control.size.height >= px(44.) && control.size.width >= px(44.));
        }
        // Keep all four hit targets separate and reachable, even on the
        // smallest phone. The compact footer must not wrap into extra rows.
        for (index, (first_name, first)) in controls.iter().enumerate() {
            for (second_name, second) in &controls[index + 1..] {
                assert!(
                    first.right() <= second.left()
                        || second.right() <= first.left()
                        || first.bottom() <= second.top()
                        || second.bottom() <= first.top(),
                    "{first_name} overlaps {second_name} at {width} x {height}"
                );
            }
        }
        for pair in controls.windows(2) {
            let (first_name, first) = &pair[0];
            let (second_name, second) = &pair[1];
            assert!(
                first.right() <= second.left(),
                "Composer order must be workspace, model, thinking, send at {width} x {height}: {first_name} before {second_name}"
            );
            assert!(
                (first.center().y - second.center().y).abs() <= px(1.),
                "{first_name} and {second_name} must share a row at {width} x {height}"
            );
        }
        fixture.read(|shell, cx| {
            assert_eq!(
                shell.composer.read(cx).text(),
                if empty_draft { "" } else { "Keep this draft" }
            );
            assert_eq!(
                (shell.composer.entity_id(), shell.transcript.entity_id()),
                entities
            );
        });
    }
}

#[test]
fn sidebar_keeps_conversations_and_settings_without_global_workspace_navigation() {
    let mut fixture = Fixture::new();
    fixture.click("drawer-open");
    assert!(fixture.cx.debug_bounds("conversation-list").is_some());
    assert!(fixture.cx.debug_bounds("settings").is_some());
    assert!(fixture.cx.debug_bounds("files").is_none());
    assert!(fixture.cx.debug_bounds("git").is_none());
    fixture.click("settings");
    assert!(fixture.read(|shell, _| shell.page == Page::Settings && !shell.drawer_open));
}

#[test]
fn drawer_shows_person_nickname_independent_of_selected_bot_without_close_button() {
    use crate::assistant_runtime::RunnerSnapshot;
    use rish_shell_core::assistant_store::{
        AssistantBot, AssistantProfile, AssistantSnapshot, DEFAULT_BOT_ID,
    };
    let mut fixture = Fixture::new();
    let bot = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    let full = AssistantSnapshot {
        user_nickname: Some("RIsh Master".into()),
        profile: AssistantProfile {
            name: "Planning Bot".into(),
            ..Default::default()
        },
        bots: vec![AssistantBot {
            id: bot.into(),
            profile: AssistantProfile {
                name: "Review Bot".into(),
                ..Default::default()
            },
            conversation_id: None,
            tasks: Vec::new(),
            memories: Vec::new(),
        }],
        ..Default::default()
    };
    for id in [DEFAULT_BOT_ID, bot] {
        fixture.update(|shell, _, cx| {
            shell.page = Page::Assistant;
            shell.assistant.directory_ui.hub_open = true;
            shell.assistant.snapshot = RunnerSnapshot {
                directory: Some(full.clone()),
                store: full.bot_snapshot(id),
                selected_bot_id: id.into(),
                ..Default::default()
            };
            cx.notify();
        });
        fixture.draw();
        fixture.click("drawer-open");
        assert!(fixture.cx.debug_bounds("drawer-close").is_none());
        let header = fixture.bounds("sidebar-user-identity");
        let name = fixture.bounds("sidebar-user-nickname");
        assert!(name.left() >= header.left() && name.right() <= header.right());
        fixture.read(|shell, _| {
            assert_eq!(shell.sidebar_user_nickname(), "RIsh Master");
            assert_ne!(
                shell.assistant.visible_profile().unwrap().name,
                shell.sidebar_user_nickname()
            );
        });
        fixture.dismiss_scrim();
    }
    fixture.resize(1194.);
    fixture.bounds("sidebar-user-nickname");
    assert!(fixture.cx.debug_bounds("drawer-close").is_none());
    assert_eq!(
        fixture.read(|shell, _| shell.sidebar_user_nickname()),
        "RIsh Master"
    );
}
