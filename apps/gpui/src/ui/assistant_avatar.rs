//! User-selected profile images remain app-private display data. No image,
//! filename or metadata is copied into an Agent run's model context.
use super::{
    assistant_copy as words,
    assistant_forms::{AssistantUi, Field, ProfileDraft},
    assistant_primitives::divider,
    assistant_view::Action,
    *,
};
use crate::icons::{Icon, icon};
use gpui::{
    AnyElement, Asset, Image, ImageCacheError, ImageFormat, ObjectFit, RenderImage, StyledImage,
    img,
};
use rish_shell_core::assistant_store::{AssistantAvatar, AssistantProfile};
use std::{
    hash::{Hash, Hasher},
    path::{Component, PathBuf},
    sync::Arc,
};

#[derive(Clone)]
struct AvatarImageKey {
    directory: PathBuf,
    avatar: AssistantAvatar,
}
impl Hash for AvatarImageKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.directory.hash(state);
        self.avatar.id.hash(state);
        self.avatar.sha256.hash(state);
        self.avatar.mime_type.hash(state);
        self.avatar.width.hash(state);
        self.avatar.height.hash(state);
        self.avatar.byte_length.hash(state);
    }
}
struct AvatarImage;
impl Asset for AvatarImage {
    type Source = AvatarImageKey;
    type Output = Result<Arc<RenderImage>, ImageCacheError>;
    fn load(
        source: Self::Source,
        cx: &mut App,
    ) -> impl std::future::Future<Output = Self::Output> + Send + 'static {
        let renderer = cx.svg_renderer();
        async move {
            let bytes = rish_shell_core::assistant_store::read_avatar_bytes(
                &source.directory,
                &source.avatar,
            )
            .map_err(|_| ImageCacheError::Asset("Profile image is unavailable".into()))?;
            Image::from_bytes(ImageFormat::Png, bytes)
                .to_image_data(renderer)
                .map_err(Into::into)
        }
    }
}

#[derive(Clone)]
pub(super) struct AvatarRequest {
    bot_id: String,
    token: String,
    expected_revision: u64,
    baseline: AssistantProfile,
    draft_baseline: AssistantProfile,
    profile: AssistantProfile,
    had_draft: bool,
    previous_error: Option<String>,
}
#[derive(Debug, PartialEq, Eq)]
pub(super) enum AvatarUpdate {
    Ignored,
    Unchanged,
    Save,
    Review,
    Failed,
}

pub(super) fn parse_avatar_reply(value: Value) -> Result<Option<AssistantAvatar>, ()> {
    if value.is_null() {
        return Ok(None);
    }
    let object = value.as_object().ok_or(())?;
    if object.len() != 2
        || object.get("schema_version") != Some(&serde_json::json!(1))
        || !object.contains_key("avatar")
    {
        return Err(());
    }
    let avatar: AssistantAvatar =
        serde_json::from_value(object["avatar"].clone()).map_err(|_| ())?;
    avatar.validate().map_err(|_| ())?;
    Ok(Some(avatar))
}
fn image_key(
    directory: Option<&PathBuf>,
    avatar: Option<&AssistantAvatar>,
) -> Option<AvatarImageKey> {
    let directory = directory?;
    let avatar = avatar?;
    if !directory.is_absolute()
        || directory
            .components()
            .any(|c| !matches!(c, Component::RootDir | Component::Normal(_)))
        || avatar.validate().is_err()
    {
        return None;
    }
    Some(AvatarImageKey {
        directory: directory.clone(),
        avatar: avatar.clone(),
    })
}

fn profile_error(locale: Locale, error: &str, has_draft: bool) -> String {
    if !has_draft
        && (error.starts_with("Assistant state changed")
            || error.starts_with("Assistant storage failed"))
    {
        words::copy(locale, "Local assistant data changed or could not be saved. Check the saved data before retrying.",
            "本机助手数据已变更或尚未保存，请核对保存结果后重试。").into()
    } else if error.starts_with("Assistant state changed") {
        words::copy(
            locale,
            "Your profile changed. Review the saved profile before saving your draft.",
            "资料已变更。请核对已保存的资料，再保存你的草稿。",
        )
        .into()
    } else if error.starts_with("Assistant storage failed") {
        words::copy(locale, "The profile save could not be confirmed. Your draft is kept; check the saved profile before retrying.",
            "尚未确认资料已保存。草稿已保留，请核对保存结果后重试。").into()
    } else {
        words::message(locale, error)
    }
}

