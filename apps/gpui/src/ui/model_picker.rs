use super::adaptive::Layout;
use super::*;
use crate::icons::{Icon, icon};

#[derive(Clone, Debug, PartialEq)]
pub(super) struct ConfigurationDraft {
    pub model: String,
    pub thinking: String,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(super) enum ConfigurationPage {
    #[default]
    Configure,
    Models,
    Providers,
    Thinking,
}

/// The shell already deducted the safe areas. Use that budget exactly once.
#[derive(Clone, Copy, Debug)]
pub(super) struct PickerBounds {
    pub left: f32,
    pub top: f32,
    pub width: f32,
    pub height: f32,
    pub header_height: f32,
    pub bottom_padding: f32,
    pub floating: bool,
}

fn picker_bounds(layout: Layout, page: ConfigurationPage, has_error: bool) -> PickerBounds {
    let available_width = layout.content_width + layout.sidebar_width;
    let floating = available_width >= 700. && layout.available_height >= 520.;
    let horizontal_margin = (if floating { 24_f32 } else { 10_f32 }).min(available_width / 2.);
    // The floating card reaches the physical bottom edge. Its internal padding
    // keeps Done and the last option above the home indicator.
    let available_height =
        layout.available_height + if floating { 0. } else { layout.insets.bottom };
    let vertical_margin = (if floating { 24_f32 } else { 10_f32 }).min(available_height / 2.);
    let bottom_padding = if floating {
        24.
    } else {
        (layout.insets.bottom - vertical_margin).max(32.)
    };
    let width = (available_width - horizontal_margin * 2.).min(440.);
    let preferred_height = match page {
        ConfigurationPage::Configure => 260. + bottom_padding + if has_error { 100. } else { 0. },
        ConfigurationPage::Models | ConfigurationPage::Providers => 568.,
        ConfigurationPage::Thinking => 270.,
    };
    let height = (available_height - vertical_margin * 2.)
        .max(0.)
        .min(preferred_height);
    PickerBounds {
        left: layout.insets.left + (available_width - width) / 2.,
        top: layout.insets.top
            + if floating {
                (available_height - height) / 2.
            } else {
                available_height - height - vertical_margin
            },
        width,
        height,
        header_height: 72_f32.min(height),
        bottom_padding,
        floating,
    }
}

pub(super) fn thinking_label(mode: &str) -> Text {
    match mode {
        "off" => Text::Off,
        "max" => Text::Max,
        _ => Text::High,
    }
}

impl Shell {
    pub(super) fn model_display_label(&self, id: &str) -> String {
        let (name, unavailable) = self.model_display_parts(id);
        match unavailable {
            Some(status) => format!("{name} · {status}"),
            None => name,
        }
    }

    pub(super) fn model_display_parts(&self, id: &str) -> (String, Option<&'static str>) {
        if id.is_empty() {
            return (
                assistant_copy::copy(self.locale, "Choose a model", "选择模型").into(),
                None,
            );
        }
        if let Some(model) = self.state.models().into_iter().find(|model| model.id == id) {
            return (model.name, None);
        }
        let name = self.state.stored_model_display_name(id).unwrap_or_else(|| {
            if id.starts_with("custom:") {
                assistant_copy::copy(self.locale, "Custom model", "自定义模型")
            } else {
                id
            }
        });
        (
            name.into(),
            Some(assistant_copy::copy(self.locale, "Unavailable", "不可用")),
        )
    }
    pub(super) fn open_model_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.model_picker {
            return;
        }
        self.close_drawer(true, window, cx);
        self.model_picker_previous_focus = window.focused(cx);
        self.config_draft = Some(ConfigurationDraft {
            error: None,
            model: if self.assistant_group_visible() {
                self.assistant_group_model()
            } else {
                self.state.selected_model().to_owned()
            },
            thinking: if self.assistant_group_visible() {
                "high".into()
            } else {
                self.state.selected_thinking().to_owned()
            },
        });
        self.config_page = if self.state.models().is_empty() {
            ConfigurationPage::Models
        } else {
            ConfigurationPage::Configure
        };
        self.model_picker_scroll
            .set_offset(gpui::point(px(0.), px(0.)));
        self.model_picker = true;
        window.focus(&self.model_picker_focus, cx);
        cx.notify();
    }

