use super::{agent_copy, *};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};
use rish_shell_core::AgentView;

impl Shell {
    fn assistant_operation_preview(&self, preview: &Value, cx: &Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let target = preview["title"].as_str().map(str::to_owned).or_else(|| {
            // Never reconstruct text deliberately omitted by the shared preview.
            if preview["truncated"] == true {
                return None;
            }
            let id = preview["target_id"].as_str()?;
            let store = self.assistant.snapshot.store.as_ref()?;
            store
                .tasks
                .iter()
                .find(|task| task.id == id)
                .map(|task| task.title.clone())
                .or_else(|| {
                    store
                        .memories
                        .iter()
                        .find(|memory| memory.id == id)
                        .map(|memory| memory.title.clone())
                })
        });
        let content = preview["content_preview"].as_str().unwrap_or("");
        div()
            .flex()
            .flex_col()
            .gap_1()
            .text_color(p.muted)
            .whitespace_normal()
            .when_some(target, |row, title| {
                row.child(div().text_color(p.text).child(title))
            })
            .when(!content.is_empty(), |row| row.child(content.to_owned()))
            .when(preview["truncated"] == true, |row| {
                row.child(agent_copy::copy(
                    self.locale,
                    "Some content is omitted from this preview.",
                    "部分内容已在预览中省略。",
                ))
            })
    }

