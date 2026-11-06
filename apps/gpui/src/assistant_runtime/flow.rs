use super::{driver::*, *};
use serde_json::json;

impl Driver {
    pub(super) fn start(&mut self) -> Result<(), String> {
        let pending = self
            .pending
            .take()
            .ok_or("No assistant start was requested")?;
        if !self.foreground {
            self.pending = Some(pending);
            return Err("Return to the foreground to start this task".into());
        }
        self.refresh()?;
        if let Some(group_id) = self.pending_group_id.take() {
            return self.start_group(&group_id, pending);
        }
        let task = self.task(&pending.task_id)?;
        if !pending.recover && !pending.due && !task.pending_manual {
            return Err("The queued manual start was withdrawn".into());
        }
        let claim = if pending.recover {
            let run = task.last_run.clone().ok_or("No saved run to reconcile")?;
            AssistantClaim {
                snapshot: self.saved.clone().unwrap(),
                task_id: task.id.clone(),
                conversation_id: task.conversation_id.clone(),
                run,
            }
        } else {
            // Claim and all five stable turn IDs become durable before ANY
            // session/native Agent effect. A duplicate manual start cannot
            // create a second attempt while this claim remains unresolved.
            self.task_store(&pending.task_id)?
                .claim(
                    self.revision()?,
                    &task.id,
                    if pending.due {
                        AssistantClaimMode::Due
                    } else {
                        AssistantClaimMode::Manual
                    },
                    now_ms(),
                )
                .map_err(|e| e.to_string())?
        };
        self.activate_claim(claim, pending)
    }

    pub(super) fn activate_claim(
        &mut self,
        claim: AssistantClaim,
        pending: Pending,
    ) -> Result<(), String> {
        self.saved = Some(claim.snapshot.clone());
        self.pi = None;
        self.runtime_failure = claim.run.failure_code.clone().filter(|c| {
            matches!(
                c.as_str(),
                "E_ASSISTANT_RUNTIME_STOPPED" | "E_ASSISTANT_RUNTIME_FAILED"
            )
        });
        let run_id = claim.run.run_id.clone();
        let conversation_id = claim.conversation_id.clone();
        let expired = pending.cancel_after_recover == Some(true)
            && matches!(
                claim.run.failure_code.as_deref(),
                Some("E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED" | "E_ASSISTANT_BACKGROUND_EXPIRED")
            );
        self.active = Some(Active {
            claim,
            recover: pending.recover,
            stopped: false,
            stop_persist_failed: false,
            expired,
            setup_pending: true,
            validated: false,
            sent: false,
            reconciled: false,
            cancel_after_recover: pending.cancel_after_recover,
        });
        self.status = RunnerStatus::Running;
        self.message = None;
        self.dispatch(
            OperationKind::Begin,
            RuntimeCommand::new(
                "TaskExperience",
                "handle",
                vec![json!({
            "schema_version":1,"op":"begin","runId":run_id,"conversationId":conversation_id,
            "backgroundEligible":!pending.due && pending.cancel_after_recover.is_none()})],
            ),
        );
        Ok(())
    }

