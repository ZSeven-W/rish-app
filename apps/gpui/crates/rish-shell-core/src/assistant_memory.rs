//! Structured local memory. Manual notes and Soul remain separate profile
//! fields; memory tools cannot write them or choose source attribution.
use super::*;
use rish_agent_core::{canonical::canonical_json, schema};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map};

pub const MAX_MEMORIES: usize = 256;
pub const MAX_MEMORY_CONTENT_BYTES: usize = 8 * 1024;
const SEARCH_PAYLOAD_BYTES: usize = 32 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantMemoryKind {
    Preference,
    Fact,
    Decision,
}

impl AssistantMemoryKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Preference => "preference",
            Self::Fact => "fact",
            Self::Decision => "decision",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantMemory {
    pub id: String,
    pub title: String,
    pub content: String,
    pub kind: AssistantMemoryKind,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    /// Native supplies this when the assistant remembers something. Manual
    /// edits retain attribution; manually created entries have no conversation.
    pub source_conversation_id: Option<String>,
}

impl AssistantStore {
    /// Manual UI edit. None creates once; retryable creation should retain a
    /// UUID and use create_memory_with_id. Some only updates an existing entry.
    pub fn remember_memory(
        &self,
        expected_revision: u64,
        memory_id: Option<&str>,
        title: &str,
        content: &str,
        kind: AssistantMemoryKind,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        let title = normalize_name(title)?;
        validate_content(content)?;
        self.mutate(expected_revision, |state| {
            save(state, memory_id, &title, content, kind, now_ms, None)?;
            Ok(())
        })
    }

    /// Stable UI create identity survives an uncertain persistence response.
    /// Exact retries preserve timestamps, later edits and all other records.
    pub fn create_memory_with_id(
        &self,
        expected_revision: u64,
        memory_id: &str,
        title: &str,
        content: &str,
        kind: AssistantMemoryKind,
        now_ms: u64,
    ) -> StoreResult<AssistantSnapshot> {
        canonical_id(memory_id)?;
        let title = normalize_name(title)?;
        validate_content(content)?;
        self.storage.locked(|| {
            let mut state = self.read_scoped()?;
            if let Some(existing) = state.memories.iter().find(|memory| memory.id == memory_id) {
                return if existing.title == title
                    && existing.content == content
                    && existing.kind == kind
                    && existing.source_conversation_id.is_none()
                {
                    self.storage.read()
                } else {
                    Err(AssistantStoreError::Invalid(
                        "memory identity already exists",
                    ))
                };
            }
            check_revision(&state, expected_revision)?;
            let created = save(&mut state, None, &title, content, kind, now_ms, None)?;
            state
                .memories
                .iter_mut()
                .find(|memory| memory.id == created)
                .unwrap()
                .id = memory_id.into();
            self.persist(state)
        })
    }

    /// Explicit manual deletion. Tool deletion uses the same operation under
    /// the atomic receipt transaction, so a retry cannot revive or redelete it.
    pub fn forget_memory(
        &self,
        expected_revision: u64,
        memory_id: &str,
    ) -> StoreResult<AssistantSnapshot> {
        canonical_id(memory_id)?;
        self.mutate(expected_revision, |state| remove(state, memory_id))
    }
}

pub(super) fn is_memory(name: &str) -> bool {
    matches!(
        name,
        "search_assistant_memory" | "remember_assistant_memory" | "forget_assistant_memory"
    )
}

pub(super) fn check_target(
    state: &AssistantSnapshot,
    name: &str,
    args: &Map<String, Value>,
) -> StoreResult<()> {
    let target = args.get("memory_id").and_then(Value::as_str);
    if let Some(target) = target {
        if !state.memories.iter().any(|memory| memory.id == target) {
            return Err(AssistantStoreError::NotFound);
        }
    } else if name == "remember_assistant_memory" && state.memories.len() >= MAX_MEMORIES {
        return Err(AssistantStoreError::Invalid("memory limit reached"));
    }
    Ok(())
}

pub(super) fn mutate(
    state: &mut AssistantSnapshot,
    name: &str,
    args: &Map<String, Value>,
    conversation_id: &str,
    now_ms: u64,
) -> StoreResult<String> {
    let target = args.get("memory_id").and_then(Value::as_str);
    if name == "forget_assistant_memory" {
        let target = target.ok_or(AssistantStoreError::Invalid("memory identity"))?;
        remove(state, target)?;
        return Ok(target.into());
    }
    let kind: AssistantMemoryKind = serde_json::from_value(args["kind"].clone())
        .map_err(|_| AssistantStoreError::Invalid("memory kind"))?;
    save(
        state,
        target,
        args["title"].as_str().unwrap(),
        args["content"].as_str().unwrap(),
        kind,
        now_ms,
        Some(conversation_id),
    )
}

