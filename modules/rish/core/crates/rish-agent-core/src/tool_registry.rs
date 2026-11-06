//! The frozen tool table, the registry projection a root implies, and the
//! policy that bounds writes.
//!
//! Ported from `AgentToolRegistry.mm`. The table is a pure table, so it lives
//! here rather than being typed out once per platform: its canonical bytes are
//! the `toolset_sha256` every stored authority is bound to, and two copies of
//! it would eventually disagree.
//!
//! Whether the guest CGI tools exist is a build fact, not a rule — iOS
//! compiles them in behind `DSH_GUEST_CGI_AVAILABLE` — so the host says, and
//! the digest follows.

use serde_json::{json, Value};

use crate::canonical::hash_json;
use crate::schema::{bounded_utf8, canonical_sha256, exact_keys, root_full};
use crate::store::StoreError;

const CAPABILITIES: &[&str] = &[
    "file_read",
    "file_write",
    "git_status",
    "git_commit",
    "git_push",
    "guest_service",
];

/// The capability each tool requires, and with it the set of known names.
const REQUIRED: &[(&str, &str)] = &[
    ("list_dir", "file_read"),
    ("read_file", "file_read"),
    ("write_file", "file_write"),
    ("git_status", "git_status"),
    ("git_commit", "git_commit"),
    ("git_push", "git_push"),
    ("start_guest_cgi", "guest_service"),
    ("stop_guest_cgi", "guest_service"),
];

fn string_property(max: u64) -> Value {
    json!({ "type": "string", "max_utf8_bytes": max })
}

fn nullable_string_property(max: u64) -> Value {
    json!({ "type": ["string", "null"], "max_utf8_bytes": max })
}

/// The table itself, in the order the digest is taken over. Parameter names
/// and schemas are needed to build a provider request, and are never copied
/// into the safe projection.
pub fn descriptors(guest_cgi: bool) -> Vec<Value> {
    let mut table = Vec::with_capacity(8);
    if guest_cgi {
        table.push(json!({
            "schema_version": 1, "name": "start_guest_cgi",
            "required_capability": "guest_service", "effect": "guest_service",
            "safe_summary_key": "agent.start_guest_cgi",
            "parameters": {
                "type": "object",
                "properties": {
                    "index_path": string_property(1024),
                    "index_sha256": string_property(64),
                    "backend_path": string_property(1024),
                    "backend_sha256": string_property(64),
                    "initial_data_path": nullable_string_property(1024),
                    "initial_data_sha256": nullable_string_property(64),
                },
                "required": ["index_path", "index_sha256", "backend_path",
                             "backend_sha256", "initial_data_path", "initial_data_sha256"],
            },
        }));
        table.push(json!({
            "schema_version": 1, "name": "stop_guest_cgi",
            "required_capability": "guest_service", "effect": "guest_service",
            "safe_summary_key": "agent.stop_guest_cgi",
            "parameters": {
                "type": "object",
                "properties": { "service_id": string_property(36) },
                "required": ["service_id"],
            },
        }));
    }
    table.push(json!({
        "schema_version": 1, "name": "git_commit", "required_capability": "git_commit",
        "effect": "git_commit", "safe_summary_key": "agent.git_commit",
        "parameters": {
            "type": "object",
            "properties": { "message": string_property(4096) },
            "required": ["message"],
        },
    }));
    table.push(json!({
        "schema_version": 1, "name": "git_push", "required_capability": "git_push",
        "effect": "git_push", "safe_summary_key": "agent.git_push",
        "fixed_remote": "origin",
        "parameters": { "type": "object", "properties": {}, "required": [] },
    }));
    table.push(json!({
        "schema_version": 1, "name": "git_status", "required_capability": "git_status",
        "effect": "read", "safe_summary_key": "agent.git_status",
        "parameters": { "type": "object", "properties": {}, "required": [] },
    }));
    table.push(json!({
        "schema_version": 1, "name": "list_dir", "required_capability": "file_read",
        "effect": "read", "safe_summary_key": "agent.list_dir",
        "parameters": {
            "type": "object",
            "properties": { "path": string_property(4096) },
            "required": ["path"],
        },
    }));
    table.push(json!({
        "schema_version": 1, "name": "read_file", "required_capability": "file_read",
        "effect": "read", "safe_summary_key": "agent.read_file",
        "parameters": {
            "type": "object",
            "properties": { "path": string_property(4096) },
            "required": ["path"],
        },
    }));
    table.push(json!({
        "schema_version": 1, "name": "write_file", "required_capability": "file_write",
        "effect": "write", "safe_summary_key": "agent.write_file",
        "parameters": {
            "type": "object",
            "properties": {
                "path": string_property(4096),
                "content": string_property(32768),
                "expected_revision": string_property(256),
            },
            "required": ["path", "content"],
        },
    }));
    table
}

