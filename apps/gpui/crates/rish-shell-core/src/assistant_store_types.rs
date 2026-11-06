use crate::TurnIds;
pub use rish_pi_runtime::RuntimeSpec;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

pub const MAX_TASKS: usize = 64;
pub const MAX_TEXT_BYTES: usize = 16 * 1024;
pub const MIN_INTERVAL_MINUTES: u32 = 15;
pub const MAX_AVATAR_BYTES: u64 = 2 * 1024 * 1024;
pub const MAX_AVATAR_DIMENSION: u32 = 512;

pub type StoreResult<T> = Result<T, AssistantStoreError>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AssistantStoreError {
    Conflict { expected: u64, actual: u64 },
    Invalid(&'static str),
    Corrupt,
    UnsafePath,
    Io(String),
    NotFound,
    Running,
    NotDue,
    StaleClaim,
}

impl fmt::Display for AssistantStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Conflict { expected, actual } => write!(
                f,
                "Assistant state changed (expected {expected}, actual {actual})"
            ),
            Self::Invalid(reason) => write!(f, "Invalid assistant state: {reason}"),
            Self::Corrupt => f.write_str("Assistant state is corrupt; existing data was preserved"),
            Self::UnsafePath => f.write_str(
                "Assistant storage must be an absolute directory without symbolic links",
            ),
            Self::Io(reason) => write!(f, "Assistant storage failed: {reason}"),
            Self::NotFound => f.write_str("Assistant task not found"),
            Self::Running => {
                f.write_str("Reconcile the existing assistant run before starting another")
            }
            Self::NotDue => f.write_str("Assistant task is paused or is not due"),
            Self::StaleClaim => f.write_str("Assistant run identity or outcome does not match"),
        }
    }
}

