//! Serialized commands share one actor and the global assistant store revision.
use super::{driver::*, *};
use serde_json::json;

impl Driver {
    pub(super) fn handle(&mut self, command: RunnerCommand) -> Result<(), String> {
        let Some(command) = self.bot_command(command)? else {
            return Ok(());
        };
        match command {
            RunnerCommand::Initialize { directory } => {
                if self.store.is_some() {
                    self.poll_due()?;
                    return Ok(());
                }
                self.store = Some(AssistantStore::open(directory).map_err(|e| e.to_string())?);
                self.refresh()?;
                self.outbox.push(Operation {
                    kind: OperationKind::Settings,
                    command: RuntimeCommand::new(
                        "TaskExperience",
                        "handle",
                        vec![json!({"schema_version":1,"op":"settings"})],
                    ),
                    run_id: String::new(),
                });
                self.outbox.push(Operation {
                    kind: OperationKind::Drain,
                    command: RuntimeCommand::new(
                        "TaskExperience",
                        "handle",
                        vec![json!({"schema_version":1,"op":"drain"})],
                    ),
                    run_id: String::new(),
                });
                // A restart exposes durable interrupted work; no automatic replay.
                if self.saved.as_ref().is_some_and(|s| {
                    !s.running_tasks().is_empty()
                        || s.groups.iter().any(|g| s.group_claim(&g.id).is_some())
                }) {
                    self.status = RunnerStatus::NeedsAttention;
                    self.message = Some("Saved assistant work needs reconciliation".into());
                }
                self.poll_due()?;
            }
            RunnerCommand::Grant {
                task_id,
                state,
                foreground,
            } => {
                if self.state.is_some() {
                    self.events.push(RunnerEvent::HandoffRejected {
                        task_id,
                        message: "Assistant already owns the session writer".into(),
                    });
                    return Err("Assistant already owns the session writer".into());
                }
                if state.is_busy()
                    || !state.is_loaded()
                    || !foreground
                    || (self.lifecycle_seen && !self.foreground)
                    || self.pending.as_ref().is_none_or(|p| p.task_id != task_id)
                {
                    self.events.push(RunnerEvent::Returned { state });
                    return Err("Assistant needs an idle, loaded foreground session".into());
                }
                self.foreground = foreground;
                self.state = Some(state);
                if let Err(error) = self.start() {
                    self.release_if_idle();
                    return Err(error);
                }
            }
            RunnerCommand::RunNow { task_id } => {
                self.task_store(&task_id)?;
                if self
                    .active
                    .as_ref()
                    .is_some_and(|a| a.claim.task_id == task_id)
                {
                    return Ok(());
                }
                self.refresh()?;
                let saved = self
                    .task_store(&task_id)?
                    .request_run(self.revision()?, &task_id, now_ms())
                    .map_err(|e| e.to_string())?;
                self.saved = Some(saved);
                if let Some(pending) = self.pending.as_mut()
                    && pending.task_id == task_id
                    && !pending.recover
                {
                    // An explicit Run Now upgrades a queued scheduled start;
                    // its durable manual marker must not fail the Due gate.
                    pending.due = false;
                }
                self.poll_due()?;
            }
            RunnerCommand::Recover { task_id } => {
                self.task_store(&task_id)?;
                if self
                    .active
                    .as_ref()
                    .is_some_and(|a| a.claim.task_id == task_id)
                {
                    let next = self.state.as_mut().unwrap().recover_agent(&now())?;
                    self.step(next)?;
                } else {
                    if self.active.is_some() {
                        return Err("Another assistant task is running".into());
                    }
                    self.refresh()?;
                    let task = self.task(&task_id)?;
                    self.task_store(&task_id)?;
                    if !task.last_run.as_ref().is_some_and(|r| {
                        matches!(
                            r.status,
                            AssistantRunStatus::Running | AssistantRunStatus::NeedsAttention
                        )
                    }) {
                        return Err("This task has no interrupted run to reconcile".into());
                    }
                    self.request_handoff(Pending {
                        task_id,
                        recover: true,
                        due: false,
                        cancel_after_recover: task.last_run.as_ref().and_then(|run| {
                            match run.failure_code.as_deref() {
                                Some(
                                    "E_ASSISTANT_BACKGROUND_EXPIRED"
                                    | "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED",
                                ) => Some(true),
                                Some(
                                    "E_ASSISTANT_NATIVE_STOP_REQUESTED"
                                    | "E_ASSISTANT_RUNTIME_STOPPED"
                                    | "E_ASSISTANT_RUNTIME_FAILED",
                                ) => Some(false),
                                _ => None,
                            }
                        }),
                    });
                }
            }
            RunnerCommand::PollDue => self.poll_due()?,
            RunnerCommand::RevokeForeground => {
                self.foreground = false;
                self.lifecycle_seen = true;
            }
            RunnerCommand::Stop => self.stop(false)?,
            RunnerCommand::Approval {
                approval_id,
                decision,
            } => {
                let state = self
                    .state
                    .as_mut()
                    .ok_or("Assistant does not own this task")?;
                if state
                    .agent_view()
                    .and_then(|v| v.approval)
                    .is_none_or(|a| a.approval_id != approval_id)
                {
                    return Err("This approval is no longer active".into());
                }
                let next = state.decide_agent_approval(&decision, None, &now())?;
                self.step(Some(next))?;
            }
            RunnerCommand::Answer { call_id, answer } => {
                let active = self
                    .active
                    .as_ref()
                    .ok_or("Assistant has no active claim")?;
                let task_id = active.claim.task_id.clone();
                let run_id = active.claim.run.run_id.clone();
                let next = self
                    .state
                    .as_mut()
                    .ok_or("Assistant does not own this task")?
                    .answer_agent_question(&call_id, answer.as_deref(), &now())?;
                self.events.push(RunnerEvent::AnswerAccepted {
                    task_id,
                    run_id,
                    call_id,
                });
                self.step(next)?;
            }
            RunnerCommand::Release => {
                if self.active.is_some()
                    || self.group_transition.is_some()
                    || self.state.as_ref().is_some_and(ShellState::is_busy)
                {
                    return Err("Resolve or stop assistant work before returning the writer".into());
                }
                self.release_if_idle();
            }
            RunnerCommand::RefreshStore => {
                self.refresh()?;
                self.poll_due()?;
            }
            RunnerCommand::SetUserNickname {
                expected_revision,
                nickname,
            } => {
                self.saved = Some(
                    self.store_ref()?
                        .set_user_nickname(expected_revision, &nickname)
                        .map_err(|error| error.to_string())?,
                );
            }
            RunnerCommand::EnsureConversation { expected_revision } => {
                self.saved = Some(
                    self.scoped_store()?
                        .ensure_conversation(expected_revision)
                        .map_err(|error| error.to_string())?,
                );
            }
            RunnerCommand::CreateMemory {
                expected_revision,
                memory_id,
                title,
                content,
                kind,
            } => {
                self.saved = Some(
                    self.scoped_store()?
                        .create_memory_with_id(
                            expected_revision,
                            &memory_id,
                            &title,
                            &content,
                            kind,
                            now_ms(),
                        )
                        .map_err(|error| error.to_string())?,
                );
            }
            RunnerCommand::RememberMemory {
                expected_revision,
                memory_id,
                title,
                content,
                kind,
            } => {
                self.saved = Some(
                    self.scoped_store()?
                        .remember_memory(
                            expected_revision,
                            memory_id.as_deref(),
                            &title,
                            &content,
                            kind,
                            now_ms(),
                        )
                        .map_err(|error| error.to_string())?,
                );
            }
            RunnerCommand::ForgetMemory {
                expected_revision,
                memory_id,
            } => {
                self.saved = Some(
                    self.scoped_store()?
                        .forget_memory(expected_revision, &memory_id)
                        .map_err(|error| error.to_string())?,
                );
            }
            RunnerCommand::SetProfile {
                expected_revision,
                profile,
            } => {
                self.saved = Some(
                    self.scoped_store()?
                        .set_profile(expected_revision, profile)
                        .map_err(|e| e.to_string())?,
                );
            }
            RunnerCommand::CreateTask {
                expected_revision,
                task_id,
                config,
            } => {
                self.saved = Some(
                    self.scoped_store()?
                        .create_task_with_id(expected_revision, &task_id, config, now_ms())
                        .map_err(|e| e.to_string())?,
                );
            }
            RunnerCommand::UpdateTask {
                expected_revision,
                task_id,
                config,
            } => {
                self.saved = Some(
                    self.task_store(&task_id)?
                        .update_task(expected_revision, &task_id, config, now_ms())
                        .map_err(|e| e.to_string())?,
                );
            }
            RunnerCommand::RemoveTask {
                expected_revision,
                task_id,
            } => {
                self.saved = Some(
                    self.task_store(&task_id)?
                        .remove_task(expected_revision, &task_id)
                        .map_err(|e| e.to_string())?,
                );
                if self.pending.as_ref().is_some_and(|p| p.task_id == task_id) {
                    self.pending = None;
                }
            }
            RunnerCommand::SetEnabled {
                expected_revision,
                task_id,
                enabled,
            } => {
                self.saved = Some(
                    self.task_store(&task_id)?
                        .set_enabled(expected_revision, &task_id, enabled, now_ms())
                        .map_err(|e| e.to_string())?,
                );
                if !enabled
                    && self
                        .pending
                        .as_ref()
                        .is_some_and(|p| p.task_id == task_id && !p.recover)
                {
                    self.pending = None;
                    if self.active.is_none() {
                        self.status = RunnerStatus::Idle;
                    }
                }
                // Pausing a job only removes future trigger eligibility.
            }
            RunnerCommand::NativeEvent { name, payload } => self.native_event(&name, payload)?,
            RunnerCommand::SelectBot { .. }
            | RunnerCommand::ForBot { .. }
            | RunnerCommand::CreateBot { .. }
            | RunnerCommand::CreateGroup { .. }
            | RunnerCommand::UpdateGroup { .. }
            | RunnerCommand::SendGroup { .. }
            | RunnerCommand::RecoverGroup { .. }
            | RunnerCommand::StopGroup { .. } => unreachable!(),
        }
        Ok(())
    }
}
