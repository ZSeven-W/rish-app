use super::{assistant_copy as words, assistant_memory_state::*, *};
use rish_shell_core::assistant_store::MAX_TEXT_BYTES;

impl Shell {
    pub(super) fn assistant_memory_action(&mut self, action: MemoryAction, cx: &mut Context<Self>) {
        if self.assistant.memory.deletion.is_some()
            && !matches!(
                action,
                MemoryAction::ConfirmDelete | MemoryAction::CancelDelete
            )
        {
            return;
        }
        match action {
            MemoryAction::Open | MemoryAction::Tasks => {
                if self.assistant.form_busy() {
                    return;
                }
                self.assistant.panel = if matches!(action, MemoryAction::Open) {
                    AssistantPanel::Memory
                } else {
                    AssistantPanel::Tasks
                };
                self.assistant.tasks_open = true;
            }
            MemoryAction::Select(id) => {
                if self.assistant.form_busy() || self.assistant.memory.editor.is_some() {
                    return;
                }
                self.assistant.memory.selected_id = Some(id);
                self.assistant.memory.scroll = Default::default();
            }
            MemoryAction::Back => {
                if self.assistant.form_busy() {
                    return;
                }
                self.assistant.memory.selected_id = None;
                self.assistant.memory.scroll = Default::default();
            }
            MemoryAction::New | MemoryAction::Edit(_) => {
                if !self.runtime.is_native() || self.assistant.form_busy() {
                    return;
                }
                let Some(store) = &self.assistant.snapshot.store else {
                    return;
                };
                let memory = if let MemoryAction::Edit(id) = action {
                    let Some(memory) = store.memories.iter().find(|m| m.id == id) else {
                        return;
                    };
                    Some(memory)
                } else {
                    None
                };
                self.assistant.memory.editor = Some(MemoryDraft::new(store, memory));
                self.assistant.memory.scroll = Default::default();
                self.assistant.error = None;
            }
            MemoryAction::Cancel => {
                if self.assistant.form_busy() {
                    return;
                }
                self.assistant.memory.editor = None;
                self.assistant.error = None;
            }
            MemoryAction::Save | MemoryAction::Overwrite => {
                if !self.runtime.is_native() || self.assistant.form_busy() {
                    return;
                }
                let Some(store) = &self.assistant.snapshot.store else {
                    return;
                };
                let Some(editor) = &mut self.assistant.memory.editor else {
                    return;
                };
                match editor.prepare_save(
                    store,
                    self.locale,
                    matches!(action, MemoryAction::Overwrite),
                ) {
                    Ok(command) => {
                        self.assistant.error = None;
                        self.assistant_command(command, cx);
                    }
                    Err(error) => self.assistant.accept_error(&error),
                }
            }
            MemoryAction::Field(field) => self.assistant_memory_field(field, cx),
            MemoryAction::Kind(kind) => {
                if self.assistant.form_busy() {
                    return;
                }
                if let Some(editor) = &mut self.assistant.memory.editor {
                    editor.kind = kind;
                }
            }
            MemoryAction::Delete(id) => {
                if !self.runtime.is_native() || self.assistant.form_busy() {
                    return;
                }
                let Some(store) = &self.assistant.snapshot.store else {
                    return;
                };
                if let Err(error) = self.assistant.memory.begin_delete(store, &id, self.locale) {
                    self.assistant.accept_error(&error);
                }
            }
            MemoryAction::ConfirmDelete => {
                if !self.runtime.is_native() || self.native_form_active {
                    return;
                }
                let Some(store) = &self.assistant.snapshot.store else {
                    return;
                };
                match self.assistant.memory.prepare_delete(store, self.locale) {
                    Ok(command) => {
                        self.assistant.error = None;
                        self.assistant_command(command, cx);
                    }
                    Err(error) => self.assistant.accept_error(&error),
                }
            }
            MemoryAction::CancelDelete => {
                if self
                    .assistant
                    .memory
                    .deletion
                    .as_ref()
                    .is_some_and(|d| !d.saving)
                {
                    self.assistant.memory.deletion = None;
                    self.assistant.error = None;
                }
            }
        }
        cx.notify();
    }

    fn assistant_memory_field(&mut self, field: MemoryField, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.assistant.form_busy() || self.native_form_active {
            return;
        }
        let Some(editor) = &self.assistant.memory.editor else {
            return;
        };
        let id = editor.id.clone();
        let (title, initial, multiline) = match field {
            MemoryField::Title => (
                words::copy(self.locale, "Memory title", "记忆标题"),
                editor.title.clone(),
                false,
            ),
            MemoryField::Content => (
                words::copy(self.locale, "What should I remember?", "想让我记住什么？"),
                editor.content.clone(),
                true,
            ),
        };
        let token = uuid::Uuid::new_v4().to_string();
        self.assistant.form_request = Some(token.clone());
        self.assistant.error = None;
        self.set_inline_native_form(true, cx);
        let command = words::field_command(title, &initial, multiline, self.locale, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.assistant.form_request.as_ref() != Some(&token) {
                    return;
                }
                this.assistant.form_request = None;
                this.set_inline_native_form(false, cx);
                match result {
                    Ok(Value::String(text))
                        if text.len() <= MAX_TEXT_BYTES && !text.contains('\0') =>
                    {
                        if let Some(editor) =
                            &mut this.assistant.memory.editor.as_mut().filter(|e| e.id == id)
                        {
                            match field {
                                MemoryField::Title => editor.title = text,
                                MemoryField::Content => editor.content = text,
                            }
                        }
                    }
                    Ok(Value::Null) => {}
                    _ => this.assistant.accept_error(words::copy(
                        this.locale,
                        "Could not use this input. Your memory draft was kept.",
                        "无法使用本次输入，记忆草稿已保留。",
                    )),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
}
