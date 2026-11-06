use super::*;
use gpui::{
    Modifiers, ScrollDelta, ScrollWheelEvent, TestAppContext, TouchPhase, VisualTestContext, point,
    size,
};
use rish_shell_core::assistant_store::AssistantSnapshot;

fn catalog() -> Value {
    let rows: Vec<_> = RuntimeProduct::ALL.into_iter().map(|product| {
        let supported = matches!(product, RuntimeProduct::ClaudeCode | RuntimeProduct::Codex);
        json!({"id":product.engine_id(),"installation":{"state":if supported {"not_installed"} else {"unavailable"},"version":null,"available_version":if supported {Some("1.2.3")} else {None},"download_supported":supported,"integrity":"unknown"},"execution":{"state":"unavailable","reason_code":"cli_adapter_unavailable"}})
    }).collect();
    json!({"schema_version":1,"engines":rows})
}
fn state() -> RuntimeEnginesUi {
    RuntimeEnginesUi {
        entries: parse_catalog(catalog()).unwrap(),
        ..Default::default()
    }
}

#[test]
fn authentication_capabilities_are_explicit_optional_and_cannot_grant_execution() {
    let legacy = parse_catalog(catalog()).unwrap();
    assert!(legacy.iter().all(|entry| !entry.authentication.supported));
    let mut value = catalog();
    value["engines"][2]["authentication"] = json!({
        "supported":true, "source_selection":true, "authorization_browser":true,
        "native_code_entry":true, "provider_selection":false,
    });
    let rows = parse_catalog(value.clone()).unwrap();
    assert!(rows[2].authentication.supported);
    assert_eq!(rows[2].execution, EngineExecution::Unavailable);
    value["engines"][2]["authentication"]["supported"] = json!(false);
    assert!(parse_catalog(value.clone()).is_err());
    value["engines"][2]["authentication"]["supported"] = json!(true);
    value["engines"][2]["authentication"]["source_selection"] = json!("yes");
    assert!(parse_catalog(value).is_err());
}

#[test]
fn partial_or_malformed_catalog_never_changes_capabilities_or_grants_execution() {
    let mut invalid = Vec::new();
    let mut value = catalog();
    value["schema_version"] = json!(2);
    invalid.push(value);
    let mut value = catalog();
    value["engines"].as_array_mut().unwrap().pop();
    invalid.push(value);
    let mut value = catalog();
    let duplicate = value["engines"][0].clone();
    value["engines"].as_array_mut().unwrap().push(duplicate);
    invalid.push(value);
    for (field, content) in [
        ("state", json!("installed")),
        ("integrity", json!("builtin")),
        ("download_supported", Value::Null),
        ("version", json!("unproven-version")),
    ] {
        let mut value = catalog();
        value["engines"][1]["installation"][field] = content;
        invalid.push(value);
    }
    let mut value = catalog();
    value["engines"][1]["execution"]["state"] = json!("ready");
    invalid.push(value);
    let mut value = catalog();
    value["engines"][1]["installation"]["state"] = json!("installing");
    value["engines"][1]["installation"]["progress"] = json!(101);
    invalid.push(value);
    for value in invalid {
        let mut ui = state();
        let before = ui
            .entries
            .iter()
            .map(|entry| entry.installation.clone())
            .collect::<Vec<_>>();
        let (request, _) = ui.prepare_request(None, false).unwrap();
        assert!(ui.accept_result(&request, Ok(value), Locale::En));
        assert!(ui.error.is_some());
        assert_eq!(
            ui.entries
                .iter()
                .map(|entry| entry.installation.clone())
                .collect::<Vec<_>>(),
            before
        );
        assert!(
            ui.prepare_request(Some(RuntimeProduct::Codex), true)
                .is_none(),
            "a failed refresh requires an explicit successful refresh before a download"
        );
        assert!(
            ui.entries
                .iter()
                .all(|entry| entry.execution == EngineExecution::Unavailable)
        );
    }
}

