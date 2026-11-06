use super::*;
use gpui::{
    Bounds, Modifiers, Pixels, ScrollDelta, ScrollWheelEvent, TestAppContext, TouchPhase,
    VisualTestContext, point, size,
};

const PROVIDER: &str = "11111111-1111-4111-8111-111111111111";
const MODEL: &str = "22222222-2222-4222-8222-222222222222";
fn provider() -> Value {
    json!({"id":PROVIDER,"active":true,"configuration":{"schema_version":1,
        "harness_id":format!("custom-{PROVIDER}"),"name":"我的兼容服务商",
        "endpoint_url":"https://api.example.com/v1/chat/completions","protocol":"chat-completions",
        "auth_type":"bearer","send_reasoning":false,"full_url":true,
        "model_mappings":{registry::logical_model_id(PROVIDER,MODEL):"deepseek-v4-flash"}},
        "models":[{"id":MODEL,"name":"自定义 Flash","wire_model":"deepseek-v4-flash","supports_images":true,"active":true}]})
}
fn snapshot(revision: u64, provider: Value) -> Value {
    json!({"schema_version":1,"revision":revision,"providers":[provider]})
}

#[test]
fn model_edit_preserves_unchanged_identity_and_capability_and_namespaces_builtin_wire() {
    let mut editor = ProviderEditor::new(7, Some(&provider()));
    editor
        .set_models("deepseek-v4-flash | 新名称\nother-model")
        .unwrap();
    assert_eq!(editor.models[0]["id"], MODEL);
    assert_eq!(editor.models[0]["supports_images"], true);
    assert_ne!(editor.models[1]["id"], MODEL);
    let payload = editor.payload().unwrap();
    assert_eq!(
        payload["configuration"]["model_mappings"][registry::logical_model_id(PROVIDER, MODEL)],
        "deepseek-v4-flash"
    );
    assert!(
        payload["configuration"]["model_mappings"]
            .get("deepseek-v4-flash")
            .is_none()
    );
    editor.set_models("changed-wire").unwrap();
    assert_ne!(editor.models[0]["id"], MODEL);
    assert_eq!(editor.models[0]["supports_images"], false);
    assert!(editor.set_models("duplicate\nduplicate").is_err());
    assert_eq!(
        editor.models[0]["wire_model"], "changed-wire",
        "invalid input keeps previous model draft"
    );
}

#[test]
fn stale_request_tokens_revisions_editors_and_profile_replies_are_rejected() {
    let mut ui = CustomProvidersUi::default();
    ui.install_snapshot(snapshot(3, provider())).unwrap();
    let mut editor = ProviderEditor::new(3, Some(&provider()));
    editor.name = "Unsaved name".into();
    let request = ProviderRequest {
        token: "request-one".into(),
        revision: 3,
        operation: Operation::Save {
            editor: editor.token.clone(),
            provider: editor.payload().unwrap(),
            key: true,
        },
    };
    ui.editor = Some(editor);
    ui.request = Some(request.clone());
    assert!(ui.current(&request));
    let mut stale = request.clone();
    stale.token = "request-old".into();
    assert!(!ui.current(&stale));
    ui.editor.as_mut().unwrap().token = "different-editor".into();
    assert!(!ui.current(&request));
    let status = ProviderRequest {
        token: "status".into(),
        revision: 3,
        operation: Operation::Status {
            id: PROVIDER.into(),
            profile: provider()["configuration"].clone(),
        },
    };
    ui.request = Some(status.clone());
    assert!(ui.current(&status));
    let mut changed = provider();
    changed["configuration"]["name"] = json!("Changed elsewhere");
    ui.install_snapshot(snapshot(4, changed)).unwrap();
    assert!(!ui.current(&status));
    assert!(ui.install_snapshot(snapshot(2, provider())).is_err());
    assert_eq!(ui.editor.unwrap().name, "Unsaved name");
}

