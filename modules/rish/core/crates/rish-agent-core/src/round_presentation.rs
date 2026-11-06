//! Bounded, display-only assistant round archives. These are never execution
//! authority: hosts validate the WAL/ownership and keep filesystem effects.
use crate::{canonical::sha256_hex, schema::canonical_uuid, store::StoreError, workspace_json};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};

pub const MAX_ROUNDS: usize = 8;
pub const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_CACHE_BYTES: usize = 2 * 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024 * 1024;

/// Native WAL projection historically permits several large rounds. The UI
/// has a separate aggregate text budget; disk IO retains its codec byte limit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArchiveBudget {
    Native,
    Display,
}

fn exact(value: &Value, keys: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|o| o.len() == keys.len() && keys.iter().all(|k| o.contains_key(*k)))
}
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}
fn kind(value: &Value) -> bool {
    matches!(value.as_str(), Some("tool_batch" | "final" | "blocked"))
}
fn index(value: &Value) -> Option<u64> {
    value.as_u64().filter(|i| *i < MAX_ROUNDS as u64)
}
pub fn validate_identity(conversation: &str, attempt: &str) -> Result<(), StoreError> {
    if canonical_uuid(Some(&json!(conversation))) && canonical_uuid(Some(&json!(attempt))) {
        Ok(())
    } else {
        Err(StoreError::InvalidArgument)
    }
}

pub fn validate_round(value: &Value) -> Result<(), StoreError> {
    let keys = [
        "round_id",
        "round_index",
        "kind",
        "text",
        "reasoning",
        "assistant_text_sha256",
        "reasoning_text_sha256",
    ];
    if !exact(value, &keys)
        || !canonical_uuid(value.get("round_id"))
        || index(&value["round_index"]).is_none()
        || !kind(&value["kind"])
    {
        return Err(StoreError::Corrupt);
    }
    for (key, digest) in [
        ("text", "assistant_text_sha256"),
        ("reasoning", "reasoning_text_sha256"),
    ] {
        let body = text(value, key).ok_or(StoreError::Corrupt)?;
        if body.len() > MAX_TEXT_BYTES
            || text(value, digest) != Some(sha256_hex(body.as_bytes()).as_str())
        {
            return Err(StoreError::Corrupt);
        }
    }
    Ok(())
}

pub fn validate_archive(
    value: &Value,
    conversation: &str,
    attempt: &str,
    budget: ArchiveBudget,
) -> Result<(), StoreError> {
    validate_identity(conversation, attempt)?;
    if !exact(
        value,
        &["schema_version", "conversation_id", "attempt_id", "rounds"],
    ) || value["schema_version"].as_u64() != Some(1)
        || text(value, "conversation_id") != Some(conversation)
        || text(value, "attempt_id") != Some(attempt)
    {
        return Err(StoreError::Corrupt);
    }
    let rounds = value["rounds"].as_array().ok_or(StoreError::Corrupt)?;
    if rounds.len() > MAX_ROUNDS {
        return Err(StoreError::Corrupt);
    }
    let mut ids = HashSet::new();
    let mut indices = HashSet::new();
    let mut total = 0usize;
    for round in rounds {
        validate_round(round)?;
        if !ids.insert(round["round_id"].as_str().unwrap())
            || !indices.insert(index(&round["round_index"]).unwrap())
        {
            return Err(StoreError::Corrupt);
        }
        total += text(round, "text").unwrap().len() + text(round, "reasoning").unwrap().len();
    }
    if budget == ArchiveBudget::Display && total > MAX_TEXT_BYTES {
        return Err(StoreError::Capacity);
    }
    Ok(())
}

pub fn decode_archive(raw: &str, conversation: &str, attempt: &str) -> Result<Value, StoreError> {
    validate_identity(conversation, attempt)?;
    if raw.len() > MAX_CACHE_BYTES || !workspace_json::bounded_exact_structure(raw.as_bytes()) {
        return Err(StoreError::Corrupt);
    }
    let value = serde_json::from_str(raw).map_err(|_| StoreError::Corrupt)?;
    validate_archive(&value, conversation, attempt, ArchiveBudget::Native)?;
    Ok(value)
}

fn make_round(
    round_id: &Value,
    round_index: &Value,
    terminal_kind: &Value,
    body: &Value,
    reasoning: &Value,
) -> Result<Value, StoreError> {
    let body = body
        .as_str()
        .filter(|t| t.len() <= MAX_TEXT_BYTES)
        .ok_or(StoreError::InvalidArgument)?;
    let reasoning = reasoning
        .as_str()
        .filter(|t| t.len() <= MAX_TEXT_BYTES)
        .ok_or(StoreError::InvalidArgument)?;
    let value = json!({"round_id":round_id,"round_index":round_index,"kind":terminal_kind,
        "text":body,"reasoning":reasoning,"assistant_text_sha256":sha256_hex(body.as_bytes()),
        "reasoning_text_sha256":sha256_hex(reasoning.as_bytes())});
    validate_round(&value).map_err(|_| StoreError::InvalidArgument)?;
    Ok(value)
}

