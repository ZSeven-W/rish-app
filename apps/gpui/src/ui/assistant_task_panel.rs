//! Secondary task management stays usable at the same width as a phone.
use super::assistant_memory_state::{AssistantPanel, MemoryAction};
use super::{assistant_copy as words, assistant_view::Action, *};
use crate::icons::Icon;
use gpui::AnyElement;

impl Shell {
    pub(super) fn assistant_task_panel(
        &self,
        height: f32,
        dismissible: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let body = if self.assistant.panel == AssistantPanel::Memory {
            self.assistant_memory_panel(cx)
        } else if self.assistant.editor.is_some() {
            self.assistant_editor(cx)
        } else if let Some(task) = self.assistant.selected_task() {
            self.assistant_detail(task, false, height, cx)
        } else {
            self.assistant_list(cx)
        };
        div()
            .id("assistant-task-panel")
            .debug_selector(|| "assistant-task-panel".into())
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .flex_col()
            .gap_3()
            .px_3()
            .pb_3()
            .child(
                div()
                    .flex_shrink_0()
                    .min_h(px(48.))
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .flex_1()
                            .min_w(px(0.))
                            .gap_1()
                            .child(self.assistant_panel_tab(
                                "assistant-tab-tasks",
                                AssistantPanel::Tasks,
                                cx,
                            ))
                            .child(self.assistant_panel_tab(
                                "assistant-tab-memory",
                                AssistantPanel::Memory,
                                cx,
                            )),
                    )
                    .when(dismissible, |v| {
                        v.child(self.assistant_icon_button(
                            "assistant-tasks-close",
                            words::copy(self.locale, "Back to chat", "返回聊天"),
                            Icon::X,
                            !self.assistant.form_busy(),
                            Action::CloseTasks,
                            cx,
                        ))
                    }),
            )
            .child(
                div()
                    .id("assistant-detail-pane")
                    .debug_selector(|| "assistant-detail-pane".into())
                    .flex_1()
                    .min_h(px(0.))
                    .min_w(px(0.))
                    .flex()
                    .flex_col()
                    .text_color(p.text)
                    .child(body),
            )
            .into_any_element()
    }
    fn assistant_panel_tab(
        &self,
        id: &'static str,
        panel: AssistantPanel,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let enabled = !self.assistant.form_busy();
        let selected = self.assistant.panel == panel;
        let label = match panel {
            AssistantPanel::Tasks => words::copy(self.locale, "Tasks", "任务"),
            AssistantPanel::Memory => words::copy(self.locale, "Memory", "记忆"),
        };
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .min_h(px(44.))
            .min_w(px(44.))
            .px_3()
            .rounded(px(12.))
            .flex()
            .items_center()
            .justify_center()
            .text_size(px(13.))
            .font_weight(if selected {
                gpui::FontWeight::SEMIBOLD
            } else {
                gpui::FontWeight::NORMAL
            })
            .text_color(if selected { p.text } else { p.muted })
            .when(selected, |v| v.bg(p.surface))
            .when(enabled, |v| v.cursor_pointer())
            .child(label)
            .on_click(cx.listener(move |this, _, _, cx| {
                if enabled {
                    this.assistant_memory_action(
                        match panel {
                            AssistantPanel::Tasks => MemoryAction::Tasks,
                            AssistantPanel::Memory => MemoryAction::Open,
                        },
                        cx,
                    );
                }
            }))
            .into_any_element()
    }
}
