use super::{Page, Reply, Shell, Text, name_prompt, screens::Browser};
use gpui::Context;
use rish_shell_core::RuntimeCommand;
use serde_json::{Value, json};

pub(super) const MAX_EDIT_BYTES: usize = 262_144;

#[derive(Clone, Debug, PartialEq)]
pub(super) struct FileSnapshot {
    pub root: Value,
    pub path: String,
    pub content: String,
    pub revision: String,
    pub truncated: bool,
}
impl FileSnapshot {
    pub fn from_read(value: &Value, root: &Value, path: &str) -> Result<Self, String> {
        let content = value["content"]
            .as_str()
            .ok_or("The file is not readable text")?;
        let file = &value["file"];
        let revision = file["revision"]
            .as_str()
            .filter(|r| valid_revision(r))
            .ok_or("Missing file revision; refresh this file")?;
        if value["schema_version"] != 1
            || value["root"] != *root
            || value["path"] != path
            || file["path"] != path
            || file["kind"] != "file"
        {
            return Err("The workspace changed while reading this file".into());
        }
        // Native readV2 refuses oversized reads. Still fail closed if a future
        // host returns a partial read: a preview must never replace a whole file.
        let truncated =
            value["truncated"] == true || file["size"].as_u64() != Some(content.len() as u64);
        Ok(Self {
            root: root.clone(),
            path: path.into(),
            content: content.into(),
            revision: revision.into(),
            truncated,
        })
    }
    pub fn editable(&self) -> bool {
        !self.truncated && self.content.len() <= MAX_EDIT_BYTES && valid_revision(&self.revision)
    }
}

#[derive(Clone, Debug)]
pub(super) struct EditTarget {
    pub root: Value,
    pub path: String,
    pub folder: String,
    pub generation: u64,
}
impl EditTarget {
    fn current(&self, browser: &Browser) -> bool {
        browser.root.as_ref() == Some(&self.root)
            && browser.generation == self.generation
            && browser.path == self.folder
            && browser.capabilities["write"] == true
    }
}

#[derive(Clone, Debug)]
pub(super) struct FileDraft {
    pub target: EditTarget,
    pub content: String,
    pub expected_revision: Option<String>,
    pub create_only: bool,
    pub failed: bool,
}
impl FileDraft {
    fn write_command(&self) -> Result<RuntimeCommand, String> {
        if self.content.len() > MAX_EDIT_BYTES
            || (self.create_only && self.expected_revision.is_some())
            || (!self.create_only
                && !self
                    .expected_revision
                    .as_deref()
                    .is_some_and(valid_revision))
        {
            return Err("Invalid file edit boundary".into());
        }
        Ok(RuntimeCommand::new(
            "LocalWorkspace",
            "writeV2",
            vec![json!({
                "schema_version":1, "root":self.target.root, "path":self.target.path,
                "content":self.content, "expected_revision":self.expected_revision,
                "create_only":self.create_only,
            })],
        ))
    }
    fn accept_write(&self, value: &Value) -> Result<FileSnapshot, String> {
        let file = &value["file"];
        if value["schema_version"] != 1
            || value["root"] != self.target.root
            || value["created"] != self.create_only
            || file["path"] != self.target.path
            || file["kind"] != "file"
            || file["size"].as_u64() != Some(self.content.len() as u64)
        {
            return Err("Unrecognized write result; the draft has been retained".into());
        }
        let revision = file["revision"]
            .as_str()
            .filter(|r| valid_revision(r))
            .ok_or("Missing saved file revision")?;
        Ok(FileSnapshot {
            root: self.target.root.clone(),
            path: self.target.path.clone(),
            content: self.content.clone(),
            revision: revision.into(),
            truncated: false,
        })
    }
}

#[derive(Clone)]
pub(super) struct FileEditRequest {
    id: String,
    draft: FileDraft,
}
#[derive(Clone, Copy)]
pub(super) enum EntryKind {
    File,
    Folder,
}
#[derive(Clone)]
pub(super) struct EntryRequest {
    id: String,
    target: EditTarget,
    kind: EntryKind,
}
#[derive(Default)]
pub(super) struct EditState {
    pub draft: Option<FileDraft>,
    active: Option<String>,
}
impl EditState {
    fn finish(&mut self, id: &str) -> bool {
        if self.active.as_deref() != Some(id) {
            return false;
        }
        self.active = None;
        true
    }
    fn retain_failed(&mut self, mut draft: FileDraft) {
        draft.failed = true;
        self.draft = Some(draft);
    }
    pub fn busy(&self) -> bool {
        self.active.is_some()
    }
}

