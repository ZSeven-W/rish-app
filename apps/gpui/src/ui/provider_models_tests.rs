use super::*;
use gpui::{Modifiers, TestAppContext, VisualTestContext, WindowHandle, size};

fn registry(models: Vec<Value>) -> Value {
    json!({"schema_version":1,"revision":1,"providers":HARNESSES.iter().map(|h|
        json!({"harness_id":h,"models":if *h=="dsh"{models.clone()}else{vec![]},"retired_models":[]})).collect::<Vec<_>>()})
}
fn row(id: &str, name: &str, images: bool) -> ModelRow {
    ModelRow {
        id: id.into(),
        name: name.into(),
        images,
    }
}
fn request(editor: &ProviderModelEditor, operation: Operation) -> Request {
    Request {
        token: uuid::Uuid::new_v4().to_string(),
        editor: editor.token.clone(),
        harness: editor.harness.clone(),
        operation,
    }
}

#[test]
fn manual_model_ids_preserve_existing_capabilities_and_allow_removing_every_model() {
    let mut editor = ProviderModelEditor::new("dsh", 1, vec![row("my-model-a", "My alias", true)]);
    editor
        .set_models("my-model-b | Beta\nmy-model-a | A new alias")
        .unwrap();
    assert_eq!(
        editor.models,
        vec![
            row("my-model-b", "Beta", false),
            row("my-model-a", "A new alias", true)
        ]
    );
    let saved = editor.models.clone();
    assert!(editor.set_models("same\nsame | Other").is_err());
    assert_eq!(editor.models, saved);
    assert!(editor.set_models("custom:invented:identity").is_err());
    editor.set_models("").unwrap();
    assert!(editor.models.is_empty());
}

#[test]
fn editing_migrated_catalog_keeps_existing_opaque_ids_without_registering_new_reserved_ids() {
    let mut editor = ProviderModelEditor::new(
        "dsh",
        1,
        vec![row("custom:my-legacy-model", "Legacy", true)],
    );
    editor
        .set_models("custom:my-legacy-model | Legacy\nnew-model")
        .unwrap();
    assert_eq!(editor.models[0].id, "custom:my-legacy-model");
    assert!(editor.models[0].images);
    assert!(editor.set_models("custom:invented-model").is_err());
}

#[test]
fn importing_a_fresh_catalog_is_additive_and_never_overwrites_manual_alias_or_images() {
    let mut editor = ProviderModelEditor::new(
        "dsh",
        1,
        vec![
            row("wire-alpha", "My private alias", true),
            row("manual-only", "Manual", false),
        ],
    );
    editor.candidates = vec![
        row("wire-alpha", "Server alias", false),
        row("wire-beta", "Beta", true),
    ];
    editor
        .selected
        .extend(["wire-alpha".into(), "wire-beta".into()]);
    assert_eq!(editor.import_selected(), Ok(1));
    assert_eq!(
        editor.models,
        vec![
            row("wire-alpha", "My private alias", true),
            row("manual-only", "Manual", false),
            row("wire-beta", "Beta", true)
        ]
    );
    editor.selected.insert("wire-beta".into());
    assert_eq!(editor.import_selected(), Ok(0));
}

#[test]
fn selected_import_respects_capacity_without_partially_mutating_the_draft() {
    let mut editor = ProviderModelEditor::new(
        "dsh",
        1,
        (0..32)
            .map(|i| row(&format!("model-{i}"), "Model", false))
            .collect(),
    );
    editor.candidates = vec![row("additional", "Additional", false)];
    editor.selected.insert("additional".into());
    let before = editor.models.clone();
    assert_eq!(editor.import_selected(), Err(()));
    assert_eq!(editor.models, before);
}

