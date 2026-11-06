//! Registry-v5 assistant task tools. Only native code can resolve the committed
//! assistant conversation, inherit its configuration and open its private store.
//! These contracts keep model arguments, safe previews and durable effects apart.
use crate::canonical::{canonical_json, hash_json};
use crate::execution_ledger::{as_str, get};
use crate::schema::{bounded_utf8, canonical_sha256, canonical_uuid, exact_keys, safe_integer};
use serde_json::{json, Map, Value};
use unicode_normalization::UnicodeNormalization;

pub const NAMES: &[&str] = &[
    "list_assistant_tasks",
    "create_assistant_task",
    "update_assistant_task",
    "search_assistant_memory",
    "remember_assistant_memory",
    "forget_assistant_memory",
];
const MAX_REVISION: u64 = 9_007_199_254_740_991;
pub fn is_assistant(name: &str) -> bool {
    NAMES.contains(&name)
}
pub fn is_mutation(name: &str) -> bool {
    matches!(
        name,
        "create_assistant_task"
            | "update_assistant_task"
            | "remember_assistant_memory"
            | "forget_assistant_memory"
    )
}
fn title(value: Option<&Value>) -> bool {
    bounded_utf8(value, 120, false).is_some_and(|text| {
        !text.trim().is_empty()
            && text.trim() == text
            && text.nfc().eq(text.chars())
            && !text.chars().any(char::is_control)
    })
}
fn instructions(value: Option<&Value>) -> bool {
    bounded_utf8(value, 16 * 1024, false)
        .is_some_and(|text| !text.trim().is_empty() && !text.contains('\0'))
}
fn memory_content(value: Option<&Value>) -> bool {
    bounded_utf8(value, 8192, false).is_some_and(|text| {
        !text.trim().is_empty()
            && !text
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
    })
}
fn memory_kind(value: Option<&Value>) -> bool {
    matches!(as_str(value), Some("preference" | "fact" | "decision"))
}
fn memory_query(value: Option<&Value>) -> bool {
    bounded_utf8(value, 512, true).is_some_and(|text| !text.chars().any(char::is_control))
}
fn interval(value: Option<&Value>) -> bool {
    value == Some(&Value::Null)
        || safe_integer(value, u64::from(u32::MAX), false).is_some_and(|n| n >= 15)
}
fn bool_value(value: Option<&Value>) -> bool {
    value.is_some_and(Value::is_boolean)
}

/// Exact property sets: never accept auth, model, runtime, workspace, path or
/// generic state-patch fields from a provider response.
pub fn arguments_valid(name: &str, arguments: &Map<String, Value>) -> bool {
    match name {
        "list_assistant_tasks" => arguments.is_empty(),
        "search_assistant_memory" => {
            arguments
                .keys()
                .all(|key| matches!(key.as_str(), "query" | "limit"))
                && arguments.get("query").is_none_or(|v| memory_query(Some(v)))
                && arguments
                    .get("limit")
                    .is_none_or(|v| safe_integer(Some(v), 20, false).is_some())
        }
        "remember_assistant_memory" => {
            arguments
                .keys()
                .all(|key| matches!(key.as_str(), "title" | "content" | "kind" | "memory_id"))
                && title(arguments.get("title"))
                && memory_content(arguments.get("content"))
                && memory_kind(arguments.get("kind"))
                && arguments
                    .get("memory_id")
                    .is_none_or(|v| canonical_uuid(Some(v)))
        }
        "forget_assistant_memory" => {
            arguments.len() == 1 && canonical_uuid(arguments.get("memory_id"))
        }
        "create_assistant_task" => {
            arguments
                .keys()
                .all(|key| matches!(key.as_str(), "title" | "instructions" | "follow_up_minutes"))
                && title(arguments.get("title"))
                && instructions(arguments.get("instructions"))
                && arguments
                    .get("follow_up_minutes")
                    .is_none_or(|v| interval(Some(v)))
        }
        "update_assistant_task" => {
            arguments.len() >= 2
                && arguments.keys().all(|key| {
                    matches!(
                        key.as_str(),
                        "task_id" | "title" | "instructions" | "follow_up_minutes" | "paused"
                    )
                })
                && canonical_uuid(arguments.get("task_id"))
                && arguments.get("title").is_none_or(|v| title(Some(v)))
                && arguments
                    .get("instructions")
                    .is_none_or(|v| instructions(Some(v)))
                && arguments
                    .get("follow_up_minutes")
                    .is_none_or(|v| interval(Some(v)))
                && arguments.get("paused").is_none_or(|v| bool_value(Some(v)))
        }
        _ => false,
    }
}