/// The new language tools are part of the same shared table, including the
/// exact schema bytes previously used by the iOS v3 descriptor bridge.
pub fn runtime_descriptors() -> Vec<Value> {
    crate::runtime_tools::NAMES
        .iter()
        .map(|name| {
            let mut properties = serde_json::Map::new();
            let mut required = Vec::new();
            let list = *name == "list_runtime_environments";
            if *name == "stop_runtime_service" {
                properties.insert("service_id".into(), string_property(36));
                required.push("service_id");
            } else if !list {
                properties.insert("environment_id".into(), string_property(96));
                required.push("environment_id");
                if *name != "install_runtime_environment" {
                    properties.insert("entry_path".into(), string_property(1024));
                    properties.insert(
                        "args".into(),
                        json!({"type":"array","maxItems":64,"items":string_property(4096)}),
                    );
                    required.extend(["entry_path", "args"]);
                }
                if *name == "start_runtime_service" {
                    properties.insert(
                        "port".into(),
                        json!({"type":"integer","minimum":1024,"maximum":65535}),
                    );
                    required.push("port");
                }
            }
            json!({"schema_version":1,"name":name,
            "required_capability":if list {"file_read"} else {"guest_service"},
            "effect":if list {"read"} else {"guest_service"},
            "safe_summary_key":format!("agent.{name}"),
            "parameters":{"type":"object","properties":properties,"required":required}})
        })
        .collect()
}

/// Defaults remain v2 for hosts that have not implemented the runtime adapter.
/// Version 1 has no CGI tools; v1/v2 table order and schemas are immutable hash
/// inputs. Version 3 uses the previously shipped iOS sorted/nullable table.
/// Version 5 is offered only after the host proves the assistant conversation.
pub fn descriptors_for_version(version: u64, guest_cgi: bool) -> Option<Vec<Value>> {
    if !(1..=5).contains(&version) {
        return None;
    }
    let mut table = descriptors(guest_cgi && version != 1);
    if version >= 3 {
        let write = table.iter_mut().find(|tool| tool["name"] == "write_file")?;
        write["parameters"]["properties"]["expected_revision"] = nullable_string_property(256);
        table.extend(runtime_descriptors());
        if version >= 4 {
            table.push(crate::user_question::descriptor());
        }
        if version == 5 {
            table.extend(crate::assistant_tools::descriptors());
        }
        table.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    }
    Some(table)
}

fn descriptors_without_runtime(version: u64, guest_cgi: bool) -> Option<Vec<Value>> {
    let mut table = descriptors_for_version(version, guest_cgi)?;
    table.retain(|tool| {
        !tool["name"]
            .as_str()
            .is_some_and(crate::runtime_tools::is_runtime)
    });
    Some(table)
}

pub fn toolset_sha256_for_version(version: u64, guest_cgi: bool) -> Option<String> {
    hash_json(
        "agent-toolset",
        &json!({"registry_version":version,"tools":descriptors_for_version(version, guest_cgi)?}),
    )
}

