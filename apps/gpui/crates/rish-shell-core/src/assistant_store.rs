//! App-private assistant state, separate from native session schema 9.
//!
//! Native ShellAssistant.storage supplies a trusted existing canonical
//! app-private directory; callers must never use workspace or model paths.
//! Profile notes remain explicit person edits. Native-authorized task tools
//! cannot change the profile or permissions. A new store has no automatic work.
//! Claiming records stable session IDs before any Agent mutation. A running
//! claim never expires: after restart the runner must reconcile those IDs with
//! the native session instead of resending. Due times are eligibility only.
#[path = "assistant_bots.rs"]
mod bots;
#[path = "assistant_groups.rs"]
mod groups;
#[path = "assistant_store_io.rs"]
mod io;
#[path = "assistant_memory.rs"]
mod memory;
#[path = "assistant_task_store.rs"]
mod task_tools;
pub use bots::*;
pub use groups::*;
#[path = "assistant_store_types.rs"]
mod types;
pub use memory::{AssistantMemory, AssistantMemoryKind, MAX_MEMORIES, MAX_MEMORY_CONTENT_BYTES};
use rish_agent_core::name_policy::{self, NameKind};
use serde_json::Value;
use std::{collections::HashSet, path::Path};
pub use task_tools::MAX_TOOL_RECEIPTS;
pub use types::*;

pub struct AssistantStore {
    storage: io::Storage,
    bot_id: String,
}

/// Read a display-only PNG from the canonical private assistant directory.
/// The caller can decode the returned, bounded bytes without reopening paths.
pub fn read_avatar_bytes(directory: &Path, avatar: &AssistantAvatar) -> StoreResult<Vec<u8>> {
    avatar.validate()?;
    io::Storage::open(directory)?.read_avatar(avatar)
}

