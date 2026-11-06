use super::{Reply, Shell, git_commands, i18n::Locale};
use gpui::Context;
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum GitAction {
    Refresh,
    Stage,
    Commit,
    Fetch,
    Pull,
    Push,
    Remote,
    Credentials,
    CheckPush,
    Diff,
    DiffStaged,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum GitStep {
    Form,
    Stage,
    Commit,
    SetRemote,
    PromptCredential,
    PushCredential,
    BeforePush,
    Push,
    CheckPush,
    VerifyRemote,
    VerifyPush,
    Fetch,
    Pull,
    Status,
    Remote,
    Credential,
    Diff,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct GitActionRequest {
    pub generation: u64,
    pub root: Value,
    pub action: GitAction,
    pub step: GitStep,
    pub id: String,
    pub head: Value,
    pub branch: Value,
    pub host: Value,
    pub origin: Value,
    pub fields: Value,
    pub receipts: Vec<Value>,
    pub acknowledged: bool,
}
impl GitActionRequest {
    pub fn cancellable(&self) -> bool {
        matches!(
            self.step,
            GitStep::Fetch | GitStep::Push | GitStep::VerifyPush
        )
    }
}
#[derive(Clone, Debug)]
pub(super) enum GitFeedback {
    Done(GitAction),
    Cancelled,
    Error(String),
    PushUncertain,
    PushConfirmed,
    PushAcknowledged,
    PushNotConfirmed,
}
#[derive(Default)]
pub(super) struct GitActions {
    pub metadata_root: Option<Value>,
    pub remote: Option<Value>,
    pub credential: Option<Value>,
    pub diff: Option<Value>,
    pub pending: Option<GitActionRequest>,
    pub feedback: Option<GitFeedback>,
    pub cancel_requested: bool,
    pub cancelling: Option<GitActionRequest>,
    pub cancelled_operation: Option<String>,
    pub resume_after_cancel: Option<GitActionRequest>,
    /// Preserve ambiguous writes by captured root even when navigation changes.
    pub uncertain: HashMap<String, GitActionRequest>,
}
impl GitActions {
    fn invalidate_metadata(&mut self) {
        self.metadata_root = None;
        self.remote = None;
        self.credential = None;
        self.diff = None;
    }

    fn cancel_pending_for(&self, request: &GitActionRequest) -> bool {
        self.cancelled_operation.as_ref() == Some(&request.id)
            || self.cancelling.as_ref().is_some_and(|r| r.id == request.id)
    }

    pub fn has_uncertain_push(&self, root: Option<&Value>) -> bool {
        root.is_some_and(|r| self.uncertain.contains_key(&r.to_string()))
    }
}

impl Shell {
    pub(super) fn git_action_available(&self, action: GitAction) -> bool {
        self.runtime.is_native()
            && !self.aux_busy
            && git_commands::action_available(&self.browser, action)
    }

    pub(super) fn begin_git_action(&mut self, action: GitAction, cx: &mut Context<Self>) {
        if !self.git_action_available(action) {
            return;
        }
        let Some(root) = self.browser.root.clone() else {
            return;
        };
        let Some(git) = git_commands::status(&self.browser) else {
            return;
        };
        let mut request = GitActionRequest {
            generation: self.browser.generation,
            root,
            action,
            step: match action {
                GitAction::Refresh => GitStep::Remote,
                GitAction::Stage => GitStep::Stage,
                GitAction::Commit | GitAction::Remote => GitStep::Form,
                GitAction::Fetch | GitAction::Pull => GitStep::Fetch,
                GitAction::Push => GitStep::PushCredential,
                GitAction::Credentials => GitStep::PromptCredential,
                GitAction::CheckPush => GitStep::VerifyRemote,
                GitAction::Diff | GitAction::DiffStaged => GitStep::Diff,
            },
            id: uuid::Uuid::new_v4().to_string(),
            head: git["head_oid"].clone(),
            branch: git["branch"].clone(),
            host: self
                .browser
                .git_actions
                .remote
                .as_ref()
                .map(|r| r["host"].clone())
                .unwrap_or(Value::Null),
            origin: self
                .browser
                .git_actions
                .remote
                .as_ref()
                .map(|r| r["url"].clone())
                .unwrap_or(Value::Null),
            fields: Value::Null,
            receipts: Vec::new(),
            acknowledged: false,
        };
        if action == GitAction::CheckPush {
            let Some(original) = self
                .browser
                .git_actions
                .uncertain
                .get(&request.root.to_string())
            else {
                return;
            };
            request.head = original.head.clone();
            request.branch = original.branch.clone();
            request.host = original.host.clone();
            request.origin = original.origin.clone();
            request.receipts = original.receipts.clone();
            request.acknowledged = original.acknowledged;
        }
        if action == GitAction::Credentials {
            request.fields = json!({"locale":if self.locale == Locale::Zh {"zh-CN"} else {"en"}});
        }
        if action == GitAction::Refresh {
            self.browser.git_actions.invalidate_metadata();
        } else {
            self.browser.git_actions.feedback = None;
            self.browser.git_actions.diff = None;
        }
        if request.step == GitStep::Form {
            let initial = if action == GitAction::Remote {
                json!({"url":self.browser.git_actions.remote.as_ref().map(|r|r["url"].clone()).unwrap_or(json!(""))})
            } else {
                json!({"message":"","author_name":"","author_email":""})
            };
            let command = super::git_forms::command(action, &initial, self.locale, cx);
            self.browser.git_actions.pending = Some(request.clone());
            self.browser.git_actions.cancel_requested =
                self.browser.git_actions.cancel_pending_for(&request);
            self.run(Reply::GitAction(request), command, cx);
        } else {
            self.run_git_action(request, cx);
        }
    }

    pub(super) fn load_git_metadata(&mut self, cx: &mut Context<Self>) {
        self.browser.git_actions.invalidate_metadata();
        self.begin_git_action(GitAction::Refresh, cx);
    }

    fn run_git_action(&mut self, request: GitActionRequest, cx: &mut Context<Self>) {
        if request.cancellable()
            && self
                .browser
                .git_actions
                .cancelling
                .as_ref()
                .is_some_and(|r| r.root["project_id"] == request.root["project_id"])
        {
            self.browser.git_actions.pending = Some(request.clone());
            self.browser.git_actions.resume_after_cancel = Some(request);
            self.browser.git_actions.cancel_requested = true;
            self.aux_busy = true;
            cx.notify();
            return;
        }
        if request.step == GitStep::Push {
            // Write ambiguity is recorded before dispatch, never inferred from a
            // failed callback. No code path automatically resends this request.
            self.browser
                .git_actions
                .uncertain
                .insert(request.root.to_string(), request.clone());
        }
        self.browser.git_actions.pending = Some(request.clone());
        self.browser.git_actions.cancel_requested =
            self.browser.git_actions.cancel_pending_for(&request);
        let command = request.command();
        self.run(Reply::GitAction(request), command, cx);
    }

    pub(super) fn cancel_git_action(&mut self, cx: &mut Context<Self>) {
        let Some(request) = self
            .browser
            .git_actions
            .pending
            .clone()
            .filter(|r| r.cancellable())
        else {
            return;
        };
        if self.browser.git_actions.cancelling.is_some() {
            return;
        }
        self.browser.git_actions.cancel_requested = true;
        self.browser.git_actions.cancelling = Some(request.clone());
        self.browser.git_actions.cancelled_operation = Some(request.id.clone());
        let command = request.cancel_command();
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| this.accept_git_cancel(request, result, cx));
        })
        .detach();
        cx.notify();
    }

    pub(super) fn accept_git_cancel(
        &mut self,
        request: GitActionRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if self.browser.git_actions.cancelling.as_ref() != Some(&request) {
            return;
        }
        self.browser.git_actions.cancelling = None;
        self.browser.git_actions.cancel_requested =
            self.browser.git_actions.pending.as_ref().is_some_and(|r| {
                self.browser.git_actions.cancelled_operation.as_ref() == Some(&r.id)
            });
        if let Err(error) = result
            && request.current(&self.browser)
        {
            self.browser.git_actions.feedback = Some(GitFeedback::Error(error));
        }
        if let Some(deferred) = self.browser.git_actions.resume_after_cancel.take()
            && self.browser.git_actions.pending.as_ref() == Some(&deferred)
        {
            if deferred.current(&self.browser) {
                self.run_git_action(deferred, cx);
            } else {
                // This request was never dispatched and has no future callback
                // to release its busy state after navigation.
                self.browser.git_actions.pending = None;
                self.aux_busy = false;
            }
        }
        cx.notify();
    }

    pub(super) fn accept_git_action(
        &mut self,
        request: GitActionRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        // Even a stale push can settle its own captured-root ambiguity, without
        // changing the selected workspace or another request's busy ownership.
        if request.step == GitStep::Push
            && (result.as_ref().is_ok_and(|v| valid_push(&request, v))
                || result.as_ref().is_err_and(|e| definitely_not_written(e)))
        {
            self.browser
                .git_actions
                .uncertain
                .remove(&request.root.to_string());
        }
        if self.browser.git_actions.pending.as_ref() != Some(&request) {
            return;
        }
        self.browser.git_actions.pending = None;
        let cancelled = self.browser.git_actions.cancelled_operation.as_ref() == Some(&request.id);
        if self.browser.git_actions.cancelled_operation.as_ref() == Some(&request.id) {
            self.browser.git_actions.cancelled_operation = None;
        }
        self.browser.git_actions.cancel_requested = false;
        self.aux_busy = false;
        if !request.current(&self.browser) {
            cx.notify();
            return;
        }
        let result = result.and_then(|value| {
            if request.step != GitStep::Form {
                request.validate_envelope(&value)?;
            }
            Ok(value)
        });
        let value = match result {
            Ok(value) => value,
            Err(error) => {
                if request.step == GitStep::Push && definitely_not_written(&error) {
                    self.browser
                        .git_actions
                        .uncertain
                        .remove(&request.root.to_string());
                    self.browser.git_actions.feedback = Some(GitFeedback::Error(error));
                    self.run_git_action(
                        GitActionRequest {
                            step: GitStep::Status,
                            ..request
                        },
                        cx,
                    );
                } else if request.step == GitStep::Push {
                    self.browser.git_actions.feedback = Some(GitFeedback::PushUncertain);
                    self.run_git_action(
                        GitActionRequest {
                            step: GitStep::VerifyRemote,
                            ..request
                        },
                        cx,
                    );
                } else {
                    self.browser.git_actions.feedback = Some(
                        if matches!(
                            request.step,
                            GitStep::CheckPush | GitStep::VerifyRemote | GitStep::VerifyPush
                        ) {
                            if request.acknowledged {
                                GitFeedback::PushAcknowledged
                            } else {
                                GitFeedback::PushUncertain
                            }
                        } else if error.starts_with("E_PROJECT_CANCELLED") {
                            GitFeedback::Cancelled
                        } else {
                            GitFeedback::Error(error)
                        },
                    );
                }
                cx.notify();
                return;
            }
        };
        let checking_push = matches!(
            request.step,
            GitStep::Push | GitStep::CheckPush | GitStep::VerifyRemote | GitStep::VerifyPush
        );
        if let Err(error) = self.apply_git_action(request, value, cancelled, cx) {
            self.browser.git_actions.feedback = Some(if checking_push {
                GitFeedback::PushUncertain
            } else {
                GitFeedback::Error(error)
            });
        }
        cx.notify();
    }

    fn apply_git_action(
        &mut self,
        mut request: GitActionRequest,
        value: Value,
        cancelled: bool,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        match request.step {
            GitStep::Diff => {
                if value["staged"] != (request.action == GitAction::DiffStaged)
                    || !value["patch"].is_string()
                    || !value["truncated"].is_boolean()
                    || !value["files"].is_array()
                {
                    return Err("Invalid Git diff".into());
                }
                self.browser.git_actions.diff = Some(value);
                return Ok(());
            }
            GitStep::Form => {
                if value.is_null() {
                    self.browser.git_actions.feedback = Some(GitFeedback::Cancelled);
                    return Ok(());
                }
                git_commands::validate_fields(request.action, &value)?;
                // An unrelated UI update cannot replace the snapshot a native
                // author form was opened against.
                if request.action == GitAction::Commit
                    && git_commands::status(&self.browser).map(|s| &s["head_oid"])
                        != Some(&request.head)
                {
                    return Err("Git HEAD changed; refresh before committing".into());
                }
                request.fields = value;
                request.step = if request.action == GitAction::Commit {
                    GitStep::Commit
                } else {
                    GitStep::SetRemote
                };
            }
            GitStep::Stage => {
                self.browser.git_actions.diff = None;
                self.browser.accept_git(value)?;
                self.browser.git_actions.feedback = Some(GitFeedback::Done(request.action));
                request.step = GitStep::Remote;
            }
            GitStep::Commit => {
                if !git_commands::valid_oid(&value["oid"]) || !value["summary"].is_string() {
                    return Err(
                        "Commit could not be confirmed; refresh Git status before another commit"
                            .into(),
                    );
                }
                self.browser.git_actions.feedback = Some(GitFeedback::Done(request.action));
                request.step = GitStep::Status;
            }
            GitStep::SetRemote => {
                validate_remote(&value)?;
                self.browser.git_actions.remote = Some(value);
                self.browser.git_actions.credential = None;
                self.browser.git_actions.feedback = Some(GitFeedback::Done(request.action));
                request.step = GitStep::Status;
            }
            GitStep::PromptCredential => {
                if !value["configured"].is_boolean() {
                    return Err("Invalid credential status".into());
                }
                self.browser.git_actions.feedback = Some(if value["configured"] == true {
                    GitFeedback::Done(request.action)
                } else {
                    GitFeedback::Cancelled
                });
                request.step = GitStep::Remote;
            }
            GitStep::PushCredential => {
                if value["host"] != request.host || !value["configured"].is_boolean() {
                    return Err("Credential host changed; refresh before pushing".into());
                }
                let configured = value["configured"] == true;
                self.browser.git_actions.credential = Some(value);
                if !configured {
                    return Err("E_PROJECT_UNAVAILABLE".into());
                }
                request.step = GitStep::BeforePush;
            }
            GitStep::BeforePush => {
                request.receipts = validate_receipts(&value)?;
                request.step = GitStep::Push;
            }
            GitStep::Push => {
                if !valid_push(&request, &value) {
                    self.browser.git_actions.feedback = Some(GitFeedback::PushUncertain);
                    request.step = GitStep::VerifyRemote;
                } else {
                    self.browser
                        .git_actions
                        .uncertain
                        .remove(&request.root.to_string());
                    self.browser.git_actions.feedback = Some(GitFeedback::Done(request.action));
                    request.step = GitStep::Status;
                }
            }
            GitStep::CheckPush => {
                let receipts = validate_receipts(&value)?;
                request.acknowledged |= confirms_push(&request, &receipts);
                if request.acknowledged {
                    if let Some(attempt) = self
                        .browser
                        .git_actions
                        .uncertain
                        .get_mut(&request.root.to_string())
                    {
                        attempt.acknowledged = true;
                    }
                }
                // A receipt is acknowledgement evidence. Only fresh fetch can
                // establish the current remote tip; never call a receipt readback.
                request.step = GitStep::VerifyPush;
            }
            GitStep::VerifyRemote => {
                validate_remote(&value)?;
                if value["url"] != request.origin || value["host"] != request.host {
                    self.browser.git_actions.feedback = Some(GitFeedback::PushUncertain);
                    return Ok(());
                }
                request.step = GitStep::CheckPush;
            }
            GitStep::VerifyPush => {
                if value["remote"] == "origin"
                    && value["branch"] == request.branch
                    && value["remote_oid"] == request.head
                {
                    self.browser
                        .git_actions
                        .uncertain
                        .remove(&request.root.to_string());
                    self.browser.git_actions.feedback = Some(GitFeedback::PushConfirmed);
                    request.step = GitStep::Status;
                } else if value["remote"] == "origin"
                    && value["branch"] == request.branch
                    && (value["remote_oid"].is_null()
                        || git_commands::valid_oid(&value["remote_oid"]))
                {
                    // Fresh remote state is known. Clear the no-blind-retry lock,
                    // but only a new explicit tap may send another normal push.
                    self.browser
                        .git_actions
                        .uncertain
                        .remove(&request.root.to_string());
                    self.browser.git_actions.feedback = Some(GitFeedback::PushNotConfirmed);
                    request.step = GitStep::Status;
                } else {
                    self.browser.git_actions.feedback = Some(GitFeedback::PushUncertain);
                    return Ok(());
                }
            }
            GitStep::Fetch => {
                if value["remote"] != "origin"
                    || value["branch"] != request.branch
                    || (!value["remote_oid"].is_null()
                        && !git_commands::valid_oid(&value["remote_oid"]))
                {
                    return Err("Invalid fetch result".into());
                }
                if request.action == GitAction::Pull && !cancelled {
                    request.step = GitStep::Pull;
                } else {
                    self.browser.git_actions.feedback = Some(if cancelled {
                        GitFeedback::Cancelled
                    } else {
                        GitFeedback::Done(request.action)
                    });
                    request.step = GitStep::Status;
                }
            }
            GitStep::Pull => {
                if value["branch"] != request.branch
                    || value["previous_oid"] != request.head
                    || !git_commands::valid_oid(&value["oid"])
                    || !value["updated"].is_boolean()
                {
                    return Err("Pull could not be confirmed; refresh Git status".into());
                }
                self.browser.git_actions.feedback = Some(GitFeedback::Done(request.action));
                request.step = GitStep::Status;
            }
            GitStep::Status => {
                self.browser.git_actions.diff = None;
                self.browser.accept_git(value)?;
                request.step = GitStep::Remote;
            }
            GitStep::Remote => {
                validate_remote(&value)?;
                let has_remote = value["url"].is_string();
                self.browser.git_actions.remote = Some(value);
                self.browser.git_actions.credential = None;
                self.browser.git_actions.metadata_root = Some(request.root.clone());
                if !has_remote {
                    return Ok(());
                }
                request.step = GitStep::Credential;
            }
            GitStep::Credential => {
                if !value["configured"].is_boolean()
                    || !value["host"].is_string()
                    || self.browser.git_actions.remote.as_ref().map(|v| &v["host"])
                        != Some(&value["host"])
                {
                    return Err("Credential host changed; refresh repository settings".into());
                }
                self.browser.git_actions.credential = Some(value);
                return Ok(());
            }
        }
        self.run_git_action(request, cx);
        Ok(())
    }
}

