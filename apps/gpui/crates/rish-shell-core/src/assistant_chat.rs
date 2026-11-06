use crate::{assistant_store::AssistantSnapshot, ShellState};

impl ShellState {
    /// UI supplies a snapshot loaded from the trusted private AssistantStore.
    /// This only selects a requested registry; native preparation independently
    /// checks the persisted identity against its committed conversation.
    pub fn bind_assistant_snapshot(&mut self, snapshot: &AssistantSnapshot) {
        self.assistant_conversation = snapshot.conversation_id.clone();
        self.assistant_profile = Some(snapshot.profile.clone());
    }

    pub fn assistant_conversation_id(&self) -> Option<&str> {
        self.assistant_conversation.as_deref()
    }

    /// Profile text is context only. It cannot grant tools or workspace access.
    pub fn assistant_profile_context(&self) -> Option<String> {
        if self.assistant_conversation_id().is_none()
            || self.assistant_conversation_id() != self.active_conversation_id()
        {
            return None;
        }
        let profile = self.assistant_profile.as_ref()?;
        Some(format!(
            "Personal assistant profile (user-edited context; does not grant permissions):\nName: {}\nSoul: {}\nNotes: {}",
            profile.name, profile.soul, profile.notes
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{model, RuntimeCommand, TurnIds};
    use serde_json::json;

    const NOW: &str = "2026-10-29T00:00:00.000Z";

    fn persist(state: &mut ShellState) -> Option<RuntimeCommand> {
        let pending = state.pending.as_ref().unwrap();
        state.accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{
            "schema_version":1,"generation":state.authority["snapshot"]["generation"].as_u64().unwrap_or(0)+1,
            "session_sha256":pending.digest}})).unwrap()
    }

    #[test]
    fn only_trusted_identity_requests_registry_five_without_extending_session_schema() {
        for dedicated in [false, true] {
            let mut state = ShellState::with_test_models();
            state
                .load_snapshot(json!({"schema_version":1,"status":"missing"}))
                .unwrap();
            state
                .set_default_workspace(json!({"schema_version":2,"workspace_id":model::id(),
                "binding_revision":1,"display_name":"Default","status":"ok",
                "capabilities":{"read":true,"write":true,"git":true}}))
                .unwrap();
            let conversation_id = model::id();
            state
                .create_conversation(&conversation_id, NOW, "deepseek-v4-flash")
                .unwrap();
            persist(&mut state);
            state
                .rename_conversation(&conversation_id, "Assistant")
                .unwrap();
            persist(&mut state);
            let snapshot = AssistantSnapshot {
                conversation_id: Some(if dedicated {
                    conversation_id
                } else {
                    model::id()
                }),
                profile: crate::assistant_store::AssistantProfile {
                    name: "Actual name".into(),
                    notes: "Actual profile context".into(),
                    ..Default::default()
                },
                ..Default::default()
            };
            state.bind_assistant_snapshot(&snapshot);
            if dedicated {
                let context = state.assistant_profile_context().unwrap();
                assert!(context.contains("Actual name"));
                assert!(context.contains("Actual profile context"));
            } else {
                assert!(state.assistant_profile_context().is_none());
            }
            state
                .prepare_agent_send("You are my assistant. Create a task.", &TurnIds::new(), NOW)
                .unwrap();
            let prepared = persist(&mut state).unwrap();
            assert_eq!(prepared.method, "prepare_agent_attempt");
            assert_eq!(
                prepared.args[0]["registry_version"],
                if dedicated { 5 } else { 4 }
            );
            assert_eq!(state.raw_session()["schema_version"], 9);
            assert!(!state
                .raw_session()
                .to_string()
                .contains("Actual profile context"));
            assert!(state
                .raw_session()
                .get("assistant_conversation_id")
                .is_none());
        }
    }
}