impl AssistantStore {
    /// Opens the canonical app-private directory returned by native storage.
    /// This is not a filesystem capability to expose to models or tools.
    pub fn open(directory: impl AsRef<Path>) -> StoreResult<Self> {
        let store = Self {
            storage: io::Storage::open(directory.as_ref())?,
            bot_id: DEFAULT_BOT_ID.into(),
        };
        store.load()?;
        Ok(store)
    }
    pub fn load(&self) -> StoreResult<AssistantSnapshot> {
        self.storage.locked(|| self.storage.read())
    }
    /// Explicit person edit. Even a Bot-scoped handle edits the global display
    /// identity, without changing Bot profiles, conversations or frozen runs.
    pub fn set_user_nickname(
        &self,
        expected_revision: u64,
        nickname: &str,
    ) -> StoreResult<AssistantSnapshot> {
        let nickname = normalize_name(nickname)?;
        self.storage.locked(|| {
            let mut snapshot = self.storage.read()?;
            check_revision(&snapshot, expected_revision)?;
            snapshot.user_nickname = Some(nickname);
            self.persist_full(snapshot)
        })
    }
    /// Explicit UI/actor action. Concurrent callers reuse the first committed
    /// identity; a stale caller cannot allocate against an unrelated edit.
    pub fn ensure_conversation(&self, expected_revision: u64) -> StoreResult<AssistantSnapshot> {
        self.storage.locked(|| {
            let mut state = self.read_scoped()?;
            if state.conversation_id.is_some() {
                return self.storage.read();
            }
            check_revision(&state, expected_revision)?;
            state.conversation_id = Some(crate::model::id());
            self.persist(state)
        })
    }
    fn mutate(
        &self,
        expected_revision: u64,
        action: impl FnOnce(&mut AssistantSnapshot) -> StoreResult<()>,
    ) -> StoreResult<AssistantSnapshot> {
        self.storage.locked(|| {
            let mut snapshot = self.read_scoped()?;
            check_revision(&snapshot, expected_revision)?;
            action(&mut snapshot)?;
            self.persist(snapshot)
        })
    }
    fn persist(&self, snapshot: AssistantSnapshot) -> StoreResult<AssistantSnapshot> {
        self.persist_for_bot(&self.bot_id, snapshot)
    }
    fn persist_full(&self, mut snapshot: AssistantSnapshot) -> StoreResult<AssistantSnapshot> {
        snapshot.revision = snapshot
            .revision
            .checked_add(1)
            .ok_or(AssistantStoreError::Invalid("revision exhausted"))?;
        validate_snapshot(&snapshot)?;
        self.storage.write(&snapshot)?;
        Ok(snapshot)
    }
    pub fn set_profile(
        &self,
        expected_revision: u64,
        mut profile: AssistantProfile,
    ) -> StoreResult<AssistantSnapshot> {
        profile.name = normalize_name(&profile.name)?;
        validate_text(&profile.notes, false)?;
        validate_text(&profile.soul, false)?;
        validate_avatar(profile.avatar.as_ref())?;
        validate_runtime(&profile.runtime)?;
        self.mutate(expected_revision, |state| {
            state.profile = profile;
            Ok(())
        })
    }
    /// Convenience for one-shot callers. Retryable UI flows must retain an ID
    /// and use `create_task_with_id` across uncertain persistence outcomes.
    pub fn create_task(
        &self,
        expected_revision: u64,
        config: AssistantTaskConfig,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        self.create_task_with_id(expected_revision, &crate::model::id(), config, now_ms)
    }
    /// UI editors retain this ID across retries, including an uncertain write
    /// result after atomic rename. Repeating the same normalized configuration
    /// returns current state without resetting the schedule, conversation, or
    /// running claim. An existing ID with different settings is never replaced.
    pub fn create_task_with_id(
        &self,
        expected_revision: u64,
        task_id: &str,
        config: AssistantTaskConfig,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        validate_identity(task_id)?;
        let config = normalize_config(config)?;
        self.storage.locked(|| {
            let mut state = self.read_scoped()?;
            if let Some(existing) = state.tasks.iter().find(|task| task.id == task_id) {
                return if existing.config() == config {
                    self.storage.read()
                } else {
                    Err(AssistantStoreError::Invalid(
                        "task identity already exists with different settings",
                    ))
                };
            }
            check_revision(&state, expected_revision)?;
            if state.tasks.len() >= MAX_TASKS {
                return Err(AssistantStoreError::Invalid("task limit reached"));
            }
            state.clock_high_water_ms = state.clock_high_water_ms.max(now_ms);
            state.tasks.push(AssistantTask {
                id: task_id.into(),
                conversation_id: crate::model::id(),
                next_due_ms: next_due(&config, state.clock_high_water_ms)?,
                title: config.title,
                instructions: config.instructions,
                workspace_binding: config.workspace_binding,
                workspace_descriptor: config.workspace_descriptor,
                model_id: config.model_id,
                interval_minutes: config.interval_minutes,
                enabled: config.enabled,
                pending_manual: false,
                last_run: None,
                runtime: config.runtime,
            });
            self.persist(state)
        })
    }
    pub fn update_task(
        &self,
        expected_revision: u64,
        task_id: &str,
        config: AssistantTaskConfig,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        let config = normalize_config(config)?;
        self.mutate(expected_revision, |state| {
            state.clock_high_water_ms = state.clock_high_water_ms.max(now_ms);
            let anchor = state.clock_high_water_ms;
            let task = task_mut(state, task_id)?;
            // A claimed task keeps reusing its conversation, whose workspace
            // is immutable. Rebinding here would save a task no future run
            // can execute. Display metadata may still refresh independently.
            if task.last_run.is_some() && task.workspace_binding != config.workspace_binding {
                return Err(AssistantStoreError::Invalid(
                    "workspace is fixed after the first run; create a new task",
                ));
            }
            let schedule_changed =
                task.enabled != config.enabled || task.interval_minutes != config.interval_minutes;
            if schedule_changed {
                task.next_due_ms = if task.is_running() {
                    None
                } else {
                    next_due(&config, anchor)?
                };
            }
            task.title = config.title;
            task.instructions = config.instructions;
            task.workspace_binding = config.workspace_binding;
            task.workspace_descriptor = config.workspace_descriptor;
            task.model_id = config.model_id;
            task.interval_minutes = config.interval_minutes;
            task.enabled = config.enabled;
            task.runtime = config.runtime;
            if !config.enabled {
                task.pending_manual = false;
            }
            Ok(())
        })
    }
    pub fn remove_task(
        &self,
        expected_revision: u64,
        task_id: &str,
    ) -> StoreResult<AssistantSnapshot> {
        self.mutate(expected_revision, |state| {
            if task_mut(state, task_id)?.is_running() {
                return Err(AssistantStoreError::Running);
            }
            state.tasks.retain(|task| task.id != task_id);
            Ok(())
        })
    }
    /// Pausing stops future scheduling, but never claims to cancel a native run.
    pub fn set_enabled(
        &self,
        expected_revision: u64,
        task_id: &str,
        enabled: bool,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        self.mutate(expected_revision, |state| {
            state.clock_high_water_ms = state.clock_high_water_ms.max(now_ms);
            let anchor = state.clock_high_water_ms;
            let task = task_mut(state, task_id)?;
            if !enabled {
                task.pending_manual = false;
            }
            if task.enabled != enabled {
                task.enabled = enabled;
                task.next_due_ms = if task.is_running() {
                    None
                } else {
                    next_due(&task.config(), anchor)?
                };
            }
            Ok(())
        })
    }
    /// Saves an explicit Run Now intent before session writer handoff. A paused
    /// schedule can be run manually without enabling future scheduled work.
    pub fn request_run(
        &self,
        expected_revision: u64,
        task_id: &str,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        self.mutate(expected_revision, |state| {
            let task = task_mut(state, task_id)?;
            if task.is_running() {
                return Err(AssistantStoreError::Running);
            }
            task.pending_manual = true;
            state.clock_high_water_ms = state.clock_high_water_ms.max(now_ms);
            Ok(())
        })
    }
    pub fn claim(
        &self,
        expected_revision: u64,
        task_id: &str,
        mode: AssistantClaimMode,
        now_ms: u64,
    ) -> StoreResult<AssistantClaim> {
        let snapshot = self.mutate(expected_revision, |state| {
            let due = state.due_task_ids(now_ms).iter().any(|id| id == task_id);
            let profile = state.profile.clone();
            let task = task_mut(state, task_id)?;
            if task.is_running() {
                return Err(AssistantStoreError::Running);
            }
            if mode == AssistantClaimMode::Due && (!due || task.pending_manual) {
                return Err(AssistantStoreError::NotDue);
            }
            task.last_run = Some(AssistantRun {
                run_id: crate::model::id(),
                ids: AssistantTurnIds::new(),
                started_at_ms: now_ms,
                status: AssistantRunStatus::Running,
                finished_at_ms: None,
                result_summary: None,
                failure_code: None,
                snapshot: AssistantRunSnapshot {
                    name: profile.name,
                    soul: profile.soul,
                    notes: profile.notes,
                    instructions: task.instructions.clone(),
                    model_id: task.model_id.clone(),
                    workspace_binding: task.workspace_binding.clone(),
                    workspace_descriptor: task.workspace_descriptor.clone(),
                    runtime: Some(task.runtime.clone().unwrap_or(profile.runtime)),
                },
            });
            task.next_due_ms = None;
            task.pending_manual = false;
            state.clock_high_water_ms = state.clock_high_water_ms.max(now_ms);
            Ok(())
        })?;
        let task = snapshot
            .all_tasks()
            .into_iter()
            .find(|task| task.id == task_id)
            .ok_or(AssistantStoreError::NotFound)?;
        Ok(AssistantClaim {
            task_id: task.id.clone(),
            conversation_id: task.conversation_id.clone(),
            run: task
                .last_run
                .clone()
                .ok_or(AssistantStoreError::StaleClaim)?,
            snapshot,
        })
    }
    pub fn finish(
        &self,
        expected_revision: u64,
        task_id: &str,
        run_id: &str,
        outcome: AssistantRunOutcome,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        validate_outcome(&outcome)?;
        self.storage.locked(|| {
            let mut state = self.read_scoped()?;
            let task = task_mut(&mut state, task_id)?;
            let run = task
                .last_run
                .as_ref()
                .ok_or(AssistantStoreError::StaleClaim)?;
            if run.run_id != run_id {
                return Err(AssistantStoreError::StaleClaim);
            }
            if run.status != AssistantRunStatus::Running {
                // Retry after an uncertain disk result is safe only for the
                // same durable token and the exact already-stored outcome.
                if run.status == outcome.status
                    && run.result_summary == outcome.result_summary
                    && run.failure_code == outcome.failure_code
                {
                    return self.storage.read();
                }
                if !run.status.is_active() {
                    return Err(AssistantStoreError::StaleClaim);
                }
            }
            check_revision(&state, expected_revision)?;
            state.clock_high_water_ms = state.clock_high_water_ms.max(now_ms);
            let anchor = state.clock_high_water_ms;
            let task = task_mut(&mut state, task_id)?;
            task.next_due_ms = if outcome.status.is_active() {
                None
            } else {
                next_due(&task.config(), anchor)?
            };
            let run = task
                .last_run
                .as_mut()
                .ok_or(AssistantStoreError::StaleClaim)?;
            run.status = outcome.status;
            run.finished_at_ms = if outcome.status.is_active() {
                None
            } else {
                Some(now_ms.max(run.started_at_ms))
            };
            run.result_summary = outcome.result_summary;
            run.failure_code = outcome.failure_code;
            self.persist(state)
        })
    }
    pub fn mark_attention(
        &self,
        expected_revision: u64,
        task_id: &str,
        run_id: &str,
        failure_code: &str,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        self.finish(
            expected_revision,
            task_id,
            run_id,
            AssistantRunOutcome {
                status: AssistantRunStatus::NeedsAttention,
                result_summary: None,
                failure_code: Some(failure_code.into()),
            },
            now_ms,
        )
    }
}

