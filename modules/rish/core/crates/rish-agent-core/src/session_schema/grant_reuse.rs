//! Tokenless conversation approval requires two independent proofs: a frozen
//! journal reference and the still-present grant in the complete conversation.
use crate::execution_ledger::{as_str, get};
use crate::schema::{canonical_sha256, canonical_uuid, safe_integer};
use serde_json::Value;

fn array(value: Option<&Value>) -> &[Value] {
    value
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}
fn same(left: Option<&Value>, right: Option<&Value>) -> bool {
    matches!((left, right), (Some(a), Some(b)) if a == b)
}
pub(super) fn family(name: &str) -> Option<&'static str> {
    match name {
        "write_file" => Some("file_write"),
        "git_commit" => Some("git_commit"),
        "git_push" => Some("git_push"),
        _ if crate::assistant_tools::is_mutation(name) => Some("assistant_metadata"),
        _ if crate::runtime_tools::is_guest(name) => Some("guest_service"),
        _ => None,
    }
}
/// Private assistant metadata writes use the assistant's readable root binding;
/// this grant never grants workspace file, Git, or runtime mutation authority.
pub(super) fn required_capability(family: &str) -> Option<&'static str> {
    match family {
        "assistant_metadata" => Some("file_read"),
        "file_write" => Some("file_write"),
        "git_commit" => Some("git_commit"),
        "git_push" => Some("git_push"),
        "guest_service" => Some("guest_service"),
        _ => None,
    }
}

/// Only this new shape may bypass the historical non-null approval-token rule.
pub(super) fn call_shape(call: &Value) -> bool {
    as_str(get(call, "access")) == Some("conversation_confirm")
        && as_str(get(call, "approval_decision")) == Some("allow_conversation")
        && get(call, "approval_token") == Some(&Value::Null)
        && canonical_uuid(get(call, "approval_reference"))
        && canonical_sha256(get(call, "idempotency_key"))
        && safe_integer(
            get(call, "native_row_revision"),
            9_007_199_254_740_991,
            false,
        )
        .is_some()
        && as_str(get(call, "name")).and_then(family).is_some()
        && get(call, "receipt")
            .filter(|v| !v.is_null())
            .is_none_or(|receipt| {
                same(
                    get(receipt, "approval_reference"),
                    get(call, "approval_reference"),
                )
            })
}
pub(super) fn journal_call_bound(call: &Value, journal: &Value) -> bool {
    let root = get(journal, "root");
    let name = as_str(get(call, "name")).unwrap_or_default();
    let Some(capability) = family(name).and_then(required_capability) else {
        return false;
    };
    call_shape(call)
        && crate::runtime_tools::grant_supports_tool(get(journal, "tool_registry_version"), name)
        && array(root.and_then(|r| get(r, "capabilities")))
            .iter()
            .any(|v| v == capability)
        && array(get(journal, "frozen_grant_ids"))
            .iter()
            .any(|id| Some(id) == get(call, "approval_reference"))
}
/// Surrounding session validation checks each grant's exact schema, unique ID
/// and issued_for attempt relation. This adds the call-specific live binding.
pub(super) fn conversation_bound(journal: &Value, conversation: &Value) -> bool {
    let root = get(journal, "root");
    array(get(journal, "batch"))
        .iter()
        .filter(|call| call_shape(call))
        .all(|call| {
            let name = as_str(get(call, "name")).unwrap_or_default();
            journal_call_bound(call, journal)
                && array(get(conversation, "agent_grants"))
                    .iter()
                    .any(|grant| {
                        same(get(grant, "grant_id"), get(call, "approval_reference"))
                            && same(get(grant, "conversation_id"), get(conversation, "id"))
                            && same(
                                get(grant, "workspace_id"),
                                root.and_then(|r| get(r, "workspace_id")),
                            )
                            && same(
                                get(grant, "project_id"),
                                root.and_then(|r| get(r, "project_id")),
                            )
                            && same(
                                get(grant, "binding_revision"),
                                root.and_then(|r| get(r, "workspace_binding_revision")),
                            )
                            && same(
                                get(grant, "root_fingerprint_sha256"),
                                root.and_then(|r| get(r, "root_fingerprint_sha256")),
                            )
                            && same(
                                get(grant, "registry_version"),
                                get(journal, "tool_registry_version"),
                            )
                            && same(
                                get(grant, "policy_version"),
                                get(journal, "policy").and_then(|p| get(p, "policy_version")),
                            )
                            && as_str(get(grant, "tool_family")) == family(name)
                    })
        })
}

/// The native coordinator includes the exact committed session in its proof.
/// A later query must retain the grants frozen by the prepared-batch checkpoint
/// instead of returning the attempt's initial empty grant list.
pub(crate) fn frozen_ids_for_projection(
    proof: &Value,
    request: &Value,
    base: &Value,
) -> Option<Value> {
    let session = get(proof, "session")?;
    let conversation = array(get(session, "conversations"))
        .iter()
        .find(|c| same(get(c, "id"), get(request, "conversation_id")))?;
    let attempt = array(get(conversation, "attempts")).iter().find(|a| {
        same(get(a, "attempt_id"), get(request, "attempt_id"))
            && same(get(a, "turn_id"), get(request, "task_id"))
    })?;
    let journal = get(attempt, "agent")?;
    let frozen = get(journal, "frozen_grant_ids")?;
    if get(proof, "matches") != Some(&Value::Bool(true))
        || !same(get(journal, "root"), get(base, "root"))
        || !same(get(journal, "policy"), get(base, "policy"))
        || !same(
            get(journal, "tool_registry_version"),
            get(base, "registry").and_then(|r| get(r, "registry_version")),
        )
        || !frozen.is_array()
        || array(Some(frozen)).len() > 2
        || !array(Some(frozen))
            .iter()
            .all(|id| canonical_uuid(Some(id)))
        || !conversation_bound(journal, conversation)
    {
        return None;
    }
    Some(frozen.clone())
}
