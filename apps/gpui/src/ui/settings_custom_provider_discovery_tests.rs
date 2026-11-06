use super::*;
use gpui::{
    Modifiers, ScrollDelta, ScrollWheelEvent, TestAppContext, TouchPhase, VisualTestContext, point,
    size,
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
const MODEL: &str = "22222222-2222-4222-8222-222222222222";
fn provider() -> Value {
    json!({"id":ID,"active":true,"configuration":{"schema_version":1,"harness_id":format!("custom-{ID}"),
        "name":"My API","endpoint_url":"https://api.example.com/v1/chat/completions","protocol":"chat-completions",
        "auth_type":"bearer","send_reasoning":false,"full_url":true,"model_mappings":{registry::logical_model_id(ID,MODEL):"manual-model"}},
        "models":[{"id":MODEL,"name":"My manual label","wire_model":"manual-model","supports_images":true,"active":true}]})
}
fn snapshot() -> Value {
    json!({"schema_version":1,"revision":1,"providers":[provider()]})
}
fn response() -> Value {
    json!({"schema_version":1,"id":ID,"operation_id":"fetch-token","truncated":false,"models":[
    {"wire_model":"manual-model","name":"Different server label","supports_images":false},
    {"wire_model":"new-model","name":"New model","supports_images":true}]})
}
fn editor() -> ProviderEditor {
    let mut editor = ProviderEditor::new(1, Some(&provider()));
    editor.discovery.profile = Some(provider()["configuration"].clone());
    editor.discovery.generation = 1;
    editor
}
fn request(editor: &ProviderEditor) -> ProviderRequest {
    ProviderRequest {
        token: "fetch-token".into(),
        revision: 1,
        operation: Operation::Discover {
            id: ID.into(),
            editor: editor.token.clone(),
            generation: editor.discovery.generation,
            profile: provider()["configuration"].clone(),
        },
    }
}

#[test]
fn discovered_import_keeps_manual_rows_and_repeated_wire_identity_stable() {
    let mut editor = editor();
    let manual = editor.models[0].clone();
    let (rows, truncated) = ModelDiscovery::parse(ID, "fetch-token", &response()).unwrap();
    editor.discovery.rows = rows;
    editor.discovery.loaded = true;
    editor.discovery.truncated = truncated;
    editor.select_visible_discovered(Locale::En);
    assert_eq!(editor.selected_new_count(), 1);
    editor.import_discovered(Locale::En);
    assert_eq!(editor.models[0], manual);
    assert_eq!(editor.models.len(), 2);
    let imported = editor.models[1].clone();
    assert_eq!(imported["supports_images"], true);
    assert_ne!(imported["id"], MODEL);
    editor.discovery.selected.insert("manual-model".into());
    editor.discovery.selected.insert("new-model".into());
    editor.import_discovered(Locale::En);
    assert_eq!(editor.models, vec![manual, imported]);
    assert_eq!(
        editor.baseline.as_ref().unwrap()["models"]
            .as_array()
            .unwrap()
            .len(),
        1,
        "import does not save registry"
    );
}

#[test]
fn provider_can_be_saved_without_models_and_import_is_bounded_utf8_safe() {
    let mut editor = editor();
    editor.set_models("").unwrap();
    let empty = editor.payload().unwrap();
    assert_eq!(empty["configuration"]["model_mappings"], json!({}));
    assert_eq!(empty["models"], json!([]));
    let mut data = response();
    data["models"] = json!((0..50).map(|n|json!({"wire_model":format!("model-{n}"),"name":"😀".repeat(20),"supports_images":false})).collect::<Vec<_>>());
    editor.discovery.rows = ModelDiscovery::parse(ID, "fetch-token", &data).unwrap().0;
    editor.discovery.loaded = true;
    editor.select_visible_discovered(Locale::Zh);
    assert_eq!(editor.selected_new_count(), 32);
    editor.import_discovered(Locale::Zh);
    assert_eq!(editor.models.len(), 32);
    assert!(
        editor
            .models
            .iter()
            .all(|model| model["name"].as_str().unwrap().len() == 80)
    );
    let after = json!({"schema_version":1,"revision":1,"providers":[editor.payload().unwrap()]});
    registry::read_registry(&after).unwrap();
}

#[test]
fn malformed_or_duplicate_discovery_envelopes_are_not_accepted() {
    let mut value = response();
    let duplicate = value["models"][0].clone();
    value["models"].as_array_mut().unwrap().push(duplicate);
    assert!(ModelDiscovery::parse(ID, "fetch-token", &value).is_err());
    value = response();
    value["id"] = json!("another-provider");
    assert!(ModelDiscovery::parse(ID, "fetch-token", &value).is_err());
    value = response();
    value["token"] = json!("unexpected");
    assert!(ModelDiscovery::parse(ID, "fetch-token", &value).is_err());
}

#[test]
fn failed_late_wrong_profile_and_cancelled_discovery_never_erase_manual_draft() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window
        .update(&mut cx, |shell, _, cx| {
            shell.loading = false;
            shell.custom_providers.install_snapshot(snapshot()).unwrap();
            for case in [
                "failed",
                "profile",
                "generation",
                "editor",
                "cancelled",
                "token",
            ] {
                let mut draft = editor();
                draft.name = if case == "profile" {
                    "Changed while fetching".into()
                } else {
                    "My API".into()
                };
                let pending = request(&draft);
                let before = draft.models.clone();
                if case == "generation" {
                    draft.discovery.generation += 1;
                }
                if case == "editor" {
                    draft.token = "new-editor".into();
                }
                shell.custom_providers.editor = Some(draft);
                shell.custom_providers.request = Some(pending.clone());
                if case == "cancelled" {
                    shell.custom_discovery_action(DiscoveryAction::CancelWait, cx);
                }
                let mut incoming = pending.clone();
                if case == "token" {
                    incoming.token = "old-token".into();
                }
                shell.complete_custom_provider_request(
                    incoming,
                    if case == "failed" {
                        Err("E_CUSTOM_PROVIDER_MODELS_KEY_REQUIRED".into())
                    } else {
                        Ok(response())
                    },
                    cx,
                );
                assert_eq!(
                    shell.custom_providers.editor.as_ref().unwrap().models,
                    before,
                    "{case}"
                );
                assert!(
                    !shell
                        .custom_providers
                        .editor
                        .as_ref()
                        .unwrap()
                        .discovery
                        .loaded,
                    "{case}"
                );
                assert!(
                    !shell.custom_providers.needs_reload,
                    "read-only failure does not force a metadata transaction"
                );
                if case == "cancelled" {
                    let cancellation = shell.custom_providers.request.clone().unwrap();
                    assert!(matches!(&cancellation.operation, Operation::CancelDiscovery { operation_id, .. } if operation_id == &pending.token));
                    shell.complete_custom_provider_request(cancellation, Ok(json!({"schema_version":1,"id":ID,"operation_id":pending.token,"status":"cancelled"})), cx);
                    assert!(!shell.custom_providers.request_pending());
                } else if case == "token" {
                    assert!(shell.custom_providers.request_pending());
                    shell.custom_providers.request = None;
                } else {
                    assert!(!shell.custom_providers.request_pending());
                }
            }
        })
        .unwrap();
}

