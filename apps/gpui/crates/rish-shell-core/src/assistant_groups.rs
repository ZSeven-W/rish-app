//! Immutable per-member session lanes share ordered group turns, not private memory.
use super::*;
use serde::{Deserialize, Serialize};
#[path = "assistant_group_turns.rs"]
mod turns;
#[path = "assistant_group_validation.rs"]
mod validation;
pub(super) use validation::validate_groups;
pub const MAX_ASSISTANT_GROUPS: usize = 32;
pub const MAX_GROUP_MEMBERS: usize = 8;
pub const MAX_GROUP_ROUNDS: usize = 128;
pub const MAX_GROUP_INPUT_BYTES: usize = 8 * 1024;
pub const MAX_GROUP_REPLY_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantGroupMember {
    pub bot_id: String,
    pub conversation_id: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantGroup {
    pub id: String,
    pub name: String,
    pub active_bot_ids: Vec<String>,
    /// Former members remain resolvable for attribution and native WAL recovery.
    pub members: Vec<AssistantGroupMember>,
    pub rounds: Vec<AssistantGroupRound>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantGroupRound {
    pub id: String,
    pub user_message_id: String,
    pub text: String,
    pub created_at_ms: u64,
    pub model_id: String,
    pub workspace_binding: Value,
    pub workspace_descriptor: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeSpec>,
    pub replies: Vec<AssistantGroupReply>,
    pub stopped: bool,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantGroupReply {
    /// Execution identity, never an ordinary saved user task.
    pub id: String,
    pub bot_id: String,
    pub conversation_id: String,
    pub run: Option<AssistantRun>,
    pub text: Option<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct AssistantGroupClaim {
    pub group_id: String,
    pub round_id: String,
    pub bot_id: String,
    pub claim: AssistantClaim,
}
impl AssistantGroupRound {
    pub fn is_pending(&self) -> bool {
        self.replies
            .iter()
            .any(|r| r.run.as_ref().is_some_and(|run| run.status.is_active()))
            || (!self.stopped && self.replies.iter().any(|r| r.run.is_none()))
    }
}
impl AssistantSnapshot {
    pub fn group_claim(&self, id: &str) -> Option<AssistantGroupClaim> {
        let group = self.groups.iter().find(|g| g.id == id)?;
        for round in &group.rounds {
            for reply in &round.replies {
                if let Some(run) = reply.run.as_ref().filter(|run| run.status.is_active()) {
                    return Some(AssistantGroupClaim {
                        group_id: group.id.clone(),
                        round_id: round.id.clone(),
                        bot_id: reply.bot_id.clone(),
                        claim: AssistantClaim {
                            snapshot: self.clone(),
                            task_id: reply.id.clone(),
                            conversation_id: reply.conversation_id.clone(),
                            run: run.clone(),
                        },
                    });
                }
            }
        }
        None
    }
}
impl AssistantStore {
    pub fn create_group_with_id(
        &self,
        revision: u64,
        id: &str,
        name: &str,
        bot_ids: &[String],
    ) -> StoreResult<AssistantSnapshot> {
        memory::canonical_id(id)?;
        let name = normalize_name(name)?;
        self.storage.locked(|| {
            let mut full = self.storage.read()?;
            validate_targets(&full, bot_ids, 2)?;
            if let Some(group) = full.groups.iter().find(|g| g.id == id) {
                return if group.name == name && group.active_bot_ids == bot_ids {
                    Ok(full)
                } else {
                    Err(AssistantStoreError::Invalid("group identity reused"))
                };
            }
            check_revision(&full, revision)?;
            if full.groups.len() >= MAX_ASSISTANT_GROUPS {
                return Err(AssistantStoreError::Invalid("group limit reached"));
            }
            full.groups.push(AssistantGroup {
                id: id.into(),
                name,
                active_bot_ids: bot_ids.to_vec(),
                members: bot_ids
                    .iter()
                    .map(|id| AssistantGroupMember {
                        bot_id: id.clone(),
                        conversation_id: crate::model::id(),
                    })
                    .collect(),
                rounds: Vec::new(),
            });
            self.persist_full(full)
        })
    }
    pub fn update_group(
        &self,
        revision: u64,
        id: &str,
        name: &str,
        bot_ids: &[String],
    ) -> StoreResult<AssistantSnapshot> {
        let name = normalize_name(name)?;
        self.storage.locked(|| {
            let mut full = self.storage.read()?;
            validate_targets(&full, bot_ids, 2)?;
            check_revision(&full, revision)?;
            let group = full
                .groups
                .iter_mut()
                .find(|g| g.id == id)
                .ok_or(AssistantStoreError::NotFound)?;
            if group.rounds.iter().any(AssistantGroupRound::is_pending) {
                return Err(AssistantStoreError::Running);
            }
            for bot_id in bot_ids {
                if !group.members.iter().any(|m| m.bot_id == *bot_id) {
                    group.members.push(AssistantGroupMember {
                        bot_id: bot_id.clone(),
                        conversation_id: crate::model::id(),
                    });
                }
            }
            group.name = name;
            group.active_bot_ids = bot_ids.to_vec();
            self.persist_full(full)
        })
    }
    /// Stops only unstarted replies; active claims still require native reconciliation.
    pub fn stop_group(&self, revision: u64, id: &str) -> StoreResult<AssistantSnapshot> {
        self.storage.locked(|| {
            let mut full = self.storage.read()?;
            let group = full
                .groups
                .iter()
                .find(|g| g.id == id)
                .ok_or(AssistantStoreError::NotFound)?;
            if group.rounds.last().is_none_or(|r| r.stopped) {
                return Ok(full);
            }
            check_revision(&full, revision)?;
            full.groups
                .iter_mut()
                .find(|g| g.id == id)
                .unwrap()
                .rounds
                .last_mut()
                .unwrap()
                .stopped = true;
            self.persist_full(full)
        })
    }
}
fn validate_targets(state: &AssistantSnapshot, ids: &[String], min: usize) -> StoreResult<()> {
    let unique: HashSet<_> = ids.iter().collect();
    if ids.len() < min
        || ids.len() > MAX_GROUP_MEMBERS
        || ids.len() != unique.len()
        || ids.iter().any(|id| state.bot_profile(id).is_none())
    {
        return Err(AssistantStoreError::Invalid("group members"));
    }
    Ok(())
}
fn bounded_group_text(text: &str, max: usize, required: bool) -> StoreResult<()> {
    if text.len() > max || (required && text.trim().is_empty()) || text.contains('\0') {
        return Err(AssistantStoreError::Invalid("group text"));
    }
    Ok(())
}