#[test]
fn save_receipt_accepts_native_url_normalization_only_for_exact_saved_metadata() {
    let saved = provider();
    let mut draft = saved.clone();
    draft["configuration"]["endpoint_url"] = json!("https://api.example.com/v1");
    draft["configuration"]["full_url"] = json!(false);
    let result = snapshot(8, saved.clone());
    assert!(actions::save_receipt_matches(&result, &draft, 7));
    assert!(!actions::save_receipt_matches(&result, &draft, 6));
    draft["configuration"]["auth_type"] = json!("none");
    assert!(!actions::save_receipt_matches(&result, &draft, 7));
    let mut ui = CustomProvidersUi::default();
    ui.install_snapshot(result).unwrap();
    assert_eq!(ui.phase(PROVIDER), CredentialPhase::Unknown);
    let mut none = saved;
    none["configuration"]["auth_type"] = json!("none");
    ui.install_snapshot(snapshot(9, none)).unwrap();
    assert_eq!(ui.phase(PROVIDER), CredentialPhase::NotRequired);
}

#[test]
fn retired_providers_and_models_never_appear_in_display_helpers() {
    let mut ui = CustomProvidersUi::default();
    ui.install_snapshot(snapshot(1, provider())).unwrap();
    let logical = registry::logical_model_id(PROVIDER, MODEL);
    assert_eq!(
        ui.model_detail(&logical).as_deref(),
        Some("我的兼容服务商 · deepseek-v4-flash")
    );
    let mut retired = provider();
    retired["active"] = json!(false);
    retired["models"][0]["active"] = json!(false);
    retired["configuration"]["model_mappings"] = json!({});
    ui.install_snapshot(snapshot(2, retired)).unwrap();
    assert!(ui.model_detail(&logical).is_none());
    assert_eq!(ui.providers().count(), 0);
}

fn reveal(cx: &mut VisualTestContext, id: &'static str) -> Bounds<Pixels> {
    let viewport = cx.debug_bounds("settings-content").unwrap();
    let control = cx.debug_bounds(id).unwrap();
    let delta = if control.bottom() > viewport.bottom() {
        viewport.bottom() - control.bottom() - px(1.)
    } else if control.top() < viewport.top() {
        viewport.top() - control.top() + px(1.)
    } else {
        px(0.)
    };
    cx.simulate_event(ScrollWheelEvent {
        position: point(viewport.left() + px(2.), viewport.center().y),
        delta: ScrollDelta::Pixels(point(px(0.), delta)),
        modifiers: Modifiers::none(),
        touch_phase: TouchPhase::Moved,
    });
    cx.run_until_parked();
    cx.update(|window, cx| window.draw(cx).clear(cx));
    let control = cx.debug_bounds(id).unwrap();
    assert!(
        control.left() >= viewport.left() && control.right() <= viewport.right(),
        "{id} horizontal bounds"
    );
    assert!(
        control.top() >= viewport.top() && control.bottom() <= viewport.bottom(),
        "{id} must be reachable"
    );
    control
}

#[test]
fn custom_provider_form_and_actions_fit_real_phone_and_tablet_geometry() {
    for width in [390., 1194.] {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(844.)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                shell.page = Page::Settings;
                shell.locale = Locale::Zh;
                shell.loading = false;
                shell.settings_expanded = Some(settings::PreferenceGroup::Accounts);
                shell
                    .custom_providers
                    .install_snapshot(snapshot(1, provider()))
                    .unwrap();
                shell.custom_providers.editor = Some(ProviderEditor::new(1, Some(&provider())));
                cx.notify();
            })
            .unwrap();
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        let add = cx.debug_bounds("settings-add-custom-provider").unwrap();
        let builtin = cx.debug_bounds("BIGMODEL_API_KEY").unwrap();
        assert!(
            add.top() >= builtin.bottom(),
            "Add follows the four builtin providers"
        );
        for id in [
            "custom-provider-name",
            "custom-provider-url",
            "custom-provider-full-url",
            "custom-protocol-chat",
            "custom-protocol-responses",
            "custom-protocol-messages",
            "custom-auth-bearer",
            "custom-auth-x-api-key",
            "custom-auth-api-key",
            "custom-auth-none",
            "custom-provider-models",
            "custom-provider-reasoning",
            "custom-provider-set-key",
            "custom-provider-save",
            "custom-provider-save-key",
            "custom-provider-remove",
            "custom-provider-cancel",
        ] {
            let bounds = reveal(&mut cx, id);
            assert!(bounds.size.height >= px(44.), "{id} touch target");
        }
        window
            .read_with(&cx, |shell, _| {
                assert!(
                    shell.custom_providers.request.is_none(),
                    "rendering makes no native or external requests"
                );
                assert_eq!(
                    shell.custom_providers.editor.as_ref().unwrap().name,
                    "我的兼容服务商"
                );
            })
            .unwrap();
    }
}