#[test]
fn discovery_replies_are_bound_to_exact_provider_operation_and_candidate_shape() {
    let editor = ProviderModelEditor::new("claude-code", 1, vec![]);
    let request = request(
        &editor,
        Operation::Discover {
            profile: json!({"harness_id":"claude-code"}),
        },
    );
    let value = json!({"schema_version":1,"harness_id":"claude-code","operation_id":request.token,"models":[{"wire_model":"provider-new-model","name":"New model","supports_images":true}],"truncated":false});
    let (rows, truncated) = actions::parse_discovery(&request, &value).unwrap();
    assert_eq!(rows, vec![row("provider-new-model", "New model", true)]);
    assert!(!truncated);
    for (field, changed) in [
        ("operation_id", json!(uuid::Uuid::new_v4().to_string())),
        ("harness_id", json!("codex")),
        ("truncated", json!("false")),
    ] {
        let mut foreign = value.clone();
        foreign[field] = changed;
        assert!(actions::parse_discovery(&request, &foreign).is_err());
    }
}

struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
}
impl Fixture {
    fn new(width: f32, height: f32, value: Value) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(height)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                shell.loading = false;
                shell.locale = Locale::Zh;
                shell.page = Page::Settings;
                shell.state.apply_provider_catalog(value.clone()).unwrap();
                shell
                    .state
                    .load_snapshot(json!({"schema_version":1,"status":"missing"}))
                    .unwrap();
                shell.provider_models.install_snapshot(value).unwrap();
                shell.settings_expanded = Some(settings::PreferenceGroup::Models);
                cx.notify();
            })
            .unwrap();
        let mut f = Self { window, cx };
        f.draw();
        f
    }
    fn draw(&mut self) {
        self.cx.run_until_parked();
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
    }
    fn click(&mut self, id: &'static str) {
        let point = self
            .cx
            .debug_bounds(id)
            .unwrap_or_else(|| panic!("missing {id}"))
            .center();
        self.cx.simulate_click(point, Modifiers::none());
        self.draw();
    }
}

#[test]
fn empty_catalog_shows_provider_setup_without_inventing_a_model_or_changing_preferences() {
    for width in [390., 1194.] {
        let mut f = Fixture::new(width, 834., registry(vec![]));
        let before = f
            .window
            .read_with(&f.cx, |s, _| {
                assert!(s.state.models().is_empty());
                assert_eq!(s.settings_default_model_id(), "");
                assert_eq!(s.model_display_label(""), "选择模型");
                s.state.raw_session().clone()
            })
            .unwrap();
        let b = f.cx.debug_bounds("settings-models-empty").unwrap();
        assert!(b.left() >= px(0.) && b.right() <= px(width));
        f.click("settings-models-empty-configure");
        f.window
            .read_with(&f.cx, |s, _| {
                assert!(s.settings_expanded == Some(settings::PreferenceGroup::Accounts));
                assert_eq!(s.state.raw_session(), &before);
            })
            .unwrap();
    }
}

#[test]
fn saved_arbitrary_models_are_the_only_default_choices() {
    let value = registry(vec![
        row("new-provider-model-2040", "Fresh provider model", false).value(),
    ]);
    let mut f = Fixture::new(390., 844., value);
    assert!(
        f.cx.debug_bounds("settings-default-model-new-provider-model-2040")
            .is_some()
    );
    for selector in [
        "settings-default-model-deepseek-v4-flash",
        "settings-default-model-claude-sonnet-5",
        "settings-default-model-gpt-5.6",
        "settings-default-model-GLM-5.3",
    ] {
        assert!(f.cx.debug_bounds(selector).is_none());
    }
    f.window
        .read_with(&f.cx, |s, _| assert_eq!(s.state.models().len(), 1))
        .unwrap();
}

#[test]
fn stale_discovery_cannot_change_reopened_provider_editor() {
    let mut f = Fixture::new(390., 844., registry(vec![]));
    f.window.update(&mut f.cx,|s,_,cx|{
        let old_editor=ProviderModelEditor::new("dsh",1,vec![row("manual","Manual",true)]);
        let old=request(&old_editor,Operation::Discover{profile:json!({"harness_id":"dsh"})});
        s.provider_models.request=Some(old.clone());
        s.provider_models.editor=Some(ProviderModelEditor::new("codex",1,vec![row("another","Another",false)]));
        let before=s.provider_models.editor.as_ref().unwrap().models.clone();
        s.complete_provider_models_request(old.clone(),Ok(json!({"schema_version":1,"harness_id":"dsh","operation_id":old.token,"models":[{"wire_model":"late","name":"Late","supports_images":false}],"truncated":false})),cx);
        assert_eq!(s.provider_models.editor.as_ref().unwrap().models,before);
        assert!(!s.provider_models.request_pending());
    }).unwrap();
}

