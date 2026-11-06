//! Native-only task tool entrypoint. Paths and execution context come from the
//! host's committed conversation, never from model arguments.
use super::*;
use rish_agent_core::{
    canonical::{canonical_json, hash_json},
    execution_ledger, schema,
};
use serde::Deserialize;
use serde_json::{json, Map};

/// Saturate rather than evict replay evidence without a native acknowledgement.
pub const MAX_TOOL_RECEIPTS: usize = 2048;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    action: String,
    conversation_id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    arguments_sha256: String,
    #[serde(default)]
    locator: Option<Value>,
    #[serde(default)]
    arguments: Value,
    #[serde(default)]
    context: Option<Context>,
    #[serde(default)]
    expected_revision: Option<u64>,
    #[serde(default)]
    now_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Context {
    conversation_id: String,
    model_id: String,
    workspace_binding: Value,
    workspace_descriptor: Value,
}

impl AssistantStore {
    /// All calls require a trusted app-private store and committed conversation
    /// identity supplied by native. `authorize` reads the identity and profile;
    /// `prepare` captures a revision without writing; `recover` only reads a
    /// durable receipt; `apply` atomically writes the effect and its receipt.
    /// Create additionally requires native's committed model/workspace context.
    pub fn task_tool(&self, request: &Value) -> StoreResult<Value> {
        let request: Request = serde_json::from_value(request.clone())
            .map_err(|_| AssistantStoreError::Invalid("task tool request"))?;
        self.storage.locked(|| {
            let full = self.storage.read()?;
            let owner = full
                .conversation_bot_id(&request.conversation_id)
                .map(str::to_owned);
            let authorized = owner.is_some() && !request.conversation_id.is_empty();
            if request.action == "authorize" {
                return Ok(if let Some(owner) = &owner {
                    let mut profile = full
                        .bot_profile(owner)
                        .ok_or(AssistantStoreError::NotFound)?
                        .clone();
                    // Group identity and character were frozen before native
                    // execution. Later profile edits must not change that turn.
                    if let Some(run) = full
                        .groups
                        .iter()
                        .flat_map(|group| &group.rounds)
                        .flat_map(|round| &round.replies)
                        .filter(|reply| reply.conversation_id == request.conversation_id)
                        .filter_map(|reply| reply.run.as_ref())
                        .find(|run| run.status.is_active())
                    {
                        profile.name = run.snapshot.name.clone();
                        profile.soul = run.snapshot.soul.clone();
                        profile.notes = run.snapshot.notes.clone();
                    }
                    json!({"authorized":true,"assistant_context":{
                        "schema_version":1,"conversation_id":request.conversation_id,
                        "profile_revision":full.revision,"name":profile.name,
                        "notes":profile.notes,"soul":profile.soul}})
                } else {
                    json!({"authorized":false})
                });
            }
            if !authorized
                || request
                    .context
                    .as_ref()
                    .is_some_and(|context| context.conversation_id != request.conversation_id)
            {
                return Err(AssistantStoreError::Invalid(
                    "assistant conversation required",
                ));
            }
            let owner = owner.ok_or(AssistantStoreError::NotFound)?;
            let mut state = full.project_for_store(&owner)?;
            let args = validate_request(&request)?;
            if let Some(receipt) = find_receipt(&state, &request)? {
                return match request.action.as_str() {
                    "prepare" => Ok(receipt.precondition.clone()),
                    "apply" | "recover" => Ok(receipt.effect.clone()),
                    _ => Err(AssistantStoreError::Invalid("task tool action")),
                };
            }
            if request.action == "recover" {
                return Ok(Value::Null);
            }
            // Before approval, an update must refer to an existing task and a
            // create must have capacity. No task or schedule changes here.
            check_target(&state, &request.name, args)?;
            let precondition = json!({
                "schema_version":1,"kind":request.name,
                "conversation_id":request.conversation_id,
                "arguments_sha256":request.arguments_sha256,
                "expected_store_revision":state.revision
            });
            if !rish_agent_core::assistant_tools::precondition_shape(Some(&precondition)) {
                return Err(AssistantStoreError::Invalid("task revision exhausted"));
            }
            if request.action == "prepare" {
                return Ok(precondition);
            }
            if request.action != "apply" {
                return Err(AssistantStoreError::Invalid("task tool action"));
            }
            check_revision(
                &state,
                request
                    .expected_revision
                    .ok_or(AssistantStoreError::Invalid("missing prepared revision"))?,
            )?;
            let locator = request
                .locator
                .as_ref()
                .ok_or(AssistantStoreError::Invalid("missing task tool locator"))?;
            if request.name == "list_assistant_tasks" {
                return effect(
                    &request,
                    locator,
                    state.revision,
                    list_payload(&state),
                    false,
                );
            }
            if request.name == "search_assistant_memory" {
                return effect(
                    &request,
                    locator,
                    state.revision,
                    memory::search_payload(&state, args),
                    false,
                );
            }
            if state.tool_receipts.len() >= MAX_TOOL_RECEIPTS {
                return Err(AssistantStoreError::Invalid("task receipt limit reached"));
            }
            let now = request
                .now_ms
                .ok_or(AssistantStoreError::Invalid("missing native clock"))?;
            state.clock_high_water_ms = state.clock_high_water_ms.max(now);
            let memory_tool = memory::is_memory(&request.name);
            let record_id = if memory_tool {
                memory::mutate(
                    &mut state,
                    &request.name,
                    args,
                    &request.conversation_id,
                    now,
                )?
            } else {
                mutate_task(&mut state, &request, args)?
            };
            let revision = state
                .revision
                .checked_add(1)
                .ok_or(AssistantStoreError::Invalid("revision exhausted"))?;
            let mut payload = json!({"schema_version":1,"store_revision":revision});
            payload[if memory_tool { "memory_id" } else { "task_id" }] = json!(record_id);
            let result = effect(&request, locator, revision, payload, true)?;
            state.tool_receipts.push(AssistantToolReceipt {
                locator: locator.clone(),
                conversation_id: request.conversation_id.clone(),
                name: request.name.clone(),
                arguments_sha256: request.arguments_sha256.clone(),
                precondition,
                effect: result.clone(),
            });
            self.persist_for_bot(&owner, state)?;
            Ok(result)
        })
    }
}

