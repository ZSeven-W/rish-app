use super::super::{
    assistant_directory::DirectoryDestination, assistant_memory_state::AssistantPanel,
};
use super::*;

impl Shell {
    pub(super) fn assistant_directory_preview_id(&self) -> Option<String> {
        let directory = self.assistant.directory()?;
        self.assistant
            .directory_ui
            .preview_bot_id
            .as_deref()
            .filter(|id| directory.bot_profile(id).is_some())
            .or_else(|| {
                Some(self.assistant.selected_bot_id())
                    .filter(|id| directory.bot_profile(id).is_some())
            })
            .or_else(|| directory.bot_ids().first().copied())
            .map(str::to_owned)
    }
    pub(super) fn assistant_directory_preview(
        &self,
        width: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let Some(id) = self.assistant_directory_preview_id() else {
            return div().into_any_element();
        };
        let Some(snapshot) = self.assistant.directory().and_then(|d| d.bot_snapshot(&id)) else {
            return div().into_any_element();
        };
        let active = self.assistant.snapshot.active_bot_id.as_deref() == Some(&id);
        let status = if active {
            assistant_copy::runner(self.locale, &self.assistant.snapshot.status)
        } else {
            copy(self.locale, "Ready when you are", "随时待命")
        };
        let soul = if snapshot.profile.soul.trim().is_empty() {
            copy(self.locale, "Personality and principles", "性格与原则")
        } else {
            copy(self.locale, "View and edit personality", "查看和编辑性格")
        };
        let mut pane = div()
            .id("assistant-directory-preview")
            .debug_selector(|| "assistant-directory-preview".into())
            .w(px(width))
            .h_full()
            .min_h(px(0.))
            .flex_shrink_0()
            .border_l_1()
            .border_color(p.line)
            .px_5()
            .py_5()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .items_center()
            .gap_3()
            .child(div().pt_5().pb_2().child(profile_avatar(
                self.assistant_storage_directory.as_ref(),
                snapshot.profile.avatar.as_ref(),
                88.,
                cx,
            )))
            .child(
                div()
                    .w_full()
                    .text_center()
                    .whitespace_normal()
                    .text_size(px(22.))
                    .line_height(px(28.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(snapshot.profile.name.clone()),
            )
            .child(div().text_size(px(13.)).text_color(p.muted).child(status))
            .child(div().w_full().h(px(1.)).my_4().bg(p.line));
        for (selector, title, detail, glyph, destination) in [
            (
                "assistant-directory-soul",
                "Soul",
                soul.to_owned(),
                Icon::File,
                DirectoryDestination::Soul,
            ),
            (
                "assistant-directory-memory",
                copy(self.locale, "Memory", "记忆"),
                format!("{}", snapshot.memories.len()),
                Icon::MessagesSquare,
                DirectoryDestination::Memory,
            ),
            (
                "assistant-directory-tasks",
                copy(self.locale, "Tasks", "任务"),
                format!("{}", snapshot.tasks.len()),
                Icon::ListChecks,
                DirectoryDestination::Tasks,
            ),
        ] {
            let bot_id = id.clone();
            pane = pane.child(
                div()
                    .id(selector)
                    .debug_selector(move || selector.into())
                    .role(gpui::Role::Button)
                    .aria_label(title)
                    .w_full()
                    .min_h(px(64.))
                    .p_3()
                    .rounded(px(18.))
                    .bg(p.composer)
                    .flex()
                    .items_center()
                    .gap_3()
                    .cursor_pointer()
                    .hover(|v| v.bg(p.surface))
                    .child(icon(glyph, 20., p.text))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(div().text_size(px(14.)).child(title))
                            .child(
                                div()
                                    .text_size(px(11.))
                                    .text_color(p.muted)
                                    .truncate()
                                    .child(detail),
                            ),
                    )
                    .child(icon(Icon::ChevronRight, 16., p.faint))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.assistant_directory_open_destination(bot_id.clone(), destination, cx)
                    })),
            );
        }
        pane.child(
            div()
                .id("assistant-directory-chat")
                .debug_selector(|| "assistant-directory-chat".into())
                .role(gpui::Role::Button)
                .aria_label(copy(self.locale, "Start chat", "开始聊天"))
                .w_full()
                .min_h(px(50.))
                .mt_3()
                .rounded(px(16.))
                .bg(p.accent)
                .text_color(p.on_accent)
                .flex()
                .items_center()
                .justify_center()
                .gap_2()
                .cursor_pointer()
                .hover(|v| v.opacity(0.9))
                .child(icon(Icon::MessageSquare, 19., p.on_accent))
                .child(copy(self.locale, "Start chat", "开始聊天"))
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.assistant_directory_open_destination(
                        id.clone(),
                        DirectoryDestination::Chat,
                        cx,
                    )
                })),
        )
        .into_any_element()
    }
    fn assistant_directory_open_destination(
        &mut self,
        id: String,
        destination: DirectoryDestination,
        cx: &mut Context<Self>,
    ) {
        // Keep the destination across the native IME navigation fence. Its
        // callback opens the Bot later, after this click has returned.
        self.assistant.directory_ui.pending_destination = Some((id.clone(), destination));
        self.assistant_open_bot(id, cx);
        self.assistant_directory_apply_destination(cx);
    }
    pub(in crate::ui) fn assistant_directory_apply_destination(&mut self, cx: &mut Context<Self>) {
        if self.page != Page::Assistant
            || self.assistant.directory_ui.hub_open
            || self.assistant.directory_ui.group_id.is_some()
        {
            return;
        }
        let Some((id, _)) = &self.assistant.directory_ui.pending_destination else {
            return;
        };
        if self.assistant.selected_bot_id() != id
            || self.assistant.directory_ui.pending_bot_id.is_some()
        {
            return;
        }
        let (_, destination) = self
            .assistant
            .directory_ui
            .pending_destination
            .take()
            .unwrap();
        match destination {
            DirectoryDestination::Chat => {}
            DirectoryDestination::Soul => {
                self.assistant_edit_field(super::super::assistant_forms::Field::ProfileSoul, cx)
            }
            DirectoryDestination::Memory => {
                self.assistant.tasks_open = true;
                self.assistant.panel = AssistantPanel::Memory;
            }
            DirectoryDestination::Tasks => {
                self.assistant.tasks_open = true;
                self.assistant.panel = AssistantPanel::Tasks;
            }
        }
        cx.notify();
    }
}