fn valid_revision(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn entry_path(folder: &str, name: &str) -> Option<String> {
    let folded = name.to_lowercase();
    if name.is_empty()
        || name.trim() != name
        || name.len() > 255
        || matches!(folded.as_str(), "." | ".." | ".git" | ".trash")
        || folded.starts_with(".staging-")
        || folded.starts_with(".rish-write-")
        || name
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\' | ':' | '\u{2028}' | '\u{2029}'))
    {
        return None;
    }
    let path = if folder.is_empty() {
        name.into()
    } else {
        format!("{folder}/{name}")
    };
    (path.len() <= 512).then_some(path)
}

impl Shell {
    pub(super) fn can_create_file(&self) -> bool {
        self.runtime.is_native()
            && !self.aux_busy
            && !self.browser.edit.busy()
            && self.browser.root.is_some()
            && self.browser.capabilities["write"] == true
            && self.browser.file.is_none()
            && self.browser.edit.draft.is_none()
    }
    pub(super) fn can_create_folder(&self) -> bool {
        self.can_create_file()
    }
    pub(super) fn can_edit_file(&self) -> bool {
        self.runtime.is_native()
            && !self.aux_busy
            && !self.browser.edit.busy()
            && self.browser.capabilities["write"] == true
            && self.browser.file.as_ref().is_some_and(|file| {
                file.editable() && self.browser.root.as_ref() == Some(&file.root)
            })
            && self.browser.edit.draft.is_none()
    }
    pub(super) fn has_file_draft(&self) -> bool {
        self.browser.edit.draft.is_some()
    }
    pub(super) fn begin_new_file(&mut self, cx: &mut Context<Self>) {
        self.begin_new_entry(EntryKind::File, cx);
    }
    pub(super) fn begin_new_folder(&mut self, cx: &mut Context<Self>) {
        self.begin_new_entry(EntryKind::Folder, cx);
    }
    fn begin_new_entry(&mut self, kind: EntryKind, cx: &mut Context<Self>) {
        if !self.can_create_file() {
            return;
        }
        let Some(root) = self.browser.root.clone() else {
            return;
        };
        let request = EntryRequest {
            id: uuid::Uuid::new_v4().to_string(),
            kind,
            target: EditTarget {
                root,
                path: self.browser.path.clone(),
                folder: self.browser.path.clone(),
                generation: self.browser.generation,
            },
        };
        self.browser.edit.active = Some(request.id.clone());
        let command =
            name_prompt::entry_command(matches!(kind, EntryKind::Folder), self.locale, cx);
        self.run(Reply::EntryName(request), command, cx);
    }
    pub(super) fn begin_edit_file(&mut self, cx: &mut Context<Self>) {
        if !self.can_edit_file() {
            return;
        }
        let file = self.browser.file.as_ref().expect("editable snapshot");
        let draft = FileDraft {
            target: EditTarget {
                root: file.root.clone(),
                path: file.path.clone(),
                folder: self.browser.path.clone(),
                generation: self.browser.generation,
            },
            content: file.content.clone(),
            expected_revision: Some(file.revision.clone()),
            create_only: false,
            failed: false,
        };
        let request = FileEditRequest {
            id: uuid::Uuid::new_v4().to_string(),
            draft,
        };
        self.open_file_editor(request, cx);
    }
    pub(super) fn reopen_file_draft(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.aux_busy || self.browser.edit.busy() {
            return;
        }
        let Some(mut draft) = self.browser.edit.draft.clone() else {
            return;
        };
        let moved = self.browser.root.as_ref() != Some(&draft.target.root)
            || self.browser.path != draft.target.folder;
        if self.browser.root.as_ref() != Some(&draft.target.root) {
            let workspace = self
                .browser
                .workspaces
                .iter()
                .find(|workspace| {
                    workspace["workspace_id"] == draft.target.root["workspace_id"]
                        && workspace["binding_revision"] == draft.target.root["binding_revision"]
                        && workspace["status"] == "ok"
                        && workspace["capabilities"]["read"] == true
                        && workspace["capabilities"]["write"] == true
                })
                .cloned();
            let Some(workspace) = workspace else {
                self.notice = Some(self.locale.text(Text::DraftRetained).into());
                cx.notify();
                return;
            };
            self.browser.root = Some(draft.target.root.clone());
            self.browser.name = workspace["display_name"].as_str().unwrap_or("").into();
            self.browser.capabilities = workspace["capabilities"].clone();
            self.browser.entries.clear();
            self.browser.file = None;
            self.browser.git = Default::default();
        }
        if self.browser.capabilities["write"] != true {
            self.notice = Some(self.locale.text(Text::WorkspaceReadOnly).into());
            cx.notify();
            return;
        }
        self.page = Page::Files;
        // Explicit resume returns to the captured workspace and folder. Only
        // the view generation changes; the original disk revision never does.
        self.browser.generation += 1;
        draft.target.generation = self.browser.generation;
        let request = FileEditRequest {
            id: uuid::Uuid::new_v4().to_string(),
            draft,
        };
        if moved {
            self.browser.path = request.draft.target.folder.clone();
            self.browser.entries.clear();
            self.browser.file = None;
            self.browser.edit.active = Some(request.id.clone());
            let command = RuntimeCommand::new(
                "LocalWorkspace",
                "listV2",
                vec![json!({
                    "schema_version":1,"root":request.draft.target.root,
                    "path":request.draft.target.folder,"max_entries":1000,
                })],
            );
            self.run(Reply::ResumeDraftFolder(request), command, cx);
        } else {
            self.open_file_editor(request, cx);
        }
    }
    pub(super) fn discard_file_draft(&mut self, cx: &mut Context<Self>) {
        if self.browser.edit.busy() {
            return;
        }
        self.browser.edit.draft = None;
        self.notice = None;
        cx.notify();
    }
    fn open_file_editor(&mut self, request: FileEditRequest, cx: &mut Context<Self>) {
        self.browser.edit.active = Some(request.id.clone());
        let title = request.draft.target.path.rsplit('/').next().unwrap_or("");
        let command = RuntimeCommand::new(
            "ShellInput",
            "editFile",
            vec![json!({
                "initial_text":request.draft.content, "title":title,
                "appearance":name_prompt::appearance(cx), "save_label":self.locale.text(Text::Save),
                "cancel_label":self.locale.text(Text::Cancel), "max_bytes":MAX_EDIT_BYTES,
                "too_long_message":self.locale.text(Text::FileTooLarge),
            })],
        );
        self.run(Reply::FileEditor(request), command, cx);
    }
    pub(super) fn accept_workspace_edit(
        &mut self,
        reply: Reply,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        let id = match &reply {
            Reply::EntryName(r) | Reply::DirectoryCreated(r) => &r.id,
            Reply::FileEditor(r) | Reply::FileWritten(r) | Reply::ResumeDraftFolder(r) => &r.id,
            _ => unreachable!(),
        };
        if self.browser.edit.active.as_deref() != Some(id) {
            return;
        }
        self.aux_busy = false;
        match reply {
            Reply::EntryName(request) => self.accept_entry_name(request, result, cx),
            Reply::FileEditor(request) => self.accept_file_editor(request, result, cx),
            Reply::FileWritten(request) => self.accept_file_written(request, result, cx),
            Reply::ResumeDraftFolder(request) => self.accept_resume_folder(request, result, cx),
            Reply::DirectoryCreated(request) => self.accept_directory_created(request, result, cx),
            _ => unreachable!(),
        }
        cx.notify();
    }
    fn accept_resume_folder(
        &mut self,
        request: FileEditRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        let target = &request.draft.target;
        if self.page != Page::Files
            || self.browser.generation != target.generation
            || self.browser.root.as_ref() != Some(&target.root)
            || self.browser.capabilities["write"] != true
        {
            self.browser.edit.finish(&request.id);
            self.notice = Some(self.locale.text(Text::DraftRetained).into());
            return;
        }
        match result.and_then(|value| self.browser.accept_files(value, target.folder.clone())) {
            Ok(()) => self.open_file_editor(request, cx),
            Err(_) => {
                self.browser.edit.finish(&request.id);
                self.notice = Some(self.locale.text(Text::FileUnavailable).into());
            }
        }
    }
    fn accept_entry_name(
        &mut self,
        mut request: EntryRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        let name = match result {
            Ok(Value::String(name)) => name,
            Ok(Value::Null) => {
                self.browser.edit.finish(&request.id);
                return;
            }
            _ => {
                self.browser.edit.finish(&request.id);
                self.notice = Some(self.locale.text(Text::SaveError).into());
                return;
            }
        };
        if !request.target.current(&self.browser) || self.page != Page::Files {
            self.browser.edit.finish(&request.id);
            self.notice = Some(self.locale.text(Text::WorkspaceChanged).into());
            return;
        }
        let Some(path) = entry_path(&request.target.folder, &name) else {
            self.browser.edit.finish(&request.id);
            self.notice = Some(self.locale.text(Text::EntryNameInvalid).into());
            return;
        };
        request.target.path = path;
        match request.kind {
            EntryKind::File => self.open_file_editor(
                FileEditRequest {
                    id: request.id,
                    draft: FileDraft {
                        target: request.target,
                        content: String::new(),
                        expected_revision: None,
                        create_only: true,
                        failed: false,
                    },
                },
                cx,
            ),
            EntryKind::Folder => {
                let command = RuntimeCommand::new(
                    "LocalWorkspace",
                    "createDirectoryV2",
                    vec![json!({
                        "schema_version":1, "root":request.target.root, "path":request.target.path,
                    })],
                );
                self.run(Reply::DirectoryCreated(request), command, cx);
            }
        }
    }
    fn accept_file_editor(
        &mut self,
        mut request: FileEditRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        let content = match result {
            Ok(Value::String(content)) => content,
            Ok(Value::Null) => {
                self.browser.edit.finish(&request.id);
                return;
            }
            _ => {
                self.browser.edit.finish(&request.id);
                self.notice = Some(self.locale.text(Text::SaveError).into());
                return;
            }
        };
        request.draft.content = content;
        self.browser.edit.draft = Some(request.draft.clone());
        if !request.draft.target.current(&self.browser) || self.page != Page::Files {
            self.browser.edit.finish(&request.id);
            self.notice = Some(self.locale.text(Text::DraftRetained).into());
            return;
        }
        if request.draft.content.len() > MAX_EDIT_BYTES {
            self.browser.edit.finish(&request.id);
            self.notice = Some(self.locale.text(Text::FileTooLarge).into());
            return;
        }
        match request.draft.write_command() {
            Ok(command) => self.run(Reply::FileWritten(request), command, cx),
            Err(_) => {
                self.browser.edit.finish(&request.id);
                self.browser.edit.retain_failed(request.draft);
                self.notice = Some(self.locale.text(Text::FileSaveFailed).into());
            }
        }
    }
    fn accept_file_written(
        &mut self,
        request: FileEditRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.browser.edit.finish(&request.id);
        let parsed =
            result.and_then(|value| request.draft.accept_write(&value).map(|file| (file, value)));
        match parsed {
            Ok((file, value)) => {
                self.browser.edit.draft = None;
                if request.draft.target.current(&self.browser) && self.page == Page::Files {
                    self.browser.entries.retain(|e| e["path"] != file.path);
                    self.browser.entries.push(value["file"].clone());
                    self.browser.file = Some(file);
                }
                self.notice = None;
            }
            Err(error) => {
                let conflict = error.contains("CONFLICT") || error.contains("EXISTS");
                let recovery = error.split_whitespace().find_map(|part| {
                    let id = part.strip_prefix(".rish-file-recovery/rish-edit-")?;
                    let parsed = uuid::Uuid::parse_str(id).ok()?;
                    if parsed.to_string() != id {
                        return None;
                    }
                    Some(part.to_owned())
                });
                log::warn!("Workspace file save failed: {error}");
                self.browser.edit.retain_failed(request.draft);
                let mut message = self
                    .locale
                    .text(if conflict {
                        Text::FileChanged
                    } else {
                        Text::FileSaveFailed
                    })
                    .to_owned();
                if let Some(path) = recovery {
                    message.push_str(&format!(
                        "\n{} {path}",
                        self.locale.text(Text::RecoveryCopy)
                    ));
                }
                self.notice = Some(message);
            }
        }
        cx.notify();
    }
    fn accept_directory_created(
        &mut self,
        request: EntryRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.browser.edit.finish(&request.id);
        match result {
            Ok(value)
                if value["schema_version"] == 1
                    && value["root"] == request.target.root
                    && value["directory"]["path"] == request.target.path
                    && value["directory"]["kind"] == "directory" =>
            {
                if request.target.current(&self.browser) && self.page == Page::Files {
                    self.load_folder(request.target.folder, cx);
                }
                self.notice = None;
            }
            _ => self.notice = Some(self.locale.text(Text::SaveError).into()),
        }
    }
}

#[cfg(test)]
#[path = "workspace_edit_tests.rs"]
mod tests;
