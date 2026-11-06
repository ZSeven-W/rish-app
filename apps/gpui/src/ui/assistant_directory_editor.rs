use super::*;

impl Shell {
    pub(in crate::ui) fn assistant_directory_editor(&self, cx: &mut Context<Self>) -> AnyElement {
        let editor = self.assistant.directory_ui.editor.as_ref().unwrap();
        let p = Palette::get(cx);
        let group = editor.members.is_some();
        let enabled = !editor.saving && editor.request.is_none();
        let mut form = div()
            .w_full()
            .max_w(px(620.))
            .flex()
            .flex_col()
            .gap_5()
            .child(
                div()
                    .text_size(px(22.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(copy(
                        self.locale,
                        if editor.editing {
                            "Edit group"
                        } else if group {
                            "New group"
                        } else {
                            "New Bot"
                        },
                        if editor.editing {
                            "编辑群聊"
                        } else if group {
                            "发起群聊"
                        } else {
                            "新建 Bot"
                        },
                    )),
            )
            .child(
                div()
                    .id("assistant-directory-name")
                    .debug_selector(|| "assistant-directory-name".into())
                    .role(gpui::Role::Button)
                    .aria_label(copy(self.locale, "Name", "名称"))
                    .min_h(px(72.))
                    .p_4()
                    .rounded(px(20.))
                    .bg(p.composer)
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(div().text_size(px(12.)).text_color(p.muted).child(copy(
                                self.locale,
                                "Name",
                                "名称",
                            )))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(16.))
                                    .child(editor.name.clone()),
                            ),
                    )
                    .child(icon(Icon::SquarePen, 18., p.muted))
                    .when(enabled, |v| v.cursor_pointer())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if enabled {
                            this.assistant_directory_edit_name(cx)
                        }
                    })),
            );
        if let Some(members) = &editor.members {
            form = form.child(div().text_size(px(13.)).text_color(p.muted).child(copy(
                self.locale,
                "Choose 2–8 assistants",
                "选择 2–8 个助手",
            )));
            let mut choices = div().rounded(px(20.)).bg(p.composer).flex().flex_col();
            if let Some(directory) = self.assistant.directory() {
                for id in directory.bot_ids() {
                    let Some(profile) = directory.bot_profile(id) else {
                        continue;
                    };
                    let selected = members.iter().any(|m| m == id);
                    let id = id.to_owned();
                    let selector = format!("assistant-group-member-{id}");
                    choices = choices.child(
                        div()
                            .id(selector.clone())
                            .debug_selector(move || selector.clone())
                            .role(gpui::Role::Button)
                            .aria_label(format!(
                                "{}{}",
                                profile.name,
                                if selected {
                                    copy(self.locale, ", selected", "，已选择")
                                } else {
                                    ""
                                }
                            ))
                            .min_h(px(68.))
                            .p_3()
                            .flex()
                            .items_center()
                            .gap_3()
                            .when(enabled, |v| v.cursor_pointer().hover(|v| v.bg(p.surface)))
                            .child(profile_avatar(
                                self.assistant_storage_directory.as_ref(),
                                profile.avatar.as_ref(),
                                36.,
                                cx,
                            ))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .truncate()
                                    .text_size(px(15.))
                                    .child(profile.name.clone()),
                            )
                            .child(icon(
                                if selected { Icon::Check } else { Icon::Plus },
                                18.,
                                if selected { p.text } else { p.faint },
                            ))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if enabled {
                                    if let Some(members) = this
                                        .assistant
                                        .directory_ui
                                        .editor
                                        .as_mut()
                                        .and_then(|e| e.members.as_mut())
                                    {
                                        if members.contains(&id) {
                                            members.retain(|m| m != &id)
                                        } else if members.len() < 8 {
                                            members.push(id.clone())
                                        }
                                    }
                                    cx.notify();
                                }
                            })),
                    );
                }
            }
            form = form.child(choices);
        } else {
            form=form.child(div().text_size(px(13.)).line_height(px(22.)).text_color(p.muted).whitespace_normal()
                .child(copy(self.locale,"Each assistant has its own profile, Soul, memory and tasks. You can edit the avatar and personality after creating it.","每位助手拥有独立的资料、Soul、记忆和任务。创建后可以更换头像、编辑性格。")));
        }
        if let Some(error) = &self.assistant.error {
            form = form.child(
                div()
                    .text_size(px(13.))
                    .text_color(p.danger)
                    .whitespace_normal()
                    .child(error.clone()),
            );
        }
        form = form.child(
            div()
                .w_full()
                .flex()
                .gap_3()
                .child(
                    div()
                        .id("assistant-directory-cancel")
                        .debug_selector(|| "assistant-directory-cancel".into())
                        .role(gpui::Role::Button)
                        .min_h(px(48.))
                        .flex_1()
                        .rounded_full()
                        .bg(p.composer)
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(copy(self.locale, "Cancel", "取消"))
                        .when(enabled, |v| v.cursor_pointer())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if enabled {
                                this.assistant.directory_ui.editor = None;
                                this.assistant.error = None;
                                cx.notify();
                            }
                        })),
                )
                .child(
                    div()
                        .id("assistant-directory-save")
                        .debug_selector(|| "assistant-directory-save".into())
                        .role(gpui::Role::Button)
                        .min_h(px(48.))
                        .flex_1()
                        .rounded_full()
                        .bg(p.accent)
                        .text_color(p.on_accent)
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(copy(
                            self.locale,
                            if editor.saving { "Saving…" } else { "Create" },
                            if editor.saving {
                                "保存中…"
                            } else {
                                "创建"
                            },
                        ))
                        .when(enabled, |v| v.cursor_pointer())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if enabled {
                                this.assistant_save_directory_editor(cx)
                            }
                        })),
                ),
        );
        div()
            .id("assistant-directory-editor")
            .debug_selector(|| "assistant-directory-editor".into())
            .flex_1()
            .size_full()
            .min_h(px(0.))
            .overflow_y_scroll()
            .px_5()
            .py_5()
            .flex()
            .flex_col()
            .items_center()
            .child(form)
            .into_any_element()
    }
}
