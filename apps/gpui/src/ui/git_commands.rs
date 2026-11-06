use super::{git_operations::*, screens::Browser, workspace_git::GitState};
use rish_shell_core::RuntimeCommand;
use serde_json::{Value, json};

impl GitActionRequest {
    pub fn current(&self, browser: &Browser) -> bool {
        self.generation == browser.generation && browser.root.as_ref() == Some(&self.root)
    }

    pub fn command(&self) -> RuntimeCommand {
        let mut args = json!({"schema_version":1,"root":self.root});
        let method = match self.step {
            GitStep::Remote | GitStep::VerifyRemote => "remoteV2",
            GitStep::Credential | GitStep::PushCredential => "credentialStatusV2",
            GitStep::Status => "statusV2",
            GitStep::BeforePush | GitStep::CheckPush => "pushReceiptsV2",
            GitStep::Stage => "stageAllV2",
            GitStep::Diff => {
                args["staged"] = json!(self.action == GitAction::DiffStaged);
                args["max_bytes"] = json!(262144);
                "diffV2"
            }
            GitStep::Commit => {
                args["operation_id"] = json!(self.id);
                args["message"] = self.fields["message"].clone();
                args["author_name"] = self.fields["author_name"].clone();
                args["author_email"] = self.fields["author_email"].clone();
                args["expected_head_oid"] = self.head.clone();
                "commitV2"
            }
            GitStep::SetRemote => {
                args["url"] = self.fields["url"].clone();
                "setRemoteV2"
            }
            GitStep::PromptCredential => {
                args["locale"] = self.fields["locale"].clone();
                "presentCredentialPromptV2"
            }
            GitStep::Fetch | GitStep::VerifyPush => {
                args["operation_id"] = json!(self.id);
                args["remote"] = json!("origin");
                args["https_proxy_url"] = Value::Null;
                "fetchV2"
            }
            GitStep::Pull => {
                args["expected_head_oid"] = self.head.clone();
                "pullFastForwardV2"
            }
            GitStep::Push => {
                args["operation_id"] = json!(self.id);
                args["remote"] = json!("origin");
                args["expected_local_oid"] = self.head.clone();
                // Native resolves the actual secret by project and origin host.
                args["credential_reference"] = json!("native-keychain");
                args["https_proxy_url"] = Value::Null;
                "pushV2"
            }
            GitStep::Form => unreachable!("native form command is localized separately"),
        };
        RuntimeCommand::new("LocalProjects", method, vec![args])
    }

    pub fn cancel_command(&self) -> RuntimeCommand {
        RuntimeCommand::new(
            "LocalProjects",
            "cancelPushV2",
            vec![json!({
                "schema_version":1,"root":self.root,"operation_id":self.id
            })],
        )
    }

    pub fn validate_envelope(&self, value: &Value) -> Result<(), String> {
        if value["schema_version"] != 2
            || value["root"] != self.root
            || value["project_id"] != self.root["project_id"]
        {
            return Err("The Git workspace changed during this operation".into());
        }
        Ok(())
    }
}

pub(super) fn status(browser: &Browser) -> Option<&Value> {
    match &browser.git {
        GitState::Attached(value) => Some(value),
        _ => None,
    }
}

pub(super) fn valid_oid(value: &Value) -> bool {
    value.as_str().is_some_and(|s| {
        s.len() == 40
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

pub(super) fn action_available(browser: &Browser, action: GitAction) -> bool {
    if browser.git_actions.pending.is_some()
        || (action != GitAction::Refresh
            && browser.git_actions.cancelling.as_ref().is_some_and(|r| {
                browser
                    .root
                    .as_ref()
                    .is_some_and(|root| root["project_id"] == r.root["project_id"])
            }))
        || browser.capabilities["git"] != true
    {
        return false;
    }
    if matches!(
        action,
        GitAction::Stage
            | GitAction::Commit
            | GitAction::Fetch
            | GitAction::Pull
            | GitAction::Push
            | GitAction::Remote
            | GitAction::CheckPush
    ) && browser.capabilities["write"] != true
    {
        return false;
    }
    let Some(git) = status(browser) else {
        return false;
    };
    let Some(root) = browser.root.as_ref() else {
        return false;
    };
    if git["root"] != *root || git["project_id"] != root["project_id"] {
        return false;
    }
    let metadata = Some(root) == browser.git_actions.metadata_root.as_ref();
    let remote = metadata
        && browser
            .git_actions
            .remote
            .as_ref()
            .is_some_and(|v| v["url"].is_string());
    let configured = metadata
        && browser
            .git_actions
            .credential
            .as_ref()
            .is_some_and(|v| v["configured"] == true);
    let head = valid_oid(&git["head_oid"]) && git["branch"].is_string();
    let conflicts = git["has_conflicts"] == true;
    let entries = git["entries"].as_array();
    let pending_push = browser
        .git_actions
        .uncertain
        .contains_key(&root.to_string());
    match action {
        GitAction::Refresh | GitAction::Diff | GitAction::DiffStaged => true,
        GitAction::Stage => {
            !conflicts
                && entries.is_some_and(|e| e.iter().any(|e| e["worktree_status"] != "unmodified"))
        }
        GitAction::Commit => {
            !conflicts
                && entries.is_some_and(|e| e.iter().any(|e| e["index_status"] != "unmodified"))
        }
        GitAction::Fetch => head && remote,
        GitAction::Pull => head && remote && git["clean"] == true && !conflicts,
        GitAction::Push => head && remote && configured && !pending_push,
        GitAction::Remote => !pending_push,
        GitAction::Credentials => remote,
        GitAction::CheckPush => pending_push,
    }
}

pub(super) fn validate_fields(action: GitAction, value: &Value) -> Result<(), String> {
    let bounded = |key: &str, max: usize| {
        value[key].as_str().is_some_and(|s| {
            !s.is_empty()
                && s.len() <= max
                && s.trim() == s
                && !s
                    .chars()
                    .any(|c| c.is_control() || c == '\u{2028}' || c == '\u{2029}')
        })
    };
    match action {
        GitAction::Commit => {
            if !bounded("message", 500)
                || !bounded("author_name", 120)
                || !bounded("author_email", 254)
            {
                return Err("Invalid commit summary or author identity".into());
            }
            let name = value["author_name"].as_str().unwrap();
            let email = value["author_email"].as_str().unwrap();
            let parts: Vec<_> = email.split('@').collect();
            if name.contains(['<', '>'])
                || email.contains(['<', '>'])
                || email.chars().any(char::is_whitespace)
                || parts.len() != 2
                || parts.iter().any(|p| p.is_empty())
            {
                return Err("Invalid commit author identity".into());
            }
        }
        GitAction::Remote => {
            if !bounded("url", 4096) {
                return Err("Invalid origin URL".into());
            }
            let url = value["url"].as_str().unwrap();
            let Some(rest) = url
                .strip_prefix("https://")
                .or_else(|| url.strip_prefix("http://"))
            else {
                return Err("Origin requires an HTTP or HTTPS URL".into());
            };
            if rest.is_empty()
                || rest.starts_with('/')
                || rest.contains(['@', '?', '#'])
                || rest.chars().any(char::is_whitespace)
            {
                return Err(
                    "Origin URL must not contain credentials, a query, or a fragment".into(),
                );
            }
        }
        _ => return Err("Unexpected Git form".into()),
    }
    Ok(())
}