/// Actual pre-v2 write schemas. ff3303e/8698427 used required nullable,
/// 101f570 used optional string. Frozen device WAL also records required
/// string; reconstructing that full table gives its exact 6ac56c... digest.
/// These are tables, not a hash allowlist: every accepted identity selects its
/// original provider schema and preserves the original descriptor order.
fn historical_tables(version: u64) -> Vec<Vec<Value>> {
    match version {
        1 => {
            let optional = descriptors(false);
            let mut required_string = optional.clone();
            let write = required_string
                .iter_mut()
                .find(|tool| tool["name"] == "write_file")
                .expect("fixed table");
            write["parameters"]["required"] = json!(["path", "content", "expected_revision"]);
            let mut required_nullable = required_string.clone();
            required_nullable
                .iter_mut()
                .find(|tool| tool["name"] == "write_file")
                .expect("fixed table")["parameters"]["properties"]["expected_revision"] =
                nullable_string_property(256);
            vec![optional, required_string, required_nullable]
        }
        2 => vec![descriptors(false), descriptors(true)],
        _ => vec![],
    }
}
fn table_hash(version: u64, table: &[Value]) -> Option<String> {
    hash_json(
        "agent-toolset",
        &json!({"registry_version":version,"tools":table}),
    )
}
fn descriptors_for_identity(
    version: u64,
    guest_cgi: bool,
    digest: Option<&Value>,
) -> Option<Vec<Value>> {
    let Some(digest) = digest else {
        return descriptors_for_version(version, guest_cgi);
    };
    if !canonical_sha256(Some(digest)) {
        return None;
    }
    let tables = if matches!(version, 4 | 5) {
        vec![
            descriptors_for_version(version, guest_cgi)?,
            descriptors_without_runtime(version, guest_cgi)?,
        ]
    } else if version == 3 {
        vec![descriptors_for_version(version, guest_cgi)?]
    } else {
        historical_tables(version)
    };
    tables
        .into_iter()
        .find(|table| table_hash(version, table).as_deref() == digest.as_str())
}
/// A standalone check additionally accepts readable historical identities.
/// Projection/descriptor checks bind the identity to the recorded version.
pub fn toolset_digest_valid(digest: &Value, version: u64, guest_cgi: bool) -> bool {
    descriptors_for_identity(version, guest_cgi, Some(digest)).is_some()
        || (version >= 3
            && [1, 2, 3]
                .iter()
                .any(|v| descriptors_for_identity(*v, guest_cgi, Some(digest)).is_some()))
}

/// `DSHAgentHJ("agent-toolset", {registry_version, tools})`: the digest every
/// stored authority is bound to.
pub fn toolset_sha256(guest_cgi: bool) -> Option<String> {
    toolset_sha256_for_version(2, guest_cgi)
}

fn descriptor_named(
    name: &str,
    guest_cgi: bool,
    version: u64,
    digest: Option<&Value>,
) -> Option<Value> {
    descriptors_for_identity(version, guest_cgi, digest)?
        .into_iter()
        .find(|descriptor| descriptor.get("name").and_then(Value::as_str) == Some(name))
}

/// The root's capability set, refused when it is not one.
fn capability_set(root: &Value) -> Option<Vec<&str>> {
    let Some(Value::Array(items)) = root.get("capabilities") else {
        return None;
    };
    if items.len() > 6 {
        return None;
    }
    let mut set: Vec<&str> = Vec::with_capacity(items.len());
    for item in items {
        let name = item.as_str()?;
        if !CAPABILITIES.contains(&name) || set.contains(&name) {
            return None;
        }
        set.push(name);
    }
    Some(set)
}

