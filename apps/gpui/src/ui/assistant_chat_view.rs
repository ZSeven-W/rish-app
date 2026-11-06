//! The personal assistant uses its own durable conversation. A task's writer
//! lease must never render that task's transcript under the personal identity.
use super::{assistant_copy as words, assistant_view::Action, *};
use crate::icons::{Icon, icon};
use gpui::AnyElement;

pub(super) const TASK_PANEL_WIDTH: f32 = 300.;
pub(super) const TASK_PANEL_BREAKPOINT: f32 = 720.;
const PANEL_GAP: f32 = 12.;

impl Shell {
    pub(super) fn assistant_personal_chat_ready(&self) -> bool {
        !self.assistant.directory_ui.hub_open
            && self.assistant.directory_ui.group_id.is_none()
            && self.assistant.directory_ui.pending_bot_id.is_none()
            && !self.assistant_writer_lease
            && self.state.is_loaded()
            && self
                .assistant
                .snapshot
                .store
                .as_ref()
                .and_then(|store| store.conversation_id.as_deref())
                .is_some_and(|id| self.state.active_conversation_id() == Some(id))
    }

    pub(super) fn assistant_chat_visible(&self, content_width: f32) -> bool {
        (self.assistant_group_visible() || self.assistant_personal_chat_ready())
            && (content_width >= TASK_PANEL_BREAKPOINT || !self.assistant.tasks_open)
    }

    pub(super) fn chat_input_visible(&self, content_width: f32, workspace_modal: bool) -> bool {
        if self.runtime.is_native() && self.assistant.directory().is_none() {
            return false;
        }
        let agent_decision = self.state.agent_view().is_some_and(|view| {
            view.approval.is_some() || view.question.is_some_and(|q| q.input_mode == "options")
        });
        (matches!(self.page, Page::Chat | Page::Files | Page::Git)
            || (self.page == Page::Assistant && self.assistant_chat_visible(content_width)))
            && self.state.is_loaded()
            && !self.drawer_open
            && !self.model_picker
            && !self.assistant.profile_menu_open
            && !self.native_form_active
            && !agent_decision
            && !workspace_modal
            && !(self.workspace_focus && matches!(self.page, Page::Files | Page::Git))
    }

    pub(super) fn assistant_page(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if self.assistant.directory_ui.hub_open {
            return self.assistant_hub(width, cx);
        }
        if self.assistant.directory_ui.group_id.is_some() {
            return self.assistant_group_page(width, height, cx);
        }
        let wide = width >= TASK_PANEL_BREAKPOINT;
        let mut page = div()
            .id("assistant-page")
            .debug_selector(|| "assistant-page".into())
            .flex_1()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .flex_col()
            .overflow_hidden();
        if let Some(error) = self.assistant.error.as_ref().or(self
            .assistant
            .snapshot
            .message
            .as_ref())
        {
            page = page.child(div().px_3().pb_2().child(self.assistant_hint(
                "assistant-error",
                words::message(self.locale, error),
                true,
                cx,
            )));
        }
        if !wide && self.assistant.tasks_open {
            return page
                .child(self.assistant_task_panel(height, true, cx))
                .into_any_element();
        }
        let chat_width = (width
            - if wide {
                TASK_PANEL_WIDTH + PANEL_GAP
            } else {
                0.
            })
        .max(0.);
        let chat = if self.assistant_personal_chat_ready() {
            self.chat(height < 600., chat_width, height, cx)
                .into_any_element()
        } else if self.assistant_writer_lease {
            self.assistant_running_task(height, cx)
        } else {
            self.assistant_waiting_chat(cx)
        };
        page.child(
            div()
                .flex_1()
                .min_h(px(0.))
                .min_w(px(0.))
                .flex()
                .gap(px(PANEL_GAP))
                .child(
                    div()
                        .id("assistant-chat-pane")
                        .debug_selector(|| "assistant-chat-pane".into())
                        .flex_1()
                        .min_w(px(0.))
                        .min_h(px(0.))
                        .h_full()
                        .flex()
                        .flex_col()
                        .child(chat),
                )
                .when(wide, |v| {
                    v.child(
                        div()
                            .w(px(TASK_PANEL_WIDTH))
                            .flex_shrink_0()
                            .h_full()
                            .min_h(px(0.))
                            .border_l_1()
                            .border_color(Palette::get(cx).line)
                            .child(self.assistant_task_panel(height, false, cx)),
                    )
                }),
        )
        .into_any_element()
    }

    pub(super) fn assistant_header_identity(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.assistant.directory_ui.hub_open || self.assistant.directory_ui.group_id.is_some() {
            return self.assistant_directory_header(cx);
        }
        let name = self
            .assistant
            .visible_profile()
            .map(|p| p.name.as_str())
            .unwrap_or("Rish");
        div()
            .id("assistant-chat-identity")
            .debug_selector(|| "assistant-chat-identity".into())
            .flex_1()
            .min_w(px(0.))
            .flex()
            .items_center()
            .gap_2()
            .child(self.assistant_hub_back_button(cx))
            .child(self.assistant_avatar_button("assistant-profile-avatar", 40., cx))
            .child(
                div()
                    .id("assistant-profile-name")
                    .debug_selector(|| "assistant-profile-name".into())
                    .min_w(px(0.))
                    .flex_1()
                    .truncate()
                    .text_size(px(16.))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(name.to_owned()),
            )
            .into_any_element()
    }

