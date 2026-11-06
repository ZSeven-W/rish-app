use super::*;
use crate::icons::{Icon, icon};

impl Shell {
    pub(super) fn nav_button(
        &self,
        id: &'static str,
        label: &'static str,
        page: Page,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let glyph = match page {
            Page::Chat => Icon::MessageSquare,
            Page::Assistant => Icon::MessagesSquare,
            Page::Files => Icon::Folder,
            Page::Git => Icon::GitBranch,
            Page::Settings => Icon::Settings2,
        };
        div()
            .id(id)
            .debug_selector(move || id.into())
            .min_h(px(HIT_TARGET.max(44.)))
            .px_3()
            .flex()
            .items_center()
            .gap_2()
            .rounded(px(10.))
            .cursor_pointer()
            .text_size(px(13.))
            .text_color(if self.page == page { p.text } else { p.muted })
            .when(self.page == page, |s| s.bg(p.raised))
            .hover(|s| s.bg(p.raised))
            .child(icon(
                glyph,
                16.,
                if self.page == page { p.text } else { p.muted },
            ))
            .child(label)
            .on_click(cx.listener(move |this, _, window, cx| {
                this.close_drawer(false, window, cx);
                if page == Page::Assistant {
                    this.assistant_open_hub(cx);
                } else {
                    this.navigate(page, cx);
                }
            }))
    }
    pub(super) fn conversations(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let active = self.state.active_conversation_id().unwrap_or("");
        let mut rows = div()
            .id("conversation-list")
            .debug_selector(|| "conversation-list".into())
            .flex()
            .flex_col()
            .gap_1()
            .min_h(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.conversation_scroll)
            .flex_1();
        let chats: Vec<_> = self
            .state
            .conversations()
            .into_iter()
            .filter(|chat| {
                !self
                    .assistant
                    .directory()
                    .is_some_and(|d| d.conversation_bot_id(&chat.id).is_some())
            })
            .collect();
        let empty = chats.is_empty();
        for chat in chats {
            let selected = chat.id == active;
            let selector = format!("conversation-row-{}", chat.id);
            let title = self.conversation_title(&chat.id, &chat.title);
            rows = rows.child(
                div()
                    .id(chat.id.clone())
                    .debug_selector(move || selector.clone())
                    .px_3()
                    .py_2()
                    .flex()
                    .items_center()
                    .gap_2()
                    .min_h(px(HIT_TARGET.max(44.)))
                    .rounded(px(10.))
                    .cursor_pointer()
                    .when(selected, |s| s.bg(p.raised))
                    .hover(|s| s.bg(p.raised))
                    .text_size(px(13.))
                    .text_color(if selected { p.text } else { p.muted })
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .child(icon(
                        Icon::MessageSquare,
                        16.,
                        if selected { p.text } else { p.muted },
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .child(title),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.close_drawer(false, window, cx);
                        this.select(chat.id.clone(), cx);
                    })),
            );
        }
        if empty {
            rows = rows.child(
                div()
                    .px_3()
                    .py_3()
                    .text_size(px(12.))
                    .text_color(p.faint)
                    .whitespace_normal()
                    .child(self.locale.text(Text::NoChats)),
            );
        }
        rows
    }
    pub(super) fn sidebar(
        &self,
        width: f32,
        side_controls: bool,
        _drawer: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        div()
            .id("sidebar")
            .w(px(width))
            .h_full()
            .overflow_y_scroll()
            .track_scroll(&self.sidebar_scroll)
            .flex_shrink_0()
            .px_3()
            .pt_3()
            .pb_3()
            .bg(p.surface)
            .flex()
            .flex_col()
            .gap_1()
            .child(self.sidebar_user_identity(cx))
            .child(
                div()
                    .id("new-chat")
                    .min_h(px(48.))
                    .px_4()
                    .flex()
                    .items_center()
                    .gap_2()
                    .rounded(px(16.))
                    .bg(p.accent)
                    .text_color(p.on_accent)
                    .cursor_pointer()
                    .hover(|s| s.opacity(0.88))
                    .text_size(px(13.))
                    .child(icon(Icon::Plus, 18., p.on_accent))
                    .child(self.locale.text(Text::NewChat))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.close_drawer(false, window, cx);
                        this.create(cx);
                    })),
            )
            .child(self.nav_button("assistant-open", "Bot", Page::Assistant, cx))
            .when(
                side_controls
                    && self.page == Page::Chat
                    && self.state.active_conversation_id().is_some(),
                |sidebar| {
                    sidebar.child(
                        div()
                            .id("sidebar-rename")
                            .min_h(px(HIT_TARGET.max(44.)))
                            .px_3()
                            .flex()
                            .items_center()
                            .gap_2()
                            .rounded(px(10.))
                            .cursor_pointer()
                            .hover(|s| s.bg(p.raised))
                            .text_size(px(13.))
                            .text_color(p.muted)
                            .child(icon(Icon::SquarePen, 16., p.muted))
                            .child(self.locale.text(Text::Title))
                            .on_click(cx.listener(|this, _, _, cx| this.begin_rename(cx))),
                    )
                },
            )
            .child(
                div()
                    .px_3()
                    .pt_4()
                    .pb_2()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .child(self.locale.text(Text::Recent)),
            )
            .child(self.conversations(cx))
            .child(div().h(px(1.)).mx_2().my_2().bg(p.line))
            .child(self.nav_button(
                "settings",
                self.locale.text(Text::Settings),
                Page::Settings,
                cx,
            ))
    }
    pub(super) fn chat(
        &self,
        compact: bool,
        content_width: f32,
        content_height: f32,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let empty = self.state.messages().is_empty();
        let agent = self.state.agent_view();
        let has_agent = agent.is_some();
        let mut page = div()
            .id("chat-page")
            .debug_selector(|| "chat-page".into())
            .flex_1()
            .min_h(px(0.))
            .size_full()
            .flex()
            .flex_col()
            .overflow_hidden();
        if empty && self.page == Page::Assistant {
            page = page.child(self.assistant_welcome(compact, cx));
        } else if empty {
            page = page.child(
                div()
                    .flex_1()
                    .min_h(px(0.))
                    .w_full()
                    .flex()
                    .flex_col()
                    .items_center()
                    .justify_center()
                    .px_5()
                    .py(px(if compact { 12. } else { 32. }))
                    .child(
                        div()
                            .w_full()
                            .max_w(px(720.))
                            .flex()
                            .flex_col()
                            .items_center()
                            .gap(px(if compact { 16. } else { 36. }))
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .items_center()
                                    .gap_3()
                                    .child(
                                        div()
                                            .text_size(px(if compact { 24. } else { 28. }))
                                            .font_weight(gpui::FontWeight::SEMIBOLD)
                                            .text_center()
                                            .child(self.locale.text(Text::Ready)),
                                    )
                                    .when(!compact, |heading| {
                                        heading.child(
                                            div()
                                                .text_size(px(15.))
                                                .text_color(p.muted)
                                                .text_center()
                                                .child(self.locale.text(Text::ReadySubtitle)),
                                        )
                                    }),
                            )
                            .when(!compact, |content| {
                                content.child(
                                    div()
                                        .w_full()
                                        .max_w(px(520.))
                                        .flex()
                                        .gap_2()
                                        .child(self.suggestion(
                                            "suggest-plan",
                                            Icon::ListChecks,
                                            Text::Plan,
                                            Text::PlanPrompt,
                                            cx,
                                        ))
                                        .child(self.suggestion(
                                            "suggest-explain",
                                            Icon::CodeXml,
                                            Text::Explain,
                                            Text::ExplainPrompt,
                                            cx,
                                        ))
                                        .child(self.suggestion(
                                            "suggest-review",
                                            Icon::CheckCheck,
                                            Text::Review,
                                            Text::ReviewPrompt,
                                            cx,
                                        )),
                                )
                            }),
                    ),
            );
        } else {
            page = page.child(
                div()
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_hidden()
                    .child(self.transcript.clone()),
            );
        }
        if let Some(agent) = agent {
            page = page.child(self.agent_panel(agent, content_height, cx));
        }
        page = page
            .when(
                self.state.is_busy() && self.state.agent_view().is_none(),
                |view| {
                    view.child(
                        div().w_full().px_5().child(
                            div()
                                .max_w(px(720.))
                                .mx_auto()
                                .py_2()
                                .text_size(px(12.))
                                .text_color(p.muted)
                                .child(self.locale.text(Text::Response)),
                        ),
                    )
                },
            )
            .child(
                div()
                    .px(px(if compact { 16. } else { 20. }))
                    .pt(px(if compact { 4. } else { 12. }))
                    .pb(px(if compact { 8. } else { 16. }))
                    .flex_shrink_0()
                    .w_full()
                    .child(
                        div().w_full().max_w(px(720.)).mx_auto().child(
                            self.composer_card(
                                (content_width - if compact { 32. } else { 40. }).clamp(0., 720.),
                                (content_height
                                    - if compact { 12. } else { 28. }
                                    - if self.state.is_busy() { 28. } else { 0. })
                                .min(if has_agent { 120. } else { f32::MAX })
                                .max(0.),
                                cx,
                            ),
                        ),
                    ),
            );
        page.when(self.state.pending_conflict().is_some(), |view| {
            view.child(self.unsaved_answer_panel(cx))
        })
    }
    fn suggestion(
        &self,
        id: &'static str,
        glyph: Icon,
        label: Text,
        prompt: Text,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        div()
            .id(id)
            .flex_1()
            .min_w(px(0.))
            .min_h(px(96.))
            .p_3()
            .rounded(px(16.))
            .border_1()
            .border_color(p.line)
            .bg(p.composer)
            .flex()
            .flex_col()
            .justify_between()
            .gap_3()
            .cursor_pointer()
            .hover(|s| s.bg(p.surface).border_color(p.faint))
            .text_size(px(13.))
            .line_height(px(20.))
            .text_color(p.muted)
            .child(icon(glyph, 19., p.text))
            .child(self.locale.text(label))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.composer.update(cx, |input, cx| {
                    input.set_text(this.locale.text(prompt).into(), cx)
                });
            }))
    }
}