/// `DSHAgentRegistryAccessForName`: what this root lets this tool do, or
/// `None` when it does not offer it at all.
pub fn access_for(name: &str, capabilities: &[&str], project: bool) -> Option<&'static str> {
    if name == crate::user_question::NAME {
        return capabilities.contains(&"file_read").then_some("auto");
    }
    if crate::assistant_tools::is_assistant(name) {
        let mutation = crate::assistant_tools::is_mutation(name);
        return capabilities.contains(&"file_read").then_some(if mutation {
            "conversation_confirm"
        } else {
            "auto"
        });
    }
    let required = REQUIRED
        .iter()
        .find(|(tool, _)| *tool == name)
        .map(|(_, capability)| *capability)
        .or_else(|| {
            crate::runtime_tools::is_runtime(name).then_some(
                if name == "list_runtime_environments" {
                    "file_read"
                } else {
                    "guest_service"
                },
            )
        })?;
    if !capabilities.contains(&required) || (name.starts_with("git_") && !project) {
        return None;
    }
    if matches!(
        name,
        "list_dir" | "read_file" | "git_status" | "list_runtime_environments"
    ) {
        return Some("auto");
    }
    // git_push follows the git_commit pattern: per-conversation confirmation,
    // a recorded grant, and the same ledger and replay protection. Network
    // effects are still covered by the write-batch effect gate.
    Some("conversation_confirm")
}

fn safe_projection(descriptor: &Value, access: &str) -> Value {
    json!({
        "schema_version": 2,
        "name": descriptor.get("name"),
        "safe_summary_key": descriptor.get("safe_summary_key"),
        "access": access,
    })
}

/// A tool this root does not offer, or does not know, is projected as a
/// durable denial. The name is bounded and opaque — never a path or payload.
fn durable_deny(name: &str) -> Value {
    let safe = if name.is_empty()
        || name.len() > 64
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        "unknown"
    } else {
        name
    };
    json!({
        "schema_version": 2,
        "name": safe,
        "safe_summary_key": "agent.unknown",
        "access": "durable_deny",
    })
}

/// A stored projection must contain the complete capability-filtered table
/// for the version and digest it records. Legacy v2 reads recognize both
/// published build variants; the current v3 remains bound to this host build.
pub fn registry_shape(registry: &Value, root: &Value, guest_cgi: bool) -> bool {
    let Some(map) = exact_keys(
        Some(registry),
        &[
            "schema_version",
            "registry_version",
            "toolset_sha256",
            "tools",
        ],
    ) else {
        return false;
    };
    let Some(version @ 1..=5) = map.get("registry_version").and_then(Value::as_u64) else {
        return false;
    };
    let Some(Value::Array(tools)) = map.get("tools") else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(2))
        || !canonical_sha256(map.get("toolset_sha256"))
        || tools.len()
            > if version == 5 {
                20
            } else if version == 4 {
                14
            } else if version == 3 {
                13
            } else {
                8
            }
        || !root_full(Some(root))
    {
        return false;
    }
    let Some(table) = descriptors_for_identity(version, guest_cgi, map.get("toolset_sha256"))
    else {
        return false;
    };
    let Ok(expected) = projected_table(root, &table) else {
        return false;
    };
    if tools.len() != expected.len() {
        return false;
    }
    tools.iter().zip(expected).all(|(actual, mut expected)| {
        // The v1/v2 git-push once-only policy is historical authority, not a
        // newly offered tool. It remains readable with its original digest.
        if version < 3
            && actual.get("name") == Some(&json!("git_push"))
            && actual.get("access") == Some(&json!("confirm_once"))
        {
            expected["access"] = json!("confirm_once");
        }
        actual == &expected
    })
}

fn projected_table(root: &Value, table: &[Value]) -> Result<Vec<Value>, StoreError> {
    if !root_full(Some(root)) {
        return Err(StoreError::InvalidArgument);
    }
    let capabilities = capability_set(root).ok_or(StoreError::InvalidArgument)?;
    let project = root.get("kind").and_then(Value::as_str) == Some("project");
    let mut tools: Vec<Value> = table
        .iter()
        .filter_map(|descriptor| {
            let name = descriptor.get("name").and_then(Value::as_str)?;
            access_for(name, &capabilities, project)
                .map(|access| safe_projection(descriptor, access))
        })
        .collect();
    tools.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    Ok(tools)
}
fn projected_tools(root: &Value, guest_cgi: bool, version: u64) -> Result<Vec<Value>, StoreError> {
    projected_table(
        root,
        &descriptors_for_version(version, guest_cgi).ok_or(StoreError::InvalidArgument)?,
    )
}