    pub(super) fn assistant_tasks_button(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let memory = self.assistant.panel == super::assistant_memory_state::AssistantPanel::Memory;
        let label = if memory {
            words::copy(self.locale, "Memory", "记忆")
        } else {
            words::copy(self.locale, "Tasks", "任务")
        };
        div()
            .id("assistant-tasks-toggle")
            .debug_selector(|| "assistant-tasks-toggle".into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .aria_expanded(self.assistant.tasks_open)
            .min_h(px(44.))
            .min_w(px(44.))
            .flex_shrink_0()
            .px_2()
            .rounded(px(12.))
            .flex()
            .items_center()
            .gap_1()
            .cursor_pointer()
            .hover(|v| v.bg(p.surface))
            .child(icon(
                if memory {
                    Icon::MessagesSquare
                } else {
                    Icon::ListChecks
                },
                18.,
                p.muted,
            ))
            .child(div().text_size(px(13.)).child(label))
            .on_click(cx.listener(|this, _, _, cx| this.assistant_action(Action::ToggleTasks, cx)))
            .into_any_element()
    }

    pub(super) fn assistant_welcome(&self, compact: bool, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let name = self
            .assistant
            .visible_profile()
            .map(|p| p.name.as_str())
            .unwrap_or("Rish");
        let greeting = if self.locale == Locale::Zh {
            format!("你好，我是 {name}")
        } else {
            format!("Hi, I’m {name}")
        };
        div().id("assistant-welcome").debug_selector(|| "assistant-welcome".into())
            .flex_1().min_h(px(0.)).w_full().overflow_y_scroll().px_5().py_4()
            .flex().flex_col().items_center().justify_center().gap_4()
            .child(self.assistant_identity_mark(if compact { 56. } else { 72. }, cx))
            .child(div().max_w(px(460.)).w_full().text_size(px(if compact { 22. } else { 27. }))
                .line_height(px(if compact { 29. } else { 35. })).font_weight(gpui::FontWeight::SEMIBOLD)
                .text_center().whitespace_normal().child(greeting))
            .child(div().max_w(px(370.)).text_size(px(14.)).line_height(px(23.))
                .text_color(p.muted).text_center().whitespace_normal()
                .child(words::copy(self.locale,
                    "Tell me what’s on your mind. We can talk it through, make a plan, and I’ll help create and follow up on tasks.",
                    "想法、琐事，或者想做的事，都可以和我聊。我会陪你理清思路，帮你建立任务、安排跟进。")))
            .into_any_element()
    }

    fn assistant_waiting_chat(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        div()
            .id("assistant-chat-preparing")
            .debug_selector(|| "assistant-chat-preparing".into())
            .size_full()
            .min_h(px(0.))
            .flex()
            .flex_col()
            .child(self.assistant_welcome(true, cx))
            .child(
                div()
                    .px_5()
                    .pb_5()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .text_center()
                    .child(words::copy(
                        self.locale,
                        "Preparing your conversation…",
                        "正在准备与你的对话…",
                    )),
            )
            .into_any_element()
    }

    fn assistant_running_task(&self, height: f32, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let task = self.assistant.snapshot.store.as_ref().and_then(|store| {
            store.tasks.iter().find(|task| {
                Some(task.id.as_str()) == self.assistant.snapshot.active_task_id.as_deref()
            })
        });
        let mut body = div()
            .id("assistant-task-running")
            .debug_selector(|| "assistant-task-running".into())
            .flex_1()
            .min_h(px(0.))
            .w_full()
            .overflow_y_scroll()
            .p_4()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_size(px(15.))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(icon(Icon::Clock, 20., p.muted))
                    .child(words::copy(
                        self.locale,
                        "Working on a task",
                        "正在处理任务",
                    )),
            )
            .child(
                div()
                    .text_size(px(18.))
                    .line_height(px(26.))
                    .whitespace_normal()
                    .child(task.map(|task| task.title.clone()).unwrap_or_else(|| {
                        words::copy(self.locale, "Current task", "当前任务").into()
                    })),
            )
            .child(
                div()
                    .text_size(px(13.))
                    .line_height(px(21.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(words::copy(
                        self.locale,
                        "Your personal chat will return when this task finishes or stops.",
                        "任务完成或停止后，就会回到我们的聊天。",
                    )),
            );
        if let Some(task) = task {
            body = body.child(self.assistant_button(
                "assistant-running-open",
                words::copy(self.locale, "Open task conversation", "打开任务对话"),
                Icon::MessageSquare,
                true,
                Action::Open(task.conversation_id.clone()),
                cx,
            ));
        }
        if let Some(panel) = self.assistant_active_panel(height, cx) {
            body = body.child(
                div()
                    .id("assistant-active-scroll")
                    .debug_selector(|| "assistant-active-scroll".into())
                    .min_h(px(0.))
                    .flex_shrink_0()
                    .child(panel),
            );
        } else {
            body = body.child(
                div()
                    .id("assistant-running-stop")
                    .debug_selector(|| "assistant-running-stop".into())
                    .role(gpui::Role::Button)
                    .min_h(px(44.))
                    .px_3()
                    .flex()
                    .items_center()
                    .gap_2()
                    .cursor_pointer()
                    .child(icon(Icon::Square, 16., p.danger))
                    .child(words::copy(self.locale, "Stop task", "停止任务"))
                    .on_click(cx.listener(|this, _, _, cx| this.stop_agent_task(cx))),
            );
        }
        body.into_any_element()
    }
}
