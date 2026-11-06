use super::*;
use crate::assistant_runtime::{RunnerCommand, RunnerSnapshot};
use crate::ui::settings_runtime_engines::{EngineExecution, EngineInstallation};
use gpui::{
    Bounds, Modifiers, Pixels, ScrollDelta, ScrollWheelEvent, TestAppContext, TouchPhase,
    VisualTestContext, point, size,
};
use rish_shell_core::assistant_store::{
    AssistantAvatar, AssistantSnapshot, AssistantStore, AssistantStoreError,
};

fn profile() -> AssistantProfile {
    AssistantProfile {
        name: "Rish".into(),
        notes: "Keep my notes".into(),
        ..Default::default()
    }
}
fn ui() -> AssistantUi {
    AssistantUi {
        snapshot: RunnerSnapshot {
            store: Some(AssistantSnapshot {
                revision: 7,
                profile: profile(),
                ..Default::default()
            }),
            ..Default::default()
        },
        ..Default::default()
    }
}
fn custom() -> RuntimeSpec {
    RuntimeSpec::custom("My engine", SCRIPT_EXAMPLE).unwrap()
}

fn reveal_runtime_control(cx: &mut VisualTestContext, id: &'static str) -> Bounds<Pixels> {
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
        control.top() >= viewport.top() && control.bottom() <= viewport.bottom(),
        "{id} must remain reachable"
    );
    control
}

#[test]
fn runtime_editor_validates_bounded_user_source_and_retains_exact_fingerprint() {
    let mut editor = RuntimeEditor::new(&profile(), &profile(), true);
    let spec = editor.spec(Locale::En).unwrap();
    assert_eq!(spec.source(), Some(SCRIPT_EXAMPLE));
    let RuntimeSpec::Custom { source, sha256, .. } = &spec else {
        panic!("custom");
    };
    assert_eq!(
        *sha256,
        rish_agent_core::canonical::sha256_hex(source.as_bytes())
    );
    editor.source = "x".repeat(MAX_SOURCE_BYTES);
    assert!(editor.spec(Locale::En).is_ok());
    editor.source.push('x');
    assert!(editor.spec(Locale::Zh).unwrap_err().contains("32 KB"));
    editor.source = " \n ".into();
    assert!(editor.spec(Locale::En).is_err());
    editor.source = SCRIPT_EXAMPLE.into();
    for name in ["".into(), "x".repeat(257), "bad\nname".into()] {
        editor.name = name;
        assert!(editor.spec(Locale::En).is_err());
    }
    editor.custom = false;
    assert_eq!(editor.spec(Locale::En).unwrap(), RuntimeSpec::pi());
}

#[test]
fn runtime_staging_merges_concurrent_profile_fields_and_requires_review() {
    let mut ui = ui();
    let baseline = profile();
    let latest = &mut ui.snapshot.store.as_mut().unwrap().profile;
    latest.name = "Changed concurrently".into();
    latest.notes = "New saved notes".into();
    latest.avatar = Some(AssistantAvatar {
        id: "c0417c3a-2161-4d6b-8aac-84611d677ad6".into(),
        sha256: "a".repeat(64),
        mime_type: "image/png".into(),
        width: 64,
        height: 64,
        byte_length: 1024,
    });
    let latest = latest.clone();
    assert!(!ui.stage_runtime(&baseline, custom()));
    let draft = ui.profile_draft.as_ref().unwrap();
    assert_eq!(draft.profile.name, latest.name);
    assert_eq!(draft.profile.notes, latest.notes);
    assert_eq!(draft.profile.avatar, latest.avatar);
    assert_eq!(draft.profile.runtime, custom());
    assert!(!draft.saving);
    assert_eq!(ui.snapshot.store.as_ref().unwrap().profile, latest);
}

#[test]
fn existing_profile_draft_is_preserved_and_never_saved_by_runtime_selection() {
    let mut ui = ui();
    let mut unsaved = profile();
    unsaved.notes = "Unsaved note edit".into();
    ui.profile_draft = Some(ProfileDraft {
        baseline: profile(),
        profile: unsaved,
        expected_revision: 7,
        saving: false,
    });
    assert!(!ui.stage_runtime(&profile(), custom()));
    assert_eq!(
        ui.profile_draft.as_ref().unwrap().profile.notes,
        "Unsaved note edit"
    );
    assert_eq!(ui.profile_draft.as_ref().unwrap().profile.runtime, custom());
    assert!(!ui.profile_draft.as_ref().unwrap().saving);
    assert_eq!(ui.snapshot.store.as_ref().unwrap().profile, profile());
}