fn reveal(cx: &mut VisualTestContext, id: &'static str) {
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
    assert!(control.left() >= viewport.left() && control.right() <= viewport.right());
    assert!(
        control.top() >= viewport.top() && control.bottom() <= viewport.bottom(),
        "{id}"
    );
}
#[test]
fn fetched_model_list_scrolls_selects_and_imports_in_phone_and_tablet_geometry() {
    for width in [390., 1194.] {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(844.)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window.update(&mut cx,|shell,_,cx| {
            shell.loading = false;shell.page = Page::Settings;shell.locale = Locale::Zh;
            shell.settings_expanded = Some(settings::PreferenceGroup::Accounts);
            shell.custom_providers.install_snapshot(snapshot()).unwrap();
            let mut draft = editor();draft.discovery.loaded = true;
            let data = json!({"schema_version":1,"id":ID,"operation_id":"fetch-token","truncated":true,"models":(0..512).map(|n|json!({"wire_model":format!("remote-{n:03}"),"name":format!("远程模型 {n}"),"supports_images":false})).collect::<Vec<_>>()});
            draft.discovery.rows = ModelDiscovery::parse(ID,"fetch-token",&data).unwrap().0;
            shell.custom_providers.editor = Some(draft);cx.notify();
        }).unwrap();
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        reveal(&mut cx, "custom-provider-fetch-models");
        reveal(&mut cx, "custom-discovered-models-list");
        let list = cx.debug_bounds("custom-discovered-models-list").unwrap();
        assert_eq!(list.size.height, px(260.));
        cx.simulate_event(ScrollWheelEvent {
            position: list.center(),
            delta: ScrollDelta::Pixels(point(px(0.), px(-40000.))),
            modifiers: Modifiers::none(),
            touch_phase: TouchPhase::Moved,
        });
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        let last = cx
            .debug_bounds("custom-discovered-model-remote-511")
            .unwrap();
        let list = cx.debug_bounds("custom-discovered-models-list").unwrap();
        assert!(last.top() >= list.top() && last.bottom() <= list.bottom());
        assert!(last.left() >= list.left() && last.right() <= list.right());
        let viewport = cx.debug_bounds("settings-content").unwrap();
        assert!(
            last.top() >= viewport.top() && last.bottom() <= viewport.bottom(),
            "last row outside viewport at width {width}: {last:?} versus {viewport:?}"
        );
        cx.simulate_click(last.center(), Modifiers::none());
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        window
            .read_with(&cx, |shell, _| {
                assert_eq!(
                    shell
                        .custom_providers
                        .editor
                        .as_ref()
                        .unwrap()
                        .selected_new_count(),
                    1,
                    "row click must select"
                )
            })
            .unwrap();
        reveal(&mut cx, "custom-provider-import-models");
        let import = cx.debug_bounds("custom-provider-import-models").unwrap();
        cx.simulate_click(import.center(), Modifiers::none());
        cx.run_until_parked();
        window
            .read_with(&cx, |shell, _| {
                let draft = shell.custom_providers.editor.as_ref().unwrap();
                assert_eq!(draft.models.len(), 2);
                assert!(draft.has_wire("remote-511"));
                assert_eq!(draft.models[0]["id"], MODEL);
                assert_eq!(
                    shell.custom_providers.provider(ID).unwrap()["models"]
                        .as_array()
                        .unwrap()
                        .len(),
                    1
                );
                assert!(!shell.custom_providers.request_pending());
            })
            .unwrap();
    }
}

