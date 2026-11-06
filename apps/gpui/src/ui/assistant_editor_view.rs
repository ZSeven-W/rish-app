//! Task form presentation. Draft validation and persistence stay in assistant_forms.
use super::{
    assistant_copy as words,
    assistant_forms::{Field, Picker},
    assistant_primitives::divider,
    assistant_view::{Action, preview},
    *,
};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};

impl Shell {
    pub(super) fn assistant_editor(&self, cx: &mut Context<Self>) -> AnyElement {
        let editor = self.assistant.editor.as_ref().unwrap();
        let p = Palette::get(cx);
        let available = self.runtime.is_native() && !self.assistant.form_busy();
        let heading = words::copy(
            self.locale,
            if editor.task_id.is_some() {
                "Edit task"
            } else {
                "New task"
            },
            if editor.task_id.is_some() {
                "编辑任务"
            } else {
                "新建任务"
            },
        );
        let mut content = div()
            .id("assistant-editor-scroll")
            .debug_selector(|| "assistant-editor-scroll".into())
            .flex_1()
            .min_h(px(0.))
            .min_w(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.assistant.detail_scroll)
            .flex()
            .flex_col()
            .gap_4()
            .pb_3();
        if editor.conflicted {
            content = content.child(self.assistant_button(
                "assistant-overwrite",
                words::copy(self.locale, "Save my version", "保存我的版本"),
                Icon::Check,
                available,
                Action::Overwrite,
                cx,
            ));
        }
        content = content.child(
            self.assistant_group(cx)
                .child(self.assistant_editor_text(
                    "assistant-editor-title",
                    words::copy(self.locale, "Task title", "任务名称"),
                    &editor.config.title,
                    false,
                    available,
                    Action::Field(Field::Title),
                    cx,
                ))
                .child(div().h(px(1.)).mx_4().bg(p.line))
                .child(self.assistant_editor_text(
                    "assistant-editor-instructions",
                    words::copy(self.locale, "Instructions", "任务要求"),
                    &editor.config.instructions,
                    true,
                    available,
                    Action::Field(Field::Instructions),
                    cx,
                )),
        );
        content = content.child(
            self.assistant_group(cx)
                .child(self.assistant_setting_row(
                    "assistant-editor-workspace",
                    words::copy(self.locale, "Workspace", "工作空间"),
                    words::workspace_name(&editor.config.workspace_descriptor, self.locale),
                    Icon::Folder,
                    available && !self.assistant.workspace_locked(),
                    Action::Pick(Picker::Workspace),
                    cx,
                ))
                .child(divider(cx))
                .child(self.assistant_setting_row(
                    "assistant-editor-model",
                    words::copy(self.locale, "Model", "模型"),
                    self.assistant_model_name(&editor.config.model_id),
                    Icon::Box,
                    available,
                    Action::Pick(Picker::Model),
                    cx,
                ))
                .child(divider(cx))
                .child(self.assistant_setting_row(
                    "assistant-editor-schedule",
                    words::copy(self.locale, "Follow-up", "跟进安排"),
                    words::interval(self.locale, editor.config.interval_minutes),
                    Icon::Clock,
                    available,
                    Action::Pick(Picker::Schedule),
                    cx,
                )),
        );
        if self.assistant.workspace_locked() {
            content = content.child(self.assistant_hint(
                "assistant-workspace-locked",
                words::copy(
                    self.locale,
                    "This task has already run. Create a new task to use another workspace.",
                    "此任务已运行。要使用其他工作空间，请新建任务。",
                ),
                false,
                cx,
            ));
        }
        if let Some(picker) = editor.picker {
            content = content.child(self.assistant_picker(picker, cx));
        }
        content = content.child(
            div().id("assistant-schedule-hint").debug_selector(|| "assistant-schedule-hint".into())
                .px_1().text_size(px(12.)).line_height(px(19.)).text_color(p.muted)
                .whitespace_normal().flex_shrink_0().child(words::copy(self.locale,
                    "New tasks run manually. Optional follow-ups need at least 15 minutes; the app runs them when it can execute.",
                    "新任务默认手动运行。跟进间隔至少 15 分钟，应用可执行时才会继续。")),
        );
        div()
            .id("assistant-editor")
            .debug_selector(|| "assistant-editor".into())
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .flex()
                    .flex_shrink_0()
                    .child(self.assistant_icon_button(
                        "assistant-editor-back",
                        words::copy(self.locale, "Cancel editing", "取消编辑"),
                        Icon::ChevronLeft,
                        !self.assistant.form_busy(),
                        Action::Cancel,
                        cx,
                    )),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .flex_shrink_0()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .child(icon(Icon::Folder, 15., p.muted))
                            .child(words::copy(self.locale, "Local task", "本机任务")),
                    )
                    .child(
                        div()
                            .text_size(px(24.))
                            .line_height(px(30.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(heading),
                    ),
            )
            .child(content)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .flex_shrink_0()
                    .child(self.assistant_button(
                        "assistant-cancel",
                        words::copy(self.locale, "Cancel", "取消"),
                        Icon::X,
                        !self.assistant.form_busy(),
                        Action::Cancel,
                        cx,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(self.assistant_primary_button(
                                "assistant-save",
                                words::copy(
                                    self.locale,
                                    if editor.saving {
                                        "Saving…"
                                    } else {
                                        "Save task"
                                    },
                                    if editor.saving {
                                        "保存中…"
                                    } else {
                                        "保存任务"
                                    },
                                ),
                                Icon::Check,
                                available,
                                Action::Save,
                                cx,
                            )),
                    ),
            )
            .into_any_element()
    }