#[test]
fn reload_keeps_draft_but_does_not_reuse_concurrently_retired_model_identity() {
    let mut editor = ProviderEditor::new(1, Some(&provider()));
    editor.name = "Unsaved provider name".into();
    let mut newer = provider();
    let new_model = "33333333-3333-4333-8333-333333333333";
    newer["models"][0]["id"] = json!(new_model);
    newer["configuration"]["model_mappings"] =
        json!({registry::logical_model_id(PROVIDER,new_model):"deepseek-v4-flash"});
    assert!(!editor.review_snapshot(2, Some(newer)));
    assert_eq!(editor.name, "Unsaved provider name");
    assert_eq!(editor.models[0]["id"], new_model);
    assert_eq!(editor.models[0]["supports_images"], true);
    assert_eq!(editor.revision, 2);
    assert!(editor.review_snapshot(3, None));
    assert!(
        editor.baseline.is_some(),
        "removal cannot turn an old ID into a new-provider draft"
    );
}

#[test]
fn unknown_native_outcome_keeps_draft_and_requires_reload_while_stale_tokens_do_nothing() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window
        .update(&mut cx, |shell, _, cx| {
            shell.loading = false;
            shell
                .custom_providers
                .install_snapshot(snapshot(1, provider()))
                .unwrap();
            let mut editor = ProviderEditor::new(1, Some(&provider()));
            editor.name = "Keep my draft".into();
            let request = ProviderRequest {
                token: "save-current".into(),
                revision: 1,
                operation: Operation::Save {
                    editor: editor.token.clone(),
                    provider: editor.payload().unwrap(),
                    key: false,
                },
            };
            shell.custom_providers.editor = Some(editor);
            shell.custom_providers.request = Some(request.clone());
            let mut stale = request.clone();
            stale.token = "save-old".into();
            shell.complete_custom_provider_request(stale, Ok(snapshot(2, provider())), cx);
            assert!(shell.custom_providers.request.is_some());
            assert!(!shell.custom_providers.needs_reload);
            shell.complete_custom_provider_request(
                request,
                Err("transport unavailable".into()),
                cx,
            );
            assert!(shell.custom_providers.request.is_none());
            assert!(shell.custom_providers.needs_reload);
            assert_eq!(
                shell.custom_providers.editor.as_ref().unwrap().name,
                "Keep my draft"
            );
            assert_eq!(shell.custom_providers.revision(), 1);
            assert_eq!(
                shell.custom_providers.phase(PROVIDER),
                CredentialPhase::Unknown
            );
        })
        .unwrap();
}

