//! One room turn delivers once to each selected member, through the existing
//! single session writer. The private Agent lanes never include direct chats.
use super::{driver::*, *};

impl Driver {
    pub(super) fn stop_group(&mut self, group_id: &str) -> Result<(), String> {
        if self
            .group_transition
            .as_ref()
            .is_some_and(|g| g.group_id == group_id)
        {
            self.refresh()?;
            self.saved = Some(
                self.store_ref()?
                    .stop_group(self.revision()?, group_id)
                    .map_err(|e| e.to_string())?,
            );
            self.group_transition.as_mut().unwrap().continue_members = false;
            return Ok(());
        }
        if self
            .group
            .as_ref()
            .is_some_and(|group| group.group_id == group_id)
            || self.pending_group_id.as_deref() == Some(group_id)
        {
            return self.stop(false);
        }
        self.refresh()?;
        // This can stop a queue saved before handoff or between foreground
        // sessions without cancelling an unrelated Bot's active native run.
        self.saved = Some(
            self.store_ref()?
                .stop_group(self.revision()?, group_id)
                .map_err(|error| error.to_string())?,
        );
        if self.active.is_none() && self.pending.is_none() {
            self.status = if self
                .saved
                .as_ref()
                .and_then(|s| s.group_claim(group_id))
                .is_some()
            {
                RunnerStatus::NeedsAttention
            } else {
                RunnerStatus::Idle
            };
        }
        Ok(())
    }
    pub(super) fn native_group_action(&mut self, payload: &Value) -> Result<bool, String> {
        if let Some(group) = &self.group_transition {
            if payload["conversationId"] == group.conversation_id
                && payload["runId"] == group.run_id
            {
                let group_id = group.group_id.clone();
                if payload["action"] == "cancel" {
                    self.stop_group(&group_id)?;
                } else if payload["action"] == "open" {
                    self.events.push(RunnerEvent::OpenConversation {
                        conversation_id: group_id,
                    });
                }
                return Ok(true);
            }
        }
        let claim = self.saved.as_ref().and_then(|s| {
            s.groups
                .iter()
                .filter_map(|g| s.group_claim(&g.id))
                .find(|g| {
                    payload["conversationId"] == g.claim.conversation_id
                        && payload["runId"] == g.claim.run.run_id
                })
        });
        let Some(group) = claim else {
            return Ok(false);
        };
        if payload["action"] == "open" {
            self.events.push(RunnerEvent::OpenConversation {
                conversation_id: group.group_id,
            });
            return Ok(true);
        }
        if payload["action"] != "cancel" {
            return Ok(false);
        }
        let expired = payload["reason"] == "background_expired";
        if self
            .group
            .as_ref()
            .is_some_and(|g| g.claim.run.run_id == group.claim.run.run_id)
        {
            self.stop(expired)?;
        } else {
            self.refresh()?;
            self.saved = Some(
                self.store_ref()?
                    .stop_group(self.revision()?, &group.group_id)
                    .map_err(|e| e.to_string())?,
            );
            self.saved = Some(
                self.store_ref()?
                    .mark_group_attention(
                        self.revision()?,
                        &group.group_id,
                        &group.claim.run.run_id,
                        if expired {
                            "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED"
                        } else {
                            "E_ASSISTANT_NATIVE_STOP_REQUESTED"
                        },
                        now_ms(),
                    )
                    .map_err(|e| e.to_string())?,
            );
            if self.active.is_none() && self.pending.is_none() {
                self.queue_group(group.group_id, true, Some(expired));
            }
        }
        Ok(true)
    }

