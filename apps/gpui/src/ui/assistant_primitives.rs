use super::{assistant_view::Action, *};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, Div, FontWeight};

#[derive(Clone, Copy, PartialEq)]
enum ButtonStyle {
    Primary,
    Secondary,
    Quiet,
}

pub(super) fn divider(cx: &App) -> Div {
    div()
        .mx_4()
        .h(px(1.))
        .flex_shrink_0()
        .bg(Palette::get(cx).line)
}

impl Shell {
    pub(super) fn assistant_group(&self, cx: &App) -> Div {
        let p = Palette::get(cx);
        div()
            .w_full()
            .min_w(px(0.))
            .flex_shrink_0()
            .rounded(px(22.))
            .border_1()
            .border_color(p.line)
            .bg(p.composer)
            .overflow_hidden()
            .flex()
            .flex_col()
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn assistant_setting_row(
        &self,
        id: impl Into<String>,
        label: impl Into<String>,
        value: impl Into<String>,
        glyph: Icon,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let id = id.into();
        let selector = id.clone();
        let label = label.into();
        let value = value.into();
        div()
            .id(id)
            .debug_selector(move || selector.clone())
            .role(gpui::Role::Button)
            .aria_label(format!("{label}: {value}"))
            .w_full()
            .min_h(px(56.))
            .min_w(px(0.))
            .flex_shrink_0()
            .px_4()
            .py_2()
            .flex()
            .items_center()
            .gap_3()
            .when(enabled, |row| {
                row.cursor_pointer().hover(|row| row.bg(p.surface))
            })
            .child(icon(glyph, 19., if enabled { p.text } else { p.muted }))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .text_size(px(14.))
                    .line_height(px(20.))
                    .whitespace_normal()
                    .text_color(p.text)
                    .child(label),
            )
            .when(!value.is_empty(), |row| {
                row.child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .text_size(px(13.))
                        .line_height(px(19.))
                        .text_right()
                        .whitespace_normal()
                        .text_color(p.muted)
                        .child(value),
                )
            })
            .child(icon(Icon::ChevronRight, 14., p.faint))
            .on_click(cx.listener(move |this, _, window, cx| {
                if enabled {
                    if matches!(
                        action,
                        Action::Memory(super::assistant_memory_state::MemoryAction::Open)
                    ) && this.assistant.profile_menu_open
                    {
                        this.close_assistant_profile_menu(window, cx);
                    }
                    this.assistant_action(action.clone(), cx);
                }
            }))
            .into_any_element()
    }

    pub(super) fn assistant_icon_button(
        &self,
        id: impl Into<String>,
        label: impl Into<String>,
        glyph: Icon,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let id = id.into();
        let selector = id.clone();
        div()
            .id(id)
            .debug_selector(move || selector.clone())
            .role(gpui::Role::Button)
            .aria_label(label.into())
            .size(px(44.))
            .flex_shrink_0()
            .rounded_full()
            .bg(p.composer)
            .flex()
            .items_center()
            .justify_center()
            .when(enabled, |v| v.cursor_pointer().hover(|v| v.bg(p.surface)))
            .child(icon(glyph, 20., if enabled { p.text } else { p.faint }))
            .on_click(cx.listener(move |this, _, _, cx| {
                if enabled {
                    this.assistant_action(action.clone(), cx);
                }
            }))
            .into_any_element()
    }

    pub(super) fn assistant_primary_button(
        &self,
        id: impl Into<String>,
        label: impl Into<String>,
        glyph: Icon,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.assistant_action_button(id, label, glyph, enabled, ButtonStyle::Primary, action, cx)
    }
    pub(super) fn assistant_button(
        &self,
        id: impl Into<String>,
        label: impl Into<String>,
        glyph: Icon,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.assistant_action_button(id, label, glyph, enabled, ButtonStyle::Quiet, action, cx)
    }
    pub(super) fn assistant_secondary_button(
        &self,
        id: impl Into<String>,
        label: impl Into<String>,
        glyph: Icon,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.assistant_action_button(
            id,
            label,
            glyph,
            enabled,
            ButtonStyle::Secondary,
            action,
            cx,
        )
    }
    #[allow(clippy::too_many_arguments)]
    fn assistant_action_button(
        &self,
        id: impl Into<String>,
        label: impl Into<String>,
        glyph: Icon,
        enabled: bool,
        style: ButtonStyle,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let id = id.into();
        let selector = id.clone();
        let label = label.into();
        let primary = style == ButtonStyle::Primary;
        let foreground = if !enabled {
            p.faint
        } else if primary {
            p.on_accent
        } else {
            p.text
        };
        div()
            .id(id)
            .debug_selector(move || selector.clone())
            .role(gpui::Role::Button)
            .aria_label(label.clone())
            .min_h(px(48.))
            .min_w(px(44.))
            .flex_shrink_0()
            .px_4()
            .py_2()
            .rounded(px(16.))
            .bg(if primary && enabled {
                p.accent
            } else if style == ButtonStyle::Secondary {
                p.composer
            } else {
                p.surface
            })
            .when(style == ButtonStyle::Secondary, |v| {
                v.border_1().border_color(p.line)
            })
            .flex()
            .items_center()
            .justify_center()
            .gap_2()
            .text_size(px(14.))
            .line_height(px(20.))
            .font_weight(FontWeight::MEDIUM)
            .text_color(foreground)
            .when(enabled, |v| v.cursor_pointer().hover(|v| v.opacity(0.84)))
            .child(icon(glyph, 18., foreground))
            .child(div().min_w(px(0.)).whitespace_normal().child(label))
            .on_click(cx.listener(move |this, _, _, cx| {
                if enabled {
                    this.assistant_action(action.clone(), cx);
                }
            }))
            .into_any_element()
    }
}