#[test]
fn download_requires_current_capability_and_explicit_action_then_returns_only_install_command() {
    let mut ui = state();
    assert!(
        ui.prepare_request(Some(RuntimeProduct::Dsh), true)
            .is_none()
    );
    assert!(
        ui.prepare_request(Some(RuntimeProduct::Zcode), true)
            .is_none()
    );
    assert!(
        ui.prepare_request(Some(RuntimeProduct::Codex), false)
            .is_none()
    );
    let (_, command) = ui
        .prepare_request(Some(RuntimeProduct::Codex), true)
        .unwrap();
    assert_eq!(command.module, "ShellRuntimeEngines");
    assert_eq!(command.method, "install");
    assert_eq!(
        command.args,
        vec![json!({"schema_version":1,"engine_id":"codex","userInitiated":true})]
    );
    assert!(
        ui.prepare_request(None, false).is_none(),
        "in-flight requests are serialized"
    );
}

#[test]
fn downloaded_integrity_is_independent_of_installation_and_execution() {
    for integrity in ["unverified", "verified"] {
        let mut value = catalog();
        value["engines"][2]["installation"]["state"] = json!("downloaded");
        value["engines"][2]["installation"]["integrity"] = json!(integrity);
        if integrity == "verified" {
            value["engines"][2]["installation"]["version"] = json!("1.2.3");
        }
        let entries = parse_catalog(value).unwrap();
        let codex = &entries[2];
        assert!(matches!(
            codex.installation,
            EngineInstallation::Downloaded { .. }
        ));
        assert_eq!(codex.execution, EngineExecution::Unavailable);
        assert_eq!(codex.can_download(), integrity != "verified");
        assert_eq!(
            codex.installation_label(Locale::Zh),
            if integrity == "verified" {
                "已下载 · 1.2.3"
            } else {
                "已下载，未验证"
            }
        );
    }
}

#[test]
fn stale_reply_and_native_error_preserve_prior_state_and_hide_raw_error_details() {
    let mut ui = state();
    let (request, _) = ui.prepare_request(None, false).unwrap();
    let stale = EngineRequest {
        token: "stale".into(),
        install: None,
    };
    assert!(!ui.accept_result(&stale, Ok(catalog()), Locale::En));
    assert!(ui.loading);
    assert_eq!(ui.request.as_ref().unwrap().token, request.token);
    assert!(ui.accept_result(
        &request,
        Err("/private/user/cache: installer stack trace".into()),
        Locale::Zh
    ));
    assert!(!ui.error.as_ref().unwrap().contains("/private"));
    assert!(matches!(
        ui.entries[2].installation,
        EngineInstallation::NotInstalled
    ));
    let (retry, _) = ui.prepare_request(None, false).unwrap();
    assert!(ui.accept_result(&retry, Ok(catalog()), Locale::Zh));
    assert!(ui.error.is_none());
}

#[test]
fn install_reply_does_not_change_profile_model_and_polling_stops_outside_runtime_page() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(393.), px(844.)), |_, cx| Shell::new(cx));
    window
        .update(&mut app, |shell, _, _| {
            shell.assistant.snapshot.store = Some(AssistantSnapshot::default());
            shell.page = Page::Settings;
            shell.settings_expanded = Some(settings::PreferenceGroup::Runtime);
            shell.runtime_engines = state();
            let session = shell.state.raw_session().clone();
            let profile = shell
                .assistant
                .snapshot
                .store
                .as_ref()
                .unwrap()
                .profile
                .clone();
            let (request, _) = shell
                .runtime_engines
                .prepare_request(Some(RuntimeProduct::Codex), true)
                .unwrap();
            let mut reply = catalog();
            reply["engines"][2]["installation"]["state"] = json!("installing");
            assert!(
                shell
                    .runtime_engines
                    .accept_result(&request, Ok(reply), Locale::En)
            );
            assert_eq!(shell.state.raw_session(), &session);
            assert_eq!(
                shell.assistant.snapshot.store.as_ref().unwrap().profile,
                profile
            );
            assert!(shell.assistant.profile_draft.is_none());
            assert!(shell.runtime_editor.is_none());
            assert!(shell.runtime_engine_poll_needed());
            shell.page = Page::Chat;
            assert!(!shell.runtime_engine_poll_needed());
            shell.page = Page::Settings;
            shell.settings_expanded = Some(settings::PreferenceGroup::Models);
            assert!(!shell.runtime_engine_poll_needed());
            shell.settings_expanded = Some(settings::PreferenceGroup::Runtime);
            shell.runtime_engines.error = Some("Refresh needed".into());
            assert!(!shell.runtime_engine_poll_needed());
        })
        .unwrap();
}