#[test]
fn unsupported_fetch_keeps_manual_model_and_uses_local_guidance_not_global_error() {
    let mut f = Fixture::new(390., 844., registry(vec![]));
    f.window
        .update(&mut f.cx, |s, _, cx| {
            let editor =
                ProviderModelEditor::new("glm", 1, vec![row("my-deployment", "My model", false)]);
            let pending = request(
                &editor,
                Operation::Discover {
                    profile: json!({"harness_id":"glm"}),
                },
            );
            s.provider_models.editor = Some(editor);
            s.provider_models.request = Some(pending.clone());
            s.complete_provider_models_request(
                pending,
                Err("E_PROVIDER_MODEL_DISCOVERY_HTTP".into()),
                cx,
            );
            let editor = s.provider_models.editor.as_ref().unwrap();
            assert_eq!(editor.models[0].id, "my-deployment");
            assert!(editor.notice.as_deref().unwrap().contains("手动添加"));
            assert!(s.notice.is_none());
        })
        .unwrap();
}

#[test]
fn long_manual_model_id_keeps_exact_wire_identity_with_bounded_default_label() {
    let mut editor = ProviderModelEditor::new("dsh", 0, vec![]);
    let id = "model-".to_owned() + &"x".repeat(122);
    editor.set_models(&id).unwrap();
    assert_eq!(editor.models[0].id, id);
    assert_eq!(editor.models[0].name.len(), 80);
}

fn commit(state: &mut ShellState, command: RuntimeCommand, generation: u64) {
    let bytes = command.args[0]["candidate_json"].as_str().unwrap();
    let digest = rish_agent_core::session_schema::candidate_digest(bytes.as_bytes()).unwrap();
    state
        .accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{
        "schema_version":1,"generation":generation,"session_sha256":digest}}))
        .unwrap();
}

#[test]
fn saving_provider_models_updates_choices_without_switching_existing_chat_or_default() {
    let initial = registry(vec![row("wire-alpha", "Alpha", false).value()]);
    let mut f = Fixture::new(390., 844., initial.clone());
    f.window.update(&mut f.cx,|s,_,cx|{
        s.state.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
        let command=s.state.create_conversation(&uuid::Uuid::new_v4().to_string(),"2026-10-30T00:00:00.000Z","wire-alpha").unwrap();
        commit(&mut s.state,command,1);
        let command=s.state.set_default_model("wire-alpha").unwrap();commit(&mut s.state,command,2);
        let session=s.state.raw_session().clone();
        let mut editor=ProviderModelEditor::new("dsh",1,vec![row("wire-alpha","Alpha",false)]);
        editor.set_models("wire-beta | Beta").unwrap();
        let models:Vec<_>=editor.models.iter().map(ModelRow::value).collect();
        let response=rish_shell_core::provider_model_catalog::save_registry(&initial,&json!({"schema_version":1,"harness_id":"dsh","expected_revision":1,"models":models}),&Value::Null,&[]).unwrap();
        let pending=request(&editor,Operation::Save{models,revision:1});
        s.provider_models.editor=Some(editor);s.provider_models.request=Some(pending.clone());
        s.complete_provider_models_request(pending,Ok(response),cx);
        assert_eq!(s.state.models().iter().map(|m|m.id.as_str()).collect::<Vec<_>>(),vec!["wire-beta"]);
        assert_eq!(s.state.selected_model(),"wire-alpha");assert_eq!(s.settings_default_model_id(),"wire-alpha");
        assert_eq!(s.state.raw_session(),&session);assert!(!s.provider_models.editor.as_ref().unwrap().needs_reload);
        assert!(s.model_display_label("wire-alpha").contains("不可用"));
    }).unwrap();
}

