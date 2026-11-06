use super::adaptive::{Insets, Metrics, Navigation, SizeClass};
use super::*;
use crate::icons::{Icon, icon};

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.model_picker && self.model_picker_focus_pending {
            self.model_picker_focus_pending = false;
            self.model_picker_previous_focus = window.focused(cx);
            window.focus(&self.model_picker_focus, cx);
        }
        theme::sync_system(window.appearance(), cx);
        let p = Palette::get(cx);
        let (top, right, bottom, left) = crate::safe_area_insets();
        let bottom = bottom.max(self.inline_keyboard_bottom());
        let (horizontal, vertical) = crate::window_size_classes();
        let layout = adaptive::resolve(Metrics {
            width: window.viewport_size().width.into(),
            height: window.viewport_size().height.into(),
            insets: Insets {
                top,
                right,
                bottom,
                left,
            },
            horizontal: SizeClass::from_raw(horizontal),
            vertical: SizeClass::from_raw(vertical),
            mobile: cfg!(any(target_os = "ios", target_os = "android")),
        });
        self.sync_assistant_visibility(layout.content_width, cx);
        let Insets {
            top,
            right,
            bottom,
            left,
        } = layout.insets;
        let wide = layout.navigation == Navigation::Sidebar;
        if wide && self.drawer_open {
            self.close_drawer(true, window, cx);
        }
        let workspace_modal =
            matches!(self.page, Page::Files | Page::Git) && layout.content_width < 840.;
        self.sync_workspace_panel_focus(workspace_modal, window, cx);
        let inline_visible = self.chat_input_visible(layout.content_width, workspace_modal);
        self.prepare_inline_composer(
            inline_visible,
            [
                window.viewport_size().width.into(),
                window.viewport_size().height.into(),
            ],
            window.scale_factor(),
            cx,
        );
        let title = match self.page {
            Page::Chat | Page::Files | Page::Git => self
                .state
                .conversations()
                .into_iter()
                .find(|c| Some(c.id.as_str()) == self.state.active_conversation_id())
                .map(|c| self.conversation_title(&c.id, &c.title))
                .unwrap_or_else(|| self.locale.text(Text::NewChat).into()),
            Page::Settings => self.locale.text(Text::Settings).into(),
            Page::Assistant => {
                assistant_copy::copy(self.locale, "Local assistant", "本机助手").into()
            }
        };
        let header_height = if matches!(self.page, Page::Assistant | Page::Settings) {
            64.
        } else {
            56.
        };
        let workspace_page = matches!(self.page, Page::Files | Page::Git);
        let mut main = div()
            .flex_1()
            .min_w(px(0.))
            .h_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .when(
                self.page != Page::Settings || !wide || !layout.side_controls,
                |main| {
                    main.child(
                        div()
                            .px(px(if wide { 24. } else { 18. }))
                            .h(px(header_height))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .justify_between()
                            .gap_2()
                            .when(
                                !wide
                                    && self.page != Page::Settings
                                    && (self.page != Page::Assistant
                                        || self.assistant_hub_visible()),
                                |header| header.child(self.drawer_open_button(cx)),
                            )
                            .when(!wide && self.page == Page::Settings, |header| {
                                header.child(
                                    visuals::round_button(cx)
                                        .id("settings-back")
                                        .role(gpui::Role::Button)
                                        .aria_label(assistant_copy::copy(
                                            self.locale,
                                            "Back",
                                            "返回",
                                        ))
                                        .cursor_pointer()
                                        .child(icon(Icon::ChevronLeft, 22., p.text))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.navigate(this.settings_return_page, cx);
                                        })),
                                )
                            })
                            .when(self.page != Page::Assistant, |header| {
                                header.child(
                                    div()
                                        .id("chat-title")
                                        .flex_1()
                                        .min_w(px(0.))
                                        .overflow_hidden()
                                        .whitespace_nowrap()
                                        .min_h(px(HIT_TARGET))
                                        .flex()
                                        .items_center()
                                        .when(self.page == Page::Settings && !wide, |v| {
                                            v.justify_center()
                                        })
                                        .text_size(px(16.))
                                        .text_color(p.text)
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .when(self.page == Page::Chat, |title| {
                                            title.cursor_pointer()
                                        })
                                        .child(title)
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            if this.page == Page::Chat && this.runtime.is_native() {
                                                this.begin_rename(cx);
                                            }
                                        })),
                                )
                            })
                            .when(self.page == Page::Assistant, |header| {
                                header.child(self.assistant_header_identity(cx))
                            })
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_3()
                                    .when(self.page == Page::Settings && !wide, |actions| {
                                        actions.child(div().size(px(44.)))
                                    })
                                    .when(
                                        self.page == Page::Assistant
                                            && !self.assistant_hub_visible()
                                            && !self.assistant_group_visible()
                                            && layout.content_width
                                                < assistant_chat_view::TASK_PANEL_BREAKPOINT,
                                        |actions| actions.child(self.assistant_tasks_button(cx)),
                                    )
                                    .when(
                                        !self.runtime.is_native() && self.page != Page::Assistant,
                                        |v| {
                                            v.child(
                                                div()
                                                    .px_2()
                                                    .py_1()
                                                    .rounded_md()
                                                    .border_1()
                                                    .border_color(p.line)
                                                    .text_size(px(10.))
                                                    .text_color(p.faint)
                                                    .child(self.locale.text(Text::Preview)),
                                            )
                                        },
                                    )
                                    .when(
                                        matches!(self.page, Page::Chat | Page::Files | Page::Git),
                                        |actions| actions.child(self.workspace_toggle_button(cx)),
                                    ),
                            ),
                    )
                },
            )
            .when(self.loading && !self.state.is_loaded(), |v| {
                v.child(
                    div()
                        .px_6()
                        .py_2()
                        .text_size(px(12.))
                        .text_color(p.muted)
                        .child(self.locale.text(Text::Loading)),
                )
            });
        if self.navigation_flow.feedback.is_some() {
            main = main.child(self.navigation_feedback_view(cx));
        }
        if let Some(error) = self
            .notice
            .as_deref()
            .filter(|_| !workspace_page)
            .or(self.state.last_error())
        {
            let workspace_notice = workspace_page && self.notice.is_some();
            let informational =
                self.notice.as_deref() == Some(error) && self.informational_notice();
            let dismiss = workspace_notice || informational;
            main = main.child(
                div()
                    .mx_5()
                    .mb_3()
                    .p_3()
                    .rounded_lg()
                    .bg(p.surface)
                    .border_1()
                    .border_color(p.line)
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .id("notice-text")
                            .debug_selector(|| "notice-text".into())
                            .flex_1()
                            .min_w(px(0.))
                            .text_size(px(12.))
                            .text_color(if informational { p.muted } else { p.danger })
                            .whitespace_normal()
                            .child(error.to_owned()),
                    )
                    .child(
                        div()
                            .id(if dismiss { "dismiss-notice" } else { "retry" })
                            .debug_selector(move || {
                                if dismiss { "dismiss-notice" } else { "retry" }.into()
                            })
                            .px_2()
                            .py_1()
                            .flex_shrink_0()
                            .min_h(px(HIT_TARGET))
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .text_size(px(12.))
                            .text_color(p.text)
                            .child(self.locale.text(if dismiss {
                                Text::Dismiss
                            } else {
                                Text::Retry
                            }))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if dismiss {
                                    this.notice = None;
                                    cx.notify();
                                } else {
                                    this.bootstrap(cx);
                                }
                            })),
                    ),
            );
        }
        if self.rename_open {
            main = main.child(
                div()
                    .mx_5()
                    .p_3()
                    .rounded_lg()
                    .bg(p.composer)
                    .border_1()
                    .border_color(p.line)
                    .flex()
                    .gap_2()
                    .child(self.title_input.clone())
                    .child(
                        div()
                            .id("save-title")
                            .min_h(px(HIT_TARGET))
                            .p_3()
                            .cursor_pointer()
                            .child(self.locale.text(Text::Save))
                            .on_click(cx.listener(|this, _, _, cx| this.save_title(cx))),
                    ),
            );
        }
        main = match self.page {
            Page::Chat | Page::Files | Page::Git => {
                main.child(self.conversation_workbench(layout, cx))
            }
            Page::Settings => main.child(self.settings_screen(layout.content_width, cx)),
            Page::Assistant => main.child(self.assistant_page(
                layout.content_width,
                (layout.available_height - header_height).max(0.),
                cx,
            )),
        };
        if !self.runtime.is_native() {
            main = main.child(
                div()
                    .px_5()
                    .pb_4()
                    .text_center()
                    .text_size(px(11.))
                    .text_color(p.faint)
                    .child(self.locale.text(Text::DesktopUnavailable)),
            );
        }
        div()
            .relative()
            .size_full()
            .bg(p.background)
            .text_color(p.text)
            .font_family(if cfg!(target_os = "android") {
                "Roboto"
            } else {
                ".SystemUIFont"
            })
            .text_size(px(14.))
            .child(
                div()
                    .size_full()
                    .pt(px(top))
                    .pr(px(right))
                    .pb(px(bottom))
                    .pl(px(left))
                    .flex()
                    .overflow_hidden()
                    .when(wide, |v| {
                        v.child(self.sidebar(layout.sidebar_width, layout.side_controls, false, cx))
                    })
                    .child(main),
            )
            .when(self.drawer_open && !wide, |root| {
                root.child(self.drawer(layout, cx))
            })
            .when(workspace_modal, |root| {
                root.child(self.workspace_panel_overlay(layout, cx))
            })
            .when(
                self.assistant_hub_visible() && self.assistant.directory_ui.add_menu_open,
                |root| root.child(self.assistant_directory_add_overlay(layout, cx)),
            )
            .when(self.model_picker, |root| {
                root.child(self.model_picker_overlay(layout, cx))
            })
            .when(self.assistant.profile_menu_open, |root| {
                root.child(self.assistant_profile_overlay(layout, cx))
            })
    }
}
