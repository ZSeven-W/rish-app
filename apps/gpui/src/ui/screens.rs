#[cfg(not(any(target_os = "ios", target_os = "android")))]
use super::i18n::Text;
use super::{Page, Reply, Shell};
use gpui::Context;
use rish_shell_core::RuntimeCommand;
use serde_json::{Value, json};

#[derive(Default)]
pub(super) struct Browser {
    pub workspaces: Vec<Value>,
    pub workspaces_loaded: bool,
    pub root: Option<Value>,
    pub name: String,
    pub path: String,
    pub entries: Vec<Value>,
    pub file: Option<super::workspace_edit::FileSnapshot>,
    pub capabilities: Value,
    pub edit: super::workspace_edit::EditState,
    pub git: super::workspace_git::GitState,
    pub git_actions: super::git_operations::GitActions,
    pub generation: u64,
    // Keep desktop pane positions when the current window collapses to one column.
    pub files_directory_scroll: gpui::ScrollHandle,
    pub files_document_scroll: gpui::ScrollHandle,
    pub git_diff_scroll: gpui::ScrollHandle,
}
impl Browser {
    pub fn accept_workspaces(&mut self, value: Value) -> Result<(), String> {
        if value["schema_version"] != 1 {
            return Err("Unsupported workspace listing".into());
        }
        self.workspaces = value["workspaces"]
            .as_array()
            .ok_or("Missing workspace listing")?
            .clone();
        self.workspaces_loaded = true;
        Ok(())
    }
    pub fn accept_files(&mut self, value: Value, path: String) -> Result<(), String> {
        if value["schema_version"] != 1
            || value["root"] != self.root.clone().unwrap_or(Value::Null)
            || value["path"] != path
        {
            return Err("The workspace changed while loading this folder".into());
        }
        self.entries = value["entries"]
            .as_array()
            .ok_or("Missing directory entries")?
            .clone();
        if self.path != path {
            self.files_directory_scroll = gpui::ScrollHandle::new();
        }
        self.path = path;
        self.file = None;
        Ok(())
    }
    pub fn accept_read(&mut self, value: Value, path: String) -> Result<(), String> {
        let root = self.root.as_ref().ok_or("No workspace selected")?;
        let snapshot = super::workspace_edit::FileSnapshot::from_read(&value, root, &path)?;
        if self.file.as_ref().map(|file| file.path.as_str()) != Some(path.as_str()) {
            self.files_document_scroll = gpui::ScrollHandle::new();
        }
        self.file = Some(snapshot);
        Ok(())
    }
}
impl Shell {
    pub(super) fn create_workspace(&mut self, name: String, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.aux_busy || name.trim().is_empty() {
            return;
        }
        self.workspace_name_open = false;
        self.run(Reply::CreatedWorkspace,RuntimeCommand::new("LocalWorkspaces","create",vec![json!({
            "schema_version":1,"display_name":name.trim(),"operation_id":uuid::Uuid::new_v4().to_string()
        })]),cx);
    }
    pub(super) fn accept_created_workspace(
        &mut self,
        value: Value,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        if value["schema_version"] != 2 || !value["workspace_id"].is_string() {
            return Err("Invalid workspace descriptor".into());
        }
        self.browser
            .workspaces
            .retain(|w| w["workspace_id"] != value["workspace_id"]);
        self.browser.workspaces.push(value.clone());
        self.browser.workspaces_loaded = true;
        self.select_workspace(value, cx);
        Ok(())
    }
    pub(super) fn begin_create_workspace(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.aux_busy {
            return;
        }
        #[cfg(any(target_os = "ios", target_os = "android"))]
        self.run(
            Reply::WorkspaceName,
            super::name_prompt::command(
                super::name_prompt::NameKind::Workspace,
                "",
                self.locale,
                cx,
            ),
            cx,
        );
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        {
            self.title_input.update(cx, |input, cx| {
                input.set_text(String::new(), cx);
                input.set_placeholder(self.locale.text(Text::WorkspaceName), cx);
            });
            self.workspace_name_open = true;
            cx.notify();
        }
    }