#[test]
fn discovery_filter_is_case_insensitive_and_only_selects_matching_new_models() {
    let mut draft = editor();
    draft.discovery.rows = ModelDiscovery::parse(ID, "fetch-token", &response())
        .unwrap()
        .0;
    draft.discovery.query = "NEW-MODEL".into();
    assert_eq!(draft.discovery.visible().count(), 1);
    draft.select_visible_discovered(Locale::En);
    assert!(draft.discovery.selected.contains("new-model"));
    assert!(!draft.discovery.selected.contains("manual-model"));
    draft.discovery.query = "different server".into();
    assert_eq!(draft.discovery.visible().count(), 1);
    draft.discovery.query = "no-such-model".into();
    assert_eq!(draft.discovery.visible().count(), 0);
}

#[test]
fn actual_successful_fetch_populates_choices_without_importing_or_saving_models() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window
        .update(&mut cx, |shell, _, cx| {
            shell.loading = false;
            shell.custom_providers.install_snapshot(snapshot()).unwrap();
            let draft = editor();
            let pending = request(&draft);
            shell.custom_providers.editor = Some(draft);
            shell.custom_providers.request = Some(pending.clone());
            assert!(
                !shell
                    .custom_providers
                    .editor
                    .as_ref()
                    .unwrap()
                    .discovery
                    .loaded
            );
            shell.complete_custom_provider_request(pending, Ok(response()), cx);
            let draft = shell.custom_providers.editor.as_ref().unwrap();
            assert!(draft.discovery.loaded);
            assert_eq!(draft.discovery.rows.len(), 2);
            assert_eq!(draft.selected_new_count(), 0);
            assert_eq!(draft.models.len(), 1);
            assert_eq!(
                shell.custom_providers.registry,
                registry::read_registry(&snapshot()).unwrap()
            );
            assert!(!shell.custom_providers.request_pending());
        })
        .unwrap();
}