impl AssistantUi {
    pub(super) fn visible_profile(&self) -> Option<&AssistantProfile> {
        self.profile_draft
            .as_ref()
            .map(|d| &d.profile)
            .or_else(|| self.snapshot.store.as_ref().map(|s| &s.profile))
    }
    pub(super) fn begin_avatar_request(&mut self) -> Option<AvatarRequest> {
        if self.form_busy() {
            return None;
        }
        let store = self.snapshot.store.as_ref()?;
        let token = uuid::Uuid::new_v4().to_string();
        let request = AvatarRequest {
            bot_id: self.selected_bot_id().to_owned(),
            token: token.clone(),
            expected_revision: store.revision,
            baseline: store.profile.clone(),
            draft_baseline: self
                .profile_draft
                .as_ref()
                .map(|draft| draft.baseline.clone())
                .unwrap_or_else(|| store.profile.clone()),
            profile: self.visible_profile()?.clone(),
            had_draft: self.profile_draft.is_some(),
            previous_error: self.error.clone(),
        };
        self.form_request = Some(token);
        self.error = None;
        Some(request)
    }
    pub(super) fn accept_avatar_result(
        &mut self,
        request: &AvatarRequest,
        result: Result<Value, String>,
        locale: Locale,
    ) -> AvatarUpdate {
        if self.form_request.as_deref() != Some(&request.token)
            || self.selected_bot_id() != request.bot_id
        {
            return AvatarUpdate::Ignored;
        }
        self.form_request = None;
        match result.and_then(|value| {
            parse_avatar_reply(value).map_err(|_| "Invalid avatar response".into())
        }) {
            Ok(None) => {
                if self.error.is_none() {
                    self.error = request.previous_error.clone();
                }
                AvatarUpdate::Unchanged
            }
            Ok(Some(avatar)) => self.stage_avatar(request, Some(avatar), locale),
            Err(_) => {
                self.accept_error(words::copy(
                    locale,
                    "Could not use that photo. Your existing profile was kept.",
                    "无法使用所选照片，现有资料已保留。",
                ));
                AvatarUpdate::Failed
            }
        }
    }
    pub(super) fn stage_avatar(
        &mut self,
        request: &AvatarRequest,
        avatar: Option<AssistantAvatar>,
        locale: Locale,
    ) -> AvatarUpdate {
        if self.selected_bot_id() != request.bot_id {
            return AvatarUpdate::Ignored;
        }
        let mut profile = request.profile.clone();
        profile.avatar = avatar;
        let current = self.snapshot.store.as_ref();
        let can_save =
            !request.had_draft && current.is_some_and(|store| store.profile == request.baseline);
        let revision = current
            .map(|store| store.revision)
            .unwrap_or(request.expected_revision);
        let mut draft = ProfileDraft {
            baseline: request.draft_baseline.clone(),
            profile,
            expected_revision: revision,
            saving: false,
        };
        if let Some(store) = current {
            draft.rebase(&store.profile);
        }
        self.profile_draft = Some(draft);
        if can_save {
            self.error = None;
            AvatarUpdate::Save
        } else {
            self.error=Some(words::copy(locale,
                "Your profile changed or has an unsaved draft. The photo choice is kept; review and save your profile.",
                "资料已变更或存在未保存草稿。已保留头像选择，请核对后保存资料。").into());
            AvatarUpdate::Review
        }
    }
}

pub(super) fn profile_avatar(
    directory: Option<&PathBuf>,
    avatar: Option<&AssistantAvatar>,
    size: f32,
    cx: &App,
) -> AnyElement {
    let Some(key) = image_key(directory, avatar) else {
        return super::visuals::rish_mark(size, cx).into_any_element();
    };
    div()
        .size(px(size))
        .flex_shrink_0()
        .rounded_full()
        .overflow_hidden()
        .child(
            img(move |window: &mut Window, cx: &mut App| window.use_asset::<AvatarImage>(&key, cx))
                .size(px(size))
                .object_fit(ObjectFit::Cover)
                .rounded_full()
                .with_fallback(move || super::visuals::rish_mark_image(size).into_any_element())
                .with_loading(move || super::visuals::rish_mark_image(size).into_any_element()),
        )
        .into_any_element()
}