    pub(super) fn continue_setup(&mut self) -> Result<(), String> {
        let active = self.active.as_ref().ok_or("No assistant claim")?;
        if active.stopped && !active.recover {
            return self.finish(AssistantRunStatus::Cancelled, None);
        }
        let validated = active.validated;
        let claim = active.claim.clone();
        let recovering = active.recover;
        let task_title = if let Some(group) = &self.group {
            self.saved
                .as_ref()
                .and_then(|s| s.groups.iter().find(|g| g.id == group.group_id))
                .map(|g| g.name.clone())
                .ok_or("Group was not found")?
        } else {
            self.task(&claim.task_id)?.title
        };
        let state = self.state.as_mut().ok_or("Missing session writer")?;
        if let Some(group) = &self.group {
            let mut bot = self
                .saved
                .as_ref()
                .and_then(|s| s.bot_snapshot(&group.bot_id))
                .ok_or("Group Bot was not found")?;
            bot.conversation_id = Some(claim.conversation_id.clone());
            // A later profile edit affects future claims only. Native also
            // resolves this immutable lane against the durable active claim.
            bot.profile.name = claim.run.snapshot.name.clone();
            bot.profile.soul = claim.run.snapshot.soul.clone();
            bot.profile.notes = claim.run.snapshot.notes.clone();
            if let Some(runtime) = &claim.run.snapshot.runtime {
                bot.profile.runtime = runtime.clone();
            }
            state.bind_assistant_snapshot(&bot);
        }
        if recovering && !active.reconciled {
            let command = state.load_command();
            self.active.as_mut().unwrap().setup_pending = true;
            self.dispatch(OperationKind::Reload, command);
            return Ok(());
        }
        if recovering && claim_ids_absent(state.raw_session(), &claim) {
            return self.finish(
                AssistantRunStatus::Failed,
                Some("E_ASSISTANT_START_INTERRUPTED".into()),
            );
        }
        if recovering {
            if claim_evidence(state.raw_session(), &claim) != ClaimEvidence::Present {
                return Err(
                    "Saved claim evidence is incomplete; inspect it before recovery".into(),
                );
            }
            if !needs_claim_recovery(state.raw_session(), &claim)? {
                self.active.as_mut().unwrap().sent = true;
                return self.settle();
            }
        }
        if !validated {
            let binding = &claim.run.snapshot.workspace_binding;
            self.active.as_mut().unwrap().setup_pending = true;
            self.dispatch(OperationKind::Workspace, RuntimeCommand::new("LocalWorkspaces", "resolve", vec![json!({
                "schema_version":1,"workspace_id":binding["workspace_id"],"expected_binding_revision":binding["binding_revision"],"required_capabilities":["read"]})]));
            return Ok(());
        }
        let conversation = rows(state.raw_session(), "conversations")
            .iter()
            .find(|c| c["id"] == claim.conversation_id)
            .cloned();
        if conversation.is_none() {
            if recovering {
                return Err(
                    "Saved claim has no committed conversation; inspect it before any new run"
                        .into(),
                );
            }
            let previous_default = state.default_workspace().cloned();
            state.set_default_workspace(claim.run.snapshot.workspace_descriptor.clone())?;
            let result = state.create_task_conversation(
                &claim.conversation_id,
                &now(),
                &claim.run.snapshot.model_id,
                &task_title,
            );
            if let Some(previous) = previous_default {
                state.set_default_workspace(previous)?;
            }
            self.step(Some(result?))?;
            return Ok(());
        }
        let conversation = conversation.unwrap();
        if conversation["workspace_binding"] != claim.run.snapshot.workspace_binding {
            return Err("The assistant conversation workspace changed; review its binding".into());
        }
        if state.active_conversation_id() != Some(&claim.conversation_id) {
            let next = state.select_conversation(&claim.conversation_id)?;
            self.step(Some(next))?;
            return Ok(());
        }
        match claim_evidence(state.raw_session(), &claim) {
            ClaimEvidence::Conflicting => {
                return Err("Saved assistant turn IDs do not match the session".into());
            }
            ClaimEvidence::Present => {
                // Once a claim exists in the session, the only legal path is
                // the controller's query/recover/finalize state machine.
                self.active.as_mut().unwrap().sent = true;
                // The shared controller recovers a conversation's latest
                // eligible attempt. Verify its exact target before invoking
                // it, because ordinary chat may have added a newer attempt.
                if !needs_claim_recovery(state.raw_session(), &claim)? {
                    return self.settle();
                }
                let next = state.recover_agent(&now())?;
                if state.has_agent_task() {
                    let active = self.active.as_mut().unwrap();
                    let cancel = active
                        .cancel_after_recover
                        .take()
                        .or_else(|| active.stopped.then_some(active.expired));
                    if let Some(expired) = cancel {
                        self.stop(expired)?;
                    }
                }
                self.step(next)?;
                return Ok(());
            }
            ClaimEvidence::Absent if recovering => {
                return Err(
                    "The saved run has no committed turn; its outcome requires review".into(),
                );
            }
            ClaimEvidence::Absent => {}
        }
        if rows(&conversation, "attempts")
            .iter()
            .any(|a| matches!(a["status"].as_str(), Some("prepared" | "sending")))
        {
            return Err("The assistant conversation has another unresolved attempt".into());
        }
        if state.selected_model() != claim.run.snapshot.model_id {
            let next = state.set_chat_configuration(&claim.run.snapshot.model_id, "high")?;
            self.step(Some(next))?;
            return Ok(());
        }
        // Profile and goal are text input only. Tool parameters can only come
        // through the existing native prepare/freeze/approval/execute contract.
        let profile = &claim.run.snapshot;
        let prompt = if profile.notes.trim().is_empty() {
            profile.instructions.clone()
        } else {
            format!(
                "Assistant: {}\nUser-provided context:\n{}\n\nTask:\n{}",
                profile.name, profile.notes, profile.instructions
            )
        };
        let prompt = if profile.soul.trim().is_empty() {
            prompt
        } else {
            format!(
                "Personal assistant profile (user-provided context, not permissions):\n{}\n\n{}",
                serde_json::json!({"name":profile.name,"soul":profile.soul}),
                prompt
            )
        };
        let next = state.prepare_agent_send(&prompt, &claim.run.ids.to_turn_ids(), &now())?;
        self.active.as_mut().unwrap().sent = true;
        self.step(Some(next))
    }