pub fn descriptors() -> Vec<Value> {
    NAMES.iter().map(|name| {
        let mut properties = Map::new();
        let mut required = Vec::new();
        if *name == "search_assistant_memory" {
            properties.insert("query".into(), json!({"type":"string","max_utf8_bytes":512}));
            properties.insert("limit".into(), json!({"type":"integer","minimum":1,"maximum":20}));
        } else if *name == "remember_assistant_memory" {
            properties.insert("title".into(), json!({"type":"string","max_utf8_bytes":120}));
            properties.insert("content".into(), json!({"type":"string","max_utf8_bytes":8192}));
            properties.insert("kind".into(), json!({"type":"string","enum":["preference","fact","decision"]}));
            properties.insert("memory_id".into(), json!({"type":"string","max_utf8_bytes":36}));
            required.extend(["title","content","kind"]);
        } else if *name == "forget_assistant_memory" {
            properties.insert("memory_id".into(), json!({"type":"string","max_utf8_bytes":36}));
            required.push("memory_id");
        } else if *name != "list_assistant_tasks" {
            properties.insert("title".into(), json!({"type":"string","max_utf8_bytes":120}));
            properties.insert("instructions".into(), json!({"type":"string","max_utf8_bytes":16384}));
            properties.insert("follow_up_minutes".into(), json!({"type":["integer","null"],"minimum":15,"maximum":u32::MAX}));
            if *name == "create_assistant_task" { required.extend(["title", "instructions"]); }
            else {
                properties.insert("task_id".into(), json!({"type":"string","max_utf8_bytes":36}));
                properties.insert("paused".into(), json!({"type":"boolean"}));
                required.push("task_id");
            }
        }
        json!({"schema_version":1,"name":name,
            "required_capability":if is_mutation(name) {"assistant_metadata"} else {"file_read"},
            "effect":if is_mutation(name) {"assistant_task"} else {"read"},
            "safe_summary_key":format!("agent.{name}"),
            "parameters":{"type":"object","properties":properties,"required":required,"additionalProperties":false}})
    }).collect()
}

pub fn precondition_shape(value: Option<&Value>) -> bool {
    exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "conversation_id",
            "arguments_sha256",
            "expected_store_revision",
        ],
    )
    .is_some_and(|map| {
        map.get("schema_version") == Some(&json!(1))
            && as_str(map.get("kind")).is_some_and(is_assistant)
            && canonical_uuid(map.get("conversation_id"))
            && canonical_sha256(map.get("arguments_sha256"))
            && safe_integer(map.get("expected_store_revision"), MAX_REVISION - 1, true).is_some()
    })
}

pub fn settled_facts_shape(value: Option<&Value>) -> bool {
    exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "conversation_id",
            "arguments_sha256",
            "locator_sha256",
            "store_revision",
            "payload_sha256",
        ],
    )
    .is_some_and(|map| {
        map.get("schema_version") == Some(&json!(1))
            && as_str(map.get("kind")).is_some_and(is_assistant)
            && canonical_uuid(map.get("conversation_id"))
            && canonical_sha256(map.get("arguments_sha256"))
            && canonical_sha256(map.get("locator_sha256"))
            && canonical_sha256(map.get("payload_sha256"))
            && safe_integer(map.get("store_revision"), MAX_REVISION, true).is_some()
    })
}

pub fn success_payload(name: &str, payload: &Value) -> bool {
    if payload["schema_version"] != 1
        || safe_integer(get(payload, "store_revision"), MAX_REVISION, true).is_none()
    {
        return false;
    }
    if matches!(
        name,
        "remember_assistant_memory" | "forget_assistant_memory"
    ) {
        return exact_keys(
            Some(payload),
            &["schema_version", "memory_id", "store_revision"],
        )
        .is_some()
            && canonical_uuid(get(payload, "memory_id"));
    }
    if name == "search_assistant_memory" {
        return memory_payload(payload);
    }
    if is_mutation(name) {
        return exact_keys(
            Some(payload),
            &["schema_version", "task_id", "store_revision"],
        )
        .is_some()
            && canonical_uuid(get(payload, "task_id"));
    }
    if name != "list_assistant_tasks" {
        return false;
    }
    let Some(tasks) = payload["tasks"].as_array() else {
        return false;
    };
    let mut ids = std::collections::HashSet::new();
    exact_keys(
        Some(payload),
        &["schema_version", "store_revision", "tasks", "truncated"],
    )
    .is_some()
        && tasks.len() <= 64
        && payload["truncated"] == false
        && tasks.iter().all(|task| {
            exact_keys(
                Some(task),
                &[
                    "task_id",
                    "title",
                    "paused",
                    "follow_up_minutes",
                    "pending_manual",
                ],
            )
            .is_some()
                && canonical_uuid(get(task, "task_id"))
                && ids.insert(task["task_id"].as_str().unwrap_or_default())
                && title(get(task, "title"))
                && bool_value(get(task, "paused"))
                && interval(get(task, "follow_up_minutes"))
                && bool_value(get(task, "pending_manual"))
        })
}

