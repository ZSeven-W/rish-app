use crate::{model::*, selected_mut, ShellState};
use serde_json::{json, Value};

/// Convert a native registry descriptor into conversation authority. A Git
/// browser project id is deliberately not conversation project consent.
pub fn workspace_binding(descriptor: &Value) -> Result<Value> {
    let valid_id = descriptor["workspace_id"]
        .as_str()
        .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok_and(|u| u.to_string() == id));
    let valid_revision = descriptor["binding_revision"]
        .as_u64()
        .is_some_and(|n| n > 0 && n < 9_007_199_254_740_991);
    if descriptor["schema_version"] != 2
        || !valid_id
        || !valid_revision
        || descriptor["status"] != "ok"
        || descriptor["capabilities"]["read"] != true
        || !descriptor["display_name"].is_string()
    {
        return Err("E_CONVERSATION_WORKSPACE_UNAVAILABLE".into());
    }
    Ok(
        json!({"schema_version":1,"workspace_id":descriptor["workspace_id"],"binding_revision":descriptor["binding_revision"],"project_id":null}),
    )
}

impl ShellState {
    pub fn set_default_workspace(&mut self, descriptor: Value) -> Result<()> {
        workspace_binding(&descriptor)?;
        self.default_workspace = Some(descriptor);
        Ok(())
    }
    pub fn default_workspace(&self) -> Option<&Value> {
        self.default_workspace.as_ref()
    }
    pub fn active_workspace_binding(&self) -> Option<&Value> {
        self.selected()
            .and_then(|c| c.get("workspace_binding"))
            .filter(|v| v.is_object())
    }
    pub fn has_unbound_workspaces(&self) -> bool {
        rows(&self.session, "conversations")
            .iter()
            .any(eligible_unbound)
    }
    pub fn migrate_unbound_workspaces(&mut self) -> Result<Option<RuntimeCommand>> {
        self.ready()?;
        if !self.has_unbound_workspaces() {
            return Ok(None);
        }
        let binding = workspace_binding(
            self.default_workspace
                .as_ref()
                .ok_or("E_CONVERSATION_WORKSPACE_REQUIRED")?,
        )?;
        let mut candidate = self.session.clone();
        for c in candidate["conversations"]
            .as_array_mut()
            .ok_or("Missing conversations")?
        {
            // Legacy project/workspace recovery is independent of plain chat
            // migration, so one unresolved legacy item cannot block all chats.
            if !eligible_unbound(c) {
                continue;
            }
            c["workspace_id"] = binding["workspace_id"].clone();
            c["workspace_binding"] = binding.clone();
            c["workspace_bootstrap_state"] = json!("none");
        }
        self.commit(candidate, None, false).map(Some)
    }
    pub fn bind_active_workspace(&mut self, descriptor: &Value) -> Result<RuntimeCommand> {
        self.ready()?;
        let binding = workspace_binding(descriptor)?;
        let mut candidate = self.session.clone();
        let c = selected_mut(&mut candidate)?;
        if !c["project_id"].is_null() {
            return Err("E_CONVERSATION_WORKSPACE_LOCKED".into());
        }
        if c["workspace_binding"] != binding
            && !c["workspace_binding"].is_null()
            && (!rows(c, "messages").is_empty()
                || !rows(c, "turns").is_empty()
                || !rows(c, "attempts").is_empty())
        {
            return Err("E_CONVERSATION_WORKSPACE_LOCKED".into());
        }
        if active(c) {
            return Err("E_CONVERSATION_WORKSPACE_LOCKED".into());
        }
        c["workspace_id"] = binding["workspace_id"].clone();
        c["workspace_binding"] = binding;
        c["workspace_bootstrap_state"] = json!("none");
        self.commit(candidate, None, false)
    }
    pub fn create_conversation_configured(
        &mut self,
        id: &str,
        now: &str,
        model: &str,
        thinking: &str,
    ) -> Result<RuntimeCommand> {
        self.create_conversation_with_title(id, now, model, thinking, None)
    }
    /// An assistant task already has a user-chosen name. Save it with the
    /// conversation's initial workspace CAS so the first contextual prompt
    /// cannot replace it, and no separate rename needs replay on recovery.
    pub fn create_task_conversation(
        &mut self,
        id: &str,
        now: &str,
        model: &str,
        title: &str,
    ) -> Result<RuntimeCommand> {
        self.create_conversation_with_title(id, now, model, "high", Some(title))
    }
    fn create_conversation_with_title(
        &mut self,
        id: &str,
        now: &str,
        model: &str,
        thinking: &str,
        title: Option<&str>,
    ) -> Result<RuntimeCommand> {
        self.ready()?;
        let binding = workspace_binding(
            self.default_workspace
                .as_ref()
                .ok_or("E_CONVERSATION_WORKSPACE_REQUIRED")?,
        )?;
        if !["off", "high", "max"].contains(&thinking) {
            return Err("Invalid thinking mode".into());
        }
        if rows(&self.session, "conversations")
            .iter()
            .any(|c| text(c, "id") == id)
        {
            return Err("Conversation already exists".into());
        }
        if !model.is_empty() && !self.catalog.iter().any(|m| m.id == model) {
            return Err("Choose a current model".into());
        }
        let (title, title_source) = match title {
            Some(title) => (
                rish_agent_core::name_policy::automatic_title(title),
                "manual",
            ),
            None => ("New chat".into(), "auto"),
        };
        let mut candidate = self.session.clone();
        candidate["conversations"].as_array_mut().ok_or("Missing conversation list")?.push(json!({
            "id":id,"project_id":null,"workspace_id":binding["workspace_id"],"title":title,"title_source":title_source,
            "model_id":if model.is_empty(){Value::Null}else{json!(model)},"thinking_mode":thinking,"messages":[],"created_at":now,"updated_at":now,
            "runtime_context_id":null,"project_context":null,"turns":[],"attempts":[],"workspace_binding":binding,
            "workspace_bootstrap_state":"none","agent_grants":[]
        }));
        candidate["active_conversation_id"] = json!(id);
        self.commit(candidate, None, false)
    }
}

fn eligible_unbound(c: &Value) -> bool {
    c["workspace_binding"].is_null()
        && c["workspace_id"].is_null()
        && c["project_id"].is_null()
        && c["workspace_bootstrap_state"] == "none"
}
