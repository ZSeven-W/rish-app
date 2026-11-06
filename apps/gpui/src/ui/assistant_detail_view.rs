use super::{assistant_copy as words, assistant_primitives::divider, assistant_view::Action, *};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};
use rish_shell_core::assistant_store::{AssistantRunStatus, AssistantTask};

impl Shell {
    pub(super) fn assistant_detail(
        &self,
        task: &AssistantTask,
        wide: bool,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let running = task.is_running();
        let available = self.runtime.is_native() && !self.assistant.form_busy();
        let attention = task
            .last_run
            .as_ref()
            .is_some_and(|r| r.status == AssistantRunStatus::NeedsAttention);
        let has_conversation = self
            .state
            .conversations()
            .iter()
            .any(|c| c.id == task.conversation_id);
        let mut top = div()
            .flex_shrink_0()
            .flex()
            .items_center()
            .justify_between()
            .gap_3();
        if !wide {
            top = top.child(self.assistant_icon_button(
                "assistant-back",
                words::copy(self.locale, "All tasks", "所有任务"),
                Icon::ChevronLeft,
                !self.assistant.form_busy(),
                Action::Back,
                cx,
            ));
        } else {
            top = top.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .child(icon(Icon::Folder, 16., p.muted))
                    .child(words::copy(self.locale, "Local task", "本机任务")),
            );
        }
        top = top.child(self.assistant_icon_button(
            "assistant-more",
            words::copy(self.locale, "More task actions", "更多任务操作"),
            Icon::Ellipsis,
            !self.assistant.form_busy(),
            Action::ToggleTaskMenu,
            cx,
        ));
        let mut content = div()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .gap_4()
            .child(top)
            .when(self.assistant.task_menu_open, |v| {
                v.child(
                    self.assistant_group(cx)
                        .child(self.assistant_setting_row(
                            "assistant-edit",
                            words::copy(self.locale, "Edit task", "编辑任务"),
                            "",
                            Icon::SquarePen,
                            available && !running,
                            Action::Edit(task.id.clone()),
                            cx,
                        ))
                        .child(divider(cx))
                        .child(self.assistant_setting_row(
                            "assistant-delete",
                            words::copy(self.locale, "Delete task", "删除任务"),
                            "",
                            Icon::Trash2,
                            available && !running,
                            Action::Delete(task.id.clone()),
                            cx,
                        )),
                )
            })
            .child(
                div()
                    .px_1()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .when(!wide, |v| {
                        v.child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .text_size(px(12.))
                                .text_color(p.muted)
                                .child(icon(Icon::Folder, 16., p.muted))
                                .child(words::copy(self.locale, "Local task", "本机任务")),
                        )
                    })
                    .child(
                        div()
                            .id("assistant-task-title")
                            .max_h(px(128.))
                            .overflow_y_scroll()
                            .text_size(px(24.))
                            .line_height(px(32.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .whitespace_normal()
                            .child(task.title.clone()),
                    )
                    .child(
                        div()
                            .id("assistant-task-instructions")
                            .max_h(px(144.))
                            .overflow_y_scroll()
                            .text_size(px(14.))
                            .line_height(px(22.))
                            .text_color(p.muted)
                            .whitespace_normal()
                            .child(task.instructions.clone()),
                    ),
            )
            .child(
                self.assistant_group(cx)
                    .child(self.assistant_setting_row(
                        "assistant-detail-workspace",
                        words::copy(self.locale, "Workspace", "工作空间"),
                        words::workspace_name(&task.workspace_descriptor, self.locale),
                        Icon::Folder,
                        available && !running && task.last_run.is_none(),
                        Action::Edit(task.id.clone()),
                        cx,
                    ))
                    .child(divider(cx))
                    .child(self.assistant_setting_row(
                        "assistant-detail-model",
                        words::copy(self.locale, "Model", "模型"),
                        self.assistant_model_name(&task.model_id),
                        Icon::Box,
                        available && !running,
                        Action::Edit(task.id.clone()),
                        cx,
                    ))
                    .child(divider(cx))
                    .child(self.assistant_setting_row(
                        "assistant-detail-schedule",
                        words::copy(self.locale, "Follow-up", "跟进"),
                        words::interval(self.locale, task.interval_minutes),
                        Icon::Play,
                        available && !running,
                        Action::Edit(task.id.clone()),
                        cx,
                    )),
            );
        if task.interval_minutes.is_some() {
            content = content.child(
                div()
                    .flex_shrink_0()
                    .px_1()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .whitespace_normal()
                            .child(format!(
                                "{} · {}",
                                words::copy(self.locale, "Next eligible time", "下次可跟进时间"),
                                words::time(self.locale, task.next_due_ms)
                            )),
                    )
                    .child(self.assistant_button(
                        "assistant-toggle-enabled",
                        words::copy(
                            self.locale,
                            if task.enabled {
                                "Pause follow-ups"
                            } else {
                                "Enable follow-ups"
                            },
                            if task.enabled {
                                "暂停跟进"
                            } else {
                                "启用跟进"
                            },
                        ),
                        if task.enabled {
                            Icon::Square
                        } else {
                            Icon::RefreshCw
                        },
                        available,
                        Action::Enabled(task.id.clone(), !task.enabled),
                        cx,
                    )),
            );
        }
        if attention {
            content=content.child(self.assistant_hint("assistant-needs-attention",words::copy(self.locale,
                "Review this run before continuing. A tool may already have changed the workspace.",
                "请先核对本次运行，部分工作空间改动可能已完成。"),true,cx))
                .child(self.assistant_button("assistant-reconcile",words::copy(self.locale,"Check saved run","核对运行记录"),
                    Icon::RefreshCw,available,Action::Recover(task.id.clone()),cx));
        }
        if let Some(run) = &task.last_run {
            let color = match run.status {
                AssistantRunStatus::Completed => p.success,
                AssistantRunStatus::Failed | AssistantRunStatus::NeedsAttention => p.danger,
                _ => p.muted,
            };
            content = content.child(
                div()
                    .id("assistant-last-run")
                    .debug_selector(|| "assistant-last-run".into())
                    .flex_shrink_0()
                    .p_4()
                    .rounded(px(20.))
                    .bg(p.surface)
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .child(words::copy(self.locale, "Last run", "最近运行")),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .items_center()
                            .gap_2()
                            .text_size(px(12.))
                            .child(icon(
                                if run.status == AssistantRunStatus::Completed {
                                    Icon::Check
                                } else {
                                    Icon::Clock
                                },
                                16.,
                                color,
                            ))
                            .child(
                                div()
                                    .text_color(color)
                                    .font_weight(FontWeight::MEDIUM)
                                    .child(words::run(self.locale, run.status)),
                            )
                            .child(
                                div()
                                    .text_color(p.muted)
                                    .child(words::time(self.locale, Some(run.started_at_ms))),
                            ),
                    )
                    .when_some(run.result_summary.clone(), |v, summary| {
                        v.child(
                            div()
                                .id("assistant-run-summary")
                                .max_h(px(120.))
                                .overflow_y_scroll()
                                .text_size(px(13.))
                                .line_height(px(20.))
                                .whitespace_normal()
                                .text_color(p.muted)
                                .child(summary),
                        )
                    })
                    .when_some(run.failure_code.clone(), |v, error| {
                        v.child(
                            div()
                                .text_size(px(13.))
                                .line_height(px(20.))
                                .whitespace_normal()
                                .text_color(p.danger)
                                .child(words::failure(self.locale, &error)),
                        )
                    }),
            );
        } else {
            content = content.child(
                div()
                    .flex_shrink_0()
                    .px_1()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .child(words::copy(
                        self.locale,
                        "This task has not run yet.",
                        "任务尚未运行。",
                    )),
            );
        }
        let actions = div()
            .id("assistant-detail-actions")
            .debug_selector(|| "assistant-detail-actions".into())
            .flex_shrink_0()
            .flex()
            .flex_col()
            .gap_2()
            .child(self.assistant_primary_button(
                "assistant-run",
                words::copy(self.locale, "Run once", "运行一次"),
                Icon::Play,
                available
                    && !running
                    && !task.pending_manual
                    && !self.assistant.snapshot.owns_writer,
                Action::Run(task.id.clone()),
                cx,
            ))
            .child(self.assistant_secondary_button(
                "assistant-open-conversation",
                words::copy(self.locale, "View conversation", "查看会话"),
                Icon::MessageSquare,
                available && has_conversation,
                Action::Open(task.conversation_id.clone()),
                cx,
            ));
        let mut footer = div()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .gap_3()
            .child(actions);
        if self
            .assistant
            .deletion
            .as_ref()
            .is_some_and(|d| d.task_id == task.id)
        {
            footer = footer.child(self.assistant_delete_confirmation(cx));
        }
        let mut scroll = div()
            .id("assistant-detail-scroll")
            .debug_selector(|| "assistant-detail-scroll".into())
            .min_h(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.assistant.detail_scroll)
            .flex()
            .flex_col()
            .gap_4()
            .pb_2()
            .child(content);
        // On short windows all task controls scroll together, leaving the
        // separate active decision viewport free of clipped fixed headers.
        if height < 600. {
            scroll.size_full().child(footer).into_any_element()
        } else {
            scroll = scroll.flex_1();
            div()
                .size_full()
                .min_h(px(0.))
                .flex()
                .flex_col()
                .gap_4()
                .child(scroll)
                .child(footer)
                .into_any_element()
        }
    }

    pub(super) fn assistant_model_name(&self, id: &str) -> String {
        self.state
            .models()
            .into_iter()
            .find(|m| m.id == id)
            .map(|m| m.name)
            .unwrap_or_else(|| {
                if id.is_empty() {
                    words::copy(self.locale, "Choose an existing model", "选择已配置模型").into()
                } else {
                    id.into()
                }
            })
    }
}
