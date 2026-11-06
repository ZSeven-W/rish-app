//! Real settings layout checks at phone, Split View and landscape tablet sizes.
use super::*;
use gpui::{
    Bounds, Modifiers, Pixels, ScrollDelta, ScrollWheelEvent, TestAppContext, TouchPhase,
    VisualTestContext, WindowHandle, point, size,
};

struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
}

impl Fixture {
    fn new(width: f32, locale: Locale) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(844.)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                shell.state = ShellState::with_test_models();
                shell.page = Page::Settings;
                shell.locale = locale;
                shell.loading = false;
                shell.notice = None;
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

    fn bounds(&mut self, selector: &str) -> Bounds<Pixels> {
        // GPUI's test API requires static selectors; generated catalog IDs
        // belong to these bounded fixtures for the lifetime of this test process.
        let selector = Box::leak(selector.to_owned().into_boxed_str());
        self.cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"))
    }

    fn resize(&mut self, width: f32) {
        self.cx.simulate_resize(size(px(width), px(844.)));
        self.draw();
    }

    fn click(&mut self, selector: &'static str) {
        self.reveal(selector);
        let position = self.bounds(selector).center();
        self.cx.simulate_click(position, Modifiers::none());
        self.draw();
    }

    fn reveal(&mut self, selector: &str) {
        let viewport = self.bounds("settings-content");
        let control = self.bounds(selector);
        let delta = if control.bottom() > viewport.bottom() {
            viewport.bottom() - control.bottom() - px(1.)
        } else if control.top() < viewport.top() {
            viewport.top() - control.top() + px(1.)
        } else {
            px(0.)
        };
        self.cx.simulate_event(ScrollWheelEvent {
            position: point(viewport.left() + px(2.), viewport.center().y),
            delta: ScrollDelta::Pixels(point(px(0.), delta)),
            modifiers: Modifiers::none(),
            touch_phase: TouchPhase::Moved,
        });
        self.draw();
    }

    fn assert_choices(&mut self, group: settings::PreferenceGroup) {
        self.window
            .update(&mut self.cx, |shell, _, cx| {
                shell.settings_expanded = Some(group);
                cx.notify();
            })
            .unwrap();
        self.draw();
        let content = self.bounds("settings-content");
        let choices: Vec<String> = match group {
            settings::PreferenceGroup::Models => self
                .window
                .read_with(&self.cx, |shell, _| {
                    shell
                        .state
                        .models()
                        .iter()
                        .map(|model| format!("settings-default-model-{}", model.id))
                        .collect()
                })
                .unwrap(),
            settings::PreferenceGroup::Accounts => [
                "DEEPSEEK_API_KEY",
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "BIGMODEL_API_KEY",
            ]
            .map(String::from)
            .to_vec(),
            settings::PreferenceGroup::Runtime => [
                "settings-runtime-pi",
                "settings-runtime-dsh",
                "settings-runtime-claude-code",
                "settings-runtime-codex",
                "settings-runtime-zcode",
                "settings-runtime-custom",
            ]
            .map(String::from)
            .to_vec(),
            settings::PreferenceGroup::Appearance => ["theme-light", "theme-dark", "theme-system"]
                .map(String::from)
                .to_vec(),
            settings::PreferenceGroup::Language => {
                ["language-zh", "language-en"].map(String::from).to_vec()
            }
        };
        let vertical = matches!(
            group,
            settings::PreferenceGroup::Models
                | settings::PreferenceGroup::Accounts
                | settings::PreferenceGroup::Runtime
        );
        let mut last = None;
        for selector in choices {
            let bounds = self.bounds(&selector);
            assert!(bounds.size.width >= px(44.) && bounds.size.height >= px(44.));
            assert!(bounds.left() >= content.left() + px(19.));
            assert!(bounds.right() <= content.right() - px(19.));
            if let Some(edge) = last {
                assert!(
                    edge <= if vertical {
                        bounds.top()
                    } else {
                        bounds.left()
                    }
                );
            }
            last = Some(if vertical {
                bounds.bottom()
            } else {
                bounds.right()
            });
        }
    }

