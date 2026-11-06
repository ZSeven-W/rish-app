//! Unsent input shares the session's single CAS writer. Timers only coalesce
//! edits; a successful native receipt is the only durability acknowledgement.
use super::*;

#[derive(Default)]
pub(super) struct ComposerDrafts {
    pub hydrated: bool,
    pub restoring_snapshot: bool,
    sequence: u64,
    scheduled: bool,
    pub saving: bool,
    pub send_after_save: Option<(String, String)>,
    pub error: Option<String>,
    pub rejected_text: bool,
}

impl Shell {
    pub(super) fn composer_draft_conflict_scope(&self, key: &str) -> String {
        if key == self.inline_conversation_key() {
            assistant_copy::copy(self.locale, "This conversation", "当前会话").into()
        } else if key == "new-draft" {
            assistant_copy::copy(self.locale, "New conversation draft", "新会话草稿").into()
        } else if let Some(chat) = self
            .state
            .conversations()
            .iter()
            .find(|chat| chat.id == key)
        {
            format!(
                "{} · {}",
                assistant_copy::copy(self.locale, "Other conversation", "其他会话"),
                chat.title
            )
        } else {
            assistant_copy::copy(
                self.locale,
                "Another conversation's draft",
                "另一会话的草稿",
            )
            .into()
        }
    }

