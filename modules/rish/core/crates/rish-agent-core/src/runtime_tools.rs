//! Additive registry-v3 language runtime contracts. Native code owns packages,
//! snapshots, VM processes and receipts; this module validates their bindings.
use crate::canonical::hash_json;
use crate::execution_ledger::{as_str, get};
use crate::schema::{bounded_utf8, canonical_sha256, canonical_uuid, exact_keys, safe_integer};
use serde_json::{json, Map, Value};

pub const NAMES: &[&str] = &[
    "list_runtime_environments",
    "install_runtime_environment",
    "run_program",
    "start_runtime_service",
    "stop_runtime_service",
];
pub const MUTATIONS: &[&str] = &[
    "install_runtime_environment",
    "run_program",
    "start_runtime_service",
    "stop_runtime_service",
];
pub fn is_runtime(name: &str) -> bool {
    NAMES.contains(&name)
}
pub fn is_mutation(name: &str) -> bool {
    MUTATIONS.contains(&name)
}
pub fn is_guest(name: &str) -> bool {
    name.ends_with("_guest_cgi") || is_mutation(name)
}
pub fn registry_version(value: Option<&Value>) -> bool {
    matches!(value.and_then(Value::as_u64), Some(1..=5))
}
pub fn grant_supports_tool(version: Option<&Value>, name: &str) -> bool {
    registry_version(version)
        && (!is_runtime(name) || matches!(version.and_then(Value::as_u64), Some(3..=5)))
        && (!crate::assistant_tools::is_assistant(name) || version == Some(&json!(5)))
        && (name != crate::user_question::NAME
            || matches!(version.and_then(Value::as_u64), Some(4 | 5)))
        && (!name.ends_with("_guest_cgi") || version != Some(&json!(1)))
}
pub fn environment_id(value: Option<&Value>) -> bool {
    bounded_utf8(value, 96, false).is_some_and(|id| {
        id.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    })
}
/// Matches native DSHRuntimeProgramValidPath, including byte and depth bounds.
pub fn entry_path(value: Option<&Value>) -> bool {
    bounded_utf8(value, 1024, false).is_some_and(|path| {
        !path.starts_with('/')
            && !path.contains(['\\', '\0'])
            && path.split('/').count() <= 32
            && path
                .split('/')
                .all(|p| !p.is_empty() && p != "." && p != ".." && p.len() <= 255)
    })
}
fn literal_args(value: Option<&Value>) -> bool {
    let Some(Value::Array(args)) = value else {
        return false;
    };
    args.len() <= 64
        && args
            .iter()
            .all(|a| bounded_utf8(Some(a), 4096, true).is_some_and(|s| !s.contains('\0')))
        && args
            .iter()
            .filter_map(Value::as_str)
            .map(str::len)
            .sum::<usize>()
            <= 65536
}
pub fn arguments_valid(name: &str, arguments: &Map<String, Value>) -> bool {
    let object = Value::Object(arguments.clone());
    let keys: &[&str] = match name {
        "list_runtime_environments" => &[],
        "install_runtime_environment" => &["environment_id"],
        "run_program" => &["environment_id", "entry_path", "args"],
        "start_runtime_service" => &["environment_id", "entry_path", "args", "port"],
        "stop_runtime_service" => &["service_id"],
        _ => return false,
    };
    if exact_keys(Some(&object), keys).is_none() {
        return false;
    }
    if name == "list_runtime_environments" {
        return true;
    }
    if name == "stop_runtime_service" {
        return canonical_uuid(arguments.get("service_id"));
    }
    environment_id(arguments.get("environment_id"))
        && (name == "install_runtime_environment"
            || (entry_path(arguments.get("entry_path")) && literal_args(arguments.get("args"))))
        && (name != "start_runtime_service"
            || safe_integer(arguments.get("port"), 65535, false).is_some_and(|p| p >= 1024))
}
pub fn precondition_shape(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "arguments_sha256",
            "snapshot_sha256",
            "environment_sha256",
        ],
    ) else {
        return false;
    };
    let name = as_str(map.get("kind")).unwrap_or_default();
    if map.get("schema_version") != Some(&json!(1))
        || !canonical_sha256(map.get("arguments_sha256"))
    {
        return false;
    }
    match name {
        "run_program" | "start_runtime_service" => {
            canonical_sha256(map.get("snapshot_sha256"))
                && canonical_sha256(map.get("environment_sha256"))
        }
        "install_runtime_environment" => {
            map.get("snapshot_sha256") == Some(&Value::Null)
                && canonical_sha256(map.get("environment_sha256"))
        }
        "list_runtime_environments" | "stop_runtime_service" => {
            map.get("snapshot_sha256") == Some(&Value::Null)
                && map.get("environment_sha256") == Some(&Value::Null)
        }
        _ => false,
    }
}
pub fn settled_facts_shape(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "arguments_sha256",
            "payload_sha256",
        ],
    ) else {
        return false;
    };
    map.get("schema_version") == Some(&json!(1))
        && as_str(map.get("kind")).is_some_and(is_runtime)
        && canonical_sha256(map.get("arguments_sha256"))
        && canonical_sha256(map.get("payload_sha256"))
}
pub fn facts_match_feedback(row: &Value, feedback: &Value, facts: &Value) -> bool {
    let Some(payload) = get(feedback, "payload") else {
        return false;
    };
    let precondition = get(row, "precondition");
    settled_facts_shape(Some(facts))
        && get(facts, "kind") == get(row, "name")
        && get(facts, "kind") == precondition.and_then(|p| get(p, "kind"))
        && get(feedback, "name") == get(row, "name")
        && get(facts, "arguments_sha256") == get(row, "arguments_sha256")
        && get(facts, "arguments_sha256") == precondition.and_then(|p| get(p, "arguments_sha256"))
        && hash_json("runtime-tool-payload", payload).as_deref()
            == as_str(get(facts, "payload_sha256"))
}
fn bool_value(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(_)))
}
fn output_shape(payload: &Value) -> bool {
    bounded_utf8(get(payload, "stdout"), 16 * 1024, true).is_some()
        && bounded_utf8(get(payload, "stderr"), 8 * 1024, true).is_some()
        && bool_value(get(payload, "truncated"))
}
fn service_url(value: Option<&Value>) -> bool {
    bounded_utf8(value, 128, false).is_some_and(|url| {
        let Some(port) = url
            .strip_prefix("http://127.0.0.1:")
            .and_then(|s| s.strip_suffix('/'))
        else {
            return false;
        };
        port.parse::<u32>()
            .is_ok_and(|p| (1024..=65535).contains(&p) && p.to_string() == port)
    })
}
pub fn success_payload(name: &str, payload: &Value) -> bool {
    if get(payload, "schema_version") != Some(&json!(1)) {
        return false;
    }
    match name {
        "list_runtime_environments" => {
            let Some(Value::Array(entries)) = get(payload, "environments") else {
                return false;
            };
            let mut ids = std::collections::HashSet::new();
            exact_keys(
                Some(payload),
                &["schema_version", "environments", "truncated"],
            )
            .is_some()
                && entries.len() <= 128
                && bool_value(get(payload, "truncated"))
                && entries.iter().all(|e| {
                    exact_keys(
                        Some(e),
                        &[
                            "environment_id",
                            "family",
                            "version",
                            "installed",
                            "available",
                            "package_bytes",
                        ],
                    )
                    .is_some()
                        && environment_id(get(e, "environment_id"))
                        && ids.insert(as_str(get(e, "environment_id")).unwrap_or_default())
                        && matches!(
                            as_str(get(e, "family")),
                            Some("python" | "java" | "go" | "rust" | "bun" | "node")
                        )
                        && bounded_utf8(get(e, "version"), 64, true).is_some()
                        && bool_value(get(e, "installed"))
                        && bool_value(get(e, "available"))
                        && (get(e, "package_bytes") == Some(&Value::Null)
                            || safe_integer(get(e, "package_bytes"), 768 * 1024 * 1024, true)
                                .is_some())
                })
        }
        "install_runtime_environment" => {
            exact_keys(
                Some(payload),
                &["schema_version", "environment_id", "status"],
            )
            .is_some()
                && environment_id(get(payload, "environment_id"))
                && as_str(get(payload, "status")) == Some("installed")
        }
        "run_program" => {
            exact_keys(
                Some(payload),
                &[
                    "schema_version",
                    "environment_id",
                    "exit_code",
                    "stdout",
                    "stderr",
                    "truncated",
                ],
            )
            .is_some()
                && environment_id(get(payload, "environment_id"))
                && get(payload, "exit_code") == Some(&json!(0))
                && output_shape(payload)
        }
        "start_runtime_service" => {
            exact_keys(
                Some(payload),
                &[
                    "schema_version",
                    "environment_id",
                    "status",
                    "service_id",
                    "url",
                ],
            )
            .is_some()
                && environment_id(get(payload, "environment_id"))
                && as_str(get(payload, "status")) == Some("running")
                && canonical_uuid(get(payload, "service_id"))
                && service_url(get(payload, "url"))
        }
        "stop_runtime_service" => {
            exact_keys(Some(payload), &["schema_version", "status", "service_id"]).is_some()
                && as_str(get(payload, "status")) == Some("stopped")
                && canonical_uuid(get(payload, "service_id"))
        }
        _ => false,
    }
}
pub fn diagnostic_failure(name: &str, payload: &Value) -> bool {
    matches!(name, "run_program" | "start_runtime_service")
        && exact_keys(
            Some(payload),
            &[
                "schema_version",
                "failure_code",
                "reason",
                "stdout",
                "stderr",
                "truncated",
                "exit_code",
            ],
        )
        .is_some()
        && get(payload, "schema_version") == Some(&json!(1))
        && crate::schema::failure_code(get(payload, "failure_code"))
        && bounded_utf8(get(payload, "reason"), 64, false)
            .is_some_and(|r| r.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'))
        && output_shape(payload)
        && (get(payload, "exit_code") == Some(&Value::Null)
            || safe_integer(get(payload, "exit_code"), 255, true).is_some())
}

pub fn prepare_rejection(value: Option<&Value>) -> bool {
    let Some(map) = exact_keys(value, &["failure_code", "reason"]) else {
        return false;
    };
    matches!(
        as_str(map.get("failure_code")),
        Some("E_AGENT_BAD_ARGUMENTS" | "E_AGENT_CAPABILITY" | "E_AGENT_TOOL_FAILED")
    ) && bounded_utf8(map.get("reason"), 64, false)
        .is_some_and(|r| r.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'))
}

/// Existing WAL C ABI extension. No new exported ABI symbols are required.
pub fn reduce_contract(op: &str, value: &Value, name: Option<&Value>) -> Option<Value> {
    let valid = match op {
        "runtime_arguments" => {
            let valid = as_str(name).filter(|n| is_runtime(n)).is_some_and(|n| {
                value
                    .as_object()
                    .is_some_and(|args| arguments_valid(n, args))
            });
            return Some(json!({"valid":valid,
                "failure_code":if valid {Value::Null} else {json!("E_AGENT_BAD_ARGUMENTS")},
                "reason":if valid {Value::Null} else {json!("arguments_do_not_match_tool_schema")}}));
        }
        "runtime_precondition" => precondition_shape(Some(value)),
        "runtime_facts" => settled_facts_shape(Some(value)),
        "runtime_feedback" => value.as_str().is_some_and(|text| {
            serde_json::from_str::<Value>(text)
                .ok()
                .is_some_and(|feedback| {
                    as_str(get(&feedback, "name")).is_some_and(is_runtime)
                        && crate::execution_ledger::feedback_string_valid(text).is_ok()
                })
        }),
        "runtime_facts_match" => {
            exact_keys(Some(value), &["row", "feedback", "facts"]).is_some()
                && get(value, "row").is_some_and(|row| {
                    get(value, "feedback").is_some_and(|feedback| {
                        as_str(get(row, "name")).is_some_and(is_runtime)
                            && precondition_shape(get(row, "precondition"))
                            && get(row, "name") == get(feedback, "name")
                            && crate::canonical::canonical_json(feedback)
                                .ok()
                                .and_then(|bytes| String::from_utf8(bytes).ok())
                                .is_some_and(|text| {
                                    crate::execution_ledger::feedback_string_valid(&text).is_ok()
                                })
                            && crate::execution_ledger::settled_facts_match_feedback(
                                row,
                                feedback,
                                get(value, "facts"),
                            )
                    })
                })
        }
        _ => return None,
    };
    Some(json!({"valid":valid}))
}

/// A recovered effect is useful only when it carries the exact protected
/// feedback and facts for this row. Native code additionally proves the receipt
/// belongs to the current process and the original conversation/root owner.
pub fn effect_valid(row: &Value, effect: &Value) -> bool {
    let Some(map) = exact_keys(
        Some(effect),
        &[
            "schema_version",
            "status",
            "feedback",
            "settled_facts",
            "truncated",
            "effect_may_have_occurred",
        ],
    ) else {
        return false;
    };
    let Some(text) = as_str(map.get("feedback")) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1))
        || !bool_value(map.get("truncated"))
        || !bool_value(map.get("effect_may_have_occurred"))
        || crate::execution_ledger::feedback_string_valid(text).is_err()
    {
        return false;
    }
    let Ok(feedback) = serde_json::from_str::<Value>(text) else {
        return false;
    };
    get(&feedback, "outcome") == map.get("status")
        && get(&feedback, "payload")
            .and_then(|p| get(p, "truncated"))
            .is_none_or(|truncated| Some(truncated) == map.get("truncated"))
        && reduce_contract(
            "runtime_facts_match",
            &json!({"row":row,"feedback":feedback,"facts":map.get("settled_facts")}),
            None,
        )
        .is_some_and(|result| result.get("valid") == Some(&json!(true)))
}