    fn assert_layout(&mut self) {
        let content = self.bounds("settings-content");
        let accounts = self.bounds("settings-accounts");
        let preferences = self.bounds("settings-preferences");
        let two_columns = content.size.width >= px(760.);
        if two_columns {
            assert!((accounts.top() - preferences.top()).abs() < px(1.));
            assert!(accounts.right() + px(23.) <= preferences.left());
        } else {
            assert!((accounts.left() - preferences.left()).abs() < px(1.));
            assert!(accounts.bottom() + px(27.) <= preferences.top());
        }
        for selector in [
            "settings-model",
            "settings-account-access",
            "settings-runtime",
            "settings-identity",
            "settings-appearance",
            "settings-language",
            "assistant-notifications",
            "assistant-background",
        ] {
            let control = self.bounds(selector);
            assert!(
                control.size.width >= px(44.),
                "{selector} too narrow: {control:?}"
            );
            assert!(
                control.size.height >= px(44.),
                "{selector} too short: {control:?}"
            );
            assert!(
                control.left() >= content.left() + px(19.),
                "{selector} escaped left gutter"
            );
            assert!(
                control.right() <= content.right() - px(19.),
                "{selector} escaped right gutter"
            );
        }
        for (selector, track) in [
            ("assistant-notifications", "assistant-notifications-switch"),
            ("assistant-background", "assistant-background-switch"),
        ] {
            let row = self.bounds(selector);
            let switch = self.bounds(track);
            assert_eq!(switch.size.width, px(44.));
            assert_eq!(switch.size.height, px(27.));
            assert!(switch.left() >= row.left());
            assert!(switch.right() <= row.right());
        }
    }
}

#[test]
fn settings_respects_phone_and_tablet_content_width_in_both_languages() {
    for locale in [Locale::Zh, Locale::En] {
        for width in [320., 393., 834., 1194.] {
            let mut fixture = Fixture::new(width, locale);
            fixture.assert_layout();
            assert!(fixture.cx.debug_bounds("theme-light").is_none());
            assert!(fixture.cx.debug_bounds("language-en").is_none());
            assert!(fixture.cx.debug_bounds("DEEPSEEK_API_KEY").is_none());
            fixture.assert_choices(settings::PreferenceGroup::Models);
            fixture.assert_choices(settings::PreferenceGroup::Accounts);
            fixture.assert_choices(settings::PreferenceGroup::Runtime);
            fixture.assert_choices(settings::PreferenceGroup::Appearance);
            fixture.assert_choices(settings::PreferenceGroup::Language);
        }
    }
}

#[test]
fn settings_resize_reflows_without_replacing_inputs_or_changing_preferences() {
    let mut fixture = Fixture::new(1194., Locale::Zh);
    let before = fixture
        .window
        .read_with(&fixture.cx, |shell, _| {
            (
                shell.composer.entity_id(),
                shell.title_input.entity_id(),
                shell.state.raw_session().clone(),
            )
        })
        .unwrap();
    for width in [320., 393., 834., 1194.] {
        fixture.resize(width);
        fixture.assert_layout();
        fixture
            .window
            .read_with(&fixture.cx, |shell, _| {
                assert_eq!(
                    (
                        shell.composer.entity_id(),
                        shell.title_input.entity_id(),
                        shell.state.raw_session().clone()
                    ),
                    before
                );
                assert!(shell.locale == Locale::Zh);
            })
            .unwrap();
    }
}

#[test]
fn settings_preference_clicks_keep_existing_busy_and_runtime_guards() {
    let mut fixture = Fixture::new(1194., Locale::En);
    fixture
        .window
        .update(&mut fixture.cx, |shell, _, cx| {
            shell.loading = true;
            cx.notify();
        })
        .unwrap();
    fixture.draw();
    for selector in [
        "settings-appearance",
        "theme-dark",
        "settings-language",
        "language-zh",
        "settings-account-access",
        "DEEPSEEK_API_KEY",
    ] {
        let position = fixture.bounds(selector).center();
        fixture.cx.simulate_click(position, Modifiers::none());
        fixture.draw();
    }
    fixture
        .window
        .read_with(&fixture.cx, |shell, cx| {
            assert!(shell.locale == Locale::En);
            assert!(cx.global::<theme::ThemeState>().mode == theme::ThemeMode::Light);
            assert!(!shell.aux_busy);
        })
        .unwrap();
}