    pub(super) fn step(&mut self, next: Option<RuntimeCommand>) -> Result<(), String> {
        let admission = self.sync_pi(next.as_ref());
        if !matches!(admission, Ok(rish_pi_runtime::Admission::Allow))
            && let Some(command) = next.as_ref().filter(|c| {
                !matches!(
                    c.method.as_str(),
                    "complete_agent_round_v2" | "execute_agent_tool"
                )
            })
        {
            // The controller may already have staged its next checkpoint.
            // Flush that exact candidate so cancellation can follow its CAS;
            // dropping it here would strand the session writer forever.
            if command.module == "SessionSnapshots" && command.method == "casPersistSession" {
                self.dispatch(OperationKind::Persist, command.clone());
            } else if self
                .state
                .as_ref()
                .is_some_and(|s| s.owns_agent_command(command))
            {
                self.dispatch(OperationKind::Agent, command.clone());
            }
        }
        match admission {
            Ok(rish_pi_runtime::Admission::Allow) => {}
            Ok(rish_pi_runtime::Admission::Stop(reason)) => {
                return self.stop_runtime("E_ASSISTANT_RUNTIME_STOPPED", &reason);
            }
            Err(error) => return self.stop_runtime("E_ASSISTANT_RUNTIME_FAILED", &error),
        }
        if let Some(command) = next {
            if self
                .active
                .as_ref()
                .is_some_and(|a| !a.expired && !a.stop_persist_failed)
            {
                self.status = RunnerStatus::Running;
                self.message = None;
            }
            if command.module == "SessionSnapshots" && command.method == "casPersistSession" {
                self.dispatch(OperationKind::Persist, command);
                self.experience("update", json!({"phase":"persistence_pending"}));
            } else if self
                .state
                .as_ref()
                .is_some_and(|s| s.owns_agent_command(&command))
            {
                let phase = match command.method.as_str() {
                    "complete_agent_round_v2" => "sending",
                    "execute_agent_tool" => "executing",
                    "query_agent_attempt" | "recover_agent_attempt" => "recovering",
                    "cancel_agent_attempt" => "cancelling",
                    _ => "preparing",
                };
                self.dispatch(OperationKind::Agent, command);
                self.experience("update", json!({"phase":phase}));
            } else {
                return Err("Assistant controller produced an unowned command".into());
            }
            Ok(())
        } else {
            self.settle()
        }
    }

    pub(super) fn stop(&mut self, expired: bool) -> Result<(), String> {
        if let Some(group) = &self.group_transition {
            let id = group.group_id.clone();
            return self.stop_group(&id);
        }
        if self.active.is_none() && self.pending_group_id.is_some() {
            let group_id = self.pending_group_id.clone().unwrap();
            self.refresh()?;
            self.saved = Some(
                self.store_ref()?
                    .stop_group(self.revision()?, &group_id)
                    .map_err(|e| e.to_string())?,
            );
            self.pending_group_id = None;
            self.pending = None;
            self.status = RunnerStatus::Idle;
            self.release_if_idle();
            return Ok(());
        }
        self.abort_pi();
        let Some(active) = self.active.as_mut() else {
            return Ok(());
        };
        active.stopped = true;
        active.expired |= expired;
        let was_expired = active.expired;
        {
            let task_id = active.claim.task_id.clone();
            let run_id = active.claim.run.run_id.clone();
            let reason = if was_expired {
                "E_ASSISTANT_BACKGROUND_EXPIRED"
            } else {
                self.runtime_failure
                    .as_deref()
                    .unwrap_or("E_ASSISTANT_NATIVE_STOP_REQUESTED")
            }
            .to_owned();
            let persisted = self.persist_run_attention(&task_id, &run_id, &reason, true);
            match persisted {
                Ok(saved) => {
                    self.saved = Some(saved);
                    self.active.as_mut().unwrap().stop_persist_failed = false;
                }
                Err(error) => {
                    self.active.as_mut().unwrap().stop_persist_failed = true;
                    self.status = RunnerStatus::NeedsAttention;
                    self.error(error);
                }
            }
        }
        if was_expired {
            self.status = RunnerStatus::NeedsAttention;
            self.message = Some(
                "Background execution expired. Review this run before starting another.".into(),
            );
        }
        if self.state.as_ref().is_some_and(ShellState::has_agent_task) {
            let next = self.state.as_mut().unwrap().cancel_agent(&now())?;
            if next.is_some() {
                self.step(next)?;
            }
            self.experience("update", json!({"phase":"cancelling"}));
        } else if !self.active.as_ref().unwrap().setup_pending
            && self.state.as_ref().is_some_and(|s| !s.is_busy())
        {
            if self.active.as_ref().unwrap().recover {
                self.continue_setup()?;
            } else {
                self.finish(AssistantRunStatus::Cancelled, None)?;
            }
        }
        Ok(())
    }