#[test]
fn provider_editor_and_bounded_discovery_list_fit_phone_and_tablet_columns() {
    for width in [390., 1194.] {
        let mut f = Fixture::new(width, 834., registry(vec![]));
        f.window
            .update(&mut f.cx, |s, _, cx| {
                s.open_provider_models("dsh", cx);
                let editor = s.provider_models.editor.as_mut().unwrap();
                editor.models = vec![row(
                    "manual-model",
                    "A long manual name that must remain inside the model editor",
                    true,
                )];
                editor.discovered = true;
                editor.candidates = (0..512)
                    .map(|i| {
                        row(
                            &format!("server-model-{i}"),
                            &format!("Service model {i}"),
                            false,
                        )
                    })
                    .collect();
                cx.notify();
            })
            .unwrap();
        f.draw();
        for id in [
            "provider-models-editor",
            "provider-models-key",
            "provider-models-fetch",
            "provider-models-manual",
            "provider-model-candidates",
            "provider-models-save",
        ] {
            let bounds =
                f.cx.debug_bounds(id)
                    .unwrap_or_else(|| panic!("missing {id}"));
            assert!(
                bounds.left() >= px(0.) && bounds.right() <= px(width),
                "{id} escaped width {width}: {bounds:?}"
            );
        }
        let bounds = f.cx.debug_bounds("provider-model-candidates").unwrap();
        assert!(bounds.size.height <= px(280.));
        f.window
            .read_with(&f.cx, |s, _| {
                assert_eq!(
                    s.provider_models.editor.as_ref().unwrap().candidates.len(),
                    512
                )
            })
            .unwrap();
    }
}

#[test]
fn empty_model_picker_opens_setup_guide_without_mutating_saved_choice() {
    let mut f = Fixture::new(390., 844., registry(vec![]));
    let before = f
        .window
        .read_with(&f.cx, |s, _| s.state.raw_session().clone())
        .unwrap();
    f.window
        .update(&mut f.cx, |s, window, cx| s.open_model_picker(window, cx))
        .unwrap();
    f.draw();
    assert!(f.cx.debug_bounds("model-picker-empty").is_some());
    f.click("model-picker-empty-configure");
    f.window
        .read_with(&f.cx, |s, _| {
            assert!(!s.model_picker);
            assert!(s.page == Page::Settings);
            assert!(s.settings_expanded == Some(settings::PreferenceGroup::Accounts));
            assert_eq!(s.state.raw_session(), &before);
        })
        .unwrap();
}

#[test]
fn credential_prompt_acknowledgment_keeps_models_and_releases_native_form() {
    let mut f = Fixture::new(
        390.,
        844.,
        registry(vec![row("manual-model", "Manual", false).value()]),
    );
    f.window
        .update(&mut f.cx, |s, _, cx| {
            let editor =
                ProviderModelEditor::new("dsh", 1, vec![row("manual-model", "Manual", false)]);
            let pending = request(&editor, Operation::Credential);
            let before = s.state.raw_session().clone();
            s.provider_models.editor = Some(editor);
            s.provider_models.request = Some(pending.clone());
            s.set_inline_native_form(true, cx);
            s.complete_provider_models_request(pending, Ok(json!(true)), cx);
            assert!(!s.native_form_active);
            assert!(!s.provider_models.request_pending());
            assert_eq!(
                s.provider_models.editor.as_ref().unwrap().models,
                vec![row("manual-model", "Manual", false)]
            );
            assert!(
                s.provider_models
                    .editor
                    .as_ref()
                    .unwrap()
                    .notice
                    .as_deref()
                    .unwrap()
                    .contains("密钥已保存")
            );
            assert_eq!(s.state.raw_session(), &before);
        })
        .unwrap();
}

#[test]
fn send_setup_picker_receives_keyboard_focus_and_restores_it_on_close() {
    let mut f = Fixture::new(
        390.,
        844.,
        registry(vec![row("manual-model", "Manual", false).value()]),
    );
    f.window
        .update(&mut f.cx, |s, window, cx| {
            window.focus(&s.drawer_focus, cx);
            s.choose_configured_model(cx);
        })
        .unwrap();
    f.draw();
    f.window
        .update(&mut f.cx, |s, window, cx| {
            assert!(s.model_picker_focus.is_focused(window));
            s.close_model_picker(window, cx);
            assert!(s.drawer_focus.is_focused(window));
        })
        .unwrap();
}
