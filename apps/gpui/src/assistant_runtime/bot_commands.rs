//! Bot selection is a display scope. Execution always resolves its persisted owner.
use super::{driver::*, *};

impl Driver {
    pub(super) fn scoped_store(&self) -> Result<AssistantStore, String> {
        let id = self
            .command_bot_id
            .as_deref()
            .unwrap_or(&self.selected_bot_id);
        self.store_ref()?.for_bot(id).map_err(|e| e.to_string())
    }

    pub(super) fn task_store(&self, task_id: &str) -> Result<AssistantStore, String> {
        let owner = self
            .saved
            .as_ref()
            .and_then(|s| s.task_bot_id(task_id))
            .ok_or("Assistant task was not found")?;
        if self.command_bot_id.as_deref().is_some_and(|id| id != owner) {
            return Err("This task belongs to another Bot".into());
        }
        self.store_ref()?.for_bot(owner).map_err(|e| e.to_string())
    }

    pub(super) fn bot_command(
        &mut self,
        command: RunnerCommand,
    ) -> Result<Option<RunnerCommand>, String> {
        match command {
            RunnerCommand::ForBot { bot_id, command } => {
                if self.command_bot_id.is_some()
                    || !matches!(
                        *command,
                        RunnerCommand::EnsureConversation { .. }
                            | RunnerCommand::CreateMemory { .. }
                            | RunnerCommand::RememberMemory { .. }
                            | RunnerCommand::ForgetMemory { .. }
                            | RunnerCommand::SetProfile { .. }
                            | RunnerCommand::CreateTask { .. }
                            | RunnerCommand::UpdateTask { .. }
                            | RunnerCommand::RemoveTask { .. }
                            | RunnerCommand::SetEnabled { .. }
                            | RunnerCommand::RunNow { .. }
                            | RunnerCommand::Recover { .. }
                    )
                {
                    return Err("Unsupported Bot scoped command".into());
                }
                self.refresh()?;
                self.store_ref()?
                    .for_bot(&bot_id)
                    .map_err(|e| e.to_string())?;
                self.command_bot_id = Some(bot_id);
                let result = self.handle(*command);
                self.command_bot_id = None;
                result?;
            }
            RunnerCommand::SelectBot { bot_id } => {
                self.refresh()?;
                if self
                    .saved
                    .as_ref()
                    .and_then(|s| s.bot_snapshot(&bot_id))
                    .is_none()
                {
                    return Err("Bot was not found".into());
                }
                self.selected_bot_id = bot_id;
            }
            RunnerCommand::CreateBot {
                expected_revision,
                bot_id,
                profile,
            } => {
                self.saved = Some(
                    self.store_ref()?
                        .create_bot_with_id(expected_revision, &bot_id, profile)
                        .map_err(|e| e.to_string())?,
                );
            }
            RunnerCommand::CreateGroup {
                expected_revision,
                group_id,
                name,
                bot_ids,
            } => {
                self.saved = Some(
                    self.store_ref()?
                        .create_group_with_id(expected_revision, &group_id, &name, &bot_ids)
                        .map_err(|e| e.to_string())?,
                );
            }
            RunnerCommand::UpdateGroup {
                expected_revision,
                group_id,
                name,
                bot_ids,
            } => {
                self.saved = Some(
                    self.store_ref()?
                        .update_group(expected_revision, &group_id, &name, &bot_ids)
                        .map_err(|e| e.to_string())?,
                );
            }
            RunnerCommand::SendGroup {
                group_id,
                turn_id,
                target_bot_id,
                text,
                model_id,
                workspace_descriptor,
            } => {
                self.send_group(
                    group_id,
                    turn_id,
                    target_bot_id,
                    text,
                    model_id,
                    workspace_descriptor,
                )?;
            }
            RunnerCommand::RecoverGroup { group_id } => self.recover_group(&group_id)?,
            RunnerCommand::StopGroup { group_id } => self.stop_group(&group_id)?,
            other => return Ok(Some(other)),
        }
        Ok(None)
    }
}
