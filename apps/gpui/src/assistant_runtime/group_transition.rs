//! Native task UI has its own asynchronous end boundary. Keep the session
//! writer until that boundary completes before admitting another group member.
use super::{driver::*, *};
use serde_json::json;

#[derive(Clone)]
pub(super) struct GroupTransition {
    pub group_id: String,
    pub run_id: String,
    pub conversation_id: String,
    pub status: AssistantRunStatus,
    pub continue_members: bool,
    pub request_pending: bool,
}

impl Driver {
    pub(super) fn dispatch_group_end(&mut self) {
        let Some(group) = self.group_transition.as_mut() else {
            return;
        };
        if group.request_pending {
            return;
        }
        group.request_pending = true;
        let status = match group.status {
            AssistantRunStatus::Completed => "completed",
            AssistantRunStatus::Cancelled => "cancelled",
            _ => "blocked",
        };
        self.outbox.push(Operation {
            kind: OperationKind::GroupEnd,
            run_id: group.run_id.clone(),
            command: RuntimeCommand::new(
                "TaskExperience",
                "handle",
                vec![json!({
                    "schema_version":1,"op":"end","runId":group.run_id,
                    "conversationId":group.conversation_id,"status":status
                })],
            ),
        });
    }

    pub(super) fn accept_group_end(
        &mut self,
        operation: Operation,
        result: Result<Value, String>,
    ) -> Result<(), String> {
        let Some(group) = &mut self.group_transition else {
            return Ok(());
        };
        if operation.run_id != group.run_id
            || operation.command.args.first().is_none_or(|q| {
                q["op"] != "end"
                    || q["runId"] != group.run_id
                    || q["conversationId"] != group.conversation_id
            })
        {
            return Ok(());
        }
        group.request_pending = false;
        // false is the native idempotent response when the exact run already
        // ended. This writer has admitted no other run in the meantime.
        if !result?.is_boolean() {
            return Err("Native group end was not acknowledged".into());
        }
        // Keep the ended run's identity until both storage read and the next
        // claim succeed. A failed read/claim must still have a retry route
        // while this actor owns the writer.
        self.refresh()?;
        let group = self.group_transition.take().unwrap();
        if group.continue_members && self.foreground {
            // A previous claim may have committed before its write receipt
            // was lost. Reconcile that exact identity rather than claiming or
            // sending another copy of the next member's work.
            let recover = self
                .saved
                .as_ref()
                .is_some_and(|s| s.group_claim(&group.group_id).is_some());
            let pending = Pending {
                task_id: group.group_id.clone(),
                recover,
                due: false,
                cancel_after_recover: None,
            };
            if let Err(error) = self.start_group(&group.group_id, pending) {
                self.group_transition = Some(group);
                return Err(error);
            }
            return Ok(());
        }
        self.status = if matches!(
            group.status,
            AssistantRunStatus::Completed | AssistantRunStatus::Cancelled
        ) {
            RunnerStatus::Idle
        } else {
            RunnerStatus::NeedsAttention
        };
        if group.continue_members && !self.foreground {
            self.message = Some("Return to the group to continue the remaining members".into());
        }
        self.release_if_idle();
        Ok(())
    }
}