#[test]
fn tablet_configuration_is_centered_and_width_limited_while_phone_stays_a_bottom_card() {
    for width in [393., 834., 1194.] {
        let mut fixture = Fixture::new(width, Locale::En);
        fixture
            .window
            .update(&mut fixture.cx, |shell, window, cx| {
                shell.page = Page::Chat;
                shell.open_model_picker(window, cx);
                cx.notify();
            })
            .unwrap();
        fixture.draw();
        for page in [
            model_picker::ConfigurationPage::Configure,
            model_picker::ConfigurationPage::Models,
        ] {
            fixture
                .window
                .update(&mut fixture.cx, |shell, _, cx| {
                    shell.show_configuration_page(page, cx);
                })
                .unwrap();
            fixture.draw();
            let panel = fixture.bounds("config-panel");
            assert!(panel.size.width <= px(440.));
            assert!(panel.left() >= px(10.) && panel.right() <= px(width - 10.));
            assert!(panel.top() >= px(10.) && panel.bottom() <= px(834.));
            if width >= 700. {
                assert!((panel.center().x - px(width / 2.)).abs() <= px(1.));
                assert!((panel.center().y - px(422.)).abs() <= px(1.));
            } else {
                assert!((panel.bottom() - px(834.)).abs() <= px(1.));
            }
        }
    }
}

#[test]
fn grouped_preference_rows_expand_and_apply_real_local_preview_choices() {
    let mut fixture = Fixture::new(1194., Locale::Zh);
    fixture.click("settings-appearance");
    fixture.bounds("theme-dark");
    fixture.click("theme-dark");
    fixture
        .window
        .read_with(&fixture.cx, |shell, cx| {
            assert!(cx.global::<theme::ThemeState>().mode == theme::ThemeMode::Dark);
            assert!(shell.settings_expanded == Some(settings::PreferenceGroup::Appearance));
        })
        .unwrap();
    fixture.click("settings-language");
    assert!(fixture.cx.debug_bounds("theme-dark").is_none());
    fixture.click("language-en");
    fixture
        .window
        .read_with(&fixture.cx, |shell, _| assert!(shell.locale == Locale::En))
        .unwrap();
    fixture.click("settings-language");
    assert!(fixture.cx.debug_bounds("language-en").is_none());
}

#[test]
fn active_assistant_writer_prevents_preference_mutations_without_hiding_choices() {
    let mut fixture = Fixture::new(1194., Locale::Zh);
    fixture
        .window
        .update(&mut fixture.cx, |shell, _, cx| {
            shell.assistant_writer_lease = true;
            cx.notify();
        })
        .unwrap();
    fixture.draw();
    fixture.click("settings-appearance");
    fixture.click("theme-dark");
    fixture.click("settings-language");
    fixture.click("language-en");
    fixture
        .window
        .read_with(&fixture.cx, |shell, cx| {
            assert!(shell.locale == Locale::Zh);
            assert!(cx.global::<theme::ThemeState>().mode == theme::ThemeMode::Light);
            assert!(shell.assistant_writer_lease);
        })
        .unwrap();
}