#[test]
fn picker_and_default_model_rows_use_namespaced_custom_identity_with_provider_display_name() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    let logical = registry::logical_model_id(PROVIDER, MODEL);
    window
        .update(&mut cx, |shell, window, cx| {
            shell.loading = false;
            shell
                .state
                .apply_custom_providers(snapshot(1, provider()))
                .unwrap();
            shell
                .custom_providers
                .install_snapshot(snapshot(1, provider()))
                .unwrap();
            shell
                .state
                .load_snapshot(json!({"schema_version":1,"status":"missing"}))
                .unwrap();
            assert_eq!(
                shell
                    .state
                    .provider_display_name(&format!("custom-{PROVIDER}")),
                Some("我的兼容服务商")
            );
            shell.open_model_picker(window, cx);
            shell.show_configuration_page(model_picker::ConfigurationPage::Models, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.update(|window, cx| window.draw(cx).clear(cx));
    let row = Box::leak(format!("model-picker-row-{logical}").into_boxed_str());
    let group = Box::leak(format!("model-picker-group-custom-{PROVIDER}").into_boxed_str());
    let list = cx.debug_bounds("model-picker-list").unwrap();
    let option = cx.debug_bounds(row).unwrap();
    assert!(option.left() >= list.left() && option.right() <= list.right());
    assert!(cx.debug_bounds(group).is_some());
    window
        .update(&mut cx, |shell, window, cx| {
            shell.choose_model(&logical, window, cx);
            assert_eq!(shell.config_draft.as_ref().unwrap().model, logical);
            assert_eq!(
                shell.settings_default_model_id(),
                logical,
                "The sole configured provider model supplies the initial default"
            );
            shell.close_model_picker(window, cx);
            shell.page = Page::Settings;
            shell.settings_expanded = Some(settings::PreferenceGroup::Models);
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    cx.update(|window, cx| window.draw(cx).clear(cx));
    let default_row = Box::leak(format!("settings-default-model-{logical}").into_boxed_str());
    assert!(cx.debug_bounds(default_row).is_some());
}

fn persist(state: &mut ShellState, command: RuntimeCommand) {
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    let generation = command.args[0]["expected"]["snapshot"]["generation"]
        .as_u64()
        .unwrap_or(0)
        + 1;
    state.accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{
        "schema_version":1,"generation":generation,
        "session_sha256":rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap()}})).unwrap();
}

#[test]
fn retired_custom_selection_keeps_human_name_and_unavailable_label_without_switching_ids() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window.update(&mut cx, |shell, _, _| {
        let logical = registry::logical_model_id(PROVIDER, MODEL);
        shell.state.apply_custom_providers(snapshot(1, provider())).unwrap();
        shell.state.load_snapshot(json!({"schema_version":1,"status":"missing"})).unwrap();
        shell.state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
        let command = shell.state.create_conversation("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "2026-10-29T00:00:00.000Z", &logical).unwrap();
        persist(&mut shell.state, command);
        let command = shell.state.set_default_model(&logical).unwrap();
        persist(&mut shell.state, command);
        assert_eq!(shell.model_display_label(&logical), "自定义 Flash");
        let session = shell.state.raw_session().clone();
        let mut retired = provider();
        retired["active"] = json!(false);
        retired["models"][0]["active"] = json!(false);
        retired["configuration"]["model_mappings"] = json!({});
        shell.state.apply_custom_providers(snapshot(2, retired)).unwrap();
        shell.locale = Locale::Zh;
        assert_eq!(shell.model_display_label(shell.state.selected_model()), "自定义 Flash · 不可用");
        assert_eq!(shell.model_display_label(shell.settings_default_model_id()), "自定义 Flash · 不可用");
        shell.locale = Locale::En;
        assert_eq!(shell.model_display_label(&logical), "自定义 Flash · Unavailable");
        assert_eq!(shell.state.selected_model(), logical);
        assert_eq!(shell.settings_default_model_id(), logical);
        assert_eq!(shell.state.raw_session(), &session);
    }).unwrap();
}

#[test]
fn ui_rejecting_an_older_snapshot_cannot_partially_publish_core_catalog() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window
        .update(&mut cx, |shell, _, _| {
            let logical = registry::logical_model_id(PROVIDER, MODEL);
            shell
                .state
                .apply_custom_providers(snapshot(1, provider()))
                .unwrap();
            shell
                .custom_providers
                .install_snapshot(snapshot(3, provider()))
                .unwrap();
            let mut older = provider();
            older["models"][0]["name"] = json!("Must not publish");
            assert!(
                shell
                    .accept_custom_provider_snapshot(snapshot(2, older))
                    .is_err()
            );
            assert_eq!(
                shell.state.custom_model_display_name(&logical),
                Some("自定义 Flash")
            );
            assert_eq!(
                shell
                    .state
                    .models()
                    .into_iter()
                    .find(|model| model.id == logical)
                    .unwrap()
                    .name,
                "自定义 Flash"
            );
            assert_eq!(shell.custom_providers.revision(), 3);
            assert!(!shell.custom_providers.request_pending());
            shell.custom_providers.request = Some(ProviderRequest {
                token: "pending-key".into(),
                revision: 3,
                operation: Operation::Key {
                    id: PROVIDER.into(),
                    profile: provider()["configuration"].clone(),
                    clear: false,
                },
            });
            assert!(shell.custom_providers.request_pending());
        })
        .unwrap();
}
