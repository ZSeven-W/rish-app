//! Headless GPUI event and layout tests for the Configure overlay.

use super::model_picker::ConfigurationPage;
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
    fn new(width: f32, height: f32) -> Self {
        // The headless platform exercises layout, focus and dispatched events;
        // it intentionally does not paint SVG assets or call the native runtime.
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(width), px(height)), |_, cx| Shell::new(cx));
        let cx = VisualTestContext::from_window(window.into(), &cx);
        let mut fixture = Self { window, cx };
        fixture.update(|shell, window, cx| {
            shell.locale = Locale::En;
            shell.state = ShellState::with_test_models();
            shell
                .state
                .load_snapshot(json!({"schema_version":1,"status":"missing"}))
                .unwrap();
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

    fn assert_composer_focused(&mut self) {
        self.update(|shell, window, cx| {
            assert!(shell.composer.read(cx).focus_handle(cx).is_focused(window));
        });
    }

    fn assert_draft(&self, model: &str, thinking: &str) {
        self.read(|shell, _| {
            let draft = shell
                .config_draft
                .as_ref()
                .expect("open configuration draft");
            assert_eq!(draft.model, model);
            assert_eq!(draft.thinking, thinking);
        });
    }

    fn assert_session_unchanged(&self, session: &Value) {
        self.read(|shell, cx| {
            assert_eq!(shell.state.raw_session(), session);
            assert_eq!(shell.composer.read(cx).text(), "Keep this draft");
            assert!(!shell.loading);
            assert!(!shell.state.is_busy());
            assert!(
                shell.state.can_reload(),
                "configuration navigation must not queue a persistence write"
            );
        });
    }

    fn assert_configure_page(&mut self) {
        assert!(self.read(|shell, _| shell.model_picker));
        assert!(self.read(|shell, _| shell.config_page == ConfigurationPage::Configure));
        assert!(self.cx.debug_bounds("config-model-row").is_some());
        assert!(self.cx.debug_bounds("config-thinking-row").is_some());
        assert!(self.cx.debug_bounds("config-done").is_some());
        assert!(self.cx.debug_bounds("model-picker-list").is_none());
        assert!(self.cx.debug_bounds("thinking-picker-list").is_none());
    }

    fn escape(&mut self) {
        self.cx.simulate_keystrokes("escape");
        self.draw();
    }

    fn load_transcript(&mut self) {
        self.update(|shell, _, cx| {
            shell.state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
            let command = shell
                .state
                .create_conversation(
                    "aaaaaaaa-aaaa-4aaa-8aaa-000000000001",
                    "2026-10-14T00:00:00.000Z",
                    "deepseek-v4-flash",
                )
                .unwrap();
            commit_candidate(&mut shell.state, command, 1);
            let command = shell
                .state
                .prepare_send(
                    "Keep this transcript message",
                    &TurnIds::new(),
                    "2026-10-14T00:00:01.000Z",
                )
                .unwrap();
            commit_candidate(&mut shell.state, command, 2);
            // Settle the fixture turn without dispatching a native completion.
            let command = shell
                .state
                .fail_send("E_TEST_OFFLINE", "2026-10-14T00:00:02.000Z")
                .unwrap();
            commit_candidate(&mut shell.state, command, 3);
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
fn model_picker_configure_is_compact_and_preserves_chat_layout_and_focus() {
    for (width, height) in [(390., 844.), (844., 390.)] {
        for with_transcript in [false, true] {
            let mut fixture = Fixture::new(width, height);
            if with_transcript {
                fixture.load_transcript();
            }
            let composer = fixture.bounds("composer-card");
            let chat = fixture.bounds("chat-page");
            let entities =
                fixture.read(|shell, _| (shell.composer.entity_id(), shell.transcript.entity_id()));

            fixture.click("model-picker-open");

            fixture.assert_configure_page();
            let panel = fixture.bounds("config-panel");
            let model = fixture.bounds("config-model-row");
            let thinking = fixture.bounds("config-thinking-row");
            let done = fixture.bounds("config-done");
            assert!(model.bottom() <= thinking.top());
            assert!(thinking.bottom() <= done.top());
            assert!(panel.contains(&model.center()));
            assert!(panel.contains(&thinking.center()));
            assert!(panel.contains(&done.center()));
            assert!(done.size.height >= px(44.));
            if height > width {
                assert!(panel.size.height < px(height / 2.));
            }
            assert_eq!(fixture.bounds("composer-card"), composer);
            assert_eq!(fixture.bounds("chat-page"), chat);
            fixture.update(|shell, window, _| {
                assert!(shell.model_picker_focus.is_focused(window));
            });
            fixture.escape();

            assert!(!fixture.read(|shell, _| shell.model_picker));
            assert!(fixture.cx.debug_bounds("config-panel").is_none());
            fixture.assert_composer_focused();
            assert_eq!(fixture.bounds("composer-card"), composer);
            fixture.read(|shell, cx| {
                assert_eq!(
                    (shell.composer.entity_id(), shell.transcript.entity_id()),
                    entities
                );
                assert_eq!(shell.composer.read(cx).text(), "Keep this draft");
            });
        }
    }
}

#[test]
fn model_picker_choices_stage_a_draft_and_done_preserves_the_native_write_guard() {
    let mut fixture = Fixture::new(390., 844.);
    fixture.load_transcript();
    let session = fixture.read(|shell, _| shell.state.raw_session().clone());
    let composer = fixture.bounds("composer-card");
    let chat = fixture.bounds("chat-page");

    fixture.click("model-picker-open");
    fixture.assert_draft("deepseek-v4-flash", "high");
    fixture.click("config-model-row");
    assert!(fixture.read(|shell, _| shell.config_page == ConfigurationPage::Models));
    assert!(fixture.cx.debug_bounds("model-picker-list").is_some());
    assert!(fixture.cx.debug_bounds("config-thinking-row").is_none());
    assert_eq!(fixture.bounds("composer-card"), composer);
    assert_eq!(fixture.bounds("chat-page"), chat);
    fixture.click("model-picker-row-deepseek-v4-pro");

    fixture.assert_configure_page();
    fixture.assert_draft("deepseek-v4-pro", "high");
    fixture.assert_session_unchanged(&session);

    for (selector, thinking) in [
        ("thinking-picker-row-off", "off"),
        ("thinking-picker-row-high", "high"),
        ("thinking-picker-row-max", "max"),
    ] {
        fixture.click("config-thinking-row");
        assert!(fixture.read(|shell, _| shell.config_page == ConfigurationPage::Thinking));
        assert!(fixture.cx.debug_bounds("thinking-picker-list").is_some());
        assert!(fixture.cx.debug_bounds("model-picker-list").is_none());
        assert_eq!(fixture.bounds("composer-card"), composer);
        assert_eq!(fixture.bounds("chat-page"), chat);
        fixture.click(selector);

        fixture.assert_configure_page();
        fixture.assert_draft("deepseek-v4-pro", thinking);
        fixture.assert_session_unchanged(&session);
    }

    assert!(!fixture.read(|shell, _| shell.runtime.is_native()));
    fixture.click("config-done");
    fixture.assert_configure_page();
    fixture.assert_draft("deepseek-v4-pro", "max");
    fixture.assert_session_unchanged(&session);
    fixture.escape();
    fixture.assert_composer_focused();
}

#[test]
fn model_picker_without_previous_focus_dismisses_without_focusing_the_chat() {
    let mut fixture = Fixture::new(390., 844.);
    fixture.update(|_, window, cx| window.blur(cx));
    fixture.draw();
    fixture.click("model-picker-open");
    fixture.read(|shell, _| assert!(shell.model_picker_previous_focus.is_none()));
    fixture.escape();

    assert!(!fixture.read(|shell, _| shell.model_picker));
    fixture.update(|_, window, cx| assert!(window.focused(cx).is_none()));
}

#[test]
fn model_picker_cancel_and_scrim_discard_changes_and_restore_current_values() {
    let mut fixture = Fixture::new(390., 844.);
    fixture.load_transcript();
    fixture.update(|shell, _, cx| {
        shell.notice = Some("Keep this notice".into());
        cx.notify();
    });
    fixture.draw();
    let session = fixture.read(|shell, _| shell.state.raw_session().clone());
    let underlying_workspace = fixture.bounds("workspace-toggle").center();

    for cancel_button in [false, true] {
        fixture.click("model-picker-open");
        fixture.assert_draft("deepseek-v4-flash", "high");
        fixture.click("config-model-row");
        fixture.click("model-picker-row-deepseek-v4-pro");
        fixture.click("config-thinking-row");
        fixture.click("thinking-picker-row-off");
        fixture.assert_draft("deepseek-v4-pro", "off");
        if cancel_button {
            fixture.click("config-model-row");
            fixture.click("model-picker-close");
        } else {
            assert!(
                !fixture
                    .bounds("config-panel")
                    .contains(&underlying_workspace)
            );
            assert!(
                fixture
                    .bounds("model-picker-scrim")
                    .contains(&underlying_workspace)
            );
            fixture.click_at(underlying_workspace);
        }
        fixture.read(|shell, _| {
            assert!(!shell.model_picker);
            assert!(shell.config_draft.is_none());
            assert_eq!(shell.notice.as_deref(), Some("Keep this notice"));
        });
        fixture.assert_session_unchanged(&session);
        assert!(fixture.cx.debug_bounds("config-panel").is_none());
        fixture.assert_composer_focused();
    }
    fixture.click("model-picker-open");
    fixture.assert_draft("deepseek-v4-flash", "high");
    fixture.assert_configure_page();
}

#[test]
fn model_picker_unchanged_done_closes_without_creating_a_conversation_or_write() {
    for with_transcript in [false, true] {
        let mut fixture = Fixture::new(390., 844.);
        if with_transcript {
            fixture.load_transcript();
        }
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        fixture.click("model-picker-open");
        fixture.click("config-model-row");
        fixture.click("model-picker-row-deepseek-v4-flash");
        fixture.assert_configure_page();
        fixture.click("config-thinking-row");
        fixture.click("thinking-picker-row-high");
        fixture.assert_configure_page();
        fixture.click("config-done");

        assert!(!fixture.read(|shell, _| shell.model_picker));
        assert!(fixture.read(|shell, _| shell.config_draft.is_none()));
        fixture.assert_session_unchanged(&session);
        fixture.assert_composer_focused();
    }
}

#[test]
fn model_picker_secondary_back_preserves_draft_and_escape_discards_it() {
    let mut fixture = Fixture::new(390., 844.);
    let session = fixture.read(|shell, _| shell.state.raw_session().clone());
    fixture.click("model-picker-open");
    fixture.click("config-model-row");
    fixture.click("model-picker-row-deepseek-v4-pro");
    fixture.click("config-thinking-row");
    fixture.click("model-picker-back");
    fixture.assert_configure_page();
    fixture.assert_draft("deepseek-v4-pro", "high");
    fixture.update(|shell, window, _| {
        assert!(shell.model_picker_focus.is_focused(window));
    });
    fixture.click("config-model-row");
    fixture.click("model-picker-back");
    fixture.assert_configure_page();
    fixture.assert_draft("deepseek-v4-pro", "high");
    fixture.click("config-thinking-row");
    fixture.escape();

    assert!(!fixture.read(|shell, _| shell.model_picker));
    fixture.assert_session_unchanged(&session);
    fixture.assert_composer_focused();
    fixture.click("model-picker-open");
    fixture.assert_draft("deepseek-v4-flash", "high");
}

#[test]
fn model_picker_short_landscape_bounds_done_and_scrolls_models_with_fixed_navigation() {
    let mut fixture = Fixture::new(844., 390.);
    fixture.click("model-picker-open");
    let configure = fixture.bounds("config-panel");
    let done = fixture.bounds("config-done");
    assert!(configure.left() >= px(0.) && configure.top() >= px(0.));
    assert!(configure.right() <= px(844.) && configure.bottom() <= px(390.));
    assert!(done.top() >= configure.top() && done.bottom() <= configure.bottom());
    assert!(done.left() >= configure.left() && done.right() <= configure.right());

    fixture.click("config-model-row");
    let panel = fixture.bounds("config-panel");
    let list = fixture.bounds("model-picker-list");
    let header = fixture.bounds("model-picker-header");
    let close = fixture.bounds("model-picker-close");
    let back = fixture.bounds("model-picker-back");
    assert!(panel.left() >= px(0.) && panel.top() >= px(0.));
    assert!(panel.right() <= px(844.) && panel.bottom() <= px(390.));
    assert!(list.top() >= header.bottom());
    assert!(list.bottom() <= panel.bottom());
    assert!(panel.contains(&close.center()));
    assert!(panel.contains(&back.center()));
    assert!(list.size.height > px(0.));
    assert!(!list.contains(&fixture.bounds("model-picker-row-GLM-5.3-Flash").center()));

    fixture.cx.simulate_event(ScrollWheelEvent {
        position: list.center(),
        delta: ScrollDelta::Pixels(point(px(0.), px(-10_000.))),
        modifiers: Modifiers::none(),
        touch_phase: TouchPhase::Moved,
    });
    fixture.draw();

    assert!(fixture.read(|shell, _| shell.model_picker_scroll.offset().y) < px(0.));
    assert!(list.contains(&fixture.bounds("model-picker-row-GLM-5.3-Flash").center()));
    assert!(list.contains(&fixture.bounds("model-picker-group-glm").center()));
    assert_eq!(fixture.bounds("model-picker-header"), header);
    assert_eq!(fixture.bounds("model-picker-close"), close);
    assert_eq!(fixture.bounds("model-picker-back"), back);
    assert_eq!(fixture.bounds("config-panel"), panel);
    fixture.click("model-picker-back");
    assert_eq!(fixture.bounds("config-panel"), configure);
    assert_eq!(fixture.bounds("config-done"), done);
    fixture.click("config-done");
    assert!(!fixture.read(|shell, _| shell.model_picker));
    fixture.assert_composer_focused();
}

#[test]
fn model_setup_roundtrip_preserves_chat_and_configuration_drafts_on_phone_and_tablet() {
    for (width, height) in [(390., 844.), (844., 390.), (1194., 834.)] {
        let mut fixture = Fixture::new(width, height);
        fixture.load_transcript();
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        fixture.click("model-picker-open");
        fixture.update(|shell, _, cx| {
            shell.config_draft.as_mut().unwrap().thinking = "max".into();
            shell.show_configuration_page(ConfigurationPage::Models, cx);
        });
        fixture.draw();
        let entry = fixture.bounds("model-picker-add-model");
        assert!(
            fixture
                .bounds("model-picker-list")
                .contains(&entry.center())
        );
        fixture.click("model-picker-add-model");
        assert!(fixture.read(|shell, _| shell.page == Page::Chat));
        assert!(fixture.read(|shell, _| shell.config_page == ConfigurationPage::Providers));
        let panel = fixture.bounds("config-panel");
        let setup = fixture.bounds("model-picker-provider-setup");
        assert!(setup.bottom() <= panel.bottom());
        assert!(panel.contains(&fixture.bounds("model-picker-back").center()));
        assert!(
            fixture
                .cx
                .debug_bounds("settings-add-custom-provider")
                .is_some()
        );
        fixture.click("DEEPSEEK_API_KEY");
        assert!(fixture.cx.debug_bounds("provider-models-editor").is_some());
        fixture.assert_draft("deepseek-v4-flash", "max");
        fixture.assert_session_unchanged(&session);
        fixture.click("model-picker-back");
        assert!(fixture.read(|shell, _| shell.config_page == ConfigurationPage::Models));
        fixture.assert_draft("deepseek-v4-flash", "max");
        fixture.assert_session_unchanged(&session);
        fixture.escape();
        fixture.assert_composer_focused();
    }
}

#[test]
fn removed_staged_model_keeps_configuration_draft_and_shows_validation_error() {
    let mut fixture = Fixture::new(390., 844.);
    fixture.load_transcript();
    let session = fixture.read(|shell, _| shell.state.raw_session().clone());
    fixture.click("model-picker-open");
    fixture.click("config-model-row");
    fixture.click("model-picker-row-deepseek-v4-pro");
    fixture.click("config-thinking-row");
    fixture.click("thinking-picker-row-max");
    fixture.click("config-model-row");
    fixture.click("model-picker-add-model");
    // Accept the same saved catalog response used by the provider editor, with
    // the staged model removed. Existing conversation A must remain unchanged.
    fixture.update(|shell, _, cx| {
        let models = shell.state.models();
        let initial = json!({"schema_version":1,"revision":0,"providers":
            provider_models::HARNESSES.iter().map(|harness| json!({
                "harness_id":harness,"models":models.iter().filter(|model| model.harness==*harness)
                    .map(|model| json!({"id":model.id,"name":model.name,"supports_images":false}))
                    .collect::<Vec<_>>(),"retired_models":[]
            })).collect::<Vec<_>>()});
        let remaining: Vec<_> = models.iter().filter(|model| model.harness=="dsh" && model.id!="deepseek-v4-pro")
            .map(|model| json!({"id":model.id,"name":model.name,"supports_images":false})).collect();
        // The real save reducer retires B and preserves all historical IDs.
        let catalog = rish_shell_core::provider_model_catalog::save_registry(&initial,
            &json!({"schema_version":1,"harness_id":"dsh","expected_revision":0,"models":remaining}),
            &Value::Null, &[]).unwrap();
        shell.accept_provider_models_snapshot(catalog).unwrap();
        cx.notify();
    });
    fixture.draw();
    fixture.click("model-picker-back");
    fixture.click("model-picker-back");
    // Headless runtime deliberately cannot persist. Exercise Done's native
    // preparation result with the actual shared-core rejection instead.
    fixture.update(|shell, window, cx| {
        let draft = shell.config_draft.as_ref().unwrap().clone();
        let result = shell
            .state
            .set_chat_configuration(&draft.model, &draft.thinking);
        assert_eq!(result.as_ref().unwrap_err(), "Choose a current model");
        shell.complete_configuration_preparation(result, window, cx);
    });
    fixture.draw();
    fixture.assert_configure_page();
    fixture.assert_draft("deepseek-v4-pro", "max");
    fixture.assert_session_unchanged(&session);
    let error = fixture.bounds("config-error");
    assert!(fixture.bounds("config-panel").contains(&error.center()));
    fixture.update(|shell, window, _| assert!(shell.model_picker_focus.is_focused(window)));
    fixture.click("config-model-row");
    fixture.click("model-picker-row-deepseek-v4-flash");
    fixture.assert_draft("deepseek-v4-flash", "max");
    assert!(fixture.cx.debug_bounds("config-error").is_none());
    fixture.assert_session_unchanged(&session);
}