fn memory_payload(payload: &Value) -> bool {
    let Some(records) = payload["memories"].as_array() else {
        return false;
    };
    let mut ids = std::collections::HashSet::new();
    exact_keys(
        Some(payload),
        &["schema_version", "store_revision", "memories", "truncated"],
    )
    .is_some()
        && records.len() <= 20
        && bool_value(get(payload, "truncated"))
        && canonical_json(payload).is_ok_and(|bytes| bytes.len() <= 32 * 1024)
        && records.iter().all(|record| {
            exact_keys(
                Some(record),
                &[
                    "memory_id",
                    "title",
                    "content",
                    "kind",
                    "created_at_ms",
                    "updated_at_ms",
                ],
            )
            .is_some()
                && canonical_uuid(get(record, "memory_id"))
                && ids.insert(record["memory_id"].as_str().unwrap_or_default())
                && title(get(record, "title"))
                && memory_content(get(record, "content"))
                && memory_kind(get(record, "kind"))
                && safe_integer(get(record, "created_at_ms"), MAX_REVISION, true).is_some()
                && safe_integer(get(record, "updated_at_ms"), MAX_REVISION, true).is_some()
                && record["created_at_ms"].as_u64() <= record["updated_at_ms"].as_u64()
        })
}

/// Durable facts bind the native receipt to this precise call, assistant
/// conversation, pre-effect store revision, and protected feedback bytes.
pub fn facts_bind_row(row: &Value, facts: &Value) -> bool {
    let precondition = &row["precondition"];
    let name = row["name"].as_str().unwrap_or_default();
    let expected = precondition["expected_store_revision"]
        .as_u64()
        .and_then(|n| n.checked_add(u64::from(is_mutation(name))));
    precondition_shape(Some(precondition))
        && settled_facts_shape(Some(facts))
        && is_assistant(name)
        && row["name"] == precondition["kind"]
        && row["name"] == facts["kind"]
        && facts["conversation_id"] == precondition["conversation_id"]
        && row["arguments_sha256"] == precondition["arguments_sha256"]
        && row["arguments_sha256"] == facts["arguments_sha256"]
        && crate::execution_ledger::ledger_locator(get(row, "locator"))
        && hash_json("assistant-tool-locator", &row["locator"]).as_deref()
            == facts["locator_sha256"].as_str()
        && expected == facts["store_revision"].as_u64()
}

pub fn facts_match_feedback(row: &Value, feedback: &Value, facts: &Value) -> bool {
    facts_bind_row(row, facts)
        && row["name"] == feedback["name"]
        && feedback["outcome"] == "ok"
        && success_payload(
            row["name"].as_str().unwrap_or_default(),
            &feedback["payload"],
        )
        && facts["store_revision"] == feedback["payload"]["store_revision"]
        && hash_json("assistant-tool-payload", &feedback["payload"]).as_deref()
            == facts["payload_sha256"].as_str()
}

pub fn effect_valid(row: &Value, effect: &Value) -> bool {
    if !as_str(get(row, "name")).is_some_and(is_assistant)
        || !precondition_shape(get(row, "precondition"))
        || row["name"] != row["precondition"]["kind"]
        || row["arguments_sha256"] != row["precondition"]["arguments_sha256"]
    {
        return false;
    }
    if exact_keys(
        Some(effect),
        &[
            "schema_version",
            "status",
            "feedback",
            "settled_facts",
            "truncated",
            "effect_may_have_occurred",
        ],
    )
    .is_none()
        || effect["schema_version"] != 1
        || !bool_value(get(effect, "truncated"))
        || !bool_value(get(effect, "effect_may_have_occurred"))
    {
        return false;
    }
    let Some(text) = effect["feedback"].as_str() else {
        return false;
    };
    if crate::execution_ledger::feedback_string_valid(text).is_err() {
        return false;
    }
    let Ok(feedback) = serde_json::from_str::<Value>(text) else {
        return false;
    };
    if feedback["name"] != row["name"] || feedback["outcome"] != effect["status"] {
        return false;
    }
    if effect["status"] == "ok" {
        (if row["name"] == "search_assistant_memory" {
            effect["truncated"] == feedback["payload"]["truncated"]
        } else {
            effect["truncated"] == false
        }) && facts_match_feedback(row, &feedback, &effect["settled_facts"])
            && effect["effect_may_have_occurred"]
                == is_mutation(row["name"].as_str().unwrap_or_default())
    } else {
        effect["truncated"] == false
            && effect["settled_facts"].is_null()
            && (effect["effect_may_have_occurred"] == false || effect["status"] == "ambiguous")
    }
}