fn cached_rounds(cached: &Value, conversation: &str, attempt: &str) -> BTreeMap<u64, Value> {
    if validate_archive(cached, conversation, attempt, ArchiveBudget::Native).is_err() {
        return BTreeMap::new();
    }
    cached["rounds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|round| (index(&round["round_index"]).unwrap(), round.clone()))
        .collect()
}
fn archive(
    conversation: &str,
    attempt: &str,
    rounds: BTreeMap<u64, Value>,
) -> Result<Value, StoreError> {
    let result = json!({"schema_version":1,"conversation_id":conversation,"attempt_id":attempt,"rounds":rounds.into_values().collect::<Vec<_>>()});
    validate_archive(&result, conversation, attempt, ArchiveBudget::Native)?;
    Ok(result)
}

/// The host passes the immutable, verified WAL's per-attempt view. Filtering
/// here is still explicit, so a foreign row can never overwrite a cached round.
fn project(value: &Value, conversation: &str, attempt: &str) -> Result<Value, StoreError> {
    let rows = value["rounds"]
        .as_array()
        .ok_or(StoreError::InvalidArgument)?;
    let transcripts = value["transcripts"]
        .as_array()
        .ok_or(StoreError::InvalidArgument)?;
    let mut by_index = cached_rounds(&value["cached"], conversation, attempt);
    for row in rows {
        let locator = &row["locator"];
        if text(locator, "attempt_id") != Some(attempt)
            || row["state"] != "completed"
            || !kind(&row["terminal_kind"])
        {
            continue;
        }
        let reference = &row["transcript_after"];
        let Some(reference_id) = text(reference, "transcript_ref") else {
            continue;
        };
        let Some(reference_generation) = reference["generation"].as_u64() else {
            continue;
        };
        for transcript in transcripts {
            if text(transcript, "attempt_id") != Some(attempt)
                || text(transcript, "transcript_ref") != Some(reference_id)
                || transcript["generation"]
                    .as_u64()
                    .is_none_or(|g| g < reference_generation)
            {
                continue;
            }
            let Some(messages) = transcript["messages"].as_array() else {
                continue;
            };
            for message in messages.iter().rev() {
                if message["role"] != "assistant"
                    || message["round_index"] != locator["round_index"]
                {
                    continue;
                }
                if let Ok(round) = make_round(
                    &locator["round_id"],
                    &locator["round_index"],
                    &row["terminal_kind"],
                    &message["content"],
                    &message["reasoning_content"],
                ) {
                    by_index.insert(index(&round["round_index"]).unwrap(), round);
                }
                // Match the native readers: do not fall back to an older
                // assistant if the latest matching assistant is malformed.
                break;
            }
        }
    }
    archive(conversation, attempt, by_index)
}

pub fn reduce(value: &Value) -> Result<Value, StoreError> {
    if value["schema_version"].as_u64() != Some(1) {
        return Err(StoreError::InvalidArgument);
    }
    let conversation = text(value, "conversation_id").ok_or(StoreError::InvalidArgument)?;
    let attempt = text(value, "attempt_id").ok_or(StoreError::InvalidArgument)?;
    validate_identity(conversation, attempt)?;
    let base = ["schema_version", "op", "conversation_id", "attempt_id"];
    let fields: &[&str] = match text(value, "op") {
        Some("identity") => &[],
        Some("decode") => &["archive_json"],
        Some("upsert") => &[
            "prior",
            "round_id",
            "round_index",
            "kind",
            "text",
            "reasoning",
        ],
        Some("project") => &["cached", "rounds", "transcripts"],
        _ => return Err(StoreError::InvalidArgument),
    };
    let keys: Vec<_> = base.into_iter().chain(fields.iter().copied()).collect();
    if !exact(value, &keys) {
        return Err(StoreError::InvalidArgument);
    }
    match text(value, "op").unwrap() {
        "identity" => Ok(json!(true)),
        "decode" => decode_archive(
            text(value, "archive_json").ok_or(StoreError::InvalidArgument)?,
            conversation,
            attempt,
        ),
        "upsert" => {
            let round = make_round(
                &value["round_id"],
                &value["round_index"],
                &value["kind"],
                &value["text"],
                &value["reasoning"],
            )?;
            let mut prior = cached_rounds(&value["prior"], conversation, attempt);
            prior.insert(index(&round["round_index"]).unwrap(), round);
            archive(conversation, attempt, prior)
        }
        "project" => project(value, conversation, attempt),
        _ => unreachable!(),
    }
}

pub fn reduce_json(raw: &str) -> String {
    let result = if raw.len() <= MAX_REQUEST_BYTES
        && workspace_json::bounded_exact_structure(raw.as_bytes())
    {
        serde_json::from_str(raw)
            .map_err(|_| StoreError::InvalidArgument)
            .and_then(|value| reduce(&value))
    } else {
        Err(StoreError::InvalidArgument)
    };
    match result {
        Ok(value) => json!({"ok":true,"value":value}).to_string(),
        Err(error) => json!({"ok":false,"error":error.code()}).to_string(),
    }
}

#[cfg(test)]
#[path = "round_presentation_tests.rs"]
mod tests;