#[test]
fn native_cancel_targets_exact_operation_and_late_cancel_cannot_clobber_new_fetch() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window.update(&mut cx, |shell, _, cx| {
        shell.loading = false;
        shell.custom_providers.install_snapshot(snapshot()).unwrap();
        let draft = editor();let fetch = request(&draft);let original_models = draft.models.clone();
        shell.custom_providers.editor = Some(draft);shell.custom_providers.request = Some(fetch.clone());
        let cancel = shell.prepare_custom_discovery_cancel().unwrap();
        assert!(matches!(&cancel, Operation::CancelDiscovery { id,operation_id,.. } if id == ID && operation_id == &fetch.token));
        let cancellation = ProviderRequest {token:"cancel-token".into(),revision:1,operation:cancel};
        shell.custom_providers.request = Some(cancellation.clone());
        shell.complete_custom_provider_request(fetch,Ok(response()),cx);
        assert_eq!(shell.custom_providers.request.as_ref().unwrap().token,"cancel-token");
        assert!(!shell.custom_providers.editor.as_ref().unwrap().discovery.loaded);
        shell.complete_custom_provider_request(cancellation.clone(),Ok(json!({"schema_version":1,"id":ID,"operation_id":"fetch-token","status":"cancelled"})),cx);
        assert!(!shell.custom_providers.request_pending());
        assert_eq!(shell.custom_providers.editor.as_ref().unwrap().models,original_models);
        let mut newer = editor();newer.discovery.generation = 3;
        let mut fetch = request(&newer);fetch.token = "newer-fetch-token".into();
        shell.custom_providers.editor = Some(newer);shell.custom_providers.request = Some(fetch.clone());
        shell.complete_custom_provider_request(cancellation,Ok(json!({"schema_version":1,"id":ID,"operation_id":"fetch-token","status":"cancelled"})),cx);
        assert_eq!(shell.custom_providers.request.as_ref().unwrap().token,"newer-fetch-token");
        let mut reply = response();reply["operation_id"] = json!("newer-fetch-token");
        shell.complete_custom_provider_request(fetch,Ok(reply),cx);
        assert!(shell.custom_providers.editor.as_ref().unwrap().discovery.loaded);
        assert_eq!(shell.custom_providers.editor.as_ref().unwrap().models,original_models);
    }).unwrap();
}

#[test]
fn wrong_operation_echo_is_not_discovery_or_cancel_success() {
    let mut reply = response();
    reply["operation_id"] = json!("wrong-operation");
    assert!(ModelDiscovery::parse(ID, "fetch-token", &reply).is_err());
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window.update(&mut cx,|shell,_,cx| {
        shell.custom_providers.install_snapshot(snapshot()).unwrap();
        let draft = editor();let fetch = request(&draft);
        shell.custom_providers.editor = Some(draft);shell.custom_providers.request = Some(fetch);
        let operation = shell.prepare_custom_discovery_cancel().unwrap();
        let request = ProviderRequest {token:"cancel-token".into(),revision:1,operation};
        shell.custom_providers.request = Some(request.clone());
        shell.complete_custom_provider_request(request,Ok(json!({"schema_version":1,"id":ID,"operation_id":"wrong-operation","status":"cancelled"})),cx);
        let draft = shell.custom_providers.editor.as_ref().unwrap();
        assert!(draft.discovery.notice.is_none());assert!(draft.discovery.error.is_some());
        assert_eq!(draft.models.len(),1);assert!(!shell.custom_providers.request_pending());
    }).unwrap();
}

#[test]
fn manual_long_wire_keeps_exact_id_with_utf8_bounded_default_display_name() {
    let mut draft = editor();
    let wire = "模型".repeat(20);
    assert_eq!(wire.len(), 120);
    draft.set_models(&wire).unwrap();
    assert_eq!(draft.models[0]["wire_model"], wire);
    let name = draft.models[0]["name"].as_str().unwrap();
    assert!(name.len() <= 80 && !name.is_empty());
    assert_eq!(name.len(), 78);
    let registry_value =
        json!({"schema_version":1,"revision":1,"providers":[draft.payload().unwrap()]});
    registry::read_registry(&registry_value).unwrap();
}
