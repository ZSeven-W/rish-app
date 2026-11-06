use super::{assistant_avatar::profile_avatar, assistant_copy::copy, *};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};
#[path = "assistant_directory_editor.rs"]
mod editor;
#[path = "assistant_directory_menu.rs"]
mod menu;
#[path = "assistant_directory_preview.rs"]
mod preview;

impl Shell {
    pub(super) fn assistant_directory_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let hub = self.assistant.directory_ui.hub_open;
        let group = self
            .assistant
            .directory_ui
            .group_id
            .as_deref()
            .and_then(|id| {
                self.assistant
                    .directory()?
                    .groups
                    .iter()
                    .find(|g| g.id == id)
            });
        let title = if hub {
            "Bot".to_owned()
        } else {
            group
                .map(|g| g.name.clone())
                .unwrap_or_else(|| copy(self.locale, "Group chat", "群聊").into())
        };
        div()
            .id("assistant-directory-header")
            .debug_selector(|| "assistant-directory-header".into())
            .flex_1()
            .min_w(px(0.))
            .flex()
            .items_center()
            .gap_2()
            .when(!hub, |v| v.child(self.assistant_hub_back_button(cx)))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .text_size(px(if hub { 22. } else { 17. }))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .when(!hub, |v| {
                v.child(
                    div()
                        .min_h(px(44.))
                        .px_2()
                        .flex()
                        .items_center()
                        .text_size(px(12.))
                        .text_color(p.muted)
                        .child(
                            group
                                .map(|g| format!("{} Bot", g.active_bot_ids.len()))
                                .unwrap_or_default(),
                        ),
                )
            })
            .when(hub && self.assistant.directory_ui.editor.is_none(), |v| {
                v.child(self.assistant_directory_add_button(cx))
            })
            .into_any_element()
    }
    pub(super) fn assistant_hub_back_button(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        div()
            .id("assistant-hub-back")
            .debug_selector(|| "assistant-hub-back".into())
            .role(gpui::Role::Button)
            .aria_label(copy(self.locale, "All Bots and groups", "全部 Bot 与群聊"))
            .size(px(44.))
            .flex_shrink_0()
            .rounded_full()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .hover(|v| v.bg(p.surface))
            .child(icon(Icon::ChevronLeft, 22., p.text))
            .on_click(cx.listener(|this, _, _, cx| this.assistant_open_hub(cx)))
            .into_any_element()
    }
    pub(super) fn assistant_hub(&self, width: f32, cx: &mut Context<Self>) -> AnyElement {
        if self.assistant.directory_ui.editor.is_some() {
            return self.assistant_directory_editor(cx);
        }
        let p = Palette::get(cx);
        let wide = width >= 850.;
        let query = self.assistant.directory_ui.search.trim().to_lowercase();
        let mut bots = div().w_full().flex().flex_col();
        let mut groups = div().w_full().flex().flex_col();
        let mut bot_count = 0;
        let mut group_count = 0;
        if let Some(directory) = self.assistant.directory() {
            let preview_id = self.assistant_directory_preview_id();
            for id in directory.bot_ids() {
                let Some(profile) = directory.bot_profile(id) else {
                    continue;
                };
                if !query.is_empty() && !profile.name.to_lowercase().contains(&query) {
                    continue;
                }
                bot_count += 1;
                let selected = wide && preview_id.as_deref() == Some(id);
                let active = self.assistant.snapshot.active_bot_id.as_deref() == Some(id);
                let status = if active {
                    assistant_copy::runner(self.locale, &self.assistant.snapshot.status)
                } else {
                    copy(self.locale, "Ready when you are", "随时待命")
                };
                let id = id.to_owned();
                let selector = format!("assistant-bot-card-{id}");
                bots = bots
                    .child(
                        div()
                            .id(selector.clone())
                            .debug_selector(move || selector.clone())
                            .role(gpui::Role::Button)
                            .aria_label(profile.name.clone())
                            .w_full()
                            .min_w(px(0.))
                            .min_h(px(96.))
                            .px_3()
                            .py_4()
                            .rounded(px(18.))
                            .when(selected, |v| v.bg(p.surface))
                            .flex()
                            .items_center()
                            .gap_4()
                            .cursor_pointer()
                            .hover(|v| v.bg(p.surface))
                            .child(profile_avatar(
                                self.assistant_storage_directory.as_ref(),
                                profile.avatar.as_ref(),
                                48.,
                                cx,
                            ))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .flex()
                                    .flex_col()
                                    .gap_2()
                                    .child(
                                        div()
                                            .flex()
                                            .items_center()
                                            .gap_2()
                                            .child(
                                                div()
                                                    .min_w(px(0.))
                                                    .truncate()
                                                    .text_size(px(16.))
                                                    .font_weight(FontWeight::SEMIBOLD)
                                                    .child(profile.name.clone()),
                                            )
                                            .when(active, |v| {
                                                v.child(
                                                    div()
                                                        .size(px(6.))
                                                        .flex_shrink_0()
                                                        .rounded_full()
                                                        .bg(p.info),
                                                )
                                            }),
                                    )
                                    .child(
                                        div().text_size(px(12.)).text_color(p.muted).child(status),
                                    ),
                            )
                            .child(icon(Icon::ChevronRight, 17., p.faint))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if wide {
                                    this.assistant.directory_ui.preview_bot_id = Some(id.clone());
                                    cx.notify();
                                } else {
                                    this.assistant_open_bot(id.clone(), cx);
                                }
                            })),
                    )
                    .child(div().ml(px(76.)).mr_3().h(px(1.)).bg(p.line));
            }
            for group in &directory.groups {
                if !query.is_empty() && !group.name.to_lowercase().contains(&query) {
                    continue;
                }
                group_count += 1;
                let id = group.id.clone();
                let selector = format!("assistant-group-card-{id}");
                let mut marks = div().relative().w(px(66.)).h(px(42.)).flex_shrink_0();
                for (index, member) in group
                    .members
                    .iter()
                    .filter(|m| group.active_bot_ids.contains(&m.bot_id))
                    .take(3)
                    .enumerate()
                {
                    if let Some(profile) = directory.bot_profile(&member.bot_id) {
                        marks = marks.child(
                            div()
                                .absolute()
                                .left(px(index as f32 * 15.))
                                .top(px(3.))
                                .p(px(2.))
                                .rounded_full()
                                .bg(p.background)
                                .child(profile_avatar(
                                    self.assistant_storage_directory.as_ref(),
                                    profile.avatar.as_ref(),
                                    32.,
                                    cx,
                                )),
                        );
                    }
                }
                groups = groups
                    .child(
                        div()
                            .id(selector.clone())
                            .debug_selector(move || selector.clone())
                            .role(gpui::Role::Button)
                            .aria_label(group.name.clone())
                            .min_h(px(88.))
                            .w_full()
                            .min_w(px(0.))
                            .px_3()
                            .py_4()
                            .rounded(px(18.))
                            .flex()
                            .items_center()
                            .gap_3()
                            .cursor_pointer()
                            .hover(|v| v.bg(p.surface))
                            .child(marks)
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .flex()
                                    .flex_col()
                                    .gap_2()
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(px(16.))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .child(group.name.clone()),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(12.))
                                            .text_color(p.muted)
                                            .child(format!("{} Bot", group.active_bot_ids.len())),
                                    ),
                            )
                            .child(icon(Icon::ChevronRight, 17., p.faint))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.assistant_open_group(id.clone(), cx)
                            })),
                    )
                    .child(div().ml(px(88.)).mr_3().h(px(1.)).bg(p.line));
            }
        }
        if bot_count == 0 {
            bots = bots.child(self.assistant_directory_empty(!query.is_empty(), false, cx));
        }
        if group_count == 0 {
            groups = groups.child(self.assistant_directory_empty(!query.is_empty(), true, cx));
        }
        let mut list = div()
            .id("assistant-directory-list")
            .debug_selector(|| "assistant-directory-list".into())
            .flex_1()
            .min_w(px(0.))
            .h_full()
            .min_h(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.assistant.directory_ui.scroll)
            .px(px(if wide { 24. } else { 20. }))
            .pb_5()
            .pt_2()
            .flex()
            .flex_col()
            .items_center();
        if let Some(error) = &self.assistant.error {
            list = list.child(
                div()
                    .w_full()
                    .pb_3()
                    .text_color(p.danger)
                    .text_size(px(13.))
                    .whitespace_normal()
                    .child(error.clone()),
            );
        }
        list = list.child(
            div()
                .w_full()
                .max_w(px(650.))
                .flex()
                .flex_col()
                .child(self.assistant_directory_search(cx))
                .child(
                    div()
                        .mt_6()
                        .mb_2()
                        .px_3()
                        .text_size(px(15.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(copy(self.locale, "My Bots", "我的 Bot")),
                )
                .child(bots)
                .child(
                    div()
                        .mt_6()
                        .mb_2()
                        .px_3()
                        .text_size(px(15.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(copy(self.locale, "Group chats", "群聊")),
                )
                .child(groups),
        );
        div()
            .id("assistant-hub")
            .debug_selector(|| "assistant-hub".into())
            .flex_1()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .overflow_hidden()
            .child(list)
            .when(wide, |v| {
                v.child(self.assistant_directory_preview((width * 0.34).clamp(280., 340.), cx))
            })
            .into_any_element()
    }
    fn assistant_directory_empty(
        &self,
        filtered: bool,
        group: bool,
        cx: &Context<Self>,
    ) -> AnyElement {
        div()
            .w_full()
            .px_3()
            .py_5()
            .text_size(px(13.))
            .line_height(px(22.))
            .text_color(Palette::get(cx).muted)
            .whitespace_normal()
            .child(if filtered {
                copy(self.locale, "No matches", "没有匹配结果")
            } else if group {
                copy(
                    self.locale,
                    "Use + to start a group with your Bots.",
                    "点击右上角 ＋，邀请 Bot 发起群聊。",
                )
            } else {
                copy(
                    self.locale,
                    "Your Bots will appear here.",
                    "你的 Bot 会显示在这里。",
                )
            })
            .into_any_element()
    }
}
