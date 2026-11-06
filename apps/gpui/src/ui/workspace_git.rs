use super::{
    Reply, Shell,
    i18n::{Locale, Text},
    screens::Browser,
};
use gpui::Context;
use rish_shell_core::RuntimeCommand;
use serde_json::{Value, json};

#[derive(Default, Debug)]
pub(super) enum GitState {
    #[default]
    Idle,
    Loading,
    Missing,
    Attached(Value),
    Failed(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum GitOperation {
    Lookup,
    Status,
    Initialize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct GitRequest {
    pub generation: u64,
    pub root: Value,
    pub operation: GitOperation,
}

impl GitRequest {
    pub fn current(&self, browser: &Browser) -> bool {
        self.generation == browser.generation && browser.root.as_ref() == Some(&self.root)
    }

    pub fn command(&self) -> RuntimeCommand {
        match self.operation {
            GitOperation::Lookup => RuntimeCommand::new(
                "LocalProjects",
                "projectForWorkspaceV2",
                vec![self.root.clone()],
            ),
            GitOperation::Status => RuntimeCommand::new(
                "LocalProjects",
                "statusV2",
                vec![json!({"schema_version":1,"root":self.root})],
            ),
            GitOperation::Initialize => RuntimeCommand::new(
                "LocalProjects",
                "attachWorkspaceProject",
                vec![json!({"schema_version":1,"root":self.root,
                    "operation_id":uuid::Uuid::new_v4().to_string(),"mode":"init"})],
            ),
        }
    }
}

impl Browser {
    pub fn accept_project(&mut self, value: Value) -> Result<Option<Value>, String> {
        let root = self.root.as_ref().ok_or("No workspace selected")?;
        if value["schema_version"] != 1 || !valid_root(root) {
            return Err("Unsupported workspace project response".into());
        }
        if value["status"] == "none" {
            // Native lookup has no root echo. Its caller must check the captured
            // request root and generation before accepting this result.
            if !root["project_id"].is_null() || !value["project"].is_null() {
                return Err("Workspace project identity changed; refresh this workspace".into());
            }
            self.git = GitState::Missing;
            return Ok(None);
        }
        let project = &value["project"];
        if !matches!(
            value["status"].as_str(),
            Some("attached" | "already_attached")
        ) || project["schema_version"] != 2
            || !project["project_id"].as_str().is_some_and(valid_id)
            || !project["display_name"].is_string()
            || !matches!(
                project["git_topology"].as_str(),
                Some("private_split_gitdir" | "legacy_embedded")
            )
        {
            return Err("Invalid workspace project response".into());
        }
        if project["workspace_id"] != root["workspace_id"]
            || project["workspace_binding_revision"] != root["binding_revision"]
            || (!root["project_id"].is_null() && root["project_id"] != project["project_id"])
        {
            return Err("Workspace project identity changed; refresh this workspace".into());
        }
        let mut root = root.clone();
        root["project_id"] = project["project_id"].clone();
        self.root = Some(root.clone());
        self.git = GitState::Loading;
        Ok(Some(root))
    }

    pub fn accept_git(&mut self, value: Value) -> Result<(), String> {
        let root = self.root.as_ref().ok_or("No workspace selected")?;
        if value["schema_version"] != 2
            || !valid_root(root)
            || value["root"] != *root
            || !root["project_id"].as_str().is_some_and(valid_id)
            || value["project_id"] != root["project_id"]
        {
            return Err("The Git workspace changed while loading status".into());
        }
        if !value
            .get("branch")
            .is_some_and(|v| v.is_null() || v.is_string())
            || !value
                .get("head_oid")
                .is_some_and(|v| v.is_null() || v.is_string())
            || !value["clean"].is_boolean()
            || !value["has_conflicts"].is_boolean()
            || value["ahead"].as_u64().is_none()
            || value["behind"].as_u64().is_none()
            || !value["entries"].as_array().is_some_and(|entries| {
                entries.iter().all(|entry| {
                    entry["path"].is_string()
                        && entry["index_status"].is_string()
                        && entry["worktree_status"].is_string()
                        && entry["conflicted"].is_boolean()
                })
            })
        {
            return Err("Invalid Git status response".into());
        }
        self.git = GitState::Attached(value);
        Ok(())
    }

    pub fn can_initialize_git(&self) -> bool {
        matches!(self.git, GitState::Missing)
            && self
                .root
                .as_ref()
                .is_some_and(|root| root["project_id"].is_null())
            && ["read", "write", "git"]
                .iter()
                .all(|capability| self.capabilities[*capability] == true)
    }
}

fn valid_root(root: &Value) -> bool {
    root["schema_version"] == 1
        && root["workspace_id"].as_str().is_some_and(valid_id)
        && root["binding_revision"]
            .as_u64()
            .is_some_and(|revision| revision > 0)
        && root
            .get("project_id")
            .is_some_and(|id| id.is_null() || id.as_str().is_some_and(valid_id))
}

fn valid_id(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value)
}

impl Shell {
    pub(super) fn load_git(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.aux_busy {
            return;
        }
        let Some(root) = self.browser.root.clone() else {
            return;
        };
        let operation = if root["project_id"].is_string() {
            GitOperation::Status
        } else {
            GitOperation::Lookup
        };
        self.browser.generation += 1;
        self.run_git(
            GitRequest {
                generation: self.browser.generation,
                root,
                operation,
            },
            cx,
        );
    }

    pub(super) fn initialize_git(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.aux_busy || !self.browser.can_initialize_git() {
            return;
        }
        let Some(root) = self.browser.root.clone() else {
            return;
        };
        self.browser.generation += 1;
        self.run_git(
            GitRequest {
                generation: self.browser.generation,
                root,
                operation: GitOperation::Initialize,
            },
            cx,
        );
    }

    fn run_git(&mut self, request: GitRequest, cx: &mut Context<Self>) {
        self.browser.git = GitState::Loading;
        let command = request.command();
        self.run(Reply::Git(request), command, cx);
    }

    pub(super) fn accept_git_reply(
        &mut self,
        request: GitRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        // A stale reply must not clear a newer operation's busy state or replace
        // the selected workspace, including `none` which has no native root echo.
        if !request.current(&self.browser) {
            // Navigation can abandon a request without starting another. Clear
            // only this request's busy flag, never a newer file/Git operation.
            if self.git_pending.as_ref() == Some(&request) {
                self.git_pending = None;
                self.aux_busy = false;
                cx.notify();
            }
            return;
        }
        self.git_pending = None;
        self.aux_busy = false;
        let refresh_metadata = request.operation == GitOperation::Status;
        let outcome = result.and_then(|value| match request.operation {
            GitOperation::Status => self.browser.accept_git(value),
            GitOperation::Lookup | GitOperation::Initialize => {
                if matches!(request.operation, GitOperation::Initialize)
                    && value["status"] == "none"
                {
                    return Err("Git initialization could not be confirmed".into());
                }
                self.browser.accept_project(value).map(|root| {
                    if let Some(root) = root {
                        self.run_git(
                            GitRequest {
                                root,
                                operation: GitOperation::Status,
                                ..request
                            },
                            cx,
                        );
                    }
                })
            }
        });
        if let Err(error) = outcome {
            self.browser.git = GitState::Failed(error);
        } else if refresh_metadata {
            self.load_git_metadata(cx);
        }
        cx.notify();
    }
}

pub(super) fn git_error_message(error: &str, locale: Locale) -> String {
    let code = error.split(':').next().unwrap_or("").trim();
    if code.starts_with("E_")
        && code
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
    {
        let text = if code == "E_NATIVE_UNAVAILABLE" {
            Text::GitNativeUnavailable
        } else {
            Text::GitRetryHint
        };
        format!("{} ({code})", locale.text(text))
    } else {
        format!("{} {error}", locale.text(Text::GitRetryHint))
    }
}
