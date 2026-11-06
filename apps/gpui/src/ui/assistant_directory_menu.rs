use super::super::adaptive::{Layout, Navigation};
use super::*;

impl Shell {
    pub(super) fn assistant_directory_add_button(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        div()
            .id("assistant-directory-add")
            .debug_selector(|| "assistant-directory-add".into())
            .role(gpui::Role::Button)
            .aria_label(copy(
                self.locale,
                "New conversation, Bot or group",
                "新建会话、Bot 或群聊",
            ))
            .aria_expanded(self.assistant.directory_ui.add_menu_open)
            .size(px(44.))
            .flex_shrink_0()
            .rounded_full()
            .bg(p.composer)
            .shadow_sm()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .hover(|v| v.bg(p.surface))
            .child(icon(Icon::Plus, 21., p.text))
            .on_click(cx.listener(|this, _, window, cx| {
                if this.assistant.directory_ui.add_menu_open {
                    this.assistant_directory_close_menu(window, cx);
                    return;
                }
                if this.assistant.directory_ui.editor.is_some() || this.native_form_active {
                    return;
                }
                this.assistant.directory_ui.add_menu_previous_focus = window.focused(cx);
                let focus = this
                    .assistant
                    .directory_ui
                    .add_menu_focus
                    .get_or_insert_with(|| cx.focus_handle())
                    .clone();
                this.assistant.directory_ui.add_menu_open = true;
                window.focus(&focus, cx);
                cx.notify();
            }))
            .into_any_element()
    }
    pub(in crate::ui) fn assistant_directory_close_menu(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.assistant.directory_ui.add_menu_open = false;
        if let Some(focus) = self.assistant.directory_ui.add_menu_previous_focus.take() {
            window.focus(&focus, cx);
        } else {
            window.blur(cx);
        }
        cx.notify();
    }
    pub(in crate::ui) fn assistant_directory_add_overlay(
        &self,
        layout: Layout,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let sidebar = if layout.navigation == Navigation::Sidebar {
            layout.sidebar_width
        } else {
            0.
        };
        let menu_width = 220_f32.min((layout.content_width - 32.).max(0.));
        let left = layout.insets.left + sidebar + layout.content_width - menu_width - 24.;
        let top = layout.insets.top + 60.;
        let mut panel = div()
            .id("assistant-directory-add-menu")
            .debug_selector(|| "assistant-directory-add-menu".into())
            .absolute()
            .left(px(left.max(layout.insets.left + 8.)))
            .top(px(top))
            .w(px(menu_width))
            .p_2()
            .rounded(px(18.))
            .bg(p.composer)
            .border_1()
            .border_color(p.line)
            .shadow_lg()
            .flex()
            .flex_col()
            .occlude()
            .when_some(
                self.assistant.directory_ui.add_menu_focus.clone(),
                |v, focus| v.track_focus(&focus),
            )
            .capture_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    this.assistant_directory_close_menu(window, cx);
                    window.prevent_default();
                }
                cx.stop_propagation();
            }))
            .on_click(|_, _, cx| cx.stop_propagation());
        for (id, label, glyph, group) in [
            (
                "assistant-create-chat",
                copy(self.locale, "New conversation", "新建会话"),
                Icon::SquarePen,
                None,
            ),
            (
                "assistant-create-bot",
                copy(self.locale, "New Bot", "新建 Bot"),
                Icon::Plus,
                Some(false),
            ),
            (
                "assistant-create-group",
                copy(self.locale, "Start group chat", "发起群聊"),
                Icon::MessagesSquare,
                Some(true),
            ),
        ] {
            if id == "assistant-create-bot" {
                panel = panel.child(div().h(px(1.)).mx_3().my_1().bg(p.line));
            }
            panel = panel.child(
                div()
                    .id(id)
                    .debug_selector(move || id.into())
                    .role(gpui::Role::Button)
                    .aria_label(label)
                    .min_h(px(48.))
                    .px_3()
                    .rounded(px(12.))
                    .flex()
                    .items_center()
                    .gap_3()
                    .text_size(px(14.))
                    .cursor_pointer()
                    .hover(|v| v.bg(p.surface))
                    .child(icon(glyph, 19., p.text))
                    .child(label)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.assistant_directory_close_menu(window, cx);
                        match group {
                            None => this.create(cx),
                            Some(group) => this.assistant_begin_directory_editor(group, cx),
                        }
                        cx.stop_propagation();
                    })),
            );
        }
        div()
            .id("assistant-directory-add-overlay")
            .absolute()
            .inset_0()
            .size_full()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .id("assistant-directory-add-scrim")
                    .debug_selector(|| "assistant-directory-add-scrim".into())
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.assistant_directory_close_menu(window, cx);
                        cx.stop_propagation();
                    })),
            )
            .child(panel)
            .into_any_element()
    }
    pub(super) fn assistant_directory_search(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let query = &self.assistant.directory_ui.search;
        div()
            .id("assistant-directory-search")
            .debug_selector(|| "assistant-directory-search".into())
            .role(gpui::Role::Button)
            .aria_label(copy(
                self.locale,
                "Search Bots or groups",
                "搜索 Bot 或群聊",
            ))
            .w_full()
            .min_h(px(44.))
            .px_3()
            .rounded(px(13.))
            .bg(p.surface)
            .flex()
            .items_center()
            .gap_2()
            .text_size(px(13.))
            .text_color(if query.is_empty() { p.muted } else { p.text })
            .cursor_pointer()
            .child(icon(Icon::Search, 17., p.muted))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .child(if query.is_empty() {
                        copy(self.locale, "Search Bots or groups", "搜索 Bot 或群聊").to_owned()
                    } else {
                        query.clone()
                    }),
            )
            .when(!query.is_empty(), |v| {
                v.child(
                    div()
                        .id("assistant-directory-search-clear")
                        .debug_selector(|| "assistant-directory-search-clear".into())
                        .role(gpui::Role::Button)
                        .aria_label(copy(self.locale, "Clear search", "清空搜索"))
                        .size(px(44.))
                        .flex_shrink_0()
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(icon(Icon::X, 15., p.muted))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.assistant.directory_ui.search.clear();
                            cx.stop_propagation();
                            cx.notify();
                        })),
                )
            })
            .on_click(cx.listener(|this, _, _, cx| this.assistant_directory_edit_search(cx)))
            .into_any_element()
    }
    fn assistant_directory_edit_search(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || self.native_form_active
            || self.assistant.directory_ui.search_request.is_some()
        {
            return;
        }
        let token = uuid::Uuid::new_v4().to_string();
        self.assistant.directory_ui.search_request = Some(token.clone());
        let command = assistant_copy::field_command(
            copy(self.locale, "Search Bots or groups", "搜索 Bot 或群聊"),
            &self.assistant.directory_ui.search,
            false,
            self.locale,
            cx,
        );
        self.set_inline_native_form(true, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                this.set_inline_native_form(false, cx);
                if this.assistant.directory_ui.search_request.as_deref() != Some(&token) {
                    return;
                }
                this.assistant.directory_ui.search_request = None;
                if this.assistant_hub_visible()
                    && let Ok(Value::String(text)) = result
                {
                    this.assistant.directory_ui.search = text.trim().to_owned();
                    this.assistant
                        .directory_ui
                        .scroll
                        .set_offset(gpui::point(px(0.), px(0.)));
                }
                cx.notify();
            });
        })
        .detach();
    }
}