#[test]
fn restoring_pi_is_a_typed_profile_change_and_preserves_notes() {
    let mut ui = ui();
    ui.snapshot.store.as_mut().unwrap().profile.runtime = custom();
    let baseline = ui.snapshot.store.as_ref().unwrap().profile.clone();
    assert!(ui.stage_runtime(&baseline, RuntimeSpec::pi()));
    let draft = ui.profile_draft.as_ref().unwrap();
    assert_eq!(draft.profile.runtime, RuntimeSpec::pi());
    assert_eq!(draft.profile.notes, baseline.notes);
    assert_eq!(
        ui.snapshot.store.as_ref().unwrap().profile.runtime,
        custom()
    );
}

#[test]
fn native_runtime_forms_ignore_stale_tokens_and_keep_drafts_on_cancel_or_invalid_input() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(393.), px(844.)), |_, cx| Shell::new(cx));
    window
        .update(&mut app, |shell, _, cx| {
            shell.runtime_editor = Some(RuntimeEditor::new(&profile(), &profile(), true));
            let id = shell.runtime_editor.as_ref().unwrap().id.clone();
            shell.assistant.form_request = Some("current".into());
            shell.native_form_active = true;
            shell.complete_runtime_field("old", &id, true, Ok(Value::String("stale".into())), cx);
            assert!(shell.native_form_active);
            assert_eq!(shell.assistant.form_request.as_deref(), Some("current"));
            assert_eq!(
                shell.runtime_editor.as_ref().unwrap().source,
                SCRIPT_EXAMPLE
            );
            shell.complete_runtime_field("current", &id, true, Ok(Value::Null), cx);
            assert!(!shell.native_form_active);
            assert!(shell.assistant.form_request.is_none());
            assert_eq!(
                shell.runtime_editor.as_ref().unwrap().source,
                SCRIPT_EXAMPLE
            );
            for result in [
                Ok(Value::Bool(true)),
                Ok(Value::String("x".repeat(MAX_SOURCE_BYTES + 1))),
                Err("native failure".into()),
            ] {
                shell.assistant.form_request = Some("invalid".into());
                shell.native_form_active = true;
                shell.complete_runtime_field("invalid", &id, true, result, cx);
                assert!(!shell.native_form_active);
                assert_eq!(
                    shell.runtime_editor.as_ref().unwrap().source,
                    SCRIPT_EXAMPLE
                );
                assert!(shell.runtime_editor.as_ref().unwrap().error.is_some());
                assert!(shell.assistant.profile_draft.is_none());
            }
            shell.assistant.form_request = Some("renamed-editor".into());
            shell.complete_runtime_field(
                "renamed-editor",
                "stale-editor-id",
                false,
                Ok(Value::String("wrong editor".into())),
                cx,
            );
            assert_eq!(shell.runtime_editor.as_ref().unwrap().name, "My runtime");
        })
        .unwrap();
}