#[test]
fn model_catalog_api_accounts_and_runtime_products_are_distinct_disclosures() {
    let mut fixture = Fixture::new(393., Locale::Zh);
    for selector in [
        "DEEPSEEK_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "BIGMODEL_API_KEY",
    ] {
        assert!(fixture.cx.debug_bounds(selector).is_none());
    }
    let card = fixture.bounds("settings-models-card");
    let default_row = fixture.bounds("settings-model");
    let add_model = fixture.bounds("settings-add-model");
    assert!(
        card.size.height <= px(124.),
        "the collapsed model group contains only the default and setup rows"
    );
    assert!(default_row.bottom() <= add_model.top());
    assert!(add_model.size.height >= px(44.));
    assert!(card.contains(&default_row.center()) && card.contains(&add_model.center()));
    assert!(
        fixture
            .cx
            .debug_bounds("settings-default-model-deepseek-v4-flash")
            .is_none()
    );
    fixture.reveal("assistant-background");
    let background = fixture.bounds("assistant-background");
    let viewport = fixture.bounds("settings-content");
    assert!(
        background.top() >= viewport.top() && background.bottom() <= viewport.bottom(),
        "app settings remain reachable below the separate runtime group"
    );
    fixture.reveal("settings-identity");
    let dot = fixture.bounds("settings-status-dot");
    let status = fixture.bounds("settings-identity-status");
    assert_eq!(dot.size.width, px(6.));
    assert!(dot.left() >= status.left() && dot.right() <= status.right());
    let before = fixture
        .window
        .read_with(&fixture.cx, |shell, _| shell.state.raw_session().clone())
        .unwrap();
    fixture.click("settings-model");
    fixture.bounds("settings-default-model-deepseek-v4-flash");
    fixture.bounds("settings-default-model-deepseek-v4-pro");
    fixture.bounds("settings-default-model-claude-sonnet-5");
    assert!(
        fixture.cx.debug_bounds("DEEPSEEK_API_KEY").is_none(),
        "runtime/service labels must not be model options"
    );
    assert!(fixture.cx.debug_bounds("provider-logo-dsh").is_none());
    fixture.click("settings-model");
    fixture.click("settings-account-access");
    assert!(
        fixture
            .cx
            .debug_bounds("settings-default-model-deepseek-v4-flash")
            .is_none()
    );
    assert_eq!(
        crate::providers::ApiProvider::ALL
            .map(|provider| { (provider.label(), provider.credential_slot()) }),
        [
            ("DeepSeek", "DEEPSEEK_API_KEY"),
            ("Anthropic", "ANTHROPIC_API_KEY"),
            ("OpenAI", "OPENAI_API_KEY"),
            ("Z.AI", "BIGMODEL_API_KEY"),
        ]
    );
    for provider in crate::providers::ApiProvider::ALL {
        fixture.bounds(provider.credential_slot());
    }
    for product in crate::providers::RuntimeProduct::ALL {
        assert!(
            fixture.cx.debug_bounds(product.selector()).is_none(),
            "runtime artwork must not label API credential rows"
        );
        assert!(
            fixture
                .cx
                .debug_bounds(product.settings_selector())
                .is_none()
        );
    }
    fixture.click("settings-runtime");
    for provider in crate::providers::ApiProvider::ALL {
        assert!(
            fixture
                .cx
                .debug_bounds(provider.credential_slot())
                .is_none()
        );
    }
    assert!(
        fixture
            .cx
            .debug_bounds("settings-default-model-deepseek-v4-flash")
            .is_none()
    );
    let pi = fixture.bounds("settings-runtime-pi");
    for product in crate::providers::RuntimeProduct::ALL {
        let row = fixture.bounds(product.settings_selector());
        let logo = product.selector();
        let image = fixture.bounds(logo);
        assert_eq!(image.size.width, px(30.));
        assert_eq!(image.size.height, px(30.));
        assert!(image.left() >= row.left() && image.right() <= row.right());
        assert_eq!(row.left(), pi.left(), "runtime products are peer rows");
        assert_eq!(row.size.width, pi.size.width);
    }
    fixture
        .window
        .read_with(&fixture.cx, |shell, _| {
            assert_eq!(shell.state.raw_session(), &before)
        })
        .unwrap();
    fixture.click("settings-runtime");
    assert!(fixture.cx.debug_bounds("DEEPSEEK_API_KEY").is_none());
    assert!(fixture.cx.debug_bounds("provider-logo-dsh").is_none());
    assert_eq!(
        fixture.bounds("settings-models-card").size.height,
        card.size.height
    );
    assert!(fixture.bounds("settings-accounts-card").size.height <= px(62.));
}

