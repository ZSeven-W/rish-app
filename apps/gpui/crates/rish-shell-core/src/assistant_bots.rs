//! Multiple personal assistants share one transaction, but never task/memory scope.
use super::*;
use serde::{Deserialize, Serialize};

pub const DEFAULT_BOT_ID: &str = "00000000-0000-4000-8000-000000000001";
pub const MAX_BOTS: usize = 16;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantBot {
    pub id: String,
    pub profile: AssistantProfile,
    pub conversation_id: Option<String>,
    pub tasks: Vec<AssistantTask>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub memories: Vec<AssistantMemory>,
}

impl AssistantSnapshot {
    pub fn bot_ids(&self) -> Vec<&str> {
        std::iter::once(DEFAULT_BOT_ID)
            .chain(self.bots.iter().map(|bot| bot.id.as_str()))
            .collect()
    }
    pub fn bot_profile(&self, bot_id: &str) -> Option<&AssistantProfile> {
        if bot_id == DEFAULT_BOT_ID {
            Some(&self.profile)
        } else {
            self.bots
                .iter()
                .find(|bot| bot.id == bot_id)
                .map(|bot| &bot.profile)
        }
    }
    /// Read-model projection only. Persistence always merges into a freshly read
    /// full directory under the common lock; this is never a replacement file.
    pub fn bot_snapshot(&self, bot_id: &str) -> Option<Self> {
        let mut projected = self.clone();
        if bot_id != DEFAULT_BOT_ID {
            let bot = self.bots.iter().find(|bot| bot.id == bot_id)?;
            projected.profile = bot.profile.clone();
            projected.conversation_id = bot.conversation_id.clone();
            projected.tasks = bot.tasks.clone();
            projected.memories = bot.memories.clone();
        }
        projected
            .tool_receipts
            .retain(|receipt| self.conversation_bot_id(&receipt.conversation_id) == Some(bot_id));
        projected.bots.clear();
        projected.groups.clear();
        Some(projected)
    }
    pub fn conversation_bot_id(&self, conversation_id: &str) -> Option<&str> {
        if self.conversation_id.as_deref() == Some(conversation_id) {
            return Some(DEFAULT_BOT_ID);
        }
        if let Some(bot) = self
            .bots
            .iter()
            .find(|bot| bot.conversation_id.as_deref() == Some(conversation_id))
        {
            return Some(&bot.id);
        }
        self.groups
            .iter()
            .flat_map(|group| &group.members)
            .find(|member| member.conversation_id == conversation_id)
            .map(|member| member.bot_id.as_str())
    }
    pub fn task_bot_id(&self, task_id: &str) -> Option<&str> {
        if self.tasks.iter().any(|task| task.id == task_id) {
            return Some(DEFAULT_BOT_ID);
        }
        self.bots
            .iter()
            .find(|bot| bot.tasks.iter().any(|task| task.id == task_id))
            .map(|bot| bot.id.as_str())
    }
    pub fn all_tasks(&self) -> Vec<&AssistantTask> {
        self.tasks
            .iter()
            .chain(self.bots.iter().flat_map(|bot| &bot.tasks))
            .collect()
    }
    pub(super) fn project_for_store(&self, bot_id: &str) -> StoreResult<Self> {
        if bot_id == DEFAULT_BOT_ID {
            return Ok(self.clone());
        }
        let mut projected = self
            .bot_snapshot(bot_id)
            .ok_or(AssistantStoreError::NotFound)?;
        // Receipt identities and CAS revisions remain global across all bots.
        projected.tool_receipts = self.tool_receipts.clone();
        Ok(projected)
    }
}

