use super::{
    assistant_copy as words,
    assistant_forms::{Field, Picker},
    assistant_primitives::divider,
    *,
};
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};

#[derive(Clone)]
pub(super) enum Action {
    Memory(super::assistant_memory_state::MemoryAction),
    New,
    Edit(String),
    Select(String),
    Back,
    Cancel,
    Save,
    Overwrite,
    SaveProfile,
    DiscardProfile,
    Field(Field),
    Run(String),
    Recover(String),
    Enabled(String, bool),
    Open(String),
    Pick(Picker),
    Model(String),
    Workspace(Value),
    Interval(Option<u32>),
    Delete(String),
    ConfirmDelete,
    CancelDelete,
    ToggleSettings,
    ToggleTaskMenu,
    ChooseAvatar,
    RestoreAvatar,
    ToggleTasks,
    CloseTasks,
}

impl Shell {
    pub(super) fn assistant_hint(
        &self,
        id: &'static str,
        text: impl Into<gpui::SharedString>,
        danger: bool,
        cx: &App,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        div()
            .id(id)
            .debug_selector(|| id.into())
            .max_h(px(96.))
            .overflow_y_scroll()
            .flex_shrink_0()
            .p_3()
            .rounded(px(16.))
            .bg(p.surface)
            .text_size(px(12.))
            .line_height(px(18.))
            .whitespace_normal()
            .text_color(if danger { p.danger } else { p.muted })
            .child(text.into())
    }

    pub(super) fn assistant_list(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let native = self.runtime.is_native() && self.assistant.snapshot.store.is_some();
        let busy = self.assistant.form_busy() || self.assistant.editor.is_some();
        let store = self.assistant.snapshot.store.as_ref();
        let tasks = store.map(|s| s.tasks.as_slice()).unwrap_or(&[]);
        let quick = self.assistant_group(cx).child(self.assistant_setting_row(
            "assistant-run-settings",
            words::copy(self.locale, "Run settings", "运行设置"),
            if self.assistant.settings_open {
                words::copy(self.locale, "Hide", "收起")
            } else {
                ""
            },
            Icon::Settings2,
            !busy,
            Action::ToggleSettings,
            cx,
        ));
        let mut list = div()
            .id("assistant-task-list")
            .debug_selector(|| "assistant-task-list".into())
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.assistant.list_scroll)
            .flex()
            .flex_col()
            .gap_4()
            .pb_3()
            .child(quick);
        if self.assistant.profile_draft.is_some() {
            list = list.child(
                self.assistant_group(cx)
                    .p_3()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.danger)
                            .whitespace_normal()
                            .child(words::copy(
                                self.locale,
                                "Unsaved profile draft",
                                "个人设置草稿尚未保存",
                            )),
                    )
                    .child(self.assistant_button(
                        "assistant-profile-retry",
                        words::copy(self.locale, "Save my profile", "保存我的设置"),
                        Icon::Check,
                        native && !busy,
                        Action::SaveProfile,
                        cx,
                    ))
                    .child(self.assistant_button(
                        "assistant-profile-discard",
                        words::copy(self.locale, "Restore saved profile", "恢复已保存设置"),
                        Icon::RotateCcw,
                        !busy,
                        Action::DiscardProfile,
                        cx,
                    )),
            );
        }
        if self.assistant.settings_open {
            list = list.child(self.assistant_platform_bar(cx));
        }
        list = list.child(
            div()
                .id("assistant-tasks-heading")
                .debug_selector(|| "assistant-tasks-heading".into())
                .min_h(px(32.))
                .flex_shrink_0()
                .flex()
                .items_center()
                .justify_between()
                .px_1()
                .child(
                    div()
                        .text_size(px(17.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(words::copy(self.locale, "My tasks", "我的任务")),
                )
                .child(self.assistant_icon_button(
                    "assistant-new",
                    words::copy(self.locale, "New task", "新建任务"),
                    Icon::Plus,
                    native && !busy,
                    Action::New,
                    cx,
                )),
        );
        let mut task_list = self.assistant_group(cx);
        if tasks.is_empty() {
            task_list = task_list.child(
                div()
                    .id("assistant-empty")
                    .debug_selector(|| "assistant-empty".into())
                    .p_5()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap_3()
                    .text_center()
                    .child(icon(Icon::ListChecks, 26., p.faint))
                    .child(
                        div()
                            .text_size(px(15.))
                            .font_weight(FontWeight::MEDIUM)
                            .child(words::copy(self.locale, "No tasks yet", "还没有任务")),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .line_height(px(19.))
                            .whitespace_normal()
                            .text_color(p.muted)
                            .child(words::copy(
                                self.locale,
                                "Tell me what you need in chat. I can help create and follow up on a task.",
                                "在聊天里告诉我你的想法，我会帮你建立任务并跟进。",
                            )),
                    ),
            );
        }
        for (index, task) in tasks.iter().enumerate() {
            if index > 0 {
                task_list = task_list.child(divider(cx));
            }
            let selected = self.assistant.selected_task_id.as_deref() == Some(&task.id);
            let id = task.id.clone();
            let selector = format!("assistant-task-{}", task.id);
            let status = if task.is_running() || task.pending_manual || !task.enabled {
                words::task_status(self.locale, task).to_owned()
            } else {
                words::interval(self.locale, task.interval_minutes)
            };
            task_list = task_list.child(
                div()
                    .id(selector.clone())
                    .debug_selector(move || selector.clone())
                    .role(gpui::Role::Button)
                    .aria_label(task.title.clone())
                    .min_h(px(76.))
                    .min_w(px(0.))
                    .flex_shrink_0()
                    .px_4()
                    .py_3()
                    .flex()
                    .items_center()
                    .gap_3()
                    .when(selected, |v| v.bg(p.surface))
                    .when(!busy, |v| v.cursor_pointer().hover(|v| v.bg(p.surface)))
                    .child(icon(
                        if task.interval_minutes.is_some() {
                            Icon::Clock
                        } else {
                            Icon::Folder
                        },
                        22.,
                        p.text,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div()
                                    .text_size(px(14.))
                                    .font_weight(FontWeight::MEDIUM)
                                    .truncate()
                                    .child(task.title.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(p.muted)
                                    .truncate()
                                    .child(status),
                            ),
                    )
                    .child(icon(Icon::ChevronRight, 14., p.faint))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if !busy {
                            this.assistant_action(Action::Select(id.clone()), cx);
                        }
                    })),
            );
        }
        list=list.child(task_list).child(div().flex_shrink_0().px_1().text_size(px(11.)).line_height(px(18.))
            .text_color(p.muted).whitespace_normal().child(words::copy(self.locale,
                "Saved on this device. Notes are sent to the selected model as context. Follow-ups run when the app can execute.",
                "任务保存在本机；备注会发送给所选模型。跟进在应用可执行时进行。")));
        if !self.runtime.is_native() {
            list = list.child(self.assistant_hint(
                "assistant-preview",
                words::copy(
                    self.locale,
                    "Desktop preview. Create and run tasks on your phone.",
                    "桌面界面预览，请在手机上创建和运行任务。",
                ),
                false,
                cx,
            ));
        }
        list.into_any_element()
    }
}

pub(super) fn preview(text: &str, max: usize) -> String {
    let mut chars = text.chars();
    let mut preview: String = chars.by_ref().take(max).collect();
    if chars.next().is_some() {
        preview.push('…');
    }
    preview
}