    pub(super) fn close_model_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.model_picker {
            return;
        }
        self.model_picker = false;
        self.model_picker_focus_pending = false;
        self.config_draft = None;
        self.config_page = ConfigurationPage::Configure;
        if let Some(previous) = self.model_picker_previous_focus.take() {
            window.focus(&previous, cx);
        } else {
            window.blur(cx);
        }
        cx.notify();
    }

    pub(super) fn show_configuration_page(
        &mut self,
        page: ConfigurationPage,
        cx: &mut Context<Self>,
    ) {
        self.config_page = page;
        self.model_picker_scroll
            .set_offset(gpui::point(px(0.), px(0.)));
        cx.notify();
    }

    pub(super) fn choose_model(&mut self, id: &str, _: &mut Window, cx: &mut Context<Self>) {
        let Some(draft) = self.config_draft.as_ref() else {
            return;
        };
        if id != draft.model {
            if self.loading
                || self.state.is_busy()
                || self.provider_models.request_pending()
                || self.custom_providers.request_pending()
                || !self.state.models().iter().any(|m| m.id == id)
            {
                return;
            }
            self.config_draft.as_mut().unwrap().model = id.to_owned();
        }
        self.config_draft.as_mut().unwrap().error = None;
        self.show_configuration_page(ConfigurationPage::Configure, cx);
    }

    pub(super) fn choose_thinking(&mut self, mode: &str, _: &mut Window, cx: &mut Context<Self>) {
        let Some(draft) = self.config_draft.as_ref() else {
            return;
        };
        if !["off", "high", "max"].contains(&mode) {
            return;
        }
        if mode != draft.thinking {
            if self.loading
                || self.state.is_busy()
                || self.provider_models.request_pending()
                || self.custom_providers.request_pending()
            {
                return;
            }
            self.config_draft.as_mut().unwrap().thinking = mode.to_owned();
        }
        self.config_draft.as_mut().unwrap().error = None;
        self.show_configuration_page(ConfigurationPage::Configure, cx);
    }

    fn configuration_changed(&self) -> bool {
        self.config_draft.as_ref().is_some_and(|draft| {
            draft.model != self.state.selected_model()
                || draft.thinking != self.state.selected_thinking()
        })
    }

    pub(super) fn finish_configuration(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.model_picker {
            return;
        }
        if self.assistant_group_visible() {
            if self.assistant_group_busy()
                || self.provider_models.request_pending()
                || self.custom_providers.request_pending()
            {
                return;
            }
            if let (Some(id), Some(draft)) = (
                self.assistant.directory_ui.group_id.clone(),
                self.config_draft.clone(),
            ) {
                self.assistant.directory_ui.models.insert(id, draft.model);
                self.close_model_picker(window, cx);
            }
            return;
        }
        if !self.configuration_changed() {
            self.close_model_picker(window, cx);
            return;
        }
        // Desktop/headless may inspect a draft, but only the native runtime writes it.
        if !self.runtime.is_native()
            || self.loading
            || self.state.is_busy()
            || self.aux_busy
            || self.provider_models.request_pending()
            || self.custom_providers.request_pending()
        {
            return;
        }
        if self.state.active_conversation_id().is_none() && self.state.default_workspace().is_none()
        {
            self.notice = Some(self.locale.text(Text::WorkspacePreparing).into());
            self.ensure_conversation_workspace(None, cx);
            cx.notify();
            return;
        }
        let Some(draft) = self.config_draft.clone() else {
            return;
        };
        if self.state.active_conversation_id().is_none() && self.composer_drafts.rejected_text {
            let message = assistant_copy::copy(
                self.locale,
                "This draft is too large. Shorten or copy it before creating a conversation.",
                "当前草稿过长，请先缩短或复制，再创建会话。",
            );
            if let Some(draft) = &mut self.config_draft {
                draft.error = Some(message.into());
            }
            cx.notify();
            return;
        }
        let command = self.prepare_configuration_commit(&draft);
        self.complete_configuration_preparation(command, window, cx);
    }

    pub(super) fn prepare_configuration_commit(
        &mut self,
        draft: &ConfigurationDraft,
    ) -> Result<RuntimeCommand, String> {
        if self.state.active_conversation_id().is_none() {
            self.state.create_conversation_from_draft(
                &uuid::Uuid::new_v4().to_string(),
                &now(),
                &draft.model,
                &draft.thinking,
            )
        } else {
            self.state
                .set_chat_configuration(&draft.model, &draft.thinking)
        }
    }

    // Shared-core validation can reject a draft after its provider catalog
    // changes. Keep the editor and focus until preparation actually succeeds.
    pub(super) fn complete_configuration_preparation(
        &mut self,
        command: Result<RuntimeCommand, String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match command {
            Ok(command) => {
                self.close_model_picker(window, cx);
                self.commit(Ok(command), cx);
            }
            Err(error) => {
                if let Some(draft) = &mut self.config_draft {
                    draft.error = Some(if error == "Choose a current model" {
                        assistant_copy::copy(self.locale,
                            "This model is no longer available. Choose another model. Your changes are kept.",
                            "该模型已不可用，请重新选择。你的设置草稿已保留。").into()
                    } else {
                        format!(
                            "{} {error}",
                            assistant_copy::copy(
                                self.locale,
                                "Could not apply settings. Your changes are kept.",
                                "暂时无法应用设置，你的设置草稿已保留。"
                            )
                        )
                    });
                }
                cx.notify();
            }
        }
    }

    fn configuration_row(
        &self,
        selector: &'static str,
        label: Text,
        value: String,
        page: ConfigurationPage,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        div()
            .id(selector)
            .debug_selector(move || selector.into())
            .role(gpui::Role::Button)
            .aria_label(format!("{}: {}", self.locale.text(label), value))
            .h(px(54.))
            .min_h(px(54.))
            .flex_shrink_0()
            .px_4()
            .flex()
            .items_center()
            .gap_3()
            .text_size(px(15.))
            .cursor_pointer()
            .hover(|s| s.bg(p.raised))
            .child(div().flex_shrink_0().child(self.locale.text(label)))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_right()
                    .text_color(p.muted)
                    .child(value),
            )
            .child(icon(Icon::ChevronRight, 17., p.muted))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.show_configuration_page(page, cx);
                cx.stop_propagation();
            }))
    }

    fn configuration_form(&self, bounds: PickerBounds, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let model_id = self
            .config_draft
            .as_ref()
            .map(|draft| draft.model.as_str())
            .unwrap_or_else(|| self.state.selected_model());
        let model_name = self.model_display_label(model_id);
        let thinking = self
            .config_draft
            .as_ref()
            .map(|draft| draft.thinking.as_str())
            .unwrap_or_else(|| self.state.selected_thinking());
        let enabled = !self.configuration_changed()
            || (self.runtime.is_native()
                && !self.loading
                && !self.state.is_busy()
                && !self.aux_busy
                && !self.provider_models.request_pending()
                && !self.custom_providers.request_pending()
                && (self.state.active_conversation_id().is_some()
                    || self.state.default_workspace().is_some()));
        let body_height = (bounds.height - bounds.header_height).max(0.);
        let footer_height = (80. + bounds.bottom_padding).min(body_height);
        div()
            .flex_1()
            .min_h(px(0.))
            .flex()
            .flex_col()
            .child(
                div()
                    .id("config-fields")
                    .debug_selector(|| "config-fields".into())
                    .h(px((body_height - footer_height).max(0.)))
                    .min_h(px(0.))
                    .overflow_y_scroll()
                    .px_6()
                    .when_some(
                        self.config_draft
                            .as_ref()
                            .and_then(|draft| draft.error.clone()),
                        |fields, error| {
                            fields.child(
                                div()
                                    .id("config-error")
                                    .debug_selector(|| "config-error".into())
                                    .py_3()
                                    .text_size(px(13.))
                                    .line_height(px(20.))
                                    .text_color(p.danger)
                                    .whitespace_normal()
                                    .child(error),
                            )
                        },
                    )
                    .child(
                        div()
                            .relative()
                            .rounded(px(18.))
                            .bg(p.surface)
                            .overflow_hidden()
                            .child(self.configuration_row(
                                "config-model-row",
                                Text::Model,
                                model_name,
                                ConfigurationPage::Models,
                                cx,
                            ))
                            .when(!self.assistant_group_visible(), |v| {
                                v.child(self.configuration_row(
                                    "config-thinking-row",
                                    Text::ThinkingIntensity,
                                    self.locale.text(thinking_label(thinking)).to_owned(),
                                    ConfigurationPage::Thinking,
                                    cx,
                                ))
                                .child(
                                    div()
                                        .absolute()
                                        .top(px(54.))
                                        .left(px(16.))
                                        .right(px(16.))
                                        .h(px(1.))
                                        .bg(p.line),
                                )
                            }),
                    ),
            )
            .child(
                div()
                    .h(px(footer_height))
                    .flex_shrink_0()
                    .px_6()
                    .pt(px(28_f32.min((footer_height - 52.).max(0.))))
                    .child(
                        div()
                            .id("config-done")
                            .debug_selector(|| "config-done".into())
                            .role(gpui::Role::Button)
                            .aria_label(self.locale.text(Text::Done))
                            .when(!enabled && !self.runtime.is_native(), |v| {
                                v.aria_description(self.locale.text(Text::MobileOnly))
                            })
                            .h(px(52_f32.min(footer_height)))
                            .w_full()
                            .rounded(px(14.))
                            .bg(p.accent)
                            .text_color(p.on_accent)
                            .text_size(px(16.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .flex()
                            .items_center()
                            .justify_center()
                            .when(enabled, |v| v.cursor_pointer().hover(|s| s.opacity(0.9)))
                            .when(!enabled, |v| v.opacity(0.45))
                            .child(self.locale.text(Text::Done))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.finish_configuration(window, cx);
                                cx.stop_propagation();
                            })),
                    ),
            )
    }

    fn configuration_header(
        &self,
        bounds: PickerBounds,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let is_main = self.config_page == ConfigurationPage::Configure;
        let title = match self.config_page {
            ConfigurationPage::Configure => self.locale.text(Text::Configure),
            ConfigurationPage::Models => self.locale.text(Text::Models),
            ConfigurationPage::Providers => {
                assistant_copy::copy(self.locale, "Add / custom model", "添加 / 自定义模型")
            }
            ConfigurationPage::Thinking => self.locale.text(Text::ThinkingIntensity),
        };
        div()
            .id("model-picker-header")
            .debug_selector(|| "model-picker-header".into())
            .h(px(bounds.header_height))
            .flex_shrink_0()
            .child(
                div()
                    .id("config-header")
                    .debug_selector(|| "config-header".into())
                    .size_full()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .h(px(20.))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .justify_center()
                            .when(!bounds.floating, |handle| {
                                handle.child(div().w(px(32.)).h(px(4.)).rounded_full().bg(p.line))
                            }),
                    )
                    .child(
                        div()
                            .relative()
                            .h(px(44.))
                            .w_full()
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_size(px(18.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(title)
                            .when(!is_main, |header| {
                                header
                                    .child(
                                        div()
                                            .id("model-picker-back")
                                            .debug_selector(|| "model-picker-back".into())
                                            .role(gpui::Role::Button)
                                            .aria_label(self.locale.text(Text::Back))
                                            .absolute()
                                            .left(px(12.))
                                            .top_0()
                                            .size(px(44.))
                                            .rounded_full()
                                            .flex()
                                            .items_center()
                                            .justify_center()
                                            .cursor_pointer()
                                            .hover(|s| s.bg(p.surface))
                                            .child(icon(Icon::ChevronLeft, 20., p.text))
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                let page = if this.config_page
                                                    == ConfigurationPage::Providers
                                                {
                                                    ConfigurationPage::Models
                                                } else {
                                                    ConfigurationPage::Configure
                                                };
                                                this.show_configuration_page(page, cx);
                                                cx.stop_propagation();
                                            })),
                                    )
                                    .child(
                                        div()
                                            .id("model-picker-close")
                                            .debug_selector(|| "model-picker-close".into())
                                            .role(gpui::Role::Button)
                                            .aria_label(self.locale.text(Text::CloseModels))
                                            .absolute()
                                            .right(px(12.))
                                            .top_0()
                                            .size(px(44.))
                                            .rounded_full()
                                            .flex()
                                            .items_center()
                                            .justify_center()
                                            .cursor_pointer()
                                            .hover(|s| s.bg(p.surface))
                                            .child(icon(Icon::X, 20., p.muted))
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.close_model_picker(window, cx);
                                                cx.stop_propagation();
                                            })),
                                    )
                            }),
                    ),
            )
    }

    pub(super) fn model_picker_overlay(
        &self,
        layout: Layout,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let bounds = picker_bounds(
            layout,
            self.config_page,
            self.config_draft
                .as_ref()
                .is_some_and(|draft| draft.error.is_some()),
        );
        div()
            .id("model-picker-overlay")
            .absolute()
            .top_0()
            .left_0()
            .size_full()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .id("model-picker-scrim")
                    .debug_selector(|| "model-picker-scrim".into())
                    .absolute()
                    .top_0()
                    .left_0()
                    .size_full()
                    .bg(gpui::black().opacity(if bounds.floating { 0.20 } else { 0.24 }))
                    .occlude()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.close_model_picker(window, cx);
                        cx.stop_propagation();
                    })),
            )
            .child(
                div()
                    .id("model-picker-panel")
                    .debug_selector(|| "model-picker-panel".into())
                    .absolute()
                    .left(px(bounds.left))
                    .top(px(bounds.top))
                    .w(px(bounds.width))
                    .h(px(bounds.height))
                    .child(
                        div()
                            .id("config-panel")
                            .debug_selector(|| "config-panel".into())
                            .role(gpui::Role::Dialog)
                            .aria_label(self.locale.text(Text::Configure))
                            .size_full()
                            .rounded(px(28.))
                            .border_1()
                            .border_color(p.line)
                            .bg(p.composer)
                            .shadow_lg()
                            .overflow_hidden()
                            .flex()
                            .flex_col()
                            .occlude()
                            .track_focus(&self.model_picker_focus)
                            .capture_key_down(cx.listener(
                                |this, event: &gpui::KeyDownEvent, window, cx| {
                                    if event.keystroke.key == "escape" {
                                        this.close_model_picker(window, cx);
                                        window.prevent_default();
                                    }
                                    cx.stop_propagation();
                                },
                            ))
                            .on_click(|_, _, cx| cx.stop_propagation())
                            .child(self.configuration_header(bounds, cx))
                            .child(match self.config_page {
                                ConfigurationPage::Configure => {
                                    self.configuration_form(bounds, cx).into_any_element()
                                }
                                ConfigurationPage::Models => {
                                    self.model_options(bounds, cx).into_any_element()
                                }
                                ConfigurationPage::Providers => {
                                    self.model_setup_options(bounds, cx).into_any_element()
                                }
                                ConfigurationPage::Thinking => {
                                    self.thinking_options(bounds, cx).into_any_element()
                                }
                            }),
                    ),
            )
    }
}