fn validate_request(request: &Request) -> StoreResult<&Map<String, Value>> {
    let args = request
        .arguments
        .as_object()
        .ok_or(AssistantStoreError::Invalid("task tool arguments"))?;
    if !rish_agent_core::assistant_tools::arguments_valid(&request.name, args)
        || hash_json(
            "tool-arguments",
            &json!({"name":request.name,"arguments":args}),
        )
        .as_deref()
            != Some(&request.arguments_sha256)
        || !schema::canonical_uuid(Some(&json!(request.conversation_id)))
        || request
            .locator
            .as_ref()
            .is_some_and(|locator| !execution_ledger::ledger_locator(Some(locator)))
        || (request.action != "prepare" && request.locator.is_none())
    {
        return Err(AssistantStoreError::Invalid(
            "task tool arguments or identity",
        ));
    }
    Ok(args)
}

fn check_target(
    state: &AssistantSnapshot,
    name: &str,
    args: &Map<String, Value>,
) -> StoreResult<()> {
    if rish_agent_core::assistant_tools::is_mutation(name)
        && state.tool_receipts.len() >= MAX_TOOL_RECEIPTS
    {
        return Err(AssistantStoreError::Invalid("task receipt limit reached"));
    }
    if memory::is_memory(name) {
        return memory::check_target(state, name, args);
    }
    match name {
        "create_assistant_task" if state.tasks.len() >= MAX_TASKS => {
            Err(AssistantStoreError::Invalid("task limit reached"))
        }
        "update_assistant_task"
            if !state
                .tasks
                .iter()
                .any(|task| Some(task.id.as_str()) == args["task_id"].as_str()) =>
        {
            Err(AssistantStoreError::NotFound)
        }
        _ => Ok(()),
    }
}

fn mutate_task(
    state: &mut AssistantSnapshot,
    request: &Request,
    args: &Map<String, Value>,
) -> StoreResult<String> {
    let anchor = state.clock_high_water_ms;
    if request.name == "create_assistant_task" {
        let context = request
            .context
            .as_ref()
            .ok_or(AssistantStoreError::Invalid(
                "missing committed conversation context",
            ))?;
        let mut config = AssistantTaskConfig::manual(
            args["title"].as_str().unwrap(),
            args["instructions"].as_str().unwrap(),
            &context.model_id,
            context.workspace_binding.clone(),
            context.workspace_descriptor.clone(),
        );
        config.interval_minutes = interval(args.get("follow_up_minutes"));
        let config = normalize_config(config)?;
        let task_id = crate::model::id();
        state.tasks.push(AssistantTask {
            id: task_id.clone(),
            conversation_id: crate::model::id(),
            next_due_ms: next_due(&config, anchor)?,
            title: config.title,
            instructions: config.instructions,
            workspace_binding: config.workspace_binding,
            workspace_descriptor: config.workspace_descriptor,
            model_id: config.model_id,
            interval_minutes: config.interval_minutes,
            enabled: true,
            pending_manual: false,
            last_run: None,
            runtime: None,
        });
        return Ok(task_id);
    }
    let task_id = args["task_id"].as_str().unwrap();
    let task = task_mut(state, task_id)?;
    let mut config = task.config();
    if let Some(title) = args.get("title") {
        config.title = title.as_str().unwrap().into();
    }
    if let Some(instructions) = args.get("instructions") {
        config.instructions = instructions.as_str().unwrap().into();
    }
    if args.contains_key("follow_up_minutes") {
        config.interval_minutes = interval(args.get("follow_up_minutes"));
    }
    if let Some(paused) = args.get("paused") {
        config.enabled = !paused.as_bool().unwrap();
    }
    let config = normalize_config(config)?;
    if task.enabled != config.enabled || task.interval_minutes != config.interval_minutes {
        task.next_due_ms = if task.is_running() {
            None
        } else {
            next_due(&config, anchor)?
        };
    }
    task.title = config.title;
    task.instructions = config.instructions;
    task.interval_minutes = config.interval_minutes;
    task.enabled = config.enabled;
    if !task.enabled {
        task.pending_manual = false;
    }
    Ok(task_id.into())
}