    pub(super) fn send_group(
        &mut self,
        group_id: String,
        turn_id: String,
        target_bot_id: Option<String>,
        text: String,
        model_id: String,
        workspace_descriptor: Value,
    ) -> Result<(), String> {
        if self.group_transition.is_some() {
            return Err("The previous native run is still finishing".into());
        }
        if self.active.is_some() || self.pending.is_some() {
            if self
                .group
                .as_ref()
                .is_some_and(|g| g.group_id == group_id && g.round_id == turn_id)
            {
                return Ok(());
            }
            return Err(
                "Resolve the current assistant work before sending another group turn".into(),
            );
        }
        self.refresh()?;
        let group = self
            .saved
            .as_ref()
            .and_then(|s| s.groups.iter().find(|g| g.id == group_id))
            .ok_or("Group was not found")?;
        let targets = match target_bot_id {
            Some(id) if group.active_bot_ids.contains(&id) => vec![id],
            Some(_) => return Err("The selected Bot is no longer in this group".into()),
            None => group.active_bot_ids.clone(),
        };
        let binding = rish_shell_core::workspace_binding(&workspace_descriptor)?;
        let config = AssistantTaskConfig::manual(
            &group.name,
            &text,
            model_id,
            binding,
            workspace_descriptor,
        );
        self.saved = Some(
            self.store_ref()?
                .start_group_round(
                    self.revision()?,
                    &group_id,
                    &turn_id,
                    &text,
                    &targets,
                    &config,
                    now_ms(),
                )
                .map_err(|e| e.to_string())?,
        );
        if self
            .saved
            .as_ref()
            .and_then(|s| s.group_claim(&group_id))
            .is_some()
        {
            return Err("Saved group work needs reconciliation".into());
        }
        self.queue_group(group_id, false, None);
        Ok(())
    }

    pub(super) fn queue_group(
        &mut self,
        group_id: String,
        recover: bool,
        cancel_after_recover: Option<bool>,
    ) {
        self.pending_group_id = Some(group_id.clone());
        self.request_handoff(Pending {
            task_id: group_id,
            recover,
            due: false,
            cancel_after_recover,
        });
    }

    pub(super) fn recover_group(&mut self, group_id: &str) -> Result<(), String> {
        if let Some(transition) = &self.group_transition {
            if transition.group_id != group_id {
                return Err("Another group is finishing".into());
            }
            self.dispatch_group_end();
            return Ok(());
        }
        if let Some(group) = &self.group {
            if group.group_id != group_id {
                return Err("Another group is running".into());
            }
            let next = self
                .state
                .as_mut()
                .ok_or("Missing group writer")?
                .recover_agent(&now())?;
            return self.step(next);
        }
        if self.active.is_some() || self.pending.is_some() {
            return Err("Another assistant is running".into());
        }
        self.refresh()?;
        let snapshot = self.saved.as_ref().unwrap();
        let group = snapshot
            .groups
            .iter()
            .find(|g| g.id == group_id)
            .ok_or("Group was not found")?;
        let Some(round) = group.rounds.last() else {
            return Err("There is no group turn to recover".into());
        };
        let claim = snapshot.group_claim(group_id);
        let expired = claim.as_ref().is_some_and(|c| {
            matches!(
                c.claim.run.failure_code.as_deref(),
                Some("E_ASSISTANT_BACKGROUND_EXPIRED" | "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED")
            )
        });
        let cancelled = round.stopped
            || claim.as_ref().is_some_and(|c| {
                c.claim.run.failure_code.as_deref().is_some_and(|code| {
                    matches!(
                        code,
                        "E_ASSISTANT_BACKGROUND_EXPIRED"
                            | "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED"
                            | "E_ASSISTANT_NATIVE_STOP_REQUESTED"
                            | "E_ASSISTANT_RUNTIME_STOPPED"
                            | "E_ASSISTANT_RUNTIME_FAILED"
                    )
                })
            });
        self.queue_group(
            group_id.into(),
            claim.is_some(),
            cancelled.then_some(expired),
        );
        Ok(())
    }

