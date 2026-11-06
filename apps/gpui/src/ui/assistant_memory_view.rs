use super::{
    assistant_copy as words,
    assistant_memory_state::*,
    assistant_view::{Action, preview},
    *,
};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};
use rish_shell_core::assistant_store::{AssistantMemory, AssistantMemoryKind};

pub(super) fn memory_kind(kind: AssistantMemoryKind, locale: Locale) -> &'static str {
    match kind {
        AssistantMemoryKind::Preference => words::copy(locale, "Preference", "偏好"),
        AssistantMemoryKind::Fact => words::copy(locale, "Fact", "事实"),
        AssistantMemoryKind::Decision => words::copy(locale, "Decision", "决定"),
    }
}
impl Shell {
    pub(super) fn assistant_memory_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.assistant.memory.editor.is_some() {
            return self.assistant_memory_editor(cx);
        }
        if let Some(memory) = self
            .assistant
            .snapshot
            .store
            .as_ref()
            .and_then(|s| self.assistant.memory.selected(s))
        {
            return self.assistant_memory_detail(memory, cx);
        }
        let p = Palette::get(cx);
        let available = self.runtime.is_native()
            && self.assistant.snapshot.store.is_some()
            && !self.assistant.form_busy();
        let mut memories = self
            .assistant
            .snapshot
            .store
            .as_ref()
            .map(|s| s.memories.iter().collect::<Vec<_>>())
            .unwrap_or_default();
        memories.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms).then(a.id.cmp(&b.id)));
        let mut list = div()
            .id("assistant-memory-list")
            .debug_selector(|| "assistant-memory-list".into())
            .flex_1()
            .min_h(px(0.))
            .min_w(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.assistant.memory.scroll)
            .flex()
            .flex_col()
            .gap_3()
            .pb_3()
            .child(
                div()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(15.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(words::copy(self.locale, "What I remember", "我记住的事")),
                    )
                    .child(self.assistant_icon_button(
                        "assistant-memory-new",
                        words::copy(self.locale, "New memory", "添加记忆"),
                        Icon::Plus,
                        available,
                        Action::Memory(MemoryAction::New),
                        cx,
                    )),
            );
        if memories.is_empty() {
            list = list.child(
                self.assistant_group(cx)
                    .p_4()
                    .gap_3()
                    .child(icon(Icon::MessagesSquare, 24., p.faint))
                    .child(div().text_size(px(14.)).child(words::copy(
                        self.locale,
                        "No memories yet",
                        "还没有记忆",
                    )))
                    .child(
                        div()
                            .text_size(px(12.))
                            .line_height(px(20.))
                            .text_color(p.muted)
                            .whitespace_normal()
                            .child(words::copy(
                                self.locale,
                                "Tell me what matters to you in chat, or add a memory here.",
                                "在聊天里告诉我想记住的事，也可以在这里手动添加。",
                            )),
                    ),
            );
        }
        for memory in memories {
            let id = memory.id.clone();
            let selector = format!("assistant-memory-{}", memory.id);
            let enabled = !self.assistant.form_busy();
            list = list.child(
                div()
                    .id(selector.clone())
                    .debug_selector(move || selector.clone())
                    .role(gpui::Role::Button)
                    .aria_label(memory.title.clone())
                    .w_full()
                    .min_w(px(0.))
                    .min_h(px(72.))
                    .flex_shrink_0()
                    .p_3()
                    .rounded(px(16.))
                    .bg(p.composer)
                    .border_1()
                    .border_color(p.line)
                    .flex()
                    .flex_col()
                    .gap_1()
                    .when(enabled, |v| v.cursor_pointer().hover(|v| v.bg(p.surface)))
                    .child(
                        div()
                            .text_size(px(13.))
                            .font_weight(FontWeight::MEDIUM)
                            .truncate()
                            .child(memory.title.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(11.))
                            .text_color(p.muted)
                            .child(memory_kind(memory.kind, self.locale)),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .truncate()
                            .child(preview(&memory.content, 64)),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if enabled {
                            this.assistant_memory_action(MemoryAction::Select(id.clone()), cx);
                        }
                    })),
            );
        }
        list.child(
            div()
                .flex_shrink_0()
                .text_size(px(11.))
                .line_height(px(18.))
                .text_color(p.muted)
                .whitespace_normal()
                .child(words::copy(
                    self.locale,
                    "Stored on this device. You can review, edit or delete any memory.",
                    "保存在这台设备上，你可以随时查看、修改或删除。",
                )),
        )
        .into_any_element()
    }

    fn assistant_memory_detail(
        &self,
        memory: &AssistantMemory,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let available = self.runtime.is_native() && !self.assistant.form_busy();
        let mut detail = div()
            .id("assistant-memory-detail")
            .debug_selector(|| "assistant-memory-detail".into())
            .flex_1()
            .min_h(px(0.))
            .min_w(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.assistant.memory.scroll)
            .flex()
            .flex_col()
            .gap_3()
            .pb_3()
            .child(self.assistant_button(
                "assistant-memory-back",
                words::copy(self.locale, "All memories", "所有记忆"),
                Icon::ChevronLeft,
                !self.assistant.form_busy(),
                Action::Memory(MemoryAction::Back),
                cx,
            ))
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(21.))
                    .line_height(px(28.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .whitespace_normal()
                    .child(memory.title.clone()),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .child(memory_kind(memory.kind, self.locale)),
            )
            .child(
                div()
                    .id("assistant-memory-content")
                    .debug_selector(|| "assistant-memory-content".into())
                    .flex_shrink_0()
                    .text_size(px(14.))
                    .line_height(px(23.))
                    .whitespace_normal()
                    .child(memory.content.clone()),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(11.))
                    .line_height(px(18.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(format!(
                        "{} · {}",
                        if memory.source_conversation_id.is_some() {
                            words::copy(self.locale, "From a conversation", "来自聊天")
                        } else {
                            words::copy(self.locale, "Added manually", "手动添加")
                        },
                        words::time(self.locale, Some(memory.updated_at_ms))
                    )),
            )
            .child(self.assistant_button(
                "assistant-memory-edit",
                words::copy(self.locale, "Edit memory", "编辑记忆"),
                Icon::SquarePen,
                available,
                Action::Memory(MemoryAction::Edit(memory.id.clone())),
                cx,
            ))
            .child(self.assistant_button(
                "assistant-memory-delete",
                words::copy(self.locale, "Delete memory", "删除记忆"),
                Icon::Trash2,
                available,
                Action::Memory(MemoryAction::Delete(memory.id.clone())),
                cx,
            ));
        if let Some(deletion) = &self.assistant.memory.deletion {
            detail = detail.child(
                self.assistant_group(cx)
                    .id("assistant-memory-delete-confirmation")
                    .debug_selector(|| "assistant-memory-delete-confirmation".into())
                    .p_3()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(13.))
                            .line_height(px(20.))
                            .whitespace_normal()
                            .child(format!(
                                "{}{}",
                                words::copy(self.locale, "Delete this memory? ", "删除这条记忆？"),
                                deletion.memory.title
                            )),
                    )
                    .child(self.assistant_button(
                        "assistant-memory-delete-cancel",
                        words::copy(self.locale, "Keep memory", "保留记忆"),
                        Icon::X,
                        !deletion.saving,
                        Action::Memory(MemoryAction::CancelDelete),
                        cx,
                    ))
                    .child(self.assistant_button(
                        "assistant-memory-delete-confirm",
                        words::copy(self.locale, "Delete memory", "删除记忆"),
                        Icon::Trash2,
                        self.runtime.is_native() && !deletion.saving,
                        Action::Memory(MemoryAction::ConfirmDelete),
                        cx,
                    )),
            );
        }
        detail.into_any_element()
    }

    fn assistant_memory_editor(&self, cx: &mut Context<Self>) -> AnyElement {
        let editor = self.assistant.memory.editor.as_ref().unwrap();
        let available = self.runtime.is_native() && !self.assistant.form_busy();
        let p = Palette::get(cx);
        let mut body = div()
            .id("assistant-memory-editor-scroll")
            .debug_selector(|| "assistant-memory-editor-scroll".into())
            .flex_1()
            .min_h(px(0.))
            .min_w(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.assistant.memory.scroll)
            .flex()
            .flex_col()
            .gap_3()
            .pb_3()
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(16.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(words::copy(
                        self.locale,
                        if editor.memory_id.is_some() {
                            "Edit memory"
                        } else {
                            "New memory"
                        },
                        if editor.memory_id.is_some() {
                            "编辑记忆"
                        } else {
                            "添加记忆"
                        },
                    )),
            )
            .child(
                self.assistant_group(cx)
                    .child(self.assistant_editor_text(
                        "assistant-memory-editor-title",
                        words::copy(self.locale, "Title", "标题"),
                        &editor.title,
                        false,
                        available,
                        Action::Memory(MemoryAction::Field(MemoryField::Title)),
                        cx,
                    ))
                    .child(super::assistant_primitives::divider(cx))
                    .child(self.assistant_editor_text(
                        "assistant-memory-editor-content",
                        words::copy(self.locale, "Content", "内容"),
                        &editor.content,
                        true,
                        available,
                        Action::Memory(MemoryAction::Field(MemoryField::Content)),
                        cx,
                    )),
            );
        let mut kinds = div().flex_shrink_0().flex().flex_wrap().gap_2();
        for (index, kind) in [
            AssistantMemoryKind::Preference,
            AssistantMemoryKind::Fact,
            AssistantMemoryKind::Decision,
        ]
        .into_iter()
        .enumerate()
        {
            let selected = editor.kind == kind;
            kinds = kinds.child(
                div()
                    .id(format!("assistant-memory-kind-{index}"))
                    .role(gpui::Role::Button)
                    .aria_label(memory_kind(kind, self.locale))
                    .min_h(px(44.))
                    .min_w(px(44.))
                    .px_3()
                    .rounded(px(12.))
                    .border_1()
                    .border_color(if selected { p.accent } else { p.line })
                    .bg(if selected { p.surface } else { p.composer })
                    .flex()
                    .items_center()
                    .text_size(px(12.))
                    .when(available, |v| v.cursor_pointer())
                    .child(memory_kind(kind, self.locale))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if available {
                            this.assistant_memory_action(MemoryAction::Kind(kind), cx);
                        }
                    })),
            );
        }
        body = body.child(kinds);
        if editor.conflicted {
            body = body.child(self.assistant_hint(
                "assistant-memory-conflict",
                words::copy(
                    self.locale,
                    "The saved memory changed. Your draft is kept.",
                    "已保存的记忆发生了变化，你的草稿仍然保留。",
                ),
                true,
                cx,
            ));
            if let Some(saved) = self
                .assistant
                .snapshot
                .store
                .as_ref()
                .and_then(|s| s.memories.iter().find(|m| m.id == editor.id))
            {
                body = body
                    .child(
                        self.assistant_group(cx)
                            .p_3()
                            .gap_2()
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(p.muted)
                                    .child(words::copy(
                                        self.locale,
                                        "Saved version",
                                        "已保存的版本",
                                    )),
                            )
                            .child(
                                div()
                                    .text_size(px(13.))
                                    .whitespace_normal()
                                    .child(saved.title.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .line_height(px(19.))
                                    .whitespace_normal()
                                    .child(saved.content.clone()),
                            ),
                    )
                    .child(self.assistant_button(
                        "assistant-memory-overwrite",
                        words::copy(self.locale, "Save my version", "保存我的版本"),
                        Icon::Check,
                        available,
                        Action::Memory(MemoryAction::Overwrite),
                        cx,
                    ));
            }
        }
        div()
            .id("assistant-memory-editor")
            .debug_selector(|| "assistant-memory-editor".into())
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .flex_col()
            .gap_2()
            .child(body)
            .child(
                div()
                    .flex_shrink_0()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(self.assistant_primary_button(
                        "assistant-memory-save",
                        words::copy(
                            self.locale,
                            if editor.saving {
                                "Saving…"
                            } else {
                                "Save memory"
                            },
                            if editor.saving {
                                "保存中…"
                            } else {
                                "保存记忆"
                            },
                        ),
                        Icon::Check,
                        available,
                        Action::Memory(MemoryAction::Save),
                        cx,
                    ))
                    .child(self.assistant_button(
                        "assistant-memory-cancel",
                        words::copy(self.locale, "Cancel", "取消"),
                        Icon::X,
                        !self.assistant.form_busy(),
                        Action::Memory(MemoryAction::Cancel),
                        cx,
                    )),
            )
            .into_any_element()
    }
}