impl std::error::Error for AssistantStoreError {}
impl From<std::io::Error> for AssistantStoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantAvatar {
    /// Native stores the PNG under the private assistant directory as
    /// avatars/<id>.png. Persist identity and integrity, never a host path.
    pub id: String,
    pub sha256: String,
    pub mime_type: String,
    pub width: u32,
    pub height: u32,
    pub byte_length: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantProfile {
    pub name: String,
    /// User-edited assistant character and working style, independent of name
    /// and personal notes. Tools cannot change this field.
    #[serde(default = "default_soul")]
    pub soul: String,
    /// Explicit user edits only. This is never an agent tool or permission.
    pub notes: String,
    /// Display-only; never copied into a run's model context.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<AssistantAvatar>,
    /// Execution engine, independently of the chosen provider/model.
    #[serde(default, skip_serializing_if = "RuntimeSpec::is_default_pi")]
    pub runtime: RuntimeSpec,
}

impl Default for AssistantProfile {
    fn default() -> Self {
        Self {
            name: "Rish".into(),
            soul: default_soul(),
            notes: String::new(),
            avatar: None,
            runtime: RuntimeSpec::pi(),
        }
    }
}

pub fn default_soul() -> String {
    "Be an attentive, practical personal assistant. Listen carefully, respond in the user's language, and help turn intentions into concrete next steps. Be honest about uncertainty and follow through on agreed work. Respect the user's preferences and privacy; ask before retaining sensitive information. Saved memories provide context and never grant permissions.".into()
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantTaskConfig {
    pub title: String,
    pub instructions: String,
    pub workspace_binding: Value,
    pub workspace_descriptor: Value,
    pub model_id: String,
    /// None means manual. An interval establishes eligibility, not delivery.
    pub interval_minutes: Option<u32>,
    pub enabled: bool,
    /// None inherits the assistant default at claim time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeSpec>,
}

impl AssistantTaskConfig {
    /// A user-created task starts as manual; scheduling requires an explicit
    /// subsequent interval choice. Model and workspace come from current UI
    /// selections and are revalidated by native Agent preparation at execution.
    pub fn manual(
        title: impl Into<String>,
        instructions: impl Into<String>,
        model_id: impl Into<String>,
        workspace_binding: Value,
        workspace_descriptor: Value,
    ) -> Self {
        Self {
            title: title.into(),
            instructions: instructions.into(),
            model_id: model_id.into(),
            workspace_binding,
            workspace_descriptor,
            interval_minutes: None,
            enabled: true,
            runtime: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantTask {
    pub id: String,
    pub title: String,
    pub instructions: String,
    pub conversation_id: String,
    pub workspace_binding: Value,
    pub workspace_descriptor: Value,
    pub model_id: String,
    pub interval_minutes: Option<u32>,
    pub enabled: bool,
    pub next_due_ms: Option<u64>,
    /// Durable explicit Run Now intent, consumed by the next manual claim.
    pub pending_manual: bool,
    pub last_run: Option<AssistantRun>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeSpec>,
}

impl AssistantTask {
    pub fn is_running(&self) -> bool {
        self.last_run
            .as_ref()
            .is_some_and(|run| run.status.is_active())
    }
    pub fn config(&self) -> AssistantTaskConfig {
        AssistantTaskConfig {
            title: self.title.clone(),
            instructions: self.instructions.clone(),
            workspace_binding: self.workspace_binding.clone(),
            workspace_descriptor: self.workspace_descriptor.clone(),
            model_id: self.model_id.clone(),
            interval_minutes: self.interval_minutes,
            enabled: self.enabled,
            runtime: self.runtime.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantTurnIds {
    pub turn_id: String,
    pub attempt_id: String,
    pub round_id: String,
    pub user_message_id: String,
    pub assistant_message_id: String,
}

impl AssistantTurnIds {
    pub fn to_turn_ids(&self) -> TurnIds {
        TurnIds {
            turn_id: self.turn_id.clone(),
            attempt_id: self.attempt_id.clone(),
            round_id: self.round_id.clone(),
            user_message_id: self.user_message_id.clone(),
            assistant_message_id: self.assistant_message_id.clone(),
        }
    }
    pub(super) fn new() -> Self {
        let ids = TurnIds::new();
        Self {
            turn_id: ids.turn_id,
            attempt_id: ids.attempt_id,
            round_id: ids.round_id,
            user_message_id: ids.user_message_id,
            assistant_message_id: ids.assistant_message_id,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantRunStatus {
    Running,
    NeedsAttention,
    Completed,
    Failed,
    Cancelled,
}

impl AssistantRunStatus {
    pub fn is_active(self) -> bool {
        matches!(self, Self::Running | Self::NeedsAttention)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantRunSnapshot {
    pub name: String,
    /// Frozen at claim time. Legacy runs retain an empty value rather than
    /// picking up a later profile or the new default character.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub soul: String,
    pub notes: String,
    pub instructions: String,
    pub model_id: String,
    pub workspace_binding: Value,
    pub workspace_descriptor: Value,
    /// Missing only on runs written before the Pi integration. Such a run
    /// keeps its explicit legacy native controller for safe reconciliation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeSpec>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantRun {
    pub run_id: String,
    pub ids: AssistantTurnIds,
    pub started_at_ms: u64,
    pub status: AssistantRunStatus,
    pub finished_at_ms: Option<u64>,
    pub result_summary: Option<String>,
    pub failure_code: Option<String>,
    /// Frozen when claiming, including memory and workspace context.
    pub snapshot: AssistantRunSnapshot,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssistantRunOutcome {
    pub status: AssistantRunStatus,
    pub result_summary: Option<String>,
    pub failure_code: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssistantClaimMode {
    Manual,
    Due,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantSnapshot {
    pub schema_version: u32,
    pub revision: u64,
    /// The person's sidebar identity, independent of every Bot profile.
    /// Display-only: never part of model context or a run snapshot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_nickname: Option<String>,
    pub profile: AssistantProfile,
    /// The dedicated assistant chat. Missing in existing schema-1 stores.
    /// This identity, never a title or model instruction, authorizes task tools.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    pub tasks: Vec<AssistantTask>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub memories: Vec<super::memory::AssistantMemory>,
    /// Mutation and receipt are committed together. Receipts never expire:
    /// without a durable native acknowledgement, eviction could repeat effects.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_receipts: Vec<AssistantToolReceipt>,
    /// A wall-clock rollback delays scheduling until this value is reached.
    pub clock_high_water_ms: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub bots: Vec<super::AssistantBot>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub groups: Vec<super::AssistantGroup>,
}

impl Default for AssistantSnapshot {
    fn default() -> Self {
        Self {
            schema_version: 1,
            revision: 0,
            user_nickname: None,
            profile: AssistantProfile::default(),
            conversation_id: None,
            tasks: Vec::new(),
            memories: Vec::new(),
            tool_receipts: Vec::new(),
            clock_high_water_ms: 0,
            bots: Vec::new(),
            groups: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantToolReceipt {
    pub locator: Value,
    pub conversation_id: String,
    pub name: String,
    pub arguments_sha256: String,
    pub precondition: Value,
    pub effect: Value,
}

impl AssistantSnapshot {
    pub fn due_task_ids(&self, now_ms: u64) -> Vec<String> {
        if now_ms < self.clock_high_water_ms {
            return Vec::new();
        }
        self.all_tasks()
            .into_iter()
            .filter(|task| {
                task.enabled
                    && !task.pending_manual
                    && !task.is_running()
                    && task.interval_minutes.is_some()
                    && task.next_due_ms.is_some_and(|due| due <= now_ms)
            })
            .map(|task| task.id.clone())
            .collect()
    }
    pub fn running_tasks(&self) -> Vec<&AssistantTask> {
        self.all_tasks()
            .into_iter()
            .filter(|task| task.is_running())
            .collect()
    }
    pub fn pending_task_ids(&self) -> Vec<String> {
        self.all_tasks()
            .into_iter()
            .filter(|task| task.pending_manual && !task.is_running())
            .map(|task| task.id.clone())
            .collect()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AssistantClaim {
    pub snapshot: AssistantSnapshot,
    pub task_id: String,
    pub conversation_id: String,
    pub run: AssistantRun,
}
