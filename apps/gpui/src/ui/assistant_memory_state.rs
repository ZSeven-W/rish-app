//! UI drafts never masquerade as saved memories. Stable creation identities
//! survive ambiguous replies; external edits require explicit review.
use super::{Locale, assistant_copy::copy};
use crate::assistant_runtime::RunnerCommand;
use rish_shell_core::assistant_store::*;

#[derive(Default, Clone, Copy, PartialEq, Eq)]
pub(super) enum AssistantPanel {
    #[default]
    Tasks,
    Memory,
}

#[derive(Clone)]
pub(super) enum MemoryAction {
    Open,
    Tasks,
    New,
    Select(String),
    Edit(String),
    Back,
    Cancel,
    Save,
    Overwrite,
    Field(MemoryField),
    Kind(AssistantMemoryKind),
    Delete(String),
    ConfirmDelete,
    CancelDelete,
}
#[derive(Clone, Copy)]
pub(super) enum MemoryField {
    Title,
    Content,
}

#[derive(Default)]
pub(super) struct MemoryUi {
    pub selected_id: Option<String>,
    pub editor: Option<MemoryDraft>,
    pub deletion: Option<MemoryDeletion>,
    pub scroll: gpui::ScrollHandle,
}
pub(super) struct MemoryDraft {
    pub id: String,
    pub memory_id: Option<String>,
    pub baseline: Option<AssistantMemory>,
    pub title: String,
    pub content: String,
    pub kind: AssistantMemoryKind,
    pub expected_revision: u64,
    pub saving: bool,
    pub conflicted: bool,
}
pub(super) struct MemoryDeletion {
    pub memory: AssistantMemory,
    pub expected_revision: u64,
    pub saving: bool,
}

impl MemoryDraft {
    pub fn new(store: &AssistantSnapshot, memory: Option<&AssistantMemory>) -> Self {
        Self {
            id: memory
                .map(|m| m.id.clone())
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
            memory_id: memory.map(|m| m.id.clone()),
            baseline: memory.cloned(),
            title: memory.map(|m| m.title.clone()).unwrap_or_default(),
            content: memory.map(|m| m.content.clone()).unwrap_or_default(),
            kind: memory.map(|m| m.kind).unwrap_or(AssistantMemoryKind::Fact),
            expected_revision: store.revision,
            saving: false,
            conflicted: false,
        }
    }
    fn matches(&self, memory: &AssistantMemory) -> bool {
        memory.id == self.id
            && memory.title == self.title
            && memory.content == self.content
            && memory.kind == self.kind
            && (self.memory_id.is_some() || memory.source_conversation_id.is_none())
    }
    pub fn prepare_save(
        &mut self,
        store: &AssistantSnapshot,
        locale: Locale,
        overwrite: bool,
    ) -> Result<RunnerCommand, String> {
        self.title = self.title.trim().into();
        if self.title.is_empty()
            || self.title.len() > 120
            || self.title.chars().any(char::is_control)
        {
            return Err(copy(
                locale,
                "Use a title of up to 120 UTF-8 bytes without line breaks.",
                "标题不能为空，最多 120 字节，且不能包含换行。",
            )
            .into());
        }
        if self.content.trim().is_empty()
            || self.content.len() > MAX_MEMORY_CONTENT_BYTES
            || self.content.contains('\0')
        {
            return Err(copy(
                locale,
                "Memory content must be 1–8192 UTF-8 bytes.",
                "记忆内容不能为空，最多 8192 字节。",
            )
            .into());
        }
        let current = store.memories.iter().find(|m| m.id == self.id);
        if overwrite {
            let Some(current) = current else {
                return Err(copy(
                    locale,
                    "This memory was removed. Your draft is kept.",
                    "这条记忆已被删除，草稿仍然保留。",
                )
                .into());
            };
            self.memory_id = Some(current.id.clone());
            self.baseline = Some(current.clone());
        }
        let changed = if self.memory_id.is_some() {
            current != self.baseline.as_ref() || current.is_none()
        } else {
            current.is_some_and(|memory| !self.matches(memory))
        };
        if changed {
            self.conflicted = true;
            return Err(copy(
                locale,
                "This memory changed. Review the saved version before saving your draft.",
                "这条记忆已变更。请核对已保存内容，再保存你的版本。",
            )
            .into());
        }
        self.expected_revision = store.revision;
        self.conflicted = false;
        self.saving = true;
        Ok(match &self.memory_id {
            Some(id) => RunnerCommand::RememberMemory {
                expected_revision: store.revision,
                memory_id: Some(id.clone()),
                title: self.title.clone(),
                content: self.content.clone(),
                kind: self.kind,
            },
            None => RunnerCommand::CreateMemory {
                expected_revision: store.revision,
                memory_id: self.id.clone(),
                title: self.title.clone(),
                content: self.content.clone(),
                kind: self.kind,
            },
        })
    }
}