/// A bounded human-reviewable preview, separate from workspace file diffs.
/// Inspect complete text for known credentials before showing any excerpt.
pub fn approval_preview(name: &str, arguments: &Value) -> Value {
    let Some(args) = arguments.as_object() else {
        return Value::Null;
    };
    if !is_mutation(name) || !arguments_valid(name, args) {
        return Value::Null;
    }
    let mut truncated = false;
    let preview_title = args.get("title").and_then(Value::as_str).map(|text| {
        if crate::project_context_secrets::suspected_secret(text.as_bytes()) {
            truncated = true;
            "[Sensitive title omitted]".to_string()
        } else {
            text.to_string()
        }
    });
    let mut details = Vec::new();
    for key in ["paused", "follow_up_minutes", "kind"] {
        if let Some(value) = args.get(key) {
            details.push(format!("{key}: {value}"));
        }
    }
    if let Some(text) = args
        .get("instructions")
        .or_else(|| args.get("content"))
        .and_then(Value::as_str)
    {
        if crate::project_context_secrets::suspected_secret(text.as_bytes()) {
            truncated = true;
            details.push("[Sensitive content omitted]".to_string());
        } else {
            details.push(
                text.chars()
                    .filter(|c| !c.is_control() || matches!(c, '\n' | '\r' | '\t'))
                    .collect(),
            );
        }
    }
    let mut content = details.join("\n");
    if content.len() > 1024 {
        let mut end = 1024;
        while !content.is_char_boundary(end) {
            end -= 1;
        }
        content.truncate(end);
        truncated = true;
    }
    json!({"schema_version":1,"kind":name,"title":preview_title,
        "target_id":args.get("task_id").or_else(|| args.get("memory_id")),
        "content_preview":if content.is_empty() {None} else {Some(content)},"truncated":truncated})
}

pub fn approval_preview_shape(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "title",
            "target_id",
            "content_preview",
            "truncated",
        ],
    ) else {
        return false;
    };
    let name = as_str(map.get("kind")).unwrap_or_default();
    map.get("schema_version") == Some(&json!(1))
        && is_mutation(name)
        && (map.get("title") == Some(&Value::Null) || title(map.get("title")))
        && (map.get("target_id") == Some(&Value::Null) || canonical_uuid(map.get("target_id")))
        && (map.get("content_preview") == Some(&Value::Null)
            || bounded_utf8(map.get("content_preview"), 1024, false).is_some())
        && bool_value(map.get("truncated"))
        && (!matches!(name, "create_assistant_task" | "remember_assistant_memory")
            || !map["title"].is_null())
        && (!matches!(name, "update_assistant_task" | "forget_assistant_memory")
            || !map["target_id"].is_null())
        && ["title", "content_preview"].iter().all(|key| {
            map[*key]
                .as_str()
                .is_none_or(|s| !crate::project_context_secrets::suspected_secret(s.as_bytes()))
        })
}

/// Available through the existing shared WAL ABI; no native duplicate schema.
pub fn reduce_contract(op: &str, value: &Value, name: Option<&Value>) -> Option<Value> {
    let valid = match op {
        "assistant_arguments" => as_str(name).is_some_and(|n| {
            value
                .as_object()
                .is_some_and(|args| arguments_valid(n, args))
        }),
        "assistant_ledger_row" => {
            as_str(get(value, "name")).is_some_and(is_assistant)
                && crate::execution_ledger::ledger_row(value)
        }
        "assistant_precondition" => precondition_shape(Some(value)),
        "assistant_facts" => settled_facts_shape(Some(value)),
        "assistant_effect" => {
            exact_keys(Some(value), &["row", "effect"]).is_some()
                && effect_valid(&value["row"], &value["effect"])
        }
        "assistant_feedback" => value.as_str().is_some_and(|text| {
            serde_json::from_str::<Value>(text).ok().is_some_and(|f| {
                as_str(get(&f, "name")).is_some_and(is_assistant)
                    && crate::execution_ledger::feedback_string_valid(text).is_ok()
            })
        }),
        _ => return None,
    };
    Some(json!({"valid":valid}))
}

/// Construct canonical feedback without accepting caller-selected result keys.
pub fn feedback_string(name: &str, payload: Value) -> Option<String> {
    if !success_payload(name, &payload) {
        return None;
    }
    String::from_utf8(
        canonical_json(&json!({"schema_version":1,"name":name,"outcome":"ok","payload":payload}))
            .ok()?,
    )
    .ok()
}