fn persist_settings(state: &mut ShellState, command: RuntimeCommand) {
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    let generation = command.args[0]["expected"]["snapshot"]["generation"]
        .as_u64()
        .unwrap_or(0)
        + 1;
    state.accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{"schema_version":1,"generation":generation,"session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()}})).unwrap();
}

#[test]
fn default_model_changes_only_after_persistence_and_leaves_existing_chat_unchanged() {
    let mut fixture = Fixture::new(1194., Locale::Zh);
    fixture.window.update(&mut fixture.cx, |shell, _, _| {
        shell.state.load_snapshot(json!({"schema_version":1,"status":"missing"})).unwrap();
        shell.state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
        let create = shell.state.create_conversation("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "2026-10-28T00:00:00.000Z", "deepseek-v4-flash").unwrap();
        persist_settings(&mut shell.state, create);
        let previous_chat = shell.state.raw_session()["conversations"][0].clone();
        let command = shell.prepare_settings_default_model("claude-sonnet-5").unwrap().unwrap();
        assert_eq!(shell.settings_default_model_id(), "deepseek-v4-flash", "a candidate is not a saved default");
        let candidate: Value = serde_json::from_str(command.args[0]["candidate_json"].as_str().unwrap()).unwrap();
        assert_eq!(candidate["preferences"]["default_model"], "claude-sonnet-5");
        assert_eq!(candidate["conversations"][0], previous_chat);
        persist_settings(&mut shell.state, command);
        assert_eq!(shell.settings_default_model_id(), "claude-sonnet-5");
        assert_eq!(shell.state.selected_model(), "deepseek-v4-flash");
        let task = shell.assistant_new_task_config().unwrap();
        assert_eq!(task.model_id, "claude-sonnet-5", "new tasks use the saved default, not the active chat");
        assert!(task.runtime.is_none(), "model selection must not choose the execution engine");
        assert_eq!(shell.state.raw_session()["conversations"][0], previous_chat);
    }).unwrap();
}

#[test]
fn new_task_model_uses_saved_default_without_an_active_chat_and_falls_back_only_to_current_catalog()
{
    let mut fixture = Fixture::new(1194., Locale::En);
    fixture.window.update(&mut fixture.cx, |shell, _, _| {
        shell.state.load_snapshot(json!({"schema_version":1,"status":"missing"})).unwrap();
        let command = shell.prepare_settings_default_model("gpt-5.6").unwrap().unwrap();
        assert_eq!(shell.assistant_new_task_config().unwrap().model_id, "deepseek-v4-flash", "pending preference is not yet a saved default");
        persist_settings(&mut shell.state, command);
        assert!(shell.state.active_conversation_id().is_none());
        assert_eq!(shell.assistant_new_task_config().unwrap().model_id, "gpt-5.6");
        let command = shell.prepare_settings_default_model("deepseek-v4-flash").unwrap().unwrap();
        persist_settings(&mut shell.state, command);
        shell.state.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-current","name":"Current","supports_images":true}],"retired_models":[{"id":"deepseek-v4-flash","name":"Retired Flash","supports_images":false}]})).unwrap();
        let before = shell.state.raw_session().clone();
        let config = shell.assistant_new_task_config().unwrap();
        assert_eq!(config.model_id, "deepseek-current");
        assert!(shell.state.models().iter().any(|model| model.id == config.model_id));
        assert!(config.runtime.is_none());
        assert_eq!(shell.settings_default_model_id(), "deepseek-v4-flash", "fallback does not rewrite the saved preference");
        assert_eq!(shell.state.raw_session(), &before);
    }).unwrap();
}

#[test]
fn default_model_uses_native_catalog_names_and_rejects_unavailable_or_busy_changes() {
    let mut fixture = Fixture::new(1194., Locale::Zh);
    fixture.window.update(&mut fixture.cx, |shell, _, cx| {
        shell.state.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-current","name":"当前可用模型 中文","supports_images":true}],"retired_models":[{"id":"deepseek-retired","name":"已下线模型","supports_images":false}]})).unwrap();
        shell.state.load_snapshot(json!({"schema_version":1,"status":"missing"})).unwrap();
        shell.settings_expanded = Some(settings::PreferenceGroup::Models);
        assert!(shell.prepare_settings_default_model("deepseek-retired").is_err());
        assert!(shell.prepare_settings_default_model("missing-model").is_err());
        assert!(!shell.state.is_busy());
        shell.loading = true;
        assert!(shell.prepare_settings_default_model("deepseek-current").unwrap().is_none());
        shell.loading = false;
        shell.aux_busy = true;
        assert!(shell.prepare_settings_default_model("deepseek-current").unwrap().is_none());
        shell.aux_busy = false;
        shell.assistant_writer_lease = true;
        assert!(shell.prepare_settings_default_model("deepseek-current").unwrap().is_none());
        shell.assistant_writer_lease = false;
        cx.notify();
    }).unwrap();
    fixture.draw();
    fixture.bounds("settings-default-model-deepseek-current");
    assert!(
        fixture
            .cx
            .debug_bounds("settings-default-model-deepseek-retired")
            .is_none()
    );
    assert!(
        fixture
            .cx
            .debug_bounds("settings-default-model-deepseek-v4-flash")
            .is_none()
    );
    // Desktop preview never creates a native preference transaction.
    fixture.click("settings-default-model-deepseek-current");
    fixture
        .window
        .read_with(&fixture.cx, |shell, _| {
            assert_eq!(shell.settings_default_model_id(), "deepseek-current");
            assert!(!shell.state.is_busy());
        })
        .unwrap();
}
