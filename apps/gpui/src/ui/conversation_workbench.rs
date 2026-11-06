//! Conversation tools live in a compact trailing sidebar; narrow windows keep
//! their chat mounted and present the same tools in a modal bottom sheet.
use super::{Page, Shell, adaptive::Layout, i18n::Text, theme::Palette, visuals};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, Context, FontWeight, IntoElement, div, prelude::*, px};

impl Shell {
    pub(super) fn workspace_selector(
        &self,
        selector: &'static str,
        width: f32,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id(selector)
            .debug_selector(move || selector.into())
            .role(gpui::Role::Button)
            .aria_label(self.locale.text(Text::ConversationWorkspace))
            .aria_expanded(self.conversation_workspace.selector)
            .w(px(width))
            .max_w_full()
            .min_w(px(0.))
            .min_h(px(44.))
            .px_3()
            .rounded(px(12.))
            .bg(p.surface)
            .when(self.conversation_workspace.selector, |s| s.bg(p.raised))
            .flex()
            .items_center()
            .gap_2()
            .cursor_pointer()
            .hover(|s| s.bg(p.raised))
            .child(icon(Icon::Folder, 17., p.muted))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .text_size(px(13.))
                    .font_weight(FontWeight::MEDIUM)
                    .child(self.conversation_workspace_name()),
            )
            .child(icon(Icon::ChevronDown, 14., p.muted).when(
                self.conversation_workspace.selector,
                |glyph| {
                    glyph.with_transformation(gpui::Transformation::rotate(gpui::radians(
                        std::f32::consts::PI,
                    )))
                },
            ))
            .on_click(cx.listener(|this, _, _, cx| this.choose_conversation_workspace(cx)))
    }

    pub(super) fn workspace_toggle_button(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let open = matches!(self.page, Page::Files | Page::Git);
        visuals::round_button(cx)
            .id("workspace-toggle")
            .debug_selector(|| "workspace-toggle".into())
            .role(gpui::Role::Button)
            .aria_label(self.locale.text(Text::WorkspacePanelTitle))
            .aria_expanded(open)
            .when(open, |s| s.bg(p.raised))
            .cursor_pointer()
            .hover(|s| s.bg(p.surface))
            .child(icon(
                Icon::PanelRight,
                20.,
                if open { p.text } else { p.muted },
            ))
            .on_click(cx.listener(|this, _, window, cx| {
                if matches!(this.page, Page::Files | Page::Git) {
                    this.close_workspace_panel(window, cx);
                } else {
                    this.open_conversation_workspace(Page::Files, cx);
                }
            }))
    }

    pub(super) fn conversation_tool_tab(
        &self,
        page: Page,
        id: &'static str,
        label: Text,
        glyph: Icon,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected = self.page == page;
        let color = if selected { p.text } else { p.muted };
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Tab)
            .aria_label(self.locale.text(label))
            .aria_selected(selected)
            .flex_1()
            .min_h(px(44.))
            .min_w(px(76.))
            .px_3()
            .rounded(px(10.))
            .flex()
            .items_center()
            .justify_center()
            .gap_2()
            .text_size(px(13.))
            .text_color(color)
            .when(selected, |s| {
                s.bg(p.composer).font_weight(FontWeight::MEDIUM)
            })
            .cursor_pointer()
            .hover(|s| s.bg(p.raised))
            .child(icon(glyph, 16., color))
            .child(self.locale.text(label))
            .on_click(cx.listener(move |this, _, _, cx| this.open_conversation_workspace(page, cx)))
    }

    pub(super) fn conversation_workbench(
        &self,
        layout: Layout,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tools_open = matches!(self.page, Page::Files | Page::Git);
        let panel_height =
            (layout.available_height - 56. - if self.runtime.is_native() { 0. } else { 32. })
                .max(0.);
        if !tools_open || layout.content_width < 840. {
            return self
                .chat(
                    layout.compact_content,
                    layout.content_width,
                    panel_height,
                    cx,
                )
                .into_any_element();
        }
        if self.workspace_focus {
            return self
                .workspace_panel_content(layout.content_width, panel_height, true, false, cx)
                .into_any_element();
        }
        let p = Palette::get(cx);
        let sidebar_width = if layout.content_width >= 1120. {
            380.
        } else {
            340.
        };
        let chat_width = layout.content_width - sidebar_width;
        div()
            .id("conversation-workbench")
            .debug_selector(|| "conversation-workbench".into())
            .flex_1()
            .min_h(px(0.))
            .w_full()
            .flex()
            .overflow_hidden()
            .child(
                div()
                    .id("workbench-chat-pane")
                    .debug_selector(|| "workbench-chat-pane".into())
                    .flex_1()
                    .min_w(px(0.))
                    .h_full()
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .child(self.chat(
                        chat_width < 380. || layout.available_height < 500.,
                        chat_width,
                        panel_height,
                        cx,
                    )),
            )
            .child(
                div()
                    .id("workbench-tools-pane")
                    .debug_selector(|| "workbench-tools-pane".into())
                    .w(px(sidebar_width))
                    .h_full()
                    .flex_shrink_0()
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .border_l_1()
                    .border_color(p.line)
                    .bg(p.composer)
                    .child(self.workspace_panel_content(
                        sidebar_width - 1.,
                        panel_height,
                        true,
                        false,
                        cx,
                    )),
            )
            .into_any_element()
    }
}