fn save(
    state: &mut AssistantSnapshot,
    memory_id: Option<&str>,
    title: &str,
    content: &str,
    kind: AssistantMemoryKind,
    now_ms: u64,
    source: Option<&str>,
) -> StoreResult<String> {
    let title = normalize_name(title)?;
    validate_content(content)?;
    let time = state.clock_high_water_ms.max(now_ms);
    if time > schema::MAX_SAFE_INTEGER {
        return Err(AssistantStoreError::Invalid("memory clock"));
    }
    if let Some(id) = memory_id {
        canonical_id(id)?;
        let memory = state
            .memories
            .iter_mut()
            .find(|memory| memory.id == id)
            .ok_or(AssistantStoreError::NotFound)?;
        memory.title = title;
        memory.content = content.into();
        memory.kind = kind;
        memory.updated_at_ms = time;
        if let Some(source) = source {
            memory.source_conversation_id = Some(source.into());
        }
        state.clock_high_water_ms = time;
        return Ok(id.into());
    }
    if state.memories.len() >= MAX_MEMORIES {
        return Err(AssistantStoreError::Invalid("memory limit reached"));
    }
    let id = crate::model::id();
    state.memories.push(AssistantMemory {
        id: id.clone(),
        title,
        content: content.into(),
        kind,
        created_at_ms: time,
        updated_at_ms: time,
        source_conversation_id: source.map(str::to_owned),
    });
    state.clock_high_water_ms = time;
    Ok(id)
}

fn remove(state: &mut AssistantSnapshot, memory_id: &str) -> StoreResult<()> {
    let index = state
        .memories
        .iter()
        .position(|memory| memory.id == memory_id)
        .ok_or(AssistantStoreError::NotFound)?;
    state.memories.remove(index);
    Ok(())
}

pub(super) fn search_payload(state: &AssistantSnapshot, args: &Map<String, Value>) -> Value {
    let query = args
        .get("query")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
    let mut matches: Vec<_> = state
        .memories
        .iter()
        .filter(|memory| {
            query.is_empty()
                || memory.title.to_lowercase().contains(&query)
                || memory.content.to_lowercase().contains(&query)
                || memory.kind.as_str().contains(&query)
        })
        .collect();
    matches.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms).then(a.id.cmp(&b.id)));
    let mut payload =
        json!({"schema_version":1,"store_revision":state.revision,"memories":[],"truncated":false});
    for memory in matches {
        if payload["memories"].as_array().unwrap().len() >= limit {
            payload["truncated"] = json!(true);
            break;
        }
        let entry = json!({"memory_id":memory.id,"title":memory.title,"content":memory.content,
            "kind":memory.kind,"created_at_ms":memory.created_at_ms,"updated_at_ms":memory.updated_at_ms});
        payload["memories"].as_array_mut().unwrap().push(entry);
        if canonical_json(&payload).map_or(true, |bytes| bytes.len() > SEARCH_PAYLOAD_BYTES) {
            payload["memories"].as_array_mut().unwrap().pop();
            payload["truncated"] = json!(true);
        }
    }
    payload
}

pub(super) fn canonical_id(id: &str) -> StoreResult<()> {
    if schema::canonical_uuid(Some(&json!(id))) {
        Ok(())
    } else {
        Err(AssistantStoreError::Invalid("memory identity"))
    }
}

fn validate_content(content: &str) -> StoreResult<()> {
    if content.trim().is_empty()
        || content.len() > MAX_MEMORY_CONTENT_BYTES
        || content
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
    {
        Err(AssistantStoreError::Invalid("memory content"))
    } else {
        Ok(())
    }
}

pub(super) fn validate_memories(state: &AssistantSnapshot) -> StoreResult<()> {
    validate_owned_memories(state, DEFAULT_BOT_ID, &state.memories)
}

pub(super) fn validate_owned_memories(
    state: &AssistantSnapshot,
    bot_id: &str,
    memories: &[AssistantMemory],
) -> StoreResult<()> {
    if memories.len() > MAX_MEMORIES {
        return Err(AssistantStoreError::Invalid("memory limit"));
    }
    let mut ids = HashSet::new();
    for memory in memories {
        canonical_id(&memory.id)?;
        validate_content(&memory.content)?;
        if !ids.insert(&memory.id)
            || normalize_name(&memory.title)? != memory.title
            || memory.created_at_ms > memory.updated_at_ms
            || memory.updated_at_ms > state.clock_high_water_ms
            || memory.updated_at_ms > schema::MAX_SAFE_INTEGER
            || memory
                .source_conversation_id
                .as_ref()
                .is_some_and(|source| state.conversation_bot_id(source) != Some(bot_id))
        {
            return Err(AssistantStoreError::Invalid("memory record"));
        }
    }
    Ok(())
}