    pub(super) fn assistant_editor_text(
        &self,
        id: &'static str,
        label: &'static str,
        text: &str,
        multiline: bool,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let value = if text.trim().is_empty() {
            words::copy(
                self.locale,
                if multiline {
                    "Describe what your assistant should do…"
                } else {
                    "Give this task a name…"
                },
                if multiline {
                    "描述希望助手完成的事情…"
                } else {
                    "给任务起个名字…"
                },
            )
            .to_owned()
        } else {
            preview(text, if multiline { 220 } else { 120 })
        };
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .min_h(px(if multiline { 132. } else { 84. }))
            .p_4()
            .min_w(px(0.))
            .flex()
            .flex_col()
            .gap_2()
            .flex_shrink_0()
            .when(enabled, |v| v.cursor_pointer().hover(|v| v.bg(p.surface)))
            .child(div().text_size(px(12.)).text_color(p.muted).child(label))
            .child(
                div()
                    .text_size(px(if multiline { 15. } else { 18. }))
                    .line_height(px(if multiline { 23. } else { 26. }))
                    .font_weight(if multiline {
                        FontWeight::NORMAL
                    } else {
                        FontWeight::MEDIUM
                    })
                    .text_color(if text.trim().is_empty() {
                        p.faint
                    } else {
                        p.text
                    })
                    .whitespace_normal()
                    .child(value),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                if enabled {
                    this.assistant_action(action.clone(), cx);
                }
            }))
            .into_any_element()
    }

    fn assistant_picker(&self, picker: Picker, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let mut list = self
            .assistant_group(cx)
            .id("assistant-field-options")
            .debug_selector(|| "assistant-field-options".into());
        let mut options: Vec<(String, String, Icon, Action)> = Vec::new();
        match picker {
            Picker::Workspace => {
                let mut workspaces = self.browser.workspaces.clone();
                for descriptor in [
                    self.state.default_workspace(),
                    self.conversation_workspace.descriptor.as_ref(),
                ]
                .into_iter()
                .flatten()
                {
                    if !workspaces
                        .iter()
                        .any(|w| w["workspace_id"] == descriptor["workspace_id"])
                    {
                        workspaces.push(descriptor.clone());
                    }
                }
                if workspaces.is_empty() {
                    list = list.child(div().p_4().text_size(px(13.)).text_color(p.muted).child(
                        words::copy(
                            self.locale,
                            "No workspace is available yet.",
                            "尚无可用工作空间。",
                        ),
                    ));
                }
                for (index, descriptor) in workspaces.into_iter().enumerate() {
                    options.push((
                        format!("assistant-workspace-{index}"),
                        words::workspace_name(&descriptor, self.locale),
                        Icon::Folder,
                        Action::Workspace(descriptor),
                    ));
                }
            }
            Picker::Model => {
                for (index, model) in self.state.models().into_iter().enumerate() {
                    options.push((
                        format!("assistant-model-{index}"),
                        model.name,
                        Icon::CodeXml,
                        Action::Model(model.id),
                    ));
                }
            }
            Picker::Schedule => {
                for (index, interval) in [None, Some(15), Some(60), Some(1440)]
                    .into_iter()
                    .enumerate()
                {
                    options.push((
                        format!("assistant-interval-{index}"),
                        words::interval(self.locale, interval),
                        Icon::RefreshCw,
                        Action::Interval(interval),
                    ));
                }
                options.push((
                    "assistant-custom-interval".into(),
                    words::copy(self.locale, "Custom minutes…", "自定义分钟数…").into(),
                    Icon::SquarePen,
                    Action::Field(Field::Interval),
                ));
            }
        }
        let enabled = self.runtime.is_native() && !self.assistant.form_busy();
        for (index, (id, label, glyph, action)) in options.into_iter().enumerate() {
            if index > 0 {
                list = list.child(divider(cx));
            }
            list = list.child(self.assistant_setting_row(
                id,
                label,
                String::new(),
                glyph,
                enabled,
                action,
                cx,
            ));
        }
        list.into_any_element()
    }
}