#[test]
fn truthful_download_controls_fit_phone_and_tablet_but_preview_cannot_dispatch_them() {
    for width in [320., 1194.] {
        for locale in [Locale::Zh, Locale::En] {
            let mut app = TestAppContext::single();
            let window = app.open_window(size(px(width), px(844.)), |_, cx| Shell::new(cx));
            let mut cx = VisualTestContext::from_window(window.into(), &app);
            cx.run_until_parked();
            window
                .update(&mut cx, |shell, _, cx| {
                    shell.page = Page::Settings;
                    shell.settings_expanded = Some(settings::PreferenceGroup::Runtime);
                    shell.locale = locale;
                    shell.runtime_engines = state();
                    cx.notify();
                })
                .unwrap();
            cx.run_until_parked();
            cx.update(|window, cx| window.draw(cx).clear(cx));
            assert!(cx.debug_bounds("settings-runtime-download-dsh").is_none());
            assert!(cx.debug_bounds("settings-runtime-download-zcode").is_none());
            for (selector, row_selector) in [
                (
                    "settings-runtime-download-claude-code",
                    "settings-runtime-claude-code",
                ),
                ("settings-runtime-download-codex", "settings-runtime-codex"),
            ] {
                let viewport = cx.debug_bounds("settings-content").unwrap();
                let bounds = cx.debug_bounds(selector).unwrap();
                let row = cx.debug_bounds(row_selector).unwrap();
                assert!(bounds.size.width >= px(68.) && bounds.size.height >= px(44.));
                assert!(
                    bounds.top() >= row.top() && bounds.bottom() <= row.bottom(),
                    "download must stay inside its engine row"
                );
                assert!(
                    bounds.left() > row.center().x && bounds.right() <= row.right(),
                    "download must trail the product in the same row"
                );
                assert!(
                    row.size.height >= px(64.) && row.size.height <= px(88.),
                    "the single engine row may wrap text on narrow screens: width={width}, locale={}, row={row:?}, button={bounds:?}",
                    locale.code()
                );
                assert!(
                    (bounds.center().y - row.center().y).abs() <= px(1.),
                    "the download button stays centered beside the product"
                );
                assert!(bounds.left() >= viewport.left() && bounds.right() <= viewport.right());
                if bounds.bottom() > viewport.bottom() {
                    cx.simulate_event(ScrollWheelEvent {
                        position: point(viewport.left() + px(2.), viewport.center().y),
                        delta: ScrollDelta::Pixels(point(
                            px(0.),
                            viewport.bottom() - bounds.bottom() - px(1.),
                        )),
                        modifiers: Modifiers::none(),
                        touch_phase: TouchPhase::Moved,
                    });
                    cx.run_until_parked();
                    cx.update(|window, cx| window.draw(cx).clear(cx));
                }
                let bounds = cx.debug_bounds(selector).unwrap();
                assert!(bounds.top() >= viewport.top() && bounds.bottom() <= viewport.bottom());
                cx.simulate_click(bounds.center(), Modifiers::none());
                cx.run_until_parked();
                window
                    .read_with(&cx, |shell, _| {
                        assert!(shell.runtime_engines.request.is_none())
                    })
                    .unwrap();
            }
        }
    }
}