    pub(super) fn settle(&mut self) -> Result<(), String> {
        let state = self.state.as_ref().ok_or("Missing assistant writer")?;
        if state.has_agent_task()
            && let Some(view) = state.agent_view()
        {
            if view.recoverable && state.has_agent_task() {
                return Err(state
                    .last_error()
                    .unwrap_or("Native outcome needs reconciliation")
                    .into());
            }
            if view.approval.is_some() || view.question.is_some() {
                self.status = RunnerStatus::NeedsAttention;
                self.message = Some(
                    if view.question.is_some() {
                        "Assistant needs an answer"
                    } else {
                        "Assistant needs approval"
                    }
                    .into(),
                );
                self.experience("update", json!({"phase":"approval_pending"}));
                return Ok(());
            }
        }
        if state.is_busy() {
            return Ok(());
        }
        let active = self.active.as_ref().ok_or("Missing assistant claim")?;
        let attempt = rows(state.raw_session(), "conversations")
            .iter()
            .find(|c| c["id"] == active.claim.conversation_id)
            .and_then(|c| {
                rows(c, "attempts")
                    .iter()
                    .find(|a| a["attempt_id"] == active.claim.run.ids.attempt_id)
            });
        let status = match attempt.and_then(|a| a["status"].as_str()) {
            Some("completed") => AssistantRunStatus::Completed,
            Some("failed") => AssistantRunStatus::Failed,
            Some("cancelled") => AssistantRunStatus::Cancelled,
            _ => return Err("The saved attempt has not reached a confirmed terminal state".into()),
        };
        let failure = attempt
            .and_then(|a| a["failure_code"].as_str())
            .map(str::to_owned);
        self.finish(status, failure)
    }