/// Default v2 is deliberately unchanged for the Android adapter.
pub fn registry_for_root(root: &Value, guest_cgi: bool) -> Result<Value, StoreError> {
    registry_for_root_version(root, guest_cgi, 2)
}
pub fn registry_for_root_version(
    root: &Value,
    guest_cgi: bool,
    version: u64,
) -> Result<Value, StoreError> {
    let tools = projected_tools(root, guest_cgi, version)?;
    let digest =
        toolset_sha256_for_version(version, guest_cgi).ok_or(StoreError::InvalidArgument)?;
    Ok(json!({"schema_version":2,"registry_version":version,"toolset_sha256":digest,"tools":tools}))
}

/// The write policy, which does not vary by root but is still refused for one
/// that is not a root.
pub fn policy_for_root(root: &Value) -> Result<Value, StoreError> {
    if !root_full(Some(root)) {
        return Err(StoreError::InvalidArgument);
    }
    Ok(json!({
        "schema_version": 1,
        "policy_version": "agent-v1",
        "max_single_write_bytes": 32768,
        "max_batch_write_bytes": 524_288,
        "max_attempt_write_bytes": 4_194_304,
    }))
}

/// The safe projection for one tool name under this root: the tool as offered,
/// or a durable denial when the root does not offer it or does not know it.
pub fn descriptor_for_tool(name: &str, root: &Value, guest_cgi: bool) -> Result<Value, StoreError> {
    descriptor_for_tool_version(name, root, guest_cgi, 2)
}
pub fn descriptor_for_tool_version(
    name: &str,
    root: &Value,
    guest_cgi: bool,
    version: u64,
) -> Result<Value, StoreError> {
    descriptor_for_tool_identity(name, root, guest_cgi, version, None)
}
pub fn descriptor_for_tool_identity(
    name: &str,
    root: &Value,
    guest_cgi: bool,
    version: u64,
    digest: Option<&Value>,
) -> Result<Value, StoreError> {
    if digest.is_some() && descriptors_for_identity(version, guest_cgi, digest).is_none() {
        return Err(StoreError::Conflict);
    }
    if !root_full(Some(root)) || bounded_utf8(Some(&json!(name)), 64, false).is_none() {
        return Err(StoreError::InvalidArgument);
    }
    let Some(descriptor) = descriptor_named(name, guest_cgi, version, digest) else {
        return Ok(durable_deny(name));
    };
    let capabilities = capability_set(root).ok_or(StoreError::InvalidArgument)?;
    let project = root.get("kind").and_then(Value::as_str) == Some("project");
    Ok(match access_for(name, &capabilities, project) {
        Some(access) => safe_projection(&descriptor, access),
        None => durable_deny(name),
    })
}

/// Use the persisted access decision as well as the persisted table identity.
/// In particular, a historical git_push confirm_once stays once-only.
pub fn descriptor_for_frozen_registry(
    name: &str,
    registry: &Value,
    root: &Value,
    guest_cgi: bool,
) -> Result<Value, StoreError> {
    if !registry_shape(registry, root, guest_cgi) {
        return Err(StoreError::Conflict);
    }
    Ok(registry["tools"]
        .as_array()
        .expect("validated")
        .iter()
        .find(|tool| tool["name"] == name)
        .cloned()
        .unwrap_or_else(|| durable_deny(name)))
}