    pub(super) fn select_workspace(&mut self, workspace: Value, cx: &mut Context<Self>) {
        self.bind_conversation_workspace(workspace, cx);
    }
    pub(super) fn refresh_workspace(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.aux_busy {
            return;
        }
        if self.browser.root.is_some() {
            if self.page == Page::Git {
                self.load_git(cx);
            } else {
                self.load_folder(self.browser.path.clone(), cx);
            }
        } else {
            self.run(
                Reply::Workspaces,
                RuntimeCommand::new("LocalWorkspaces", "list", vec![]),
                cx,
            );
        }
    }
    pub(super) fn load_folder(&mut self, path: String, cx: &mut Context<Self>) {
        if !self.runtime.is_native() {
            return;
        }
        let Some(root) = self.browser.root.clone() else {
            return;
        };
        self.browser.generation += 1;
        let command = RuntimeCommand::new(
            "LocalWorkspace",
            "listV2",
            vec![json!({"schema_version":1,"root":root,"path":path,"max_entries":1000})],
        );
        self.run(Reply::Files(self.browser.generation, path), command, cx);
    }
    pub(super) fn open_entry(&mut self, entry: Value, cx: &mut Context<Self>) {
        let Some(path) = entry["path"].as_str().map(str::to_owned) else {
            return;
        };
        if entry["kind"] == "directory" {
            self.load_folder(path, cx);
        } else if let Some(root) = self.browser.root.clone() {
            self.browser.generation += 1;
            self.run(
                Reply::Read(self.browser.generation, path.clone()),
                RuntimeCommand::new(
                    "LocalWorkspace",
                    "readV2",
                    vec![json!({"schema_version":1,"root":root,"path":path,"max_bytes":262144})],
                ),
                cx,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn browser() -> Browser {
        Browser {
            root: Some(
                json!({"schema_version":1,"workspace_id":"workspace-a","binding_revision":4,"project_id":null}),
            ),
            ..Browser::default()
        }
    }
    #[test]
    fn a_file_from_an_old_workspace_cannot_replace_the_current_preview() {
        let mut browser = browser();
        browser.file = Some(super::super::workspace_edit::FileSnapshot {
            root: browser.root.clone().unwrap(),
            path: "current.rs".into(),
            content: "current".into(),
            revision: "a".repeat(64),
            truncated: false,
        });
        let original = browser.file.clone();
        let reply = json!({"schema_version":1,"root":{"schema_version":1,"workspace_id":"workspace-b","binding_revision":4,"project_id":null},"path":"secret.rs","content":"other workspace"});
        assert!(browser.accept_read(reply, "secret.rs".into()).is_err());
        assert_eq!(browser.file, original);
    }
    #[test]
    fn a_directory_response_must_match_the_requested_path_and_authority() {
        let mut browser = browser();
        let reply = json!({"schema_version":1,"root":browser.root,"path":"src","entries":[{"name":"main.rs","path":"src/main.rs","kind":"file"}]});
        assert!(browser.accept_files(reply.clone(), "docs".into()).is_err());
        assert!(browser.entries.is_empty());
        browser.accept_files(reply, "src".into()).unwrap();
        assert_eq!(browser.path, "src");
        assert_eq!(browser.entries.len(), 1);
    }
    #[test]
    fn git_attachment_cannot_change_the_authorized_binding() {
        let mut browser = browser();
        let reply = json!({"schema_version":1,"project":{"project_id":"project-a","workspace_id":"workspace-a","workspace_binding_revision":5}});
        assert!(browser.accept_project(reply).is_err());
        assert!(browser.root.as_ref().unwrap()["project_id"].is_null());
        assert!(
            browser
                .accept_git(json!({"schema_version":2,"root":null,"entries":[]}))
                .is_err()
        );
        assert!(matches!(
            browser.git,
            super::super::workspace_git::GitState::Idle
        ));
    }
}