impl MemoryUi {
    pub fn selected<'a>(&self, store: &'a AssistantSnapshot) -> Option<&'a AssistantMemory> {
        store
            .memories
            .iter()
            .find(|m| Some(m.id.as_str()) == self.selected_id.as_deref())
    }
    pub fn busy(&self) -> bool {
        self.editor.as_ref().is_some_and(|e| e.saving) || self.deletion.is_some()
    }
    pub fn accept_error(&mut self) {
        if let Some(editor) = &mut self.editor {
            editor.saving = false;
        }
        if let Some(deletion) = &mut self.deletion {
            deletion.saving = false;
        }
    }
    pub fn apply_snapshot(&mut self, store: &AssistantSnapshot) {
        if self.deletion.as_ref().is_some_and(|d| {
            store.revision > d.expected_revision
                && !store.memories.iter().any(|m| m.id == d.memory.id)
        }) {
            self.deletion = None;
        }
        if let Some(editor) = &mut self.editor {
            let saved = store.memories.iter().find(|m| m.id == editor.id);
            if editor.saving && store.revision >= editor.expected_revision {
                if saved.is_some_and(|m| editor.matches(m)) {
                    self.selected_id = Some(editor.id.clone());
                    self.editor = None;
                    self.scroll = Default::default();
                } else if store.revision > editor.expected_revision {
                    editor.saving = false;
                    editor.conflicted = if editor.memory_id.is_some() {
                        saved != editor.baseline.as_ref() || saved.is_none()
                    } else {
                        saved.is_some()
                    };
                }
            } else if saved.is_some_and(|m| editor.memory_id.is_none() && !editor.matches(m)) {
                editor.conflicted = true;
            }
        }
        if self.selected_id.is_some() && self.selected(store).is_none() {
            self.selected_id = None;
        }
    }
    pub fn begin_delete(
        &mut self,
        store: &AssistantSnapshot,
        id: &str,
        locale: Locale,
    ) -> Result<(), String> {
        if self.busy() || self.editor.is_some() {
            return Err(copy(
                locale,
                "Finish the current edit first.",
                "请先完成当前编辑。",
            )
            .into());
        }
        let memory = store.memories.iter().find(|m| m.id == id).ok_or_else(|| {
            copy(
                locale,
                "This memory no longer exists.",
                "这条记忆已不存在。",
            )
            .to_owned()
        })?;
        self.deletion = Some(MemoryDeletion {
            memory: memory.clone(),
            expected_revision: store.revision,
            saving: false,
        });
        Ok(())
    }
    pub fn prepare_delete(
        &mut self,
        store: &AssistantSnapshot,
        locale: Locale,
    ) -> Result<RunnerCommand, String> {
        let deletion = self.deletion.as_mut().ok_or_else(|| {
            copy(
                locale,
                "Review the memory before deleting it.",
                "请先核对要删除的记忆。",
            )
            .to_owned()
        })?;
        if deletion.saving {
            return Err(copy(
                locale,
                "Deletion is still being saved.",
                "正在保存删除结果。",
            )
            .into());
        }
        if store.revision != deletion.expected_revision
            || store.memories.iter().find(|m| m.id == deletion.memory.id) != Some(&deletion.memory)
        {
            return Err(copy(
                locale,
                "Memory data changed. Cancel and reopen this confirmation to review it.",
                "记忆已变更。请取消并重新打开删除确认，核对内容。",
            )
            .into());
        }
        deletion.saving = true;
        Ok(RunnerCommand::ForgetMemory {
            expected_revision: store.revision,
            memory_id: deletion.memory.id.clone(),
        })
    }
}