impl AssistantStore {
    pub fn for_bot(&self, bot_id: &str) -> StoreResult<Self> {
        if self.load()?.bot_profile(bot_id).is_none() {
            return Err(AssistantStoreError::NotFound);
        }
        Ok(Self {
            storage: self.storage.duplicate()?,
            bot_id: bot_id.into(),
        })
    }
    pub(super) fn read_scoped(&self) -> StoreResult<AssistantSnapshot> {
        self.storage.read()?.project_for_store(&self.bot_id)
    }
    pub(super) fn persist_for_bot(
        &self,
        bot_id: &str,
        scoped: AssistantSnapshot,
    ) -> StoreResult<AssistantSnapshot> {
        if bot_id == DEFAULT_BOT_ID {
            return self.persist_full(scoped);
        }
        let mut full = self.storage.read()?;
        check_revision(&full, scoped.revision)?;
        let bot = full
            .bots
            .iter_mut()
            .find(|bot| bot.id == bot_id)
            .ok_or(AssistantStoreError::NotFound)?;
        bot.profile = scoped.profile;
        bot.conversation_id = scoped.conversation_id;
        bot.tasks = scoped.tasks;
        bot.memories = scoped.memories;
        full.clock_high_water_ms = scoped.clock_high_water_ms;
        full.tool_receipts = scoped.tool_receipts;
        self.persist_full(full)
    }
    pub fn create_bot_with_id(
        &self,
        expected_revision: u64,
        id: &str,
        mut profile: AssistantProfile,
    ) -> StoreResult<AssistantSnapshot> {
        memory::canonical_id(id)?;
        if id == DEFAULT_BOT_ID {
            return Err(AssistantStoreError::Invalid("reserved bot identity"));
        }
        profile.name = normalize_name(&profile.name)?;
        validate_text(&profile.soul, false)?;
        validate_text(&profile.notes, false)?;
        validate_avatar(profile.avatar.as_ref())?;
        validate_runtime(&profile.runtime)?;
        self.storage.locked(|| {
            let mut full = self.storage.read()?;
            if let Some(bot) = full.bots.iter().find(|bot| bot.id == id) {
                return if bot.profile == profile {
                    Ok(full)
                } else {
                    Err(AssistantStoreError::Invalid("bot identity reused"))
                };
            }
            check_revision(&full, expected_revision)?;
            if full.bots.len() + 1 >= MAX_BOTS {
                return Err(AssistantStoreError::Invalid("bot limit reached"));
            }
            full.bots.push(AssistantBot {
                id: id.into(),
                profile,
                conversation_id: None,
                tasks: Vec::new(),
                memories: Vec::new(),
            });
            self.persist_full(full)
        })
    }
}

pub(super) fn validate_directory(state: &AssistantSnapshot) -> StoreResult<()> {
    if state.bots.len() + 1 > MAX_BOTS {
        return Err(AssistantStoreError::Invalid("bot limit"));
    }
    let mut identities = HashSet::<String>::new();
    identities.insert(DEFAULT_BOT_ID.into());
    let mut insert = |id: &str| -> StoreResult<()> {
        validate_identity(id)?;
        if !identities.insert(id.into()) {
            return Err(AssistantStoreError::Invalid("duplicate directory identity"));
        }
        Ok(())
    };
    if let Some(id) = &state.conversation_id {
        insert(id)?;
    }
    for bot in &state.bots {
        memory::canonical_id(&bot.id)?;
        insert(&bot.id)?;
        if let Some(id) = &bot.conversation_id {
            memory::canonical_id(id)?;
            insert(id)?;
        }
        let validation = AssistantSnapshot {
            profile: bot.profile.clone(),
            tasks: bot.tasks.clone(),
            clock_high_water_ms: state.clock_high_water_ms,
            revision: state.revision,
            ..Default::default()
        };
        // Reuse the original strict task/profile/run validator without copied
        // receipts or attribution; those are checked against the full directory.
        validate_snapshot(&validation)?;
        memory::validate_owned_memories(state, &bot.id, &bot.memories)?;
    }
    for task in state.all_tasks() {
        insert(&task.id)?;
        insert(&task.conversation_id)?;
        if let Some(run) = &task.last_run {
            for id in [
                &run.run_id,
                &run.ids.turn_id,
                &run.ids.attempt_id,
                &run.ids.round_id,
                &run.ids.user_message_id,
                &run.ids.assistant_message_id,
            ] {
                insert(id)?;
            }
        }
    }
    for memory in state
        .memories
        .iter()
        .chain(state.bots.iter().flat_map(|bot| &bot.memories))
    {
        insert(&memory.id)?;
    }
    groups::validate_groups(state, &mut insert)
}
