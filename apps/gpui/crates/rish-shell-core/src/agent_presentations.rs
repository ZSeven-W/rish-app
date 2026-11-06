use crate::{model::*, AgentPresentation, ShellState};
use rish_agent_core::round_presentation::{self, ArchiveBudget};
use serde_json::{json, Value};
impl ShellState {
    pub fn read_agent_presentations_command(&self) -> Option<RuntimeCommand> {
        let c = self.selected()?;
        let a = rows(c, "attempts")
            .iter()
            .rev()
            .find(|a| !a["agent"].is_null())?;
        Some(RuntimeCommand::new(
            "AgentRuntime",
            "read_agent_round_presentations",
            vec![
                json!({"schema_version":1,"conversation_id":c["id"],"attempt_id":a["attempt_id"]}),
            ],
        ))
    }
    pub fn read_agent_presentations_commands(&self) -> Vec<RuntimeCommand> {
        let Some(c) = self.selected() else {
            return vec![];
        };
        rows(c,"attempts").iter().rev().take(96).filter(|a|!a["agent"].is_null()&&!rows(a,"rounds").is_empty()).filter(|a|self.agent_presentation_versions.get(text(a,"attempt_id")).is_none_or(|count|*count<rows(a,"rounds").len())).map(|a|RuntimeCommand::new("AgentRuntime","read_agent_round_presentations",vec![json!({"schema_version":1,"conversation_id":c["id"],"attempt_id":a["attempt_id"]})])).collect()
    }
    /// A read-only, separately correlated display lane; cannot resume effects.
    pub fn accept_agent_presentations(
        &mut self,
        command: &RuntimeCommand,
        value: Value,
    ) -> Result<()> {
        if command.module != "AgentRuntime"
            || command.method != "read_agent_round_presentations"
            || command.args.len() != 1
        {
            return Err("Unexpected presentation command".into());
        }
        let v = decode(value)?;
        let q = &command.args[0];
        round_presentation::validate_archive(
            &v,
            text(q, "conversation_id"),
            text(q, "attempt_id"),
            ArchiveBudget::Display,
        )
        .map_err(|_| "Invalid Agent presentation archive".to_string())?;
        let c = rows(&self.session, "conversations")
            .iter()
            .find(|c| c["id"] == q["conversation_id"])
            .ok_or("Conversation is no longer present")?;
        let a = rows(c, "attempts")
            .iter()
            .find(|a| a["attempt_id"] == q["attempt_id"])
            .ok_or("Attempt is no longer present")?;
        let user_message_id = rows(c, "turns")
            .iter()
            .find(|t| t["turn_id"] == a["turn_id"])
            .map(|t| text(t, "user_message_id"))
            .unwrap_or("")
            .to_string();
        let mut presentations = Vec::new();
        for p in rows(&v, "rounds") {
            let index = p["round_index"].as_u64().expect("validated round index");
            // A provider response can finish before the UI checkpoint does.
            // It is shown only after that exact native round was saved.
            if !rows(a, "rounds").iter().any(|r| {
                r["round_id"] == p["round_id"]
                    && r["round_index"] == p["round_index"]
                    && match text(p, "kind") {
                        "final" => r["finish_reason"] == "stop",
                        "tool_batch" => r["finish_reason"] == "tool_calls",
                        "blocked" => {
                            matches!(text(r, "finish_reason"), "length" | "content_filter")
                        }
                        _ => false,
                    }
            }) {
                continue;
            }
            presentations.push(AgentPresentation {
                user_message_id: user_message_id.clone(),
                attempt_id: text(a, "attempt_id").into(),
                round_id: text(p, "round_id").into(),
                round_index: index,
                kind: text(p, "kind").into(),
                text: text(p, "text").into(),
                reasoning: text(p, "reasoning").into(),
            });
        }
        presentations.sort_by_key(|p| p.round_index);
        // Native cleanup can remove content after a successful terminal read;
        // retain the current-launch display cache without treating it as proof.
        if self.agent_presentation_versions.len() >= 256 {
            let valid: std::collections::HashSet<String> = rows(&self.session, "conversations")
                .iter()
                .flat_map(|c| rows(c, "attempts").iter().rev().take(96))
                .map(|a| text(a, "attempt_id").into())
                .collect();
            self.agent_presentation_versions
                .retain(|id, _| valid.contains(id));
        }
        self.agent_presentation_versions
            .insert(text(q, "attempt_id").into(), rows(a, "rounds").len());
        if self.agent_presentations.len() >= 96
            && !self.agent_presentations.contains_key(text(q, "attempt_id"))
        {
            self.agent_presentations.clear();
        }
        if !presentations.is_empty() {
            self.agent_presentations
                .insert(text(q, "attempt_id").into(), presentations);
        }
        while self
            .agent_presentations
            .values()
            .flatten()
            .map(|p| p.text.len() + p.reasoning.len())
            .sum::<usize>()
            > 8 * 1024 * 1024
        {
            let Some(old) = self
                .agent_presentations
                .keys()
                .find(|id| id.as_str() != text(q, "attempt_id"))
                .cloned()
            else {
                break;
            };
            self.agent_presentations.remove(&old);
        }
        Ok(())
    }
    pub fn agent_presentations(&self) -> Vec<AgentPresentation> {
        let Some(c) = self.selected() else {
            return vec![];
        };
        rows(c, "attempts")
            .iter()
            .flat_map(|a| {
                self.agent_presentations
                    .get(text(a, "attempt_id"))
                    .into_iter()
                    .flatten()
                    .filter(|p| p.kind != "final" || a["assistant_message_id"].is_null())
            })
            .cloned()
            .collect()
    }
}