fn check_revision(state: &AssistantSnapshot, expected: u64) -> StoreResult<()> {
    if state.revision == expected {
        Ok(())
    } else {
        Err(AssistantStoreError::Conflict {
            expected,
            actual: state.revision,
        })
    }
}
fn task_mut<'a>(state: &'a mut AssistantSnapshot, id: &str) -> StoreResult<&'a mut AssistantTask> {
    state
        .tasks
        .iter_mut()
        .find(|task| task.id == id)
        .ok_or(AssistantStoreError::NotFound)
}
fn normalize_name(name: &str) -> StoreResult<String> {
    name_policy::normalize(NameKind::Conversation, name)
        .map_err(|_| AssistantStoreError::Invalid("name"))
}
fn validate_text(text: &str, required: bool) -> StoreResult<()> {
    if text.len() > MAX_TEXT_BYTES || text.contains('\0') || (required && text.trim().is_empty()) {
        Err(AssistantStoreError::Invalid("text"))
    } else {
        Ok(())
    }
}
fn validate_identity(id: &str) -> StoreResult<()> {
    if id.is_empty() || id.len() > 256 || id.chars().any(char::is_control) {
        Err(AssistantStoreError::Invalid("identity"))
    } else {
        Ok(())
    }
}
fn validate_avatar(avatar: Option<&AssistantAvatar>) -> StoreResult<()> {
    match avatar {
        Some(avatar) => avatar.validate(),
        None => Ok(()),
    }
}
fn validate_runtime(runtime: &RuntimeSpec) -> StoreResult<()> {
    runtime
        .validate()
        .map_err(|_| AssistantStoreError::Invalid("runtime definition"))
}
impl AssistantAvatar {
    /// Validate metadata before deriving the private PNG path or saving a
    /// profile. Native image loading must separately verify the file bytes.
    pub fn validate(&self) -> StoreResult<()> {
        if !uuid::Uuid::parse_str(&self.id).is_ok_and(|id| id.to_string() == self.id)
            || self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || self.mime_type != "image/png"
            || !(1..=MAX_AVATAR_DIMENSION).contains(&self.width)
            || !(1..=MAX_AVATAR_DIMENSION).contains(&self.height)
            || !(1..=MAX_AVATAR_BYTES).contains(&self.byte_length)
        {
            Err(AssistantStoreError::Invalid("avatar metadata"))
        } else {
            Ok(())
        }
    }
}
fn validate_workspace(value: &Value) -> StoreResult<()> {
    // Native Agent preparation owns workspace authority validation. These
    // opaque descriptors only retain the explicitly selected context.
    if !value.is_object() || value.to_string().len() > MAX_TEXT_BYTES {
        Err(AssistantStoreError::Invalid("workspace context"))
    } else {
        Ok(())
    }
}
fn normalize_config(mut config: AssistantTaskConfig) -> StoreResult<AssistantTaskConfig> {
    config.title = normalize_name(&config.title)?;
    validate_config(&config)?;
    Ok(config)
}
fn validate_config(config: &AssistantTaskConfig) -> StoreResult<()> {
    if let Some(runtime) = &config.runtime {
        validate_runtime(runtime)?;
    }
    if normalize_name(&config.title)? != config.title {
        return Err(AssistantStoreError::Invalid("name normalization"));
    }
    validate_text(&config.instructions, true)?;
    validate_identity(&config.model_id)?;
    validate_workspace(&config.workspace_binding)?;
    validate_workspace(&config.workspace_descriptor)?;
    if config
        .interval_minutes
        .is_some_and(|value| value < MIN_INTERVAL_MINUTES)
    {
        return Err(AssistantStoreError::Invalid(
            "interval must be at least 15 minutes",
        ));
    }
    Ok(())
}
fn next_due(config: &AssistantTaskConfig, now_ms: u64) -> StoreResult<Option<u64>> {
    if !config.enabled {
        return Ok(None);
    }
    config
        .interval_minutes
        .map(|minutes| {
            now_ms
                .checked_add(u64::from(minutes) * 60_000)
                .ok_or(AssistantStoreError::Invalid("due time overflow"))
        })
        .transpose()
}
fn validate_outcome(outcome: &AssistantRunOutcome) -> StoreResult<()> {
    if outcome.status == AssistantRunStatus::Running {
        return Err(AssistantStoreError::Invalid(
            "finish requires terminal outcome",
        ));
    }
    if let Some(summary) = &outcome.result_summary {
        validate_text(summary, false)?;
    }
    if let Some(code) = &outcome.failure_code {
        validate_identity(code)?;
    }
    if outcome.status == AssistantRunStatus::Completed && outcome.failure_code.is_some() {
        return Err(AssistantStoreError::Invalid("completed run has failure"));
    }
    if matches!(
        outcome.status,
        AssistantRunStatus::Failed | AssistantRunStatus::NeedsAttention
    ) && outcome.failure_code.is_none()
    {
        return Err(AssistantStoreError::Invalid(
            "failed or waiting run needs failure code",
        ));
    }
    Ok(())
}
fn validate_snapshot(state: &AssistantSnapshot) -> StoreResult<()> {
    if state.schema_version != 1 || state.tasks.len() > MAX_TASKS {
        return Err(AssistantStoreError::Invalid("schema or task limit"));
    }
    if let Some(nickname) = &state.user_nickname {
        if normalize_name(nickname)? != *nickname {
            return Err(AssistantStoreError::Invalid("user nickname normalization"));
        }
    }
    if normalize_name(&state.profile.name)? != state.profile.name {
        return Err(AssistantStoreError::Invalid("profile name normalization"));
    }
    validate_text(&state.profile.notes, false)?;
    validate_text(&state.profile.soul, false)?;
    validate_avatar(state.profile.avatar.as_ref())?;
    validate_runtime(&state.profile.runtime)?;
    let mut identities = HashSet::new();
    if let Some(conversation_id) = &state.conversation_id {
        if !rish_agent_core::schema::canonical_uuid(Some(&Value::String(conversation_id.clone()))) {
            return Err(AssistantStoreError::Invalid(
                "assistant conversation identity",
            ));
        }
        identities.insert(conversation_id.as_str());
    }
    bots::validate_directory(state)?;
    task_tools::validate_receipts(state)?;
    memory::validate_memories(state)?;
    for task in &state.tasks {
        validate_config(&task.config())?;
        for id in [&task.id, &task.conversation_id] {
            validate_identity(id)?;
            if !identities.insert(id.as_str()) {
                return Err(AssistantStoreError::Invalid("duplicate identity"));
            }
        }
        if (!task.enabled || task.interval_minutes.is_none() || task.is_running())
            && task.next_due_ms.is_some()
        {
            return Err(AssistantStoreError::Invalid("unexpected due time"));
        }
        if task.is_running() && task.pending_manual {
            return Err(AssistantStoreError::Invalid(
                "running task has pending manual intent",
            ));
        }
        if task.enabled
            && task.interval_minutes.is_some()
            && !task.is_running()
            && task.next_due_ms.is_none()
        {
            return Err(AssistantStoreError::Invalid("missing due time"));
        }
        if let Some(run) = &task.last_run {
            for id in [
                &run.run_id,
                &run.ids.turn_id,
                &run.ids.attempt_id,
                &run.ids.round_id,
                &run.ids.user_message_id,
                &run.ids.assistant_message_id,
            ] {
                validate_identity(id)?;
                if !identities.insert(id.as_str()) {
                    return Err(AssistantStoreError::Invalid("duplicate run identity"));
                }
            }
            if run.started_at_ms > state.clock_high_water_ms {
                return Err(AssistantStoreError::Invalid("run clock"));
            }
            if normalize_name(&run.snapshot.name)? != run.snapshot.name {
                return Err(AssistantStoreError::Invalid("snapshot name"));
            }
            validate_text(&run.snapshot.notes, false)?;
            validate_text(&run.snapshot.soul, false)?;
            validate_text(&run.snapshot.instructions, true)?;
            validate_identity(&run.snapshot.model_id)?;
            validate_workspace(&run.snapshot.workspace_binding)?;
            validate_workspace(&run.snapshot.workspace_descriptor)?;
            if let Some(runtime) = &run.snapshot.runtime {
                validate_runtime(runtime)?;
            }
            if run.status.is_active() {
                if run.finished_at_ms.is_some() {
                    return Err(AssistantStoreError::Invalid("running finish time"));
                }
                if run.status == AssistantRunStatus::Running {
                    if run.result_summary.is_some() || run.failure_code.is_some() {
                        return Err(AssistantStoreError::Invalid("running outcome"));
                    }
                } else {
                    validate_outcome(&AssistantRunOutcome {
                        status: run.status,
                        result_summary: run.result_summary.clone(),
                        failure_code: run.failure_code.clone(),
                    })?;
                }
            } else {
                if !run.finished_at_ms.is_some_and(|time| {
                    time >= run.started_at_ms && time <= state.clock_high_water_ms
                }) {
                    return Err(AssistantStoreError::Invalid("finish clock"));
                }
                validate_outcome(&AssistantRunOutcome {
                    status: run.status,
                    result_summary: run.result_summary.clone(),
                    failure_code: run.failure_code.clone(),
                })?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "assistant_store_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "assistant_store_idempotency_tests.rs"]
mod idempotency_tests;

#[cfg(test)]
#[path = "assistant_store_avatar_tests.rs"]
mod avatar_tests;

#[cfg(test)]
#[path = "assistant_avatar_read_tests.rs"]
mod avatar_read_tests;

#[cfg(test)]
#[path = "assistant_memory_tests.rs"]
mod memory_tests;

#[cfg(test)]
#[path = "assistant_bot_tests.rs"]
mod bot_tests;

#[cfg(test)]
#[path = "assistant_user_identity_tests.rs"]
mod user_identity_tests;