fn validate_remote(value: &Value) -> Result<(), String> {
    if value["remote"] != "origin"
        || value["url"].is_null() != value["host"].is_null()
        || !value
            .get("url")
            .is_some_and(|v| v.is_null() || v.is_string())
        || !value
            .get("host")
            .is_some_and(|v| v.is_null() || v.is_string())
    {
        return Err("Invalid origin metadata".into());
    }
    Ok(())
}
fn valid_push(request: &GitActionRequest, value: &Value) -> bool {
    request.validate_envelope(value).is_ok()
        && value["remote"] == "origin"
        && value["branch"] == request.branch
        && value["oid"] == request.head
        && value["pushed_at"].is_string()
}
fn validate_receipts(value: &Value) -> Result<Vec<Value>, String> {
    let receipts = value["receipts"]
        .as_array()
        .ok_or("Invalid push receipts")?;
    if receipts.iter().any(|r| {
        r["schema_version"] != 1
            || r["remote"] != "origin"
            || !r["host"].is_string()
            || !r["branch"].is_string()
            || !git_commands::valid_oid(&r["local_oid"])
            || !r["pushed_at"].is_string()
    }) {
        return Err("Invalid push receipt".into());
    }
    Ok(receipts.clone())
}
pub(super) fn confirms_push(request: &GitActionRequest, receipts: &[Value]) -> bool {
    receipts.iter().any(|r| {
        r["remote"] == "origin"
            && r["host"] == request.host
            && r["branch"] == request.branch
            && r["local_oid"] == request.head
            && r["remote_oid"] == request.head
            && !request.receipts.contains(r)
    })
}

/// These errors are emitted before transport or for an explicit ref rejection
/// on both hosts. Auth, cancellation, timeout, unavailable, and generic errors
/// can follow sent bytes and must remain uncertain.
pub(super) fn definitely_not_written(error: &str) -> bool {
    matches!(
        error.split(':').next().unwrap_or("").trim(),
        "E_PROJECT_REQUEST_INVALID"
            | "E_PROJECT_CONFLICT"
            | "E_PROJECT_NON_FAST_FORWARD"
            | "E_WORKSPACE_CONFIRMATION"
    )
}