    pub(super) fn agent_panel(
        &self,
        view: AgentView,
        available_height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let zh = self.locale;
        let needs_account = view.failure_code.as_deref() == Some("E_AGENT_PROVIDER_CREDENTIAL");
        let phase = if view.approval.is_some() {
            "awaiting_approval"
        } else if view.question.is_some() {
            "awaiting_question"
        } else {
            &view.phase
        };
        let interactive = !self.loading && !self.agent_request_in_flight();
        let mut content = div()
            .id("agent-progress-scroll")
            .debug_selector(|| "agent-progress-scroll".into())
            .w_full()
            .max_h(px((available_height * 0.38).clamp(96., 300.)))
            .overflow_y_scroll()
            .track_scroll(&self.agent_scroll)
            .flex()
            .flex_col()
            .gap_2()
            .p_3();
        if let Some(code) = &view.failure_code {
            content = content.child(
                div()
                    .text_size(px(13.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(agent_copy::failure(zh, code)),
            );
        }
        if view.preview_incomplete {
            content = content.child(
                div()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(agent_copy::copy(
                        zh,
                        "Live preview is incomplete. The saved result will replace it.",
                        "实时预览暂不完整，将以保存后的结果更新。",
                    )),
            );
        }
        if matches!(
            view.phase.as_str(),
            "unknown" | "ambiguous" | "manual_reconciliation"
        ) {
            content = content.child(div().text_size(px(12.)).text_color(p.danger).whitespace_normal()
                .child(agent_copy::copy(zh, "A tool may have changed your workspace. Check its saved result before running it again.", "工具可能已经修改工作空间。请先核对保存的结果，避免重复执行。")));
        }
        for (index, tool) in view.tools.iter().enumerate() {
            let done = matches!(
                tool.status.as_str(),
                "succeeded" | "completed" | "executed" | "ok"
            );
            let failed = matches!(tool.status.as_str(), "failed" | "denied" | "cancelled");
            let color = if failed { p.danger } else { p.muted };
            content = content.child(
                div()
                    .id(("agent-tool", index))
                    .flex()
                    .items_start()
                    .gap_2()
                    .text_size(px(12.))
                    .text_color(color)
                    .child(icon(
                        if done {
                            Icon::Check
                        } else if failed {
                            Icon::X
                        } else {
                            Icon::CodeXml
                        },
                        16.,
                        color,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(agent_copy::tool(zh, &tool.name))
                            .when(is_assistant_write_preview(&tool.preview), |row| {
                                row.child(self.assistant_operation_preview(&tool.preview, cx))
                            })
                            .when(!preview_paths(&tool.preview).is_empty(), |row| {
                                row.child(
                                    div()
                                        .whitespace_normal()
                                        .text_color(p.muted)
                                        .child(preview_paths(&tool.preview)),
                                )
                            }),
                    ),
            );
        }
        if let Some(approval) = &view.approval {
            content = content.child(
                div()
                    .id("agent-approval-preview")
                    .debug_selector(|| "agent-approval-preview".into())
                    .flex()
                    .flex_col()
                    .gap_2()
                    .text_size(px(13.))
                    .text_color(p.text)
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(agent_copy::tool(zh, &approval.name)),
                    )
                    .child(
                        div()
                            .whitespace_normal()
                            .child(preview_paths(&approval.preview)),
                    )
                    .when(
                        approval.preview["content_bytes"].as_u64().is_some(),
                        |row| {
                            row.child(div().text_size(px(12.)).text_color(p.muted).child(format!(
                            "{} {} B", agent_copy::copy(zh, "Content:", "内容："),
                            approval.preview["content_bytes"].as_u64().unwrap_or_default()
                        )))
                        },
                    )
                    .when(approval.preview["diff_preview"].as_str().is_some(), |row| {
                        row.child(
                            div()
                                .p_3()
                                .rounded(px(8.))
                                .bg(p.background)
                                .font_family(theme::code_font_family())
                                .text_size(px(12.))
                                .line_height(px(18.))
                                .whitespace_normal()
                                .child(
                                    approval.preview["diff_preview"]
                                        .as_str()
                                        .unwrap_or_default()
                                        .to_owned(),
                                ),
                        )
                    })
                    .when(approval.preview["diff_truncated"] == true, |row| {
                        row.child(div().text_size(px(12.)).text_color(p.muted).child(
                            agent_copy::copy(
                                zh,
                                "Preview is shortened. Review the file before approving.",
                                "预览已截断，请先核对文件再批准。",
                            ),
                        ))
                    }),
            );
        }
        if let Some(question) = &view.question {
            content = content.child(
                div()
                    .id("agent-question")
                    .debug_selector(|| "agent-question".into())
                    .text_size(px(14.))
                    .whitespace_normal()
                    .child(question.question.clone()),
            );
            if question.input_mode == "free_text" {
                content = content.child(div().text_size(px(12.)).text_color(p.muted).child(
                    agent_copy::copy(
                        zh,
                        "Type your answer in the message box below.",
                        "在下方输入框填写回答。",
                    ),
                ));
            }
        }
        let mut actions = div().flex().flex_wrap().gap_2().px_3().pb_2();
        if needs_account {
            actions = actions.child(
                div()
                    .id("agent-open-settings")
                    .debug_selector(|| "agent-open-settings".into())
                    .role(gpui::Role::Button)
                    .aria_label(self.locale.text(Text::Settings))
                    .min_h(px(HIT_TARGET.max(44.)))
                    .px_3()
                    .rounded(px(10.))
                    .flex()
                    .items_center()
                    .gap_2()
                    .bg(p.surface)
                    .text_size(px(13.))
                    .cursor_pointer()
                    .child(icon(Icon::Settings2, 16., p.muted))
                    .child(self.locale.text(Text::Settings))
                    .on_click(cx.listener(|this, _, _, cx| this.navigate(Page::Settings, cx))),
            );
        }
        if let Some(question) = &view.question {
            for (index, (answer, label)) in question.options.iter().enumerate() {
                let answer = answer.clone();
                let id = question.id.clone();
                content = content.child(
                    div()
                        .id(("agent-question-option", index))
                        .role(gpui::Role::Button)
                        .aria_label(label.clone())
                        .min_h(px(HIT_TARGET.max(44.)))
                        .max_w_full()
                        .px_3()
                        .py_2()
                        .rounded(px(10.))
                        .flex()
                        .items_center()
                        .text_size(px(13.))
                        .whitespace_normal()
                        .bg(p.surface)
                        .text_color(p.text)
                        .when(interactive, |v| v.cursor_pointer())
                        .child(label.clone())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if interactive {
                                this.answer_agent(&id, Some(&answer), cx);
                            }
                        })),
                );
            }
            let id = question.id.clone();
            actions = actions.child(
                div()
                    .id("agent-question-skip")
                    .debug_selector(|| "agent-question-skip".into())
                    .role(gpui::Role::Button)
                    .aria_label(agent_copy::copy(zh, "Skip question", "跳过此问题"))
                    .min_h(px(HIT_TARGET.max(44.)))
                    .px_3()
                    .rounded(px(10.))
                    .flex()
                    .items_center()
                    .text_size(px(13.))
                    .text_color(p.muted)
                    .when(interactive, |v| v.cursor_pointer())
                    .child(agent_copy::copy(zh, "Skip question", "跳过此问题"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if interactive {
                            this.answer_agent(&id, None, cx);
                        }
                    })),
            );
        }
        if let Some(approval) = &view.approval {
            // Each displayed button must be explicitly offered by the current
            // native token. Unsupported decisions never acquire a handler.
            for decision in &approval.allowed_decisions {
                let (selector, label) = match decision.as_str() {
                    "allow_once" => (
                        "agent-allow-once",
                        agent_copy::copy(zh, "Allow once", "允许本次"),
                    ),
                    "denied" => ("agent-deny", agent_copy::copy(zh, "Decline", "拒绝")),
                    "cancelled" => (
                        "agent-decision-cancel",
                        agent_copy::copy(zh, "Stop task", "停止任务"),
                    ),
                    _ => continue,
                };
                let decision = decision.clone();
                let approval_id = approval.approval_id.clone();
                actions = actions.child(
                    div()
                        .id(selector)
                        .debug_selector(move || selector.into())
                        .role(gpui::Role::Button)
                        .aria_label(label)
                        .min_h(px(HIT_TARGET.max(44.)))
                        .px_3()
                        .rounded(px(10.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(px(13.))
                        .bg(if decision == "allow_once" {
                            p.accent
                        } else {
                            p.surface
                        })
                        .text_color(if decision == "allow_once" {
                            p.on_accent
                        } else {
                            p.text
                        })
                        .when(!interactive, |v| v.opacity(0.5))
                        .when(interactive, |v| v.cursor_pointer())
                        .child(label)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if interactive {
                                this.decide_agent(&approval_id, &decision, cx);
                            }
                        })),
                );
            }
        }
        if view.recoverable {
            actions = actions.child(
                div()
                    .id("agent-recover")
                    .debug_selector(|| "agent-recover".into())
                    .role(gpui::Role::Button)
                    .aria_label(agent_copy::copy(zh, "Check saved progress", "核对任务进度"))
                    .min_h(px(HIT_TARGET.max(44.)))
                    .px_3()
                    .rounded(px(10.))
                    .flex()
                    .items_center()
                    .gap_2()
                    .bg(p.surface)
                    .text_size(px(13.))
                    .when(interactive, |v| v.cursor_pointer())
                    .child(icon(Icon::RefreshCw, 16., p.muted))
                    .child(agent_copy::copy(zh, "Check saved progress", "核对任务进度"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if interactive {
                            this.recover_visible_agent(cx);
                        }
                    })),
            );
        }
        div()
            .id("agent-panel")
            .debug_selector(|| "agent-panel".into())
            .w_full()
            .px_5()
            .py_1()
            .flex_shrink_0()
            .child(
                div()
                    .w_full()
                    .max_w(px(720.))
                    .mx_auto()
                    .rounded(px(14.))
                    .border_1()
                    .border_color(p.line)
                    .bg(p.composer)
                    .overflow_hidden()
                    .child(
                        div()
                            .px_3()
                            .py_2()
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .child(icon(Icon::ListChecks, 16., p.muted))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .child(agent_copy::phase(zh, phase)),
                            )
                            .when(self.state.has_agent_task(), |header| {
                                header.child(
                                    div()
                                        .id("agent-stop")
                                        .debug_selector(|| "agent-stop".into())
                                        .role(gpui::Role::Button)
                                        .aria_label(agent_copy::copy(zh, "Stop task", "停止任务"))
                                        .min_w(px(HIT_TARGET.max(44.)))
                                        .min_h(px(HIT_TARGET.max(44.)))
                                        .rounded(px(8.))
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .cursor_pointer()
                                        .hover(|v| v.bg(p.surface))
                                        .child(icon(Icon::Square, 14., p.text))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.stop_agent_task(cx);
                                        })),
                                )
                            }),
                    )
                    .when(
                        !view.tools.is_empty()
                            || view.approval.is_some()
                            || view.question.is_some()
                            || view.preview_incomplete
                            || view.recoverable
                            || view.failure_code.is_some(),
                        |panel| panel.child(content),
                    )
                    .when(
                        view.approval.is_some()
                            || view.question.is_some()
                            || view.recoverable
                            || needs_account,
                        |panel| panel.child(actions),
                    ),
            )
            .into_any_element()
    }
}

fn preview_paths(preview: &Value) -> String {
    preview["paths"]
        .as_array()
        .map(|paths| {
            paths
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn is_assistant_write_preview(preview: &Value) -> bool {
    preview["schema_version"] == 1
        && matches!(
            preview["kind"].as_str(),
            Some(
                "create_assistant_task"
                    | "update_assistant_task"
                    | "remember_assistant_memory"
                    | "forget_assistant_memory"
            )
        )
}