fn interval(value: Option<&Value>) -> Option<u32> {
    value.and_then(Value::as_u64).map(|value| value as u32)
}

fn list_payload(state: &AssistantSnapshot) -> Value {
    let tasks: Vec<_> = state
        .tasks
        .iter()
        .map(|task| {
            json!({
                "task_id":task.id,"title":task.title,"paused":!task.enabled,
                "follow_up_minutes":task.interval_minutes,"pending_manual":task.pending_manual
            })
        })
        .collect();
    json!({"schema_version":1,"store_revision":state.revision,"tasks":tasks,"truncated":false})
}

fn effect(
    request: &Request,
    locator: &Value,
    revision: u64,
    payload: Value,
    mutation: bool,
) -> StoreResult<Value> {
    let truncated = request.name == "search_assistant_memory" && payload["truncated"] == true;
    let facts = json!({"schema_version":1,"kind":request.name,
        "conversation_id":request.conversation_id,"arguments_sha256":request.arguments_sha256,
        "locator_sha256":digest("assistant-tool-locator", locator)?,"store_revision":revision,
        "payload_sha256":digest("assistant-tool-payload", &payload)?});
    let feedback = canonical_json(
        &json!({"schema_version":1,"name":request.name,"outcome":"ok","payload":payload}),
    )
    .map_err(|_| AssistantStoreError::Invalid("task feedback"))?;
    Ok(
        json!({"schema_version":1,"status":"ok","feedback":String::from_utf8(feedback).unwrap(),
        "settled_facts":facts,"truncated":truncated,"effect_may_have_occurred":mutation}),
    )
}

fn digest(domain: &str, value: &Value) -> StoreResult<String> {
    hash_json(domain, value).ok_or(AssistantStoreError::Invalid("task receipt digest"))
}

fn same_call(a: &Value, b: &Value) -> bool {
    [
        "task_id",
        "attempt_id",
        "round_id",
        "round_index",
        "call_index",
        "call_id",
    ]
    .iter()
    .all(|key| a[key] == b[key])
        || a["idempotency_key"] == b["idempotency_key"]
}

fn find_receipt<'a>(
    state: &'a AssistantSnapshot,
    request: &Request,
) -> StoreResult<Option<&'a AssistantToolReceipt>> {
    let Some(locator) = request.locator.as_ref() else {
        return Ok(None);
    };
    let Some(receipt) = state
        .tool_receipts
        .iter()
        .find(|receipt| same_call(&receipt.locator, locator))
    else {
        return Ok(None);
    };
    if receipt.locator != *locator
        || receipt.conversation_id != request.conversation_id
        || receipt.name != request.name
        || receipt.arguments_sha256 != request.arguments_sha256
    {
        return Err(AssistantStoreError::Invalid(
            "task operation identity reused",
        ));
    }
    Ok(Some(receipt))
}

pub(super) fn validate_receipts(state: &AssistantSnapshot) -> StoreResult<()> {
    if state.tool_receipts.len() > MAX_TOOL_RECEIPTS {
        return Err(AssistantStoreError::Invalid("task receipt limit"));
    }
    let mut calls = HashSet::new();
    let mut keys = HashSet::new();
    let mut previous = 0;
    for receipt in &state.tool_receipts {
        let revision = receipt.precondition["expected_store_revision"].as_u64();
        let after = revision.and_then(|revision| revision.checked_add(1));
        let mut call_identity = receipt.locator.clone();
        if let Some(call) = call_identity.as_object_mut() {
            call.remove("idempotency_key");
        }
        let row = json!({"name":receipt.name,"conversation_id":receipt.conversation_id,
            "arguments_sha256":receipt.arguments_sha256,"locator":receipt.locator,
            "precondition":receipt.precondition});
        if !rish_agent_core::assistant_tools::is_mutation(&receipt.name)
            || state
                .conversation_bot_id(&receipt.conversation_id)
                .is_none()
            || receipt.precondition["conversation_id"] != receipt.conversation_id
            || after.is_none_or(|revision| revision > state.revision || revision <= previous)
            || receipt.effect["status"] != "ok"
            || receipt.effect["effect_may_have_occurred"] != true
            || !rish_agent_core::assistant_tools::effect_valid(&row, &receipt.effect)
            || !calls.insert(digest("assistant-tool-call", &call_identity)?)
            || !keys.insert(
                receipt.locator["idempotency_key"]
                    .as_str()
                    .unwrap_or_default(),
            )
        {
            return Err(AssistantStoreError::Invalid("task operation receipt"));
        }
        previous = after.unwrap();
    }
    Ok(())
}

#[cfg(test)]
#[path = "assistant_task_store_tests.rs"]
mod tests;