    pub(super) fn composer_draft_conflict_view(
        &self,
        key: String,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let keep = key.clone();
        let local_preview = self
            .state
            .composer_draft(&key)
            .chars()
            .take(160)
            .collect::<String>();
        let preview = self
            .state
            .saved_composer_draft(&key)
            .chars()
            .take(160)
            .collect::<String>();
        div()
            .id("composer-draft-conflict")
            .px_4()
            .pb_2()
            .text_size(px(11.))
            .child(
                div()
                    .text_color(p.text)
                    .whitespace_normal()
                    .child(self.composer_draft_conflict_scope(&key)),
            )
            .child(
                div()
                    .max_h(px(48.))
                    .overflow_hidden()
                    .whitespace_normal()
                    .text_color(p.muted)
                    .child(format!(
                        "{} {}",
                        assistant_copy::copy(self.locale, "Local text:", "本地文字："),
                        local_preview
                    )),
            )
            .child(
                div()
                    .max_h(px(48.))
                    .overflow_hidden()
                    .whitespace_normal()
                    .text_color(p.muted)
                    .child(format!(
                        "{} {}",
                        assistant_copy::copy(self.locale, "Saved text:", "已保存的文字："),
                        preview
                    )),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        div()
                            .id("keep-local-composer-draft")
                            .min_h(px(44.))
                            .px_2()
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .child(assistant_copy::copy(
                                self.locale,
                                "Keep local text",
                                "保留本地文字",
                            ))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.resolve_composer_draft(&keep, true, cx)
                            })),
                    )
                    .child(
                        div()
                            .id("use-saved-composer-draft")
                            .min_h(px(44.))
                            .px_2()
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .child(assistant_copy::copy(
                                self.locale,
                                "Use saved text",
                                "使用已保存文字",
                            ))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.resolve_composer_draft(&key, false, cx)
                            })),
                    ),
            )
    }

    pub(super) fn record_composer_draft(&mut self, key: &str, text: &str, cx: &mut Context<Self>) {
        // Rooms use BotStore, whose submission receipt is a separate authority.
        // Keep their existing process-only drafts until that store owns drafts.
        if key.starts_with("assistant-group-") {
            return;
        }
        if self.state.composer_draft(key) == text {
            if self.composer_drafts.rejected_text {
                self.composer_drafts.rejected_text = false;
                self.composer_drafts.error = None;
            }
            return;
        }
        match self.state.stage_composer_draft(key, text) {
            Ok(()) => {
                self.composer_drafts.error = None;
                self.composer_drafts.rejected_text = false;
                self.schedule_composer_draft_save(cx);
            }
            Err(error) => {
                self.composer_drafts.rejected_text = self.state.composer_draft(key) != text;
                self.composer_drafts.error = Some(error);
            }
        }
        cx.notify();
    }

    pub(super) fn composer_text_changed(&mut self, cx: &mut Context<Self>) {
        // align owns the old editor key until it has captured its final text.
        // A notification from hydration must never clear a restored draft.
        self.align_inline_session(true, cx);
    }

    pub(super) fn schedule_composer_draft_save(&mut self, cx: &mut Context<Self>) {
        if !self.state.has_unsaved_composer_drafts()
            || self.composer_drafts.scheduled
            || self.composer_drafts.error.is_some()
        {
            return;
        }
        self.composer_drafts.scheduled = true;
        self.composer_drafts.sequence = self.composer_drafts.sequence.wrapping_add(1);
        let sequence = self.composer_drafts.sequence;
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(300))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.composer_drafts.sequence == sequence {
                    this.composer_drafts.scheduled = false;
                    this.save_composer_drafts(cx);
                }
            });
        })
        .detach();
    }

    pub(super) fn save_composer_drafts(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || !self.state.is_loaded()
            || self.assistant_writer_lease
            || self.loading
            || self.aux_busy
            || self.state.is_busy()
            || !self.inline_allows_assistant_handoff()
            || self.composer_drafts.error.is_some()
        {
            return;
        }
        match self.state.persist_composer_drafts() {
            Ok(Some(command)) => {
                self.composer_drafts.saving = true;
                self.run(Reply::Persist, command, cx);
            }
            Ok(None) => {}
            Err(error) => {
                self.composer_drafts.error = Some(error);
                cx.notify();
            }
        }
    }

    pub(super) fn retry_composer_drafts(&mut self, cx: &mut Context<Self>) {
        self.composer_drafts.error = None;
        self.align_inline_session(true, cx);
        if !self.state.is_loaded() || self.state.query_pending_commit().is_some() {
            self.bootstrap(cx);
        } else {
            self.save_composer_drafts(cx);
        }
        cx.notify();
    }

    pub(super) fn load_snapshot_preserving_composer(
        &mut self,
        value: Value,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        let mut state = self.state.clone();
        state.load_snapshot(value)?;
        self.retain_composer_drafts(state, cx);
        self.align_inline_session(true, cx);
        Ok(())
    }

    pub(super) fn resolve_composer_draft(
        &mut self,
        key: &str,
        keep_local: bool,
        cx: &mut Context<Self>,
    ) {
        if self.assistant_writer_lease {
            return;
        }
        match self.state.resolve_composer_draft_conflict(key, keep_local) {
            Ok(()) => {
                self.composer_drafts.error = None;
                if !keep_local && key == self.inline_conversation_key() {
                    let text = self.state.composer_draft(key).to_owned();
                    self.composer
                        .update(cx, |input, cx| input.set_text(text, cx));
                    self.align_inline_session(true, cx);
                }
                self.save_composer_drafts(cx);
            }
            Err(error) => self.composer_drafts.error = Some(error),
        }
        cx.notify();
    }

    pub(super) fn composer_draft_status(&self) -> Option<&'static str> {
        let copy = |en, zh| assistant_copy::copy(self.locale, en, zh);
        if self.assistant_group_visible() {
            Some(copy(
                "Group drafts are kept while the app is open.",
                "群聊草稿仅在应用打开期间保留。",
            ))
        } else if !self.state.composer_draft_conflicts().is_empty() {
            Some(copy(
                "A draft changed elsewhere. Choose which text to keep.",
                "一份草稿已在别处修改，请选择保留的文字。",
            ))
        } else if self.composer_drafts.error.as_deref() == Some("E_COMPOSER_DRAFT_BOUNDS") {
            Some(copy(
                "Draft is too large to save. Shorten or copy it first.",
                "草稿超出保存限制，请先缩短或复制保存。",
            ))
        } else if self.composer_drafts.error.is_some() {
            Some(copy(
                "Draft not saved. Your text is kept here.",
                "草稿未保存，文字仍保留在此处。",
            ))
        } else if self.composer_drafts.saving {
            Some(copy("Saving draft…", "正在保存草稿…"))
        } else if self.state.has_unsaved_composer_drafts() {
            Some(copy(
                "Draft waiting to save. Keep the app open.",
                "草稿等待保存，请保持应用打开。",
            ))
        } else {
            None
        }
    }
}
