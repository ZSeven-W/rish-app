//! Navigation may wait for read/snapshot work. It never replays user effects.
use super::*;
use gpui::AnyElement;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum NavigationAction {
    Create,
    Select(String),
    BotHub,
    Bot(String),
    Group(String),
    Assistant,
}
pub(super) struct PendingNavigation {
    pub action: NavigationAction,
    token: u64,
}
#[derive(Default)]
pub(super) struct NavigationFlow {
    pub pending: Option<PendingNavigation>,
    pub feedback: Option<String>,
    pub scheduled: bool,
    pub creating: bool,
    sequence: u64,
}

impl Shell {
    pub(super) fn informational_notice(&self) -> bool {
        let Some(notice) = self.notice.as_deref() else {
            return false;
        };
        [Locale::En, Locale::Zh].iter().any(|locale| {
            [
                Text::Cancelled,
                Text::CredentialSaved,
                Text::InlineComposing,
                Text::WorkspacePreparing,
                Text::FinishWorkspaceOperation,
            ]
            .iter()
            .any(|text| notice == locale.text(*text))
        })
    }
    pub(super) fn clear_navigation_feedback(&mut self) {
        self.navigation_flow.feedback = None;
        if [Locale::En, Locale::Zh]
            .iter()
            .any(|l| self.notice.as_deref() == Some(l.text(Text::FinishWorkspaceOperation)))
        {
            self.notice = None;
        }
    }
    pub(super) fn navigation_block_reason(&self) -> Option<&'static str> {
        let copy = |en, zh| assistant_copy::copy(self.locale, en, zh);
        if self.composer_drafts.rejected_text {
            Some(copy(
                "This draft is too large. Shorten or copy it before switching.",
                "当前草稿过长，请先缩短或复制，再切换会话。",
            ))
        } else if self.has_file_draft() {
            Some(copy(
                "Your file changes are kept. Save or discard them before switching.",
                "文件修改已保留，请先保存或放弃修改，再切换。",
            ))
        } else if self.assistant_writer_lease || self.state.has_agent_task() {
            Some(copy(
                "A task is running. You can switch after it finishes or you stop it.",
                "任务正在运行，完成或停止后即可切换。",
            ))
        } else if self.state.pending_conflict().is_some() {
            Some(copy(
                "Your changes are kept. Resolve the pending save before switching.",
                "修改已保留，请先处理尚未完成的保存。",
            ))
        } else if self.native_form_active
            || self.browser.edit.busy()
            || self.browser.git_actions.pending.is_some()
        {
            Some(copy(
                "Finish the current edit or operation before switching.",
                "请先完成当前编辑或操作，再切换。",
            ))
        } else if self.assistant.profile_draft.is_some()
            || self.assistant.editor.is_some()
            || self.assistant.memory.editor.is_some()
            || self.assistant.deletion.is_some()
            || self.assistant.directory_ui.editor.is_some()
        {
            Some(copy(
                "Your draft is kept. Save or cancel this edit before switching.",
                "编辑草稿已保留，请先保存或取消本次编辑。",
            ))
        } else if self.assistant.directory_ui.submit.is_some() {
            Some(copy(
                "Checking the group message. Wait for its saved result before switching.",
                "正在核对群聊消息，请待保存结果确认后切换。",
            ))
        } else {
            None
        }
    }
    fn navigation_waiting(&self) -> bool {
        self.loading
            || self.aux_busy
            || self.state.is_busy()
            || self.custom_providers.request_pending()
            || self.provider_models.request_pending()
            || self.assistant.directory_ui.pending_bot_id.is_some()
    }
    /// Call only after the native input snapshot/IME preflight. Draft text is
    /// retained by the input transport, including when this action waits.
    pub(super) fn defer_navigation(
        &mut self,
        action: NavigationAction,
        cx: &mut Context<Self>,
    ) -> bool {
        self.clear_navigation_feedback();
        self.composer_drafts.send_after_save = None;
        if let Some(reason) = self.navigation_block_reason() {
            self.navigation_flow.pending = None;
            self.navigation_flow.feedback = Some(reason.into());
            cx.notify();
            return true;
        }
        if action == NavigationAction::Create && self.navigation_flow.creating {
            // This latest click requests the conversation already being
            // created, superseding any older queued destination.
            self.navigation_flow.pending = None;
            self.navigation_flow.feedback = Some(
                assistant_copy::copy(
                    self.locale,
                    "Opening your new conversation…",
                    "正在打开新会话…",
                )
                .into(),
            );
            cx.notify();
            return true;
        }
        if self.navigation_waiting() {
            // A newer explicit navigation supersedes the old default-workspace
            // continuation, including a not-yet-dispatched send. Keep its text,
            // but never send it after the user has asked to leave that page.
            self.conversation_workspace.intent = None;
            self.send_after_create = false;
            self.cancel_inline_send_intent();
            self.navigation_flow.sequence = self.navigation_flow.sequence.wrapping_add(1);
            let token = self.navigation_flow.sequence;
            self.navigation_flow.pending = Some(PendingNavigation { action, token });
            self.navigation_flow.feedback = Some(
                assistant_copy::copy(
                    self.locale,
                    "Preparing… Your requested page will open automatically.",
                    "正在准备，完成后会自动打开。",
                )
                .into(),
            );
            cx.spawn(async move |this,cx| {
                cx.background_executor().timer(std::time::Duration::from_secs(15)).await;
                let _ = this.update(cx, |this,cx| {
                    if this.navigation_flow.pending.as_ref().is_some_and(|p|p.token == token) {
                        this.navigation_flow.pending = None;
                        this.navigation_flow.feedback = Some(assistant_copy::copy(this.locale,
                            "This operation is taking longer. Your draft is kept; try opening the page again shortly.",
                            "当前操作耗时较长，草稿已保留，稍后可再次打开。").into());
                        cx.notify();
                    }
                });
            }).detach();
            cx.notify();
            return true;
        }
        self.navigation_flow.pending = None;
        false
    }
    pub(super) fn cancel_deferred_navigation(&mut self, cx: &mut Context<Self>) {
        self.navigation_flow.pending = None;
        self.cancel_pending_inline_navigation();
        self.clear_navigation_feedback();
        cx.notify();
    }
    pub(super) fn schedule_navigation_resume(&mut self, cx: &mut Context<Self>) {
        if self.navigation_flow.scheduled {
            return;
        }
        self.navigation_flow.scheduled = true;
        let weak = cx.weak_entity();
        cx.defer(move |cx| {
            let _ = weak.update(cx, |this, cx| {
                this.navigation_flow.scheduled = false;
                this.resume_deferred_navigation(cx);
            });
        });
    }
    pub(super) fn resume_deferred_navigation(&mut self, cx: &mut Context<Self>) {
        if !self.loading && !self.state.is_busy() {
            if self.navigation_flow.creating {
                self.clear_navigation_feedback();
            }
            self.navigation_flow.creating = false;
        }
        if self.navigation_waiting() {
            return;
        }
        let Some(pending) = self.navigation_flow.pending.take() else {
            if self.navigation_block_reason().is_none() && self.navigation_flow.feedback.is_some() {
                self.clear_navigation_feedback();
                cx.notify();
            }
            return;
        };
        if let Some(reason) = self.navigation_block_reason() {
            self.navigation_flow.feedback = Some(reason.into());
            cx.notify();
            return;
        }
        self.clear_navigation_feedback();
        match pending.action {
            NavigationAction::Create => self.create(cx),
            NavigationAction::Select(id) => self.select(id, cx),
            NavigationAction::BotHub => self.assistant_open_hub(cx),
            NavigationAction::Bot(id) => self.assistant_open_bot(id, cx),
            NavigationAction::Group(id) => self.assistant_open_group(id, cx),
            NavigationAction::Assistant => self.navigate(Page::Assistant, cx),
        }
    }
    pub(super) fn navigation_feedback_view(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let waiting = self.navigation_flow.pending.is_some();
        div()
            .id("navigation-feedback")
            .debug_selector(|| "navigation-feedback".into())
            .mx_5()
            .mb_2()
            .px_3()
            .py_2()
            .rounded(px(12.))
            .bg(p.surface)
            .flex()
            .items_center()
            .gap_2()
            .text_size(px(12.))
            .text_color(p.muted)
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .whitespace_normal()
                    .child(self.navigation_flow.feedback.clone().unwrap_or_default()),
            )
            .child(
                div()
                    .id("cancel-navigation-wait")
                    .debug_selector(|| "cancel-navigation-wait".into())
                    .min_h(px(44.))
                    .px_2()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .cursor_pointer()
                    .child(assistant_copy::copy(
                        self.locale,
                        if waiting { "Cancel" } else { "Dismiss" },
                        if waiting { "取消等待" } else { "知道了" },
                    ))
                    .on_click(cx.listener(|this, _, _, cx| this.cancel_deferred_navigation(cx))),
            )
            .into_any_element()
    }
}