    pub(super) fn start_group(&mut self, group_id: &str, pending: Pending) -> Result<(), String> {
        let group = if pending.recover {
            self.saved
                .as_ref()
                .and_then(|s| s.group_claim(group_id))
                .ok_or("Saved group run was not found")?
        } else {
            let Some(group) = self
                .store_ref()?
                .claim_group_next(self.revision()?, group_id, now_ms())
                .map_err(|e| e.to_string())?
            else {
                self.status = RunnerStatus::Idle;
                self.release_if_idle();
                return Ok(());
            };
            group
        };
        let claim = group.claim.clone();
        self.group = Some(group);
        self.activate_claim(claim, pending)
    }

    pub(super) fn persist_run_attention(
        &mut self,
        task_id: &str,
        run_id: &str,
        reason: &str,
        stop_queue: bool,
    ) -> Result<AssistantSnapshot, String> {
        // A native memory/task receipt may have advanced the catalog before its
        // refresh event arrives. Re-read rather than using the display revision.
        self.refresh()?;
        if let Some(group) = &self.group {
            let group_id = group.group_id.clone();
            if stop_queue {
                self.saved = Some(
                    self.store_ref()?
                        .stop_group(self.revision()?, &group_id)
                        .map_err(|e| e.to_string())?,
                );
            }
            self.store_ref()?
                .mark_group_attention(self.revision()?, &group_id, run_id, reason, now_ms())
                .map_err(|e| e.to_string())
        } else {
            self.task_store(task_id)?
                .mark_attention(self.revision()?, task_id, run_id, reason, now_ms())
                .map_err(|e| e.to_string())
        }
    }

    pub(super) fn finish_group(
        &mut self,
        status: AssistantRunStatus,
        failure_code: Option<String>,
    ) -> Result<(), String> {
        let group = self.group.clone().ok_or("Missing group claim")?;
        let active = self.active.as_ref().ok_or("Missing group execution")?;
        let stopped = active.stopped || active.expired;
        let state = self.state.as_ref().ok_or("Missing group writer")?;
        let text = state.raw_session()["conversations"]
            .as_array()
            .and_then(|rows| rows.iter().find(|c| c["id"] == group.claim.conversation_id))
            .and_then(|c| c["messages"].as_array())
            .and_then(|rows| {
                rows.iter().find(|m| {
                    m["id"] == group.claim.run.ids.assistant_message_id && m["role"] == "assistant"
                })
            })
            .and_then(|m| m["text"].as_str())
            .filter(|_| status == AssistantRunStatus::Completed)
            .map(group_history_text);
        if status == AssistantRunStatus::Completed && text.is_none() {
            return Err("The completed group reply is missing".into());
        }
        self.refresh()?;
        self.saved = Some(
            self.store_ref()?
                .finish_group_member(
                    self.revision()?,
                    &group.group_id,
                    &group.claim.run.run_id,
                    AssistantRunOutcome {
                        status,
                        result_summary: None,
                        failure_code,
                    },
                    text.as_deref(),
                    now_ms(),
                )
                .map_err(|e| e.to_string())?,
        );
        self.group_transition = Some(super::group_transition::GroupTransition {
            group_id: group.group_id.clone(),
            run_id: group.claim.run.run_id.clone(),
            conversation_id: group.claim.conversation_id.clone(),
            status,
            continue_members: status == AssistantRunStatus::Completed && !stopped,
            request_pending: false,
        });
        self.active = None;
        self.group = None;
        self.pi = None;
        self.runtime_failure = None;
        self.dispatch_group_end();
        Ok(())
    }
}

// The authoritative full answer remains in the committed native lane. Keep
// the aggregate history bounded without leaving a finished provider attempt
// permanently unrecoverable when a reply exceeds the sidecar display budget.
fn group_history_text(text: &str) -> String {
    if text.len() <= MAX_GROUP_REPLY_BYTES {
        return text.to_owned();
    }
    const NOTICE: &str = "\n\n[回复过长，群聊记录已截断 / Group history reply truncated]";
    let mut end = MAX_GROUP_REPLY_BYTES - NOTICE.len();
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{NOTICE}", &text[..end])
}