/// The full descriptor, parameters and all, for building a provider request.
pub fn native_descriptor(name: &str, guest_cgi: bool) -> Result<Value, StoreError> {
    native_descriptor_for_version(name, guest_cgi, 2)
}
pub fn native_descriptor_for_version(
    name: &str,
    guest_cgi: bool,
    version: u64,
) -> Result<Value, StoreError> {
    native_descriptor_for_identity(name, guest_cgi, version, None)
}
pub fn native_descriptor_for_identity(
    name: &str,
    guest_cgi: bool,
    version: u64,
    digest: Option<&Value>,
) -> Result<Value, StoreError> {
    if digest.is_some() && descriptors_for_identity(version, guest_cgi, digest).is_none() {
        return Err(StoreError::Conflict);
    }
    if bounded_utf8(Some(&json!(name)), 64, false).is_none() {
        return Err(StoreError::InvalidArgument);
    }
    descriptor_named(name, guest_cgi, version, digest).ok_or(StoreError::NotFound)
}

/// `rish_agent_tool_registry_reduce`.
pub fn reduce_json(input: &str) -> String {
    let value = match reduce_json_inner(input) {
        Ok(output) => {
            let mut object = output.as_object().cloned().unwrap_or_default();
            object.insert("ok".to_string(), Value::Bool(true));
            Value::Object(object)
        }
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn reduce_json_inner(input: &str) -> Result<Value, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = envelope
        .get("op")
        .and_then(Value::as_str)
        .ok_or(StoreError::Corrupt)?;
    let mut keys = vec!["op"];
    for option in ["guest_cgi", "registry_version", "runtime_tools"] {
        if envelope.get(option).is_some() {
            keys.push(option);
        }
    }
    match op {
        "toolset_sha256" | "descriptors" => {}
        "toolset_valid" => keys.push("toolset_sha256"),
        "registry" | "policy" => keys.push("root"),
        "descriptor" => keys.extend(["root", "name"]),
        "native_descriptor" => keys.push("name"),
        "registry_shape" => keys.extend(["root", "registry"]),
        "frozen_descriptor" => keys.extend(["root", "registry", "name"]),
        _ => return Err(StoreError::InvalidArgument),
    }
    if matches!(op, "descriptors" | "descriptor" | "native_descriptor")
        && envelope.get("toolset_sha256").is_some()
    {
        keys.push("toolset_sha256");
    }
    if exact_keys(Some(&envelope), &keys).is_none() {
        return Err(StoreError::InvalidArgument);
    }
    let guest_cgi = match envelope.get("guest_cgi") {
        None => false,
        Some(Value::Bool(value)) => *value,
        _ => return Err(StoreError::InvalidArgument),
    };
    let version = match envelope.get("registry_version") {
        None => 2,
        Some(value) => value
            .as_u64()
            .filter(|v| (1..=5).contains(v))
            .ok_or(StoreError::InvalidArgument)?,
    };
    let runtime_tools = match envelope.get("runtime_tools") {
        None => true,
        Some(Value::Bool(value)) if matches!(version, 4 | 5) => *value,
        _ => return Err(StoreError::InvalidArgument),
    };
    let table = if matches!(version, 4 | 5) && !runtime_tools {
        descriptors_without_runtime(version, guest_cgi)
    } else {
        descriptors_for_version(version, guest_cgi)
    }
    .ok_or(StoreError::InvalidArgument)?;
    let current_digest = json!(table_hash(version, &table).ok_or(StoreError::InvalidArgument)?);
    let requested_digest = envelope.get("toolset_sha256").unwrap_or(&current_digest);
    let root = || envelope.get("root").ok_or(StoreError::InvalidArgument);
    let name = || {
        envelope
            .get("name")
            .and_then(Value::as_str)
            .ok_or(StoreError::InvalidArgument)
    };
    match op {
        "toolset_sha256" => Ok(json!({"toolset_sha256":current_digest})),
        "toolset_valid" => Ok(
            json!({"valid":toolset_digest_valid(&envelope["toolset_sha256"], version, guest_cgi)}),
        ),
        "descriptors" => Ok(
            json!({"descriptors":descriptors_for_identity(version, guest_cgi, Some(requested_digest)).ok_or(StoreError::Conflict)?}),
        ),
        "registry" => Ok(
            json!({"registry":{"schema_version":2,"registry_version":version,
                "toolset_sha256":current_digest,"tools":projected_table(root()?, &table)?}}),
        ),
        "policy" => Ok(json!({"policy":policy_for_root(root()?)?})),
        "descriptor" => Ok(
            json!({"descriptor":descriptor_for_tool_identity(name()?, root()?, guest_cgi, version, Some(requested_digest))?}),
        ),
        "native_descriptor" => Ok(
            json!({"descriptor":native_descriptor_for_identity(name()?, guest_cgi, version, Some(requested_digest))?}),
        ),
        "registry_shape" => {
            Ok(json!({"valid":registry_shape(&envelope["registry"], root()?, guest_cgi)}))
        }
        "frozen_descriptor" => Ok(
            json!({"descriptor":descriptor_for_frozen_registry(name()?, &envelope["registry"], root()?, guest_cgi)?}),
        ),
        _ => Err(StoreError::InvalidArgument),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workspace_root(capabilities: Value) -> Value {
        json!({
            "schema_version": 1, "kind": "workspace",
            "workspace_id": "11111111-1111-4111-8111-111111111111",
            "project_id": null,
            "root_fingerprint_sha256": "c".repeat(64),
            "workspace_binding_revision": 1,
            "capabilities": capabilities,
        })
    }

    /// Every stored authority is bound to this digest, so the table's bytes
    /// are a compatibility contract, not an implementation detail. These two
    /// values were the ones the Objective-C table produced; a change to the
    /// table changes them and invalidates every authority on every device.
    #[test]
    fn the_toolset_digest_is_the_one_stored_authorities_are_bound_to() {
        assert_eq!(
            toolset_sha256(true).expect("digest"),
            "bbdeb99de07223175703fb9748e16444f1f89e0b072283d030be9017c2fdebd4"
        );
        assert_eq!(
            toolset_sha256(false).expect("digest"),
            "62e426ffac0cc058b8affcbc8744549eeb91bc9a99923bb1982ec42c47e8a60c"
        );
    }

    #[test]
    fn a_workspace_root_is_never_offered_a_git_tool() {
        // A workspace root may not even carry a git capability, so the
        // registry never has to decide whether to offer one.
        assert!(
            registry_for_root(&workspace_root(json!(["file_read", "git_commit"])), false).is_err()
        );
        let registry =
            registry_for_root(&workspace_root(json!(["file_read", "file_write"])), false)
                .expect("registry");
        let tools = registry["tools"].as_array().expect("tools");
        assert_eq!(tools.len(), 3);
        assert_eq!(tools[0]["name"], json!("list_dir"));
        assert_eq!(tools[1]["name"], json!("read_file"));
        assert_eq!(tools[2]["name"], json!("write_file"));
        assert_eq!(tools[0]["access"], json!("auto"));
        assert_eq!(tools[2]["access"], json!("conversation_confirm"));
    }

    #[test]
    fn a_tool_the_root_does_not_offer_is_a_durable_denial_not_an_error() {
        let root = workspace_root(json!(["file_read"]));
        let denied = descriptor_for_tool("write_file", &root, false).expect("projection");
        assert_eq!(denied["access"], json!("durable_deny"));
        assert_eq!(denied["safe_summary_key"], json!("agent.unknown"));
        // An unknown name is denied under a name that cannot carry a payload.
        let unknown = descriptor_for_tool("../../etc/passwd", &root, false).expect("projection");
        assert_eq!(unknown["name"], json!("unknown"));
    }

    #[test]
    fn a_registry_whose_access_disagrees_with_its_root_is_refused() {
        let root = workspace_root(json!(["file_read", "file_write"]));
        let mut registry = registry_for_root(&root, false).expect("registry");
        assert!(registry_shape(&registry, &root, false));
        registry["tools"][0]["access"] = json!("conversation_confirm");
        assert!(!registry_shape(&registry, &root, false));
    }
}
