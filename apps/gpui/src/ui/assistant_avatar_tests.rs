use super::*;
use crate::assistant_runtime::RunnerSnapshot;
use gpui::{
    Bounds, Modifiers, Pixels, ScrollDelta, ScrollWheelEvent, TestAppContext, TouchPhase,
    VisualTestContext, point, size,
};
use rish_shell_core::assistant_store::{AssistantSnapshot, AssistantStore, AssistantStoreError};
use serde_json::json;

fn avatar() -> AssistantAvatar {
    AssistantAvatar {
        id: "c0417c3a-2161-4d6b-8aac-84611d677ad6".into(),
        sha256: "a".repeat(64),
        mime_type: "image/png".into(),
        width: 64,
        height: 64,
        byte_length: 1024,
    }
}
fn profile() -> AssistantProfile {
    AssistantProfile {
        name: "我的助手".into(),
        notes: "保留这份中文偏好，不覆盖其他资料。".into(),
        avatar: None,
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
fn reply() -> Value {
    json!({"schema_version":1,"avatar":avatar()})
}

#[test]
fn picker_response_accepts_only_canonical_metadata_and_explicit_cancellation() {
    assert_eq!(parse_avatar_reply(Value::Null), Ok(None));
    assert_eq!(parse_avatar_reply(reply()), Ok(Some(avatar())));
    for value in [
        json!({"cancelled":true}),
        json!({"schema_version":2,"avatar":avatar()}),
        json!({"schema_version":1,"avatar":avatar(),"uri":"file:///private/secret.png"}),
        json!({"schema_version":1,"avatar":null}),
    ] {
        assert!(parse_avatar_reply(value).is_err());
    }
    for (field, value) in [
        ("id", json!("../../photo")),
        ("uri", json!("file:///photo.png")),
        ("width", json!(1.5)),
        ("height", json!(513)),
        ("mime_type", json!("image/svg+xml")),
        ("byte_length", json!(2_097_153)),
    ] {
        let mut result = reply();
        result["avatar"][field] = value;
        assert!(
            parse_avatar_reply(result).is_err(),
            "{field} must be rejected"
        );
    }
}

#[test]
fn cancelling_photo_selection_preserves_profile_draft_and_prior_error() {
    let mut ui = ui();
    let mut draft = profile();
    draft.name = "未保存的名称".into();
    ui.profile_draft = Some(ProfileDraft {
        baseline: profile(),
        profile: draft.clone(),
        expected_revision: 6,
        saving: false,
    });
    ui.error = Some("Existing profile conflict".into());
    let request = ui.begin_avatar_request().unwrap();
    assert_eq!(
        ui.accept_avatar_result(&request, Ok(Value::Null), Locale::Zh),
        AvatarUpdate::Unchanged
    );
    assert_eq!(ui.profile_draft.as_ref().unwrap().profile, draft);
    assert_eq!(ui.snapshot.store.as_ref().unwrap().profile, profile());
    assert_eq!(ui.error.as_deref(), Some("Existing profile conflict"));
    assert!(ui.form_request.is_none());
}

#[test]
fn new_avatar_preserves_name_and_notes_until_the_saved_snapshot_acknowledges_it() {
    let mut ui = ui();
    let request = ui.begin_avatar_request().unwrap();
    assert_eq!(
        ui.accept_avatar_result(&request, Ok(reply()), Locale::Zh),
        AvatarUpdate::Save
    );
    let draft = ui.profile_draft.as_ref().unwrap();
    assert_eq!(draft.expected_revision, 7);
    assert_eq!(draft.profile.name, profile().name);
    assert_eq!(draft.profile.notes, profile().notes);
    assert_eq!(draft.profile.avatar, Some(avatar()));
    assert!(ui.snapshot.store.as_ref().unwrap().profile.avatar.is_none());
    let saved = draft.profile.clone();
    ui.profile_draft.as_mut().unwrap().saving = true;
    ui.apply_snapshot(ui.snapshot.clone());
    assert!(
        ui.profile_draft.is_some(),
        "unconfirmed writes cannot clear the photo choice"
    );
    let mut acknowledged = ui.snapshot.clone();
    let store = acknowledged.store.as_mut().unwrap();
    store.revision = 8;
    store.profile = saved;
    ui.apply_snapshot(acknowledged);
    assert!(ui.profile_draft.is_none());
    assert_eq!(
        ui.snapshot.store.as_ref().unwrap().profile.avatar,
        Some(avatar())
    );
}

#[test]
fn stale_picker_result_cannot_close_another_form_or_replace_its_profile() {
    let mut ui = ui();
    let request = ui.begin_avatar_request().unwrap();
    ui.form_request = Some("another-native-form".into());
    ui.error = Some("newer error".into());
    assert_eq!(
        ui.accept_avatar_result(&request, Ok(reply()), Locale::Zh),
        AvatarUpdate::Ignored
    );
    assert_eq!(ui.form_request.as_deref(), Some("another-native-form"));
    assert_eq!(ui.error.as_deref(), Some("newer error"));
    assert!(ui.profile_draft.is_none());
}

#[test]
fn changed_profile_and_existing_drafts_require_explicit_review() {
    let mut changed = ui();
    let request = changed.begin_avatar_request().unwrap();
    let store = changed.snapshot.store.as_mut().unwrap();
    store.revision += 1;
    store.profile.name = "另一处修改的名字".into();
    assert_eq!(
        changed.accept_avatar_result(&request, Ok(reply()), Locale::Zh),
        AvatarUpdate::Review
    );
    assert_eq!(
        changed.snapshot.store.as_ref().unwrap().profile.name,
        "另一处修改的名字"
    );
    assert_eq!(
        changed.profile_draft.as_ref().unwrap().profile.name,
        "另一处修改的名字"
    );
    assert_eq!(
        changed.profile_draft.as_ref().unwrap().profile.avatar,
        Some(avatar())
    );
    let mut existing = ui();
    let mut draft = profile();
    draft.notes = "尚未决定覆盖的备注".into();
    existing.profile_draft = Some(ProfileDraft {
        baseline: profile(),
        profile: draft.clone(),
        expected_revision: 6,
        saving: false,
    });
    let request = existing.begin_avatar_request().unwrap();
    assert_eq!(
        existing.accept_avatar_result(&request, Ok(reply()), Locale::Zh),
        AvatarUpdate::Review
    );
    assert_eq!(
        existing.profile_draft.as_ref().unwrap().profile.notes,
        draft.notes
    );
    assert!(!existing.profile_draft.as_ref().unwrap().saving);
    let mut unrelated = ui();
    let request = unrelated.begin_avatar_request().unwrap();
    unrelated.snapshot.store.as_mut().unwrap().revision += 1;
    assert_eq!(
        unrelated.accept_avatar_result(&request, Ok(reply()), Locale::Zh),
        AvatarUpdate::Save
    );
    assert_eq!(
        unrelated.profile_draft.as_ref().unwrap().expected_revision,
        8
    );
}

#[test]
fn picker_errors_preserve_previous_photo_without_exposing_native_paths() {
    for result in [
        Err("Native failed /private/photo.png".into()),
        Ok(json!({"unexpected":true})),
    ] {
        let mut ui = ui();
        ui.snapshot.store.as_mut().unwrap().profile.avatar = Some(avatar());
        let request = ui.begin_avatar_request().unwrap();
        assert_eq!(
            ui.accept_avatar_result(&request, result, Locale::Zh),
            AvatarUpdate::Failed
        );
        assert_eq!(
            ui.snapshot.store.as_ref().unwrap().profile.avatar,
            Some(avatar())
        );
        assert!(ui.profile_draft.is_none());
        assert!(ui.form_request.is_none());
        let message = ui.error.unwrap();
        assert!(message.contains("现有资料已保留"));
        assert!(!message.contains("/private"));
    }
}

#[test]
fn restoring_default_only_changes_the_avatar_and_keeps_unsaved_edits() {
    let mut ui = ui();
    ui.snapshot.store.as_mut().unwrap().profile.avatar = Some(avatar());
    let request = ui.begin_avatar_request().unwrap();
    ui.form_request = None;
    assert_eq!(
        ui.stage_avatar(&request, None, Locale::Zh),
        AvatarUpdate::Save
    );
    assert_eq!(ui.profile_draft.as_ref().unwrap().profile, profile());
    assert_eq!(
        ui.snapshot.store.as_ref().unwrap().profile.avatar,
        Some(avatar())
    );
    let request = ui.begin_avatar_request().unwrap();
    ui.form_request = None;
    assert_eq!(
        ui.stage_avatar(&request, None, Locale::Zh),
        AvatarUpdate::Review,
        "an existing draft is not implicit overwrite approval"
    );
}

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let p = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("rish-avatar-ui-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&p).unwrap();
        Self(p)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn actual_store_cas_rejects_a_profile_changed_after_the_picker_finishes() {
    let directory = Directory::new();
    let store = AssistantStore::open(&directory.0).unwrap();
    let original = store.set_profile(0, profile()).unwrap();
    let mut ui = ui();
    ui.snapshot.store = Some(original.clone());
    let request = ui.begin_avatar_request().unwrap();
    assert_eq!(
        ui.accept_avatar_result(&request, Ok(reply()), Locale::Zh),
        AvatarUpdate::Save
    );
    let pending = ui.profile_draft.as_ref().unwrap();
    let expected = pending.expected_revision;
    let desired = pending.profile.clone();
    let mut another = profile();
    another.name = "并发保存的名称".into();
    let committed = store
        .set_profile(original.revision, another.clone())
        .unwrap();
    let error = store.set_profile(expected, desired.clone()).unwrap_err();
    assert!(matches!(error, AssistantStoreError::Conflict { .. }));
    ui.accept_error(&error.to_string());
    ui.apply_snapshot(RunnerSnapshot {
        store: Some(committed),
        ..Default::default()
    });
    assert_eq!(store.load().unwrap().profile, another);
    let mut rebased = another.clone();
    rebased.avatar = desired.avatar;
    assert_eq!(ui.profile_draft.as_ref().unwrap().profile, rebased);
    assert!(!ui.profile_draft.as_ref().unwrap().saving);
}

#[test]
fn avatar_sources_require_a_native_absolute_root_and_safe_metadata() {
    assert!(image_key(None, Some(&avatar())).is_none());
    assert!(image_key(Some(&PathBuf::from("relative")), Some(&avatar())).is_none());
    assert!(
        image_key(
            Some(&PathBuf::from("/private/root/../other")),
            Some(&avatar())
        )
        .is_none()
    );
    let mut invalid = avatar();
    invalid.id = "/private/other".into();
    assert!(image_key(Some(&PathBuf::from("/private/root")), Some(&invalid)).is_none());
    assert!(image_key(Some(&PathBuf::from("/private/root")), Some(&avatar())).is_some());
}

// A synthetic transparent pixel, never a user's photo.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52, 0, 0, 0,
    1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 0x0b, 0x49, 0x44, 0x41, 0x54,
    0x78, 0x9c, 0x63, 0x60, 0, 2, 0, 0, 5, 0, 1, 0x7a, 0x5e, 0xab, 0x3f, 0, 0, 0, 0, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];
#[test]
fn cached_asset_loader_verifies_private_bytes_then_decodes_the_png() {
    let dir = Directory::new();
    std::fs::create_dir(dir.0.join("avatars")).unwrap();
    let mut meta = avatar();
    meta.width = 1;
    meta.height = 1;
    meta.byte_length = PNG.len() as u64;
    meta.sha256 = rish_agent_core::canonical::sha256_hex(PNG);
    let path = dir.0.join("avatars").join(format!("{}.png", meta.id));
    std::fs::write(&path, PNG).unwrap();
    let key = image_key(Some(&dir.0), Some(&meta)).unwrap();
    let app = TestAppContext::single();
    let image = app
        .update(|cx| futures::executor::block_on(AvatarImage::load(key.clone(), cx)))
        .unwrap();
    assert_eq!(image.as_bytes(0).unwrap().len(), 4);
    let mut tampered = PNG.to_vec();
    tampered[40] ^= 1;
    std::fs::write(path, &tampered).unwrap();
    assert!(
        app.update(|cx| futures::executor::block_on(AvatarImage::load(key, cx)))
            .is_err()
    );
}

fn bounds(cx: &mut VisualTestContext, id: &'static str) -> Bounds<Pixels> {
    cx.debug_bounds(id)
        .unwrap_or_else(|| panic!("missing {id}"))
}
#[test]
fn profile_menu_keeps_actions_reachable_and_dismissal_preserves_drafts() {
    for (width, height) in [(320., 480.), (390., 844.), (1194., 834.)] {
        for locale in [Locale::Zh, Locale::En] {
            let mut app = TestAppContext::single();
            let window = app.open_window(size(px(width), px(height)), |_, cx| Shell::new(cx));
            let mut cx = VisualTestContext::from_window(window.into(), &app);
            cx.run_until_parked();
            window
                .update(&mut cx, |shell, window, cx| {
                    shell.page = Page::Settings;
                    shell.locale = locale;
                    shell.assistant = ui();
                    shell.assistant.profile_menu_open = true;
                    let focus = cx.focus_handle();
                    window.focus(&focus, cx);
                    shell.assistant.profile_menu_focus = Some(focus);
                    shell.assistant.profile_draft = Some(ProfileDraft {
                        baseline: profile(),
                        profile: profile(),
                        expected_revision: 6,
                        saving: false,
                    });
                    shell.assistant.error = Some("请核对未保存的头像和资料。".repeat(12));
                    cx.notify();
                })
                .unwrap();
            cx.run_until_parked();
            cx.update(|window, cx| window.draw(cx).clear(cx));
            let panel = bounds(&mut cx, "assistant-profile-menu");
            let scroll = bounds(&mut cx, "assistant-profile-menu-scroll");
            assert!(
                panel.left() >= px(0.)
                    && panel.right() <= px(width)
                    && panel.top() >= px(0.)
                    && panel.bottom() <= px(height)
            );
            assert!(scroll.bottom() <= panel.bottom() && scroll.size.height >= px(44.));
            for id in [
                "assistant-profile-rename",
                "assistant-profile-notes",
                "assistant-profile-soul",
                "assistant-profile-memory",
                "assistant-profile-photo",
                "assistant-profile-default",
                "assistant-profile-save-draft",
                "assistant-profile-discard-draft",
            ] {
                let button = bounds(&mut cx, id);
                let delta = if button.bottom() > scroll.bottom() {
                    scroll.bottom() - button.bottom() - px(1.)
                } else if button.top() < scroll.top() {
                    scroll.top() - button.top() + px(1.)
                } else {
                    px(0.)
                };
                cx.simulate_event(ScrollWheelEvent {
                    position: point(scroll.left() + px(2.), scroll.center().y),
                    delta: ScrollDelta::Pixels(point(px(0.), delta)),
                    modifiers: Modifiers::none(),
                    touch_phase: TouchPhase::Moved,
                });
                cx.run_until_parked();
                cx.update(|window, cx| window.draw(cx).clear(cx));
                let button = bounds(&mut cx, id);
                assert!(button.size.height >= px(44.), "{id}");
                assert!(
                    button.top() >= scroll.top() && button.bottom() <= scroll.bottom(),
                    "{id}: {button:?} in {scroll:?}"
                );
            }
            let close = bounds(&mut cx, "assistant-profile-close");
            assert!(close.size.height >= px(44.) && close.size.width >= px(44.));
            cx.simulate_click(close.center(), Modifiers::none());
            cx.run_until_parked();
            window
                .read_with(&cx, |shell, _| {
                    assert!(!shell.assistant.profile_menu_open);
                    assert!(shell.assistant.profile_draft.is_some());
                    assert_eq!(
                        shell.assistant.snapshot.store.as_ref().unwrap().profile,
                        profile()
                    );
                })
                .unwrap();
        }
    }
}

#[test]
fn profile_save_errors_are_localized_without_exposing_storage_paths() {
    let conflict = profile_error(
        Locale::Zh,
        "Assistant state changed (expected 7, actual 8)",
        true,
    );
    assert!(conflict.contains("草稿"));
    let failure = profile_error(
        Locale::Zh,
        "Assistant storage failed: /private/profile.json",
        true,
    );
    assert!(failure.contains("尚未确认"));
    assert!(!failure.contains("/private"));
    let no_draft = profile_error(
        Locale::Zh,
        "Assistant storage failed: /private/profile.json",
        false,
    );
    assert!(!no_draft.contains("草稿"));
    assert!(!no_draft.contains("/private"));
}
