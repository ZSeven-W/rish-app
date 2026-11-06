use super::{Page, Shell, adaptive::Layout, i18n::Text, theme::Palette};
use crate::icons::{Icon, icon};
use gpui::{Context, Div, FontWeight, IntoElement, Window, div, prelude::*, px};

impl Shell {
    pub(super) fn sync_workspace_panel_focus(
        &mut self,
        is_modal: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if is_modal && !self.workspace_panel_modal {
            self.workspace_panel_previous_focus = window.focused(cx);
            self.workspace_panel_modal = true;
            window.focus(&self.workspace_panel_focus, cx);
        } else if !is_modal && self.workspace_panel_modal {
            self.workspace_panel_modal = false;
            if let Some(previous) = self.workspace_panel_previous_focus.take() {
                window.focus(&previous, cx);
            } else {
                window.blur(cx);
            }
        }
    }

    pub(super) fn close_workspace_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.cancel_conversation_workspace_selection(cx);
        self.page = self
            .state
            .active_conversation_id()
            .map(|id| self.page_for_conversation(id))
            .unwrap_or(Page::Chat);
        self.workspace_focus = false;
        self.sync_workspace_panel_focus(false, window, cx);
        cx.notify();
    }

    pub(super) fn workspace_panel_content(
        &self,
        width: f32,
        available_height: f32,
        can_expand: bool,
        modal: bool,
        cx: &mut Context<Self>,
    ) -> Div {
        let p = Palette::get(cx);
        // Notice text can scroll inside its bounded card. Budget its maximum
        // height so a short inspector never claims more vertical space than exists.
        let chrome_height = if modal { 176. } else { 88. };
        let notice_height = if self.notice.is_some() { 124. } else { 0. };
        let body_height = (available_height - chrome_height - notice_height).max(0.);
        div()
            .flex_1()
            .min_h(px(0.))
            .w_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .child(
                div()
                    .id("workspace-panel-header")
                    .debug_selector(|| "workspace-panel-header".into())
                    .h(px(if modal { 56. } else { 44. }))
                    .flex_shrink_0()
                    .px(px(if modal { 12. } else { 8. }))
                    .flex()
                    .items_center()
                    .gap(px(if modal { 8. } else { 4. }))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .pl_2()
                            .text_size(px(if modal { 16. } else { 14. }))
                            .font_weight(FontWeight::SEMIBOLD)
                            .truncate()
                            .child(if !modal && self.workspace_focus {
                                self.conversation_workspace_name()
                            } else {
                                self.locale.text(Text::WorkspacePanelTitle).to_owned()
                            }),
                    )
                    .child(
                        div()
                            .id("refresh-workspaces")
                            .debug_selector(|| "refresh-workspaces".into())
                            .role(gpui::Role::Button)
                            .aria_label(self.locale.text(Text::Refresh))
                            .size(px(44.))
                            .rounded(px(12.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .when(!self.aux_busy, |s| {
                                s.cursor_pointer().hover(|s| s.bg(p.surface))
                            })
                            .when(self.aux_busy, |s| s.opacity(0.45))
                            .child(icon(Icon::RefreshCw, 17., p.muted))
                            .on_click(cx.listener(|this, _, _, cx| this.refresh_workspace(cx))),
                    )
                    .when(can_expand, |header| {
                        header.child(
                            div()
                                .id("workbench-focus")
                                .debug_selector(|| "workbench-focus".into())
                                .role(gpui::Role::Button)
                                .aria_label(self.locale.text(if self.workspace_focus {
                                    Text::WorkbenchCollapse
                                } else {
                                    Text::WorkbenchExpand
                                }))
                                .size(px(44.))
                                .rounded(px(12.))
                                .flex()
                                .items_center()
                                .justify_center()
                                .cursor_pointer()
                                .hover(|s| s.bg(p.surface))
                                .child(icon(
                                    if self.workspace_focus {
                                        Icon::PanelLeft
                                    } else {
                                        Icon::Monitor
                                    },
                                    18.,
                                    p.muted,
                                ))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.workspace_focus = !this.workspace_focus;
                                    cx.notify();
                                })),
                        )
                    })
                    .child(
                        div()
                            .id("workspace-panel-close")
                            .debug_selector(|| "workspace-panel-close".into())
                            .role(gpui::Role::Button)
                            .aria_label(self.locale.text(Text::CloseMenu))
                            .aria_keyshortcuts("Escape")
                            .size(px(44.))
                            .rounded(px(12.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .hover(|s| s.bg(p.surface))
                            .child(icon(Icon::X, 18., p.muted))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_workspace_panel(window, cx)
                            })),
                    ),
            )
            .when(modal, |panel| {
                panel.child(
                    div()
                        .px_4()
                        .pb_3()
                        .flex_shrink_0()
                        .child(self.workspace_selector(
                            "workspace-panel-workspace",
                            (width - 32.).max(0.),
                            p,
                            cx,
                        )),
                )
            })
            .child(
                div()
                    .id("workspace-panel-tabs")
                    .debug_selector(|| "workspace-panel-tabs".into())
                    .relative()
                    .px(px(if modal { 16. } else { 8. }))
                    .when(modal, |tabs| tabs.pb_3())
                    .when(!modal, |tabs| tabs.h(px(44.)))
                    .flex_shrink_0()
                    .child(
                        div()
                            .when(modal, |tabs| tabs.p_1())
                            .rounded(px(if modal { 14. } else { 10. }))
                            .bg(p.surface)
                            .flex()
                            .gap_1()
                            .child(self.conversation_tool_tab(
                                Page::Files,
                                "conversation-files",
                                Text::Files,
                                Icon::Folder,
                                p,
                                cx,
                            ))
                            .child(self.conversation_tool_tab(
                                Page::Git,
                                "conversation-git",
                                Text::Git,
                                Icon::GitBranch,
                                p,
                                cx,
                            )),
                    )
                    .child(
                        div()
                            .absolute()
                            .bottom_0()
                            .left_0()
                            .right_0()
                            .h(px(1.))
                            .bg(p.line),
                    ),
            )
            .when_some(self.notice.as_ref(), |panel, notice| {
                panel.child(self.workspace_panel_notice(notice, p, cx))
            })
            .child(
                div()
                    .id("workspace-panel-body")
                    .debug_selector(|| "workspace-panel-body".into())
                    .flex_1()
                    .min_h(px(0.))
                    .w_full()
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .when(modal, |body| body.bg(p.background))
                    .child(if !modal && !self.workspace_focus {
                        self.workspace_inspector(width, body_height, cx)
                            .into_any_element()
                    } else {
                        self.workspace_screen(width, cx).into_any_element()
                    }),
            )
    }

    fn workspace_panel_notice(
        &self,
        notice: &str,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id("workspace-panel-notice")
            .debug_selector(|| "workspace-panel-notice".into())
            .mx_4()
            .mt_3()
            .px_3()
            .py_2()
            .max_h(px(112.))
            .flex_shrink_0()
            .rounded(px(12.))
            .bg(p.surface)
            .border_1()
            .border_color(p.line)
            .flex()
            .items_center()
            .gap_2()
            .child(
                div()
                    .id("workspace-panel-notice-text")
                    .flex_1()
                    .min_w(px(0.))
                    .max_h(px(92.))
                    .overflow_y_scroll()
                    .text_size(px(12.))
                    .text_color(p.danger)
                    .whitespace_normal()
                    .child(notice.to_owned()),
            )
            .child(
                div()
                    .id("dismiss-notice")
                    .debug_selector(|| "dismiss-notice".into())
                    .role(gpui::Role::Button)
                    .aria_label(self.locale.text(Text::Dismiss))
                    .size(px(44.))
                    .flex_shrink_0()
                    .rounded(px(10.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .hover(|s| s.bg(p.raised))
                    .child(icon(Icon::X, 18., p.muted))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.notice = None;
                        cx.notify();
                    })),
            )
    }

    pub(super) fn workspace_panel_overlay(
        &self,
        layout: Layout,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let available_width = layout.content_width + layout.sidebar_width;
        let available_height = layout.available_height + layout.insets.bottom;
        let margin = 8_f32.min(available_width / 2.);
        let width = (available_width - margin * 2.).max(0.).min(680.);
        let height = if available_height < 520. {
            (available_height - 8.).max(0.)
        } else {
            available_height * 0.84
        };
        let top = layout.insets.top + available_height - height;
        div()
            .id("workspace-panel-overlay")
            .debug_selector(|| "workspace-panel-overlay".into())
            .absolute()
            .top_0()
            .left_0()
            .size_full()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .id("workspace-panel-scrim")
                    .debug_selector(|| "workspace-panel-scrim".into())
                    .absolute()
                    .top_0()
                    .left_0()
                    .size_full()
                    .bg(gpui::black().opacity(0.28))
                    .occlude()
                    .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.close_workspace_panel(window, cx);
                        cx.stop_propagation();
                    })),
            )
            .child(
                div()
                    .id("workspace-panel-sheet")
                    .debug_selector(|| "workspace-panel-sheet".into())
                    .role(gpui::Role::Dialog)
                    .aria_label(self.locale.text(Text::WorkspacePanelTitle))
                    .absolute()
                    .left(px(layout.insets.left + (available_width - width) / 2.))
                    .top(px(top))
                    .w(px(width))
                    .h(px(height))
                    .rounded(px(28.))
                    .bg(p.composer)
                    .shadow_lg()
                    .border_1()
                    .border_color(p.line)
                    .overflow_hidden()
                    .occlude()
                    .pb(px(layout.insets.bottom.max(12.)))
                    .flex()
                    .flex_col()
                    .track_focus(&self.workspace_panel_focus)
                    .capture_key_down(cx.listener(
                        |this, event: &gpui::KeyDownEvent, window, cx| {
                            if event.keystroke.key == "escape" {
                                this.close_workspace_panel(window, cx);
                                window.prevent_default();
                            }
                            cx.stop_propagation();
                        },
                    ))
                    .on_click(|_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .h(px(16.))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(div().w(px(32.)).h(px(4.)).rounded_full().bg(p.line)),
                    )
                    .child(self.workspace_panel_content(
                        width - 2.,
                        (height - 18. - layout.insets.bottom.max(12.)).max(0.),
                        false,
                        true,
                        cx,
                    )),
            )
    }
}