    pub(super) fn finish(
        &mut self,
        status: AssistantRunStatus,
        failure_code: Option<String>,
    ) -> Result<(), String> {
        let active = self.active.as_ref().ok_or("Missing assistant run")?;
        if self.state.as_ref().is_some_and(ShellState::is_busy) {
            return Err("The session outcome is still unresolved".into());
        }
        let task_id = active.claim.task_id.clone();
        let run_id = active.claim.run.run_id.clone();
        let expired = active.expired;
        let summary = self
            .state
            .as_ref()
            .and_then(|s| {
                rows(s.raw_session(), "conversations")
                    .iter()
                    .find(|c| c["id"] == active.claim.conversation_id)
            })
            .and_then(|c| {
                let attempt = rows(c, "attempts")
                    .iter()
                    .find(|a| a["attempt_id"] == active.claim.run.ids.attempt_id)?;
                rows(c, "messages")
                    .iter()
                    .find(|m| {
                        m["id"] == attempt["assistant_message_id"] && m["role"] == "assistant"
                    })
                    .and_then(|m| m["text"].as_str())
            })
            .map(|s| clip(s, 16 * 1024));
        let status = if expired {
            AssistantRunStatus::NeedsAttention
        } else if self.runtime_failure.as_deref() == Some("E_ASSISTANT_RUNTIME_FAILED") {
            AssistantRunStatus::Failed
        } else {
            status
        };
        let failure_code = if expired {
            Some("E_ASSISTANT_BACKGROUND_EXPIRED".into())
        } else {
            self.runtime_failure.clone().or(failure_code)
        };
        if self.group.is_some() {
            return self.finish_group(status, failure_code);
        }
        self.saved = Some(
            self.task_store(&task_id)?
                .finish(
                    self.revision()?,
                    &task_id,
                    &run_id,
                    AssistantRunOutcome {
                        status,
                        result_summary: summary,
                        failure_code,
                    },
                    now_ms(),
                )
                .map_err(|e| e.to_string())?,
        );
        let native_status = match status {
            AssistantRunStatus::Completed => "completed",
            AssistantRunStatus::Cancelled => "cancelled",
            _ => "blocked",
        };
        // End is sent only after native session terminal/finalize and the
        // independent run outcome are both durable.
        self.experience("end", json!({"status":native_status}));
        self.active = None;
        self.pi = None;
        self.runtime_failure = None;
        self.status = if expired {
            RunnerStatus::NeedsAttention
        } else {
            RunnerStatus::Idle
        };
        if !expired {
            self.message = None;
        }
        self.release_if_idle();
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum ClaimEvidence {
    Absent,
    Present,
    Conflicting,
}
pub(super) fn claim_evidence(session: &Value, claim: &AssistantClaim) -> ClaimEvidence {
    let ids = &claim.run.ids;
    let Some(conversation) = rows(session, "conversations")
        .iter()
        .find(|c| c["id"] == claim.conversation_id)
    else {
        return ClaimEvidence::Absent;
    };
    let attempt = rows(conversation, "attempts")
        .iter()
        .find(|a| a["attempt_id"] == ids.attempt_id);
    let turn = rows(conversation, "turns")
        .iter()
        .find(|t| t["turn_id"] == ids.turn_id);
    let user = rows(conversation, "messages")
        .iter()
        .find(|m| m["id"] == ids.user_message_id);
    match (attempt, turn, user) {
        (None, None, None) => ClaimEvidence::Absent,
        (Some(a), Some(t), Some(m))
            if a["turn_id"] == ids.turn_id
                && t["user_message_id"] == ids.user_message_id
                && rows(t, "attempt_ids")
                    .iter()
                    .any(|id| id == &ids.attempt_id)
                && m["role"] == "user" =>
        {
            ClaimEvidence::Present
        }
        _ => ClaimEvidence::Conflicting,
    }
}
fn rows<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}
/// A fresh native snapshot must contain none of the claim's identifiers in
/// any conversation, event or cleanup record before a pre-start claim can be
/// closed. Ambiguous partial evidence always stays blocked.
pub(super) fn claim_ids_absent(session: &Value, claim: &AssistantClaim) -> bool {
    let ids = &claim.run.ids;
    let keys = [
        &ids.attempt_id,
        &ids.turn_id,
        &ids.round_id,
        &ids.user_message_id,
        &ids.assistant_message_id,
    ];
    fn contains(value: &Value, keys: &[&String]) -> bool {
        match value {
            Value::String(value) => keys.contains(&value),
            Value::Array(values) => values.iter().any(|v| contains(v, keys)),
            Value::Object(values) => values.values().any(|v| contains(v, keys)),
            _ => false,
        }
    }
    !contains(session, &keys)
}

/// Mirrors ShellState::recover_agent's candidate selection, then restricts
/// recovery to this exact durable claim. Terminal claims need no controller.
pub(super) fn needs_claim_recovery(
    session: &Value,
    claim: &AssistantClaim,
) -> Result<bool, String> {
    let conversation = rows(session, "conversations")
        .iter()
        .find(|c| c["id"] == claim.conversation_id)
        .ok_or("Claim conversation missing")?;
    let own = rows(conversation, "attempts")
        .iter()
        .find(|a| a["attempt_id"] == claim.run.ids.attempt_id)
        .ok_or("Claim attempt missing")?;
    let cleanup = rows(session, "agent_transcript_cleanup_outbox")
        .iter()
        .find(|c| c["conversation_id"] == claim.conversation_id);
    let own_cleanup = rows(session, "agent_transcript_cleanup_outbox")
        .iter()
        .any(|c| c["attempt_id"] == claim.run.ids.attempt_id);
    if matches!(
        own["status"].as_str(),
        Some("completed" | "failed" | "cancelled")
    ) && !own_cleanup
    {
        return Ok(false);
    }
    let target = rows(conversation, "attempts").iter().rev().find(|a| {
        cleanup.is_some_and(|c| a["attempt_id"] == c["attempt_id"])
            || (matches!(a["status"].as_str(), Some("prepared" | "sending"))
                && (!a["agent"].is_null() || a["status"] == "prepared"))
    });
    if target.is_none_or(|a| a["attempt_id"] != claim.run.ids.attempt_id) {
        return Err(
            "Another attempt owns conversation recovery; the assistant claim was not resumed"
                .into(),
        );
    }
    Ok(true)
}
fn clip(text: &str, max: usize) -> String {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}