impl Shell {
    pub(super) fn assistant_identity_mark(&self, size: f32, cx: &App) -> AnyElement {
        profile_avatar(
            self.assistant_storage_directory.as_ref(),
            self.assistant
                .visible_profile()
                .and_then(|p| p.avatar.as_ref()),
            size,
            cx,
        )
    }
    pub(super) fn assistant_avatar_button(
        &self,
        id: &'static str,
        size: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let enabled = self.runtime.is_native()
            && self.assistant.snapshot.store.is_some()
            && !self.assistant.form_busy()
            && !self.native_form_active;
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(words::copy(
                self.locale,
                "Edit assistant profile",
                "编辑助手资料",
            ))
            .size(px(size.max(44.)))
            .flex_shrink_0()
            .flex()
            .items_center()
            .justify_center()
            .rounded_full()
            .when(enabled, |v| v.cursor_pointer())
            .child(self.assistant_identity_mark(size, cx))
            .on_click(cx.listener(move |this, _, window, cx| {
                if enabled {
                    this.open_assistant_profile_menu(window, cx);
                }
                cx.stop_propagation();
            }))
            .into_any_element()
    }
    pub(super) fn open_assistant_profile_menu(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.runtime.is_native()
            || self.assistant.form_busy()
            || self.native_form_active
            || self.assistant.snapshot.store.is_none()
        {
            return;
        }
        self.assistant.profile_previous_focus = window.focused(cx);
        let focus = self
            .assistant
            .profile_menu_focus
            .get_or_insert_with(|| cx.focus_handle())
            .clone();
        self.assistant.profile_menu_open = true;
        window.focus(&focus, cx);
        cx.notify();
    }
    pub(super) fn close_assistant_profile_menu(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.assistant.profile_menu_open = false;
        if let Some(previous) = self.assistant.profile_previous_focus.take() {
            window.focus(&previous, cx);
        } else {
            window.blur(cx);
        }
        cx.notify();
    }
    pub(super) fn assistant_choose_avatar(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.native_form_active {
            return;
        }
        let Some(request) = self.assistant.begin_avatar_request() else {
            return;
        };
        self.set_inline_native_form(true, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(
                    "ShellAssistant",
                    "pickAvatar",
                    serde_json::json!([{"schema_version":1,"userInitiated":true}]),
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                let update = this
                    .assistant
                    .accept_avatar_result(&request, result, this.locale);
                if update == AvatarUpdate::Ignored {
                    return;
                }
                this.set_inline_native_form(false, cx);
                if update == AvatarUpdate::Save {
                    this.assistant_save_profile(cx);
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn assistant_restore_avatar(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || self.native_form_active
            || self
                .assistant
                .visible_profile()
                .is_none_or(|p| p.avatar.is_none())
        {
            return;
        }
        let Some(request) = self.assistant.begin_avatar_request() else {
            return;
        };
        self.assistant.form_request = None;
        if self.assistant.stage_avatar(&request, None, self.locale) == AvatarUpdate::Save {
            self.assistant_save_profile(cx);
        }
        cx.notify();
    }

    pub(super) fn assistant_profile_overlay(
        &self,
        layout: adaptive::Layout,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let width = (layout.content_width + layout.sidebar_width - 32.).clamp(0., 360.);
        let height = (layout.available_height - 32.).max(0.).min(
            if self.assistant.profile_draft.is_some() {
                638.
            } else {
                508.
            },
        );
        let left = layout.insets.left + (layout.content_width + layout.sidebar_width - width) / 2.;
        let top = layout.insets.top + (layout.available_height - height) / 2.;
        let enabled = self.runtime.is_native()
            && self.assistant.snapshot.store.is_some()
            && !self.assistant.form_busy()
            && !self.native_form_active;
        let profile = self.assistant.visible_profile();
        let name = profile.map(|p| p.name.as_str()).unwrap_or("Rish");
        let mut content = div()
            .id("assistant-profile-menu-scroll")
            .debug_selector(|| "assistant-profile-menu-scroll".into())
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll()
            .px_4()
            .pb_4()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                self.assistant_group(cx)
                    .child(self.assistant_setting_row(
                        "assistant-profile-rename",
                        words::copy(self.locale, "Name", "名称"),
                        super::assistant_view::preview(name, 24),
                        Icon::SquarePen,
                        enabled,
                        Action::Field(Field::ProfileName),
                        cx,
                    ))
                    .child(divider(cx))
                    .child(
                        self.assistant_setting_row(
                            "assistant-profile-notes",
                            words::copy(self.locale, "Long-term notes", "长期备注"),
                            profile
                                .map(|p| {
                                    if p.notes.is_empty() {
                                        words::copy(self.locale, "Add", "添加").to_owned()
                                    } else {
                                        super::assistant_view::preview(&p.notes, 18)
                                    }
                                })
                                .unwrap_or_default(),
                            Icon::SquarePen,
                            enabled,
                            Action::Field(Field::ProfileNotes),
                            cx,
                        ),
                    )
                    .child(divider(cx))
                    .child(
                        self.assistant_setting_row(
                            "assistant-profile-soul",
                            words::copy(self.locale, "Soul", "Soul · 性格与原则"),
                            profile
                                .map(|p| super::assistant_view::preview(&p.soul, 18))
                                .unwrap_or_default(),
                            Icon::SquarePen,
                            enabled,
                            Action::Field(Field::ProfileSoul),
                            cx,
                        ),
                    )
                    .child(divider(cx))
                    .child(
                        self.assistant_setting_row(
                            "assistant-profile-memory",
                            words::copy(self.locale, "Memory", "记忆"),
                            self.assistant
                                .snapshot
                                .store
                                .as_ref()
                                .map(|store| {
                                    if self.locale == Locale::Zh {
                                        format!("{} 条", store.memories.len())
                                    } else {
                                        store.memories.len().to_string()
                                    }
                                })
                                .unwrap_or_default(),
                            Icon::MessagesSquare,
                            self.assistant.snapshot.store.is_some()
                                && !self.assistant.form_busy()
                                && !self.native_form_active,
                            Action::Memory(super::assistant_memory_state::MemoryAction::Open),
                            cx,
                        ),
                    )
                    .child(divider(cx))
                    .child(self.assistant_setting_row(
                        "assistant-profile-photo",
                        words::copy(self.locale, "Change photo", "更换头像"),
                        words::copy(self.locale, "Choose photo", "选择照片"),
                        Icon::File,
                        enabled,
                        Action::ChooseAvatar,
                        cx,
                    ))
                    .child(divider(cx))
                    .child(self.assistant_setting_row(
                        "assistant-profile-default",
                        words::copy(self.locale, "Default avatar", "恢复默认头像"),
                        "",
                        Icon::RotateCcw,
                        enabled && profile.is_some_and(|p| p.avatar.is_some()),
                        Action::RestoreAvatar,
                        cx,
                    )),
            );
        if let Some(error) = &self.assistant.error {
            content = content.child(self.assistant_hint(
                "assistant-profile-error",
                profile_error(self.locale, error, self.assistant.profile_draft.is_some()),
                true,
                cx,
            ));
        }
        if self.assistant.profile_draft.is_some() {
            content = content
                .child(self.assistant_primary_button(
                    "assistant-profile-save-draft",
                    words::copy(self.locale, "Save my profile", "保存我的资料"),
                    Icon::Check,
                    enabled,
                    Action::SaveProfile,
                    cx,
                ))
                .child(self.assistant_button(
                    "assistant-profile-discard-draft",
                    words::copy(self.locale, "Discard draft", "放弃草稿"),
                    Icon::RotateCcw,
                    !self.assistant.form_busy(),
                    Action::DiscardProfile,
                    cx,
                ));
        }
        let panel = div()
            .id("assistant-profile-menu")
            .debug_selector(|| "assistant-profile-menu".into())
            .absolute()
            .left(px(left))
            .top(px(top))
            .w(px(width))
            .h(px(height))
            .rounded(px(24.))
            .bg(p.composer)
            .border_1()
            .border_color(p.line)
            .shadow_lg()
            .overflow_hidden()
            .flex()
            .flex_col()
            .occlude()
            .when_some(self.assistant.profile_menu_focus.clone(), |v, focus| {
                v.track_focus(&focus)
            })
            .capture_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    this.close_assistant_profile_menu(window, cx);
                    window.prevent_default();
                }
                cx.stop_propagation();
            }))
            .on_click(|_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .px_4()
                    .py_2()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .child(
                        div()
                            .text_size(px(17.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(words::copy(self.locale, "Edit profile", "编辑资料")),
                    )
                    .child(
                        div()
                            .id("assistant-profile-close")
                            .debug_selector(|| "assistant-profile-close".into())
                            .role(gpui::Role::Button)
                            .aria_label(words::copy(self.locale, "Close", "关闭"))
                            .size(px(44.))
                            .flex_shrink_0()
                            .rounded_full()
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .child(icon(Icon::X, 19., p.muted))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_assistant_profile_menu(window, cx)
                            })),
                    ),
            )
            .child(content);
        div()
            .id("assistant-profile-overlay")
            .absolute()
            .inset_0()
            .size_full()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .id("assistant-profile-scrim")
                    .debug_selector(|| "assistant-profile-scrim".into())
                    .absolute()
                    .inset_0()
                    .size_full()
                    .bg(gpui::black().opacity(0.22))
                    .occlude()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.close_assistant_profile_menu(window, cx);
                        cx.stop_propagation();
                    })),
            )
            .child(panel)
            .into_any_element()
    }
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "assistant_avatar_tests.rs"]
mod tests;
