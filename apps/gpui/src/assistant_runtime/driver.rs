use super::*;
use serde_json::json;

#[derive(Clone, Debug)]
pub(super) enum OperationKind {
    Settings,
    Drain,
    Begin,
    Workspace,
    Reload,
    Persist,
    Agent,
    Experience,
    GroupEnd,
}
#[derive(Clone, Debug)]
pub(super) struct Operation {
    pub kind: OperationKind,
    pub command: RuntimeCommand,
    pub run_id: String,
}
#[derive(Clone)]
pub(super) struct Pending {
    pub task_id: String,
    pub recover: bool,
    pub due: bool,
    pub cancel_after_recover: Option<bool>,
}
pub(super) struct Active {
    pub claim: AssistantClaim,
    pub recover: bool,
    pub stopped: bool,
    pub stop_persist_failed: bool,
    pub expired: bool,
    pub setup_pending: bool,
    pub validated: bool,
    pub sent: bool,
    pub reconciled: bool,
    pub cancel_after_recover: Option<bool>,
}
pub(super) struct Driver {
    pub pi: Option<super::pi_gate::PiGate>,
    pub runtime_failure: Option<String>,
    pub store: Option<AssistantStore>,
    pub saved: Option<AssistantSnapshot>,
    pub state: Option<ShellState>,
    pub active: Option<Active>,
    pub pending: Option<Pending>,
    pub foreground: bool,
    pub(super) lifecycle_seen: bool,
    pub selected_bot_id: String,
    pub command_bot_id: Option<String>,
    pub group: Option<AssistantGroupClaim>,
    pub pending_group_id: Option<String>,
    pub group_transition: Option<super::group_transition::GroupTransition>,
    pub status: RunnerStatus,
    pub message: Option<String>,
    pub outbox: Vec<Operation>,
    pub events: Vec<RunnerEvent>,
}
impl Driver {
    pub fn new() -> Self {
        Self {
            pi: None,
            runtime_failure: None,
            store: None,
            saved: None,
            state: None,
            active: None,
            pending: None,
            foreground: false,
            lifecycle_seen: false,
            selected_bot_id: DEFAULT_BOT_ID.into(),
            command_bot_id: None,
            group: None,
            pending_group_id: None,
            group_transition: None,
            status: RunnerStatus::Idle,
            message: None,
            outbox: Vec::new(),
            events: Vec::new(),
        }
    }
    pub fn snapshot(&self) -> RunnerSnapshot {
        RunnerSnapshot {
            directory: self.saved.clone(),
            selected_bot_id: self.selected_bot_id.clone(),
            active_bot_id: self.group.as_ref().map(|g| g.bot_id.clone()).or_else(|| {
                self.active.as_ref().and_then(|a| {
                    self.saved
                        .as_ref()?
                        .task_bot_id(&a.claim.task_id)
                        .map(str::to_owned)
                })
            }),
            active_group_id: self
                .group
                .as_ref()
                .map(|g| g.group_id.clone())
                .or_else(|| self.pending_group_id.clone())
                .or_else(|| self.group_transition.as_ref().map(|g| g.group_id.clone())),
            store: self
                .saved
                .as_ref()
                .and_then(|s| s.bot_snapshot(&self.selected_bot_id)),
            state: self.state.clone(),
            active_task_id: self.active.as_ref().map(|a| a.claim.task_id.clone()),
            owns_writer: self.state.is_some(),
            foreground: self.foreground,
            status: self.status.clone(),
            message: self.message.clone(),
        }
    }
    pub fn command(&mut self, command: RunnerCommand) {
        if let Err(error) = self.handle(command) {
            self.error(error);
        }
    }
    pub fn reply(&mut self, operation: Operation, result: Result<Value, String>) {
        if matches!(operation.kind, OperationKind::GroupEnd) {
            if let Err(error) = self.accept_group_end(operation, result) {
                self.status = RunnerStatus::NeedsAttention;
                self.error(error);
            }
            return;
        }
        if matches!(operation.kind, OperationKind::Drain) {
            if let Ok(Value::Array(actions)) = result {
                for action in actions {
                    if let Err(error) = self.native_event("taskExperienceAction", action) {
                        self.error(error);
                    }
                }
            }
            return;
        }
        if matches!(operation.kind, OperationKind::Settings) {
            if let Ok(value) = result
                && !self.lifecycle_seen
                && let Some(foreground) = value["foreground"].as_bool()
            {
                self.foreground = foreground;
                self.lifecycle_seen = true;
            }
            return;
        }
        if matches!(operation.kind, OperationKind::Experience) {
            return;
        }
        if self
            .active
            .as_ref()
            .is_none_or(|a| a.claim.run.run_id != operation.run_id)
        {
            return;
        }
        if matches!(operation.kind, OperationKind::Agent)
            && !self
                .state
                .as_ref()
                .is_some_and(|s| s.owns_agent_command(&operation.command))
        {
            return;
        }
        if let Err(error) = self.accept(operation, result) {
            self.attention(&error);
        }
    }
    fn accept(
        &mut self,
        operation: Operation,
        result: Result<Value, String>,
    ) -> Result<(), String> {
        match operation.kind {
            OperationKind::Begin => {
                self.active.as_mut().unwrap().setup_pending = false;
                let value = result?;
                if value != true && value["started"] != true {
                    return Err("Native task admission was not granted".into());
                }
                self.continue_setup()?;
            }
            OperationKind::Workspace => {
                self.active.as_mut().unwrap().setup_pending = false;
                let value = result?;
                let descriptor = &value["workspace"];
                if value["schema_version"] != 1
                    || rish_shell_core::workspace_binding(descriptor)?
                        != self
                            .active
                            .as_ref()
                            .unwrap()
                            .claim
                            .run
                            .snapshot
                            .workspace_binding
                {
                    return Err("E_CONVERSATION_WORKSPACE_UNAVAILABLE".into());
                }
                self.active.as_mut().unwrap().validated = true;
                self.continue_setup()?;
            }
            OperationKind::Persist => {
                let next = self.state.as_mut().unwrap().accept_persist(result?)?;
                if let Some(next) = next {
                    self.step(Some(next))?;
                } else if self.active.as_ref().unwrap().sent {
                    self.settle()?;
                } else {
                    self.continue_setup()?;
                }
            }
            OperationKind::Reload => {
                self.active.as_mut().unwrap().setup_pending = false;
                self.state.as_mut().unwrap().load_snapshot(result?)?;
                self.active.as_mut().unwrap().reconciled = true;
                self.continue_setup()?;
            }
            OperationKind::Agent => {
                let state = self.state.as_mut().unwrap();
                let next = match result {
                    Ok(value) => state.accept_agent_result(&operation.command, value, &now()),
                    Err(error) => state.fail_agent_command(&operation.command, &error, &now()),
                }?;
                self.step(next)?;
            }
            OperationKind::Experience
            | OperationKind::Settings
            | OperationKind::Drain
            | OperationKind::GroupEnd => {}
        }
        Ok(())
    }
    pub fn dispatch(&mut self, kind: OperationKind, command: RuntimeCommand) {
        if let Some(active) = &self.active {
            self.outbox.push(Operation {
                kind,
                command,
                run_id: active.claim.run.run_id.clone(),
            });
        }
    }
    pub fn experience(&mut self, op: &str, fields: Value) {
        let Some(active) = &self.active else { return };
        let mut request = json!({"schema_version":1,"op":op,"runId":active.claim.run.run_id,"conversationId":active.claim.conversation_id});
        if let Some(fields) = fields.as_object() {
            request.as_object_mut().unwrap().extend(fields.clone());
        }
        self.dispatch(
            OperationKind::Experience,
            RuntimeCommand::new("TaskExperience", "handle", vec![request]),
        );
    }
    pub fn store_ref(&self) -> Result<&AssistantStore, String> {
        self.store
            .as_ref()
            .ok_or("Assistant storage is not initialized".into())
    }
    pub fn revision(&self) -> Result<u64, String> {
        self.saved
            .as_ref()
            .map(|s| s.revision)
            .ok_or("Assistant storage is not loaded".into())
    }
    pub fn refresh(&mut self) -> Result<(), String> {
        self.saved = Some(self.store_ref()?.load().map_err(|e| e.to_string())?);
        Ok(())
    }
    pub fn task(&self, id: &str) -> Result<AssistantTask, String> {
        self.saved
            .as_ref()
            .and_then(|s| s.all_tasks().into_iter().find(|t| t.id == id))
            .cloned()
            .ok_or("Assistant task was not found".into())
    }
    pub(super) fn poll_due(&mut self) -> Result<(), String> {
        self.poll_due_at(now_ms())
    }
    pub(super) fn poll_due_at(&mut self, time: u64) -> Result<(), String> {
        if self.store.is_none() || self.active.is_some() || self.group_transition.is_some() {
            return Ok(());
        }
        if let Some(pending) = &self.pending {
            // UI entities can disappear after receiving this notification.
            // Reoffer the same durable intent until its writer is granted.
            if self.state.is_none() {
                self.events.push(RunnerEvent::HandoffNeeded {
                    task_id: pending.task_id.clone(),
                });
            }
            return Ok(());
        }
        self.refresh()?;
        let saved = self.saved.as_ref().unwrap();
        if let Some(task) = saved.all_tasks().into_iter().find(|task| {
            task.last_run.as_ref().is_some_and(|run| {
                run.status.is_active()
                    && matches!(
                        run.failure_code.as_deref(),
                        Some(
                            "E_ASSISTANT_NATIVE_STOP_REQUESTED"
                                | "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED"
                                | "E_ASSISTANT_RUNTIME_STOPPED"
                                | "E_ASSISTANT_RUNTIME_FAILED"
                        )
                    )
            })
        }) {
            self.request_handoff(Pending {
                task_id: task.id.clone(),
                recover: true,
                due: false,
                cancel_after_recover: Some(
                    task.last_run.as_ref().unwrap().failure_code.as_deref()
                        == Some("E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED"),
                ),
            });
            return Ok(());
        }
        if let Some(task_id) = saved.pending_task_ids().into_iter().next() {
            self.request_handoff(Pending {
                task_id,
                recover: false,
                due: false,
                cancel_after_recover: None,
            });
        } else if let Some(task_id) = saved.due_task_ids(time).into_iter().next() {
            self.request_handoff(Pending {
                task_id,
                recover: false,
                due: true,
                cancel_after_recover: None,
            });
        }
        Ok(())
    }
    pub(super) fn request_handoff(&mut self, pending: Pending) {
        // A native notification or recovery request cannot replace an already
        // offered writer lease with another conversation. Persisted requests
        // remain available after that current handoff settles.
        if self
            .pending
            .as_ref()
            .is_some_and(|current| current.task_id != pending.task_id)
        {
            return;
        }
        if self.pending_group_id.as_deref() != Some(&pending.task_id) {
            self.pending_group_id = None;
        }
        self.events.push(RunnerEvent::HandoffNeeded {
            task_id: pending.task_id.clone(),
        });
        self.pending = Some(pending);
        self.status = RunnerStatus::WaitingForForeground;
    }
    pub fn release_if_idle(&mut self) {
        if self.active.is_none()
            && self.group_transition.is_none()
            && self.state.as_ref().is_some_and(|s| !s.is_busy())
        {
            self.events.push(RunnerEvent::Returned {
                state: self.state.take().unwrap(),
            });
        }
    }
    pub fn error(&mut self, error: String) {
        self.message = Some(error.clone());
        self.events.push(RunnerEvent::Error(error));
    }
    pub fn attention(&mut self, error: &str) {
        self.status = RunnerStatus::NeedsAttention;
        self.error(error.into());
        if let Some(active) = &self.active {
            let saved_reason = self
                .saved
                .as_ref()
                .and_then(|s| {
                    s.all_tasks()
                        .into_iter()
                        .find(|t| t.id == active.claim.task_id)
                })
                .and_then(|t| t.last_run.as_ref())
                .and_then(|r| r.failure_code.as_deref());
            let reason = if active.expired {
                "E_ASSISTANT_BACKGROUND_EXPIRED"
            } else if let Some(code) = self.runtime_failure.as_deref() {
                code
            } else if active.stopped {
                "E_ASSISTANT_NATIVE_STOP_REQUESTED"
            } else if matches!(
                saved_reason,
                Some(
                    "E_ASSISTANT_BACKGROUND_EXPIRED"
                        | "E_ASSISTANT_NATIVE_BACKGROUND_EXPIRED"
                        | "E_ASSISTANT_NATIVE_STOP_REQUESTED"
                )
            ) {
                saved_reason.unwrap()
            } else {
                "E_ASSISTANT_RECONCILIATION_REQUIRED"
            };
            let task_id = active.claim.task_id.clone();
            let run_id = active.claim.run.run_id.clone();
            let reason = reason.to_owned();
            let result = self.persist_run_attention(&task_id, &run_id, &reason, false);
            match result {
                Ok(saved) => self.saved = Some(saved),
                Err(e) => self.error(e),
            }
        }
        self.experience("update", json!({"phase":"blocked"}));
        // If no session/native effect is outstanding, display-only attention
        // does not need to lock unrelated ordinary chat.
        if self.state.as_ref().is_some_and(|s| !s.is_busy())
            && self.active.as_ref().is_some_and(|a| !a.setup_pending)
        {
            if let Some(group) = &self.group {
                // Paused group recovery can immediately start this same lane
                // again. It must wait for the previous native display's end
                // just like a completed member does.
                self.group_transition = Some(super::group_transition::GroupTransition {
                    group_id: group.group_id.clone(),
                    run_id: group.claim.run.run_id.clone(),
                    conversation_id: group.claim.conversation_id.clone(),
                    status: AssistantRunStatus::NeedsAttention,
                    continue_members: false,
                    request_pending: false,
                });
            } else {
                self.experience("end", json!({"status":"blocked"}));
            }
            self.active = None;
            self.group = None;
            self.pi = None;
            self.dispatch_group_end();
            self.release_if_idle();
        }
    }
}
