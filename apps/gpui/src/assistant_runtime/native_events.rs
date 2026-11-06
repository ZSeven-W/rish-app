use super::{driver::*, *};

impl Driver {
    pub(super) fn native_event(&mut self, name: &str, payload: Value) -> Result<(), String> {
        if name == "agentRoundPreview" {
            if let Some(state) = self.state.as_mut() {
                state.accept_agent_preview(payload);
            }
            return Ok(());
        }
        if payload["schema_version"] != 1 {
            return Ok(());
        }
        if name == "taskExperienceLifecycle" {
            self.lifecycle_seen = true;
            self.foreground = payload["foreground"].as_bool().unwrap_or(false);
            if self.foreground {
                self.poll_due()?;
            }
        } else if name == "taskExperienceAction" {
            if self.native_group_action(&payload)? {
                return Ok(());
            }
            // Native notification IDs must refer to a durable task, and Stop
            // must match the *current* attempt to fence late action deliveries.
            if payload["action"] == "open" {
                if self.saved.as_ref().is_some_and(|s| {
                    s.all_tasks().into_iter().any(|t| {
                        payload["conversationId"] == t.conversation_id
                            && t.last_run
                                .as_ref()
                                .is_some_and(|r| payload["runId"] == r.run_id)
                    })
                }) {
                    self.events.push(RunnerEvent::OpenConversation {
                        conversation_id: payload["conversationId"].as_str().unwrap().into(),
                    });
                }
            } else if payload["action"] == "cancel"
                && self.active.as_ref().is_some_and(|a| {
                    payload["runId"] == a.claim.run.run_id
                        && payload["conversationId"] == a.claim.conversation_id
                })
            {
                self.stop(payload["reason"] == "background_expired")?;
            } else if payload["action"] == "cancel" {
                let task = self
                    .saved
                    .as_ref()
                    .and_then(|s| {
                        s.all_tasks().into_iter().find(|t| {
                            payload["conversationId"] == t.conversation_id
                                && t.last_run.as_ref().is_some_and(|r| {
                                    r.status.is_active() && payload["runId"] == r.run_id
                                })
                        })
                    })
                    .cloned();
                if let Some(task) = task {
                    let expired = payload["reason"] == "background_expired";
                    let run = task.last_run.as_ref().unwrap();
                    self.saved = Some(
                        self.task_store(&task.id)?
                            .mark_attention(
                                self.revision()?,
                                &task.id,
                                &run.run_id,
                                if expired {
                                    "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED"
                                } else {
                                    "E_ASSISTANT_NATIVE_STOP_REQUESTED"
                                },
                                now_ms(),
                            )
                            .map_err(|e| e.to_string())?,
                    );
                    self.request_handoff(Pending {
                        task_id: task.id,
                        recover: true,
                        due: false,
                        cancel_after_recover: Some(expired),
                    });
                }
            }
        }
        Ok(())
    }
}