struct Directory(std::path::PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-runtime-settings-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn actual_profile_cas_retains_runtime_draft_and_only_matching_acknowledgment_clears_it() {
    let dir = Directory::new();
    let store = AssistantStore::open(&dir.0).unwrap();
    let saved = store.set_profile(0, profile()).unwrap();
    let mut ui = ui();
    ui.snapshot.store = Some(saved.clone());
    // Saving source must not evaluate it, even if it would throw on evaluation.
    let spec = RuntimeSpec::custom(
        "Unexecuted",
        "(() => { throw new Error('save must not execute'); })()",
    )
    .unwrap();
    assert!(ui.stage_runtime(&saved.profile, spec.clone()));
    let RunnerCommand::SetProfile {
        expected_revision,
        profile: candidate,
    } = assistant_forms::prepare_profile_save(ui.profile_draft.as_mut().unwrap(), &saved)
    else {
        panic!("profile command");
    };
    let mut concurrent = saved.profile.clone();
    concurrent.notes = "Another saved note".into();
    let changed = store
        .set_profile(saved.revision, concurrent.clone())
        .unwrap();
    let error = store.set_profile(expected_revision, candidate).unwrap_err();
    assert!(matches!(error, AssistantStoreError::Conflict { .. }));
    ui.accept_error(&error.to_string());
    ui.apply_snapshot(RunnerSnapshot {
        store: Some(changed.clone()),
        ..Default::default()
    });
    let draft = ui.profile_draft.as_ref().unwrap();
    assert_eq!(draft.profile.runtime, spec);
    assert_eq!(draft.profile.notes, concurrent.notes);
    assert!(!draft.saving);
    let RunnerCommand::SetProfile {
        expected_revision,
        profile: candidate,
    } = assistant_forms::prepare_profile_save(ui.profile_draft.as_mut().unwrap(), &changed)
    else {
        panic!("profile command");
    };
    ui.apply_snapshot(ui.snapshot.clone());
    assert!(
        ui.profile_draft.is_some(),
        "unchanged snapshot cannot acknowledge a write"
    );
    let committed = store.set_profile(expected_revision, candidate).unwrap();
    assert_eq!(committed.profile.runtime, spec);
    ui.apply_snapshot(RunnerSnapshot {
        store: Some(committed),
        ..Default::default()
    });
    assert!(ui.profile_draft.is_none());
}

#[test]
fn existing_task_inherits_changed_runtime_on_its_next_run_without_changing_its_model() {
    use rish_shell_core::assistant_store::{
        AssistantClaimMode, AssistantRunOutcome, AssistantRunStatus, AssistantTaskConfig,
    };
    let directory = Directory::new();
    let store = AssistantStore::open(&directory.0).unwrap();
    let task = AssistantTaskConfig::manual(
        "Existing task",
        "Review the workspace",
        "deepseek-v4-flash",
        serde_json::json!({"workspace_id":"workspace-1"}),
        serde_json::json!({"id":"workspace-1"}),
    );
    let saved = store.create_task(0, task.clone(), 1).unwrap();
    let id = saved.tasks[0].id.clone();
    let first = store
        .claim(saved.revision, &id, AssistantClaimMode::Manual, 2)
        .unwrap();
    assert_eq!(first.run.snapshot.runtime, Some(RuntimeSpec::pi()));
    let changed = store
        .set_profile(
            first.snapshot.revision,
            AssistantProfile {
                runtime: custom(),
                ..profile()
            },
        )
        .unwrap();
    assert_eq!(
        changed.tasks[0].config(),
        task,
        "changing the profile engine leaves the saved task model and configuration intact"
    );
    assert_eq!(
        changed.tasks[0].last_run.as_ref().unwrap().snapshot.runtime,
        Some(RuntimeSpec::pi()),
        "a running task keeps its frozen engine"
    );
    let finished = store
        .finish(
            changed.revision,
            &id,
            &first.run.run_id,
            AssistantRunOutcome {
                status: AssistantRunStatus::Completed,
                result_summary: Some("Finished".into()),
                failure_code: None,
            },
            3,
        )
        .unwrap();
    let second = store
        .claim(finished.revision, &id, AssistantClaimMode::Manual, 4)
        .unwrap();
    assert_eq!(second.run.snapshot.runtime, Some(custom()));
    assert_eq!(second.run.snapshot.model_id, task.model_id);
    assert!(
        second.snapshot.tasks[0].runtime.is_none(),
        "the task continues to inherit without storing a provider-derived runtime"
    );
}

#[test]
fn custom_runtime_form_fits_phone_tablet_languages_and_themes_without_mutating_preview() {
    for width in [320., 1194.] {
        for locale in [Locale::Zh, Locale::En] {
            for mode in [theme::ThemeMode::Light, theme::ThemeMode::Dark] {
                let mut app = TestAppContext::single();
                let window = app.open_window(size(px(width), px(844.)), |_, cx| Shell::new(cx));
                let mut cx = VisualTestContext::from_window(window.into(), &app);
                cx.run_until_parked();
                window
                    .update(&mut cx, |shell, _, cx| {
                        shell.page = Page::Settings;
                        shell.locale = locale;
                        shell.loading = false;
                        shell.notice = None;
                        shell.assistant = ui();
                        shell.settings_expanded = Some(PreferenceGroup::Runtime);
                        shell.runtime_editor =
                            Some(RuntimeEditor::new(&profile(), &profile(), true));
                        theme::set_mode(mode, cx);
                        cx.notify();
                    })
                    .unwrap();
                cx.run_until_parked();
                cx.update(|window, cx| window.draw(cx).clear(cx));
                let pi = cx.debug_bounds("settings-runtime-pi").unwrap();
                for product in crate::providers::RuntimeProduct::ALL {
                    let row = cx.debug_bounds(product.settings_selector()).unwrap();
                    let logo = cx.debug_bounds(product.selector()).unwrap();
                    assert_eq!(row.left(), pi.left());
                    assert_eq!(row.size.width, pi.size.width);
                    assert_eq!(logo.size.width, px(30.));
                    assert_eq!(logo.size.height, px(30.));
                    assert!(logo.left() >= row.left() && logo.right() <= row.right());
                }
                for id in [
                    "settings-runtime-pi",
                    "settings-runtime-dsh",
                    "settings-runtime-claude-code",
                    "settings-runtime-codex",
                    "settings-runtime-zcode",
                    "settings-runtime-custom",
                    "settings-runtime-name",
                    "settings-runtime-source",
                    "settings-runtime-save",
                    "settings-runtime-cancel",
                ] {
                    let viewport = cx.debug_bounds("settings-content").unwrap();
                    let control = cx.debug_bounds(id).unwrap();
                    assert!(
                        control.size.height >= px(44.) && control.size.width >= px(44.),
                        "{id}"
                    );
                    assert!(
                        control.left() >= viewport.left() + px(19.)
                            && control.right() <= viewport.right() - px(19.),
                        "{id}"
                    );
                    reveal_runtime_control(&mut cx, id);
                }
                window
                    .update(&mut cx, |shell, _, cx| {
                        shell.runtime_action(RuntimeAction::Save, cx);
                        assert!(
                            shell.runtime_editor.is_some(),
                            "preview must not issue native profile writes"
                        );
                        assert!(shell.assistant.profile_draft.is_none());
                        assert_eq!(
                            shell
                                .assistant
                                .snapshot
                                .store
                                .as_ref()
                                .unwrap()
                                .profile
                                .runtime,
                            RuntimeSpec::pi()
                        );
                    })
                    .unwrap();
            }
        }
    }
}

#[test]
fn installed_products_without_execution_do_not_change_pi_model_or_existing_drafts() {
    for has_draft in [false, true] {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(393.), px(844.)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                shell.page = Page::Settings;
                shell.loading = false;
                shell.notice = None;
                shell.assistant = ui();
                shell.settings_expanded = Some(PreferenceGroup::Runtime);
                for entry in &mut shell.runtime_engines.entries {
                    entry.installation = EngineInstallation::Installed {
                        version: Some("fixture-version".into()),
                    };
                    entry.execution = EngineExecution::Unavailable;
                }
                if has_draft {
                    let mut profile_draft = profile();
                    profile_draft.notes = "Unsaved notes".into();
                    profile_draft.runtime = custom();
                    shell.assistant.profile_draft = Some(ProfileDraft {
                        baseline: profile(),
                        profile: profile_draft,
                        expected_revision: 7,
                        saving: false,
                    });
                    shell.runtime_editor = Some(RuntimeEditor::new(&profile(), &profile(), true));
                }
                cx.notify();
            })
            .unwrap();
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        let before = window
            .read_with(&cx, |shell, _| {
                (
                    shell.state.raw_session().clone(),
                    shell.assistant.profile_draft.as_ref().map(|draft| {
                        (
                            draft.baseline.clone(),
                            draft.profile.clone(),
                            draft.expected_revision,
                            draft.saving,
                        )
                    }),
                    shell.runtime_editor.as_ref().map(|editor| {
                        (
                            editor.id.clone(),
                            editor.baseline.clone(),
                            editor.custom,
                            editor.name.clone(),
                            editor.source.clone(),
                            editor.error.clone(),
                        )
                    }),
                )
            })
            .unwrap();
        for product in crate::providers::RuntimeProduct::ALL {
            let control = reveal_runtime_control(&mut cx, product.settings_selector());
            cx.simulate_click(control.center(), Modifiers::none());
            cx.run_until_parked();
            cx.update(|window, cx| window.draw(cx).clear(cx));
            window
                .read_with(&cx, |shell, _| {
                    assert_eq!(shell.state.raw_session(), &before.0);
                    assert_eq!(
                        shell.assistant.snapshot.store.as_ref().unwrap().profile,
                        profile()
                    );
                    assert_eq!(
                        shell
                            .assistant
                            .snapshot
                            .store
                            .as_ref()
                            .unwrap()
                            .profile
                            .runtime,
                        RuntimeSpec::pi()
                    );
                    assert_eq!(
                        shell.assistant.profile_draft.as_ref().map(|draft| {
                            (
                                draft.baseline.clone(),
                                draft.profile.clone(),
                                draft.expected_revision,
                                draft.saving,
                            )
                        }),
                        before.1
                    );
                    assert_eq!(
                        shell.runtime_editor.as_ref().map(|editor| {
                            (
                                editor.id.clone(),
                                editor.baseline.clone(),
                                editor.custom,
                                editor.name.clone(),
                                editor.source.clone(),
                                editor.error.clone(),
                            )
                        }),
                        before.2
                    );
                    assert!(shell.assistant.form_request.is_none());
                    assert!(!shell.native_form_active);
                })
                .unwrap();
        }
    }
}
