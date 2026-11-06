use super::*;
use crate::{model, RuntimeCommand, TurnIds};
use rish_agent_core::session_schema;

const A: &str = "11111111-1111-4111-8111-111111111111";
const B: &str = "22222222-2222-4222-8222-222222222222";
const M: &str = "33333333-3333-4333-8333-333333333333";
const C: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const NOW: &str = "2026-10-29T01:00:00.000Z";
const LATER: &str = "2026-10-29T01:00:01.000Z";

fn policy(request: Value) -> Value {
    let response: Value =
        serde_json::from_str(&provider_policy::reduce_json(&request.to_string())).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["value"].clone()
}

fn provider(id: &str, name: &str) -> Value {
    json!({"id":id,"active":true,"configuration":{
        "schema_version":1,"harness_id":format!("custom-{id}"),"name":name,
        "endpoint_url":"https://relay.example/v1/chat/completions","full_url":true,
        "protocol":"chat-completions","auth_type":"bearer","send_reasoning":true,
        "model_mappings":{registry::logical_model_id(id,M):"same-upstream-model"}},
        "models":[{"id":M,"name":"Shared Model","wire_model":"same-upstream-model",
        "supports_images":false,"active":true}]})
}

fn save(registry: &Value, provider: Value) -> Value {
    policy(json!({"op":"registry_save","registry":registry,
        "expected_revision":registry["revision"].as_u64().unwrap_or(0),"provider":provider}))
}

fn remove(registry: &Value, id: &str) -> Value {
    policy(json!({"op":"registry_remove","registry":registry,
        "expected_revision":registry["revision"],"provider_id":id}))
}

fn registry() -> Value {
    save(&Value::Null, provider(A, "Provider A"))
}

fn ready(registry: Value) -> ShellState {
    let mut shell = ShellState::new();
    shell.apply_custom_providers(registry).unwrap();
    shell
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    shell.set_default_workspace(json!({"schema_version":2,
        "workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,
        "display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    shell
}

fn commit(shell: &mut ShellState) -> Option<RuntimeCommand> {
    let pending = shell.pending.as_ref().unwrap();
    shell.accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{
        "schema_version":1,"generation":shell.authority["snapshot"]["generation"].as_u64().unwrap_or(0)+1,
        "session_sha256":pending.digest}})).unwrap()
}

fn snapshot(session: &Value) -> Value {
    let raw = session.to_string();
    json!({"schema_version":1,"status":"present","session_json":raw,"snapshot":{
        "schema_version":1,"generation":4,
        "session_sha256":session_schema::candidate_digest(raw.as_bytes()).unwrap()}})
}

fn binding() -> Value {
    policy(
        json!({"op":"binding","configuration":provider(A,"Provider A")["configuration"],
        "logical_model":registry::logical_model_id(A,M),"model_harness":format!("custom-{A}")}),
    )
}

fn reply(command: &RuntimeCommand) -> Value {
    let request: Value = serde_json::from_str(command.args[0].as_str().unwrap()).unwrap();
    let mut response = json!({"schema_version":2,"round_index":0,
        "provider_request_id":model::id(),"provider_response_id":"response-1",
        "requested_model":request["model"],"text":"Custom answer","reasoning":"",
        "tool_calls":[],"finish_reason":"stop","latency_ms":12,
        "visible_history_sha256":"a".repeat(64),"model_input_sha256":"b".repeat(64),
        "request_body_sha256":"c".repeat(64),"project_context_receipt":null,
        "provider_configuration":binding()});
    for key in [
        "harness_id",
        "turn_id",
        "attempt_id",
        "round_id",
        "model",
        "thinking_mode",
    ] {
        response[key] = request[key].clone();
    }
    response
}

fn environment(shell: &ShellState) -> Value {
    json!({"models":shell.environment.supported_models,"harnesses":shell.environment.harness_by_model,
        "providers":shell.environment.provider_ids,"hosts":shell.environment.host_by_model,
        "bindings":shell.environment.provider_bindings.iter().map(|binding|json!({
            "key":binding.canonical_sha256,"valid":binding.valid,"host":binding.host})).collect::<Vec<_>>()})
}

fn state(shell: &ShellState) -> Value {
    json!({"session":shell.session,"authority":shell.authority,"registry":shell.custom_registry,
        "environment":environment(shell),"providers":shell.custom_provider_names,
        "names":shell.custom_model_names,"models":shell.models().into_iter().map(|model|json!({
        "id":model.id,"name":model.name,"harness":model.harness})).collect::<Vec<_>>(),
        "workspace":shell.default_workspace,"error":shell.error,"loaded":shell.loaded})
}

#[test]
fn bootstrap_installs_independent_providers_and_preserves_configured_choices() {
    let mut shell = ShellState::with_test_models();
    let original = shell.models();
    let registry = save(&registry(), provider(B, "Provider B"));
    shell
        .apply_custom_providers(json!(registry.to_string()))
        .unwrap();
    assert!(!shell.is_loaded());
    assert_eq!(shell.models()[..original.len()], original);
    for (id, label) in [(A, "Provider A"), (B, "Provider B")] {
        let logical = registry::logical_model_id(id, M);
        let harness = format!("custom-{id}");
        assert!(shell
            .models()
            .iter()
            .any(|model| model.id == logical && model.harness == harness));
        assert_eq!(shell.provider_display_name(&harness), Some(label));
        assert!(shell.environment.provider_ids.contains(&harness));
        assert_eq!(shell.environment.host_by_model[&logical], "relay.example");
    }
    assert_eq!(shell.provider_display_name("custom-unknown"), None);
    assert_eq!(shell.provider_display_name("codex"), None);
}

#[test]
fn refresh_retirement_preserves_conversation_selection_authority_and_old_metadata() {
    let registry = registry();
    let mut shell = ready(registry.clone());
    let logical = registry::logical_model_id(A, M);
    shell.create_conversation(C, NOW, &logical).unwrap();
    commit(&mut shell);
    shell.record_error("Unrelated error");
    let before = shell.session.clone();
    let authority = shell.authority.clone();
    let workspace = shell.default_workspace.clone();
    shell.apply_custom_providers(remove(&registry, A)).unwrap();
    assert_eq!(shell.session, before);
    assert_eq!(shell.authority, authority);
    assert_eq!(shell.default_workspace, workspace);
    assert_eq!(shell.last_error(), Some("Unrelated error"));
    assert_eq!(shell.selected_model(), logical);
    assert_eq!(
        shell.custom_model_display_name(&logical),
        Some("Shared Model")
    );
    assert!(!shell.models().iter().any(|model| model.id == logical));
    assert!(shell.environment.supported_models.contains(&logical));
    assert!(shell
        .prepare_send("Do not route", &TurnIds::new(), LATER)
        .is_err());
    assert_eq!(shell.session, before);
    assert!(!shell.is_busy());
}

#[test]
fn historical_binding_reopens_after_endpoint_change_and_retirement_without_dispatch() {
    let initial = registry();
    let mut shell = ready(initial.clone());
    shell
        .create_conversation(C, NOW, &registry::logical_model_id(A, M))
        .unwrap();
    commit(&mut shell);
    shell.prepare_send("Hello", &TurnIds::new(), NOW).unwrap();
    let command = commit(&mut shell).unwrap();
    shell.accept_completion(reply(&command), LATER).unwrap();
    commit(&mut shell);
    let history = shell.session.clone();
    let mut updated = provider(A, "New label");
    updated["configuration"]["endpoint_url"] = json!("https://new.example/v1/chat/completions");
    let changed = save(&initial, updated);
    shell.apply_custom_providers(changed.clone()).unwrap();
    assert_eq!(
        shell.environment.host_by_model[&registry::logical_model_id(A, M)],
        "new.example"
    );
    assert!(shell
        .environment
        .provider_bindings
        .iter()
        .any(|fact| fact.valid && fact.host.as_deref() == Some("relay.example")));
    let retired = remove(&changed, A);
    shell.apply_custom_providers(retired.clone()).unwrap();
    shell.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-v4-flash","name":"Flash","supports_images":false}],"retired_models":[]})).unwrap();
    shell.load_snapshot(snapshot(&history)).unwrap();
    assert_eq!(shell.session, history);
    assert!(
        session_schema::validate_candidate(history.to_string().as_bytes(), &shell.environment)
            .is_ok()
    );
    assert!(shell
        .prepare_send("Do not dispatch old route", &TurnIds::new(), LATER)
        .is_err());

    let mut reopened = ready(retired);
    reopened.load_snapshot(snapshot(&history)).unwrap();
    assert_eq!(reopened.messages().last().unwrap().text, "Custom answer");
    assert!(session_schema::validate_candidate(
        history.to_string().as_bytes(),
        &reopened.environment
    )
    .is_ok());
}

#[test]
fn invalid_registry_or_revision_never_partially_changes_state() {
    let initial = registry();
    let mut shell = ready(initial.clone());
    let before = state(&shell);
    for value in [
        json!({}),
        Value::Null,
        json!("not-json"),
        json!({"schema_version":1,"revision":99,"providers":[]}),
    ] {
        assert!(shell.apply_custom_providers(value).is_err());
        assert_eq!(state(&shell), before);
    }
    let mut bad_url = initial.clone();
    bad_url["revision"] = json!(2);
    bad_url["providers"][0]["configuration"]["endpoint_url"] =
        json!("http://remote.example/v1/chat/completions");
    assert!(shell.apply_custom_providers(bad_url).is_err());
    assert_eq!(state(&shell), before);
    assert!(shell
        .apply_catalog(json!({"schema_version":1,"models":[{"id":"gpt-5.6","name":"DSH collision","supports_images":false}],"retired_models":[]}))
        .is_err());
    assert_eq!(state(&shell), before);
}

#[test]
fn pending_and_sending_operations_block_registry_refresh() {
    let initial = registry();
    let changed = save(&initial, provider(A, "Renamed"));
    let mut shell = ready(initial);
    shell
        .create_conversation(C, NOW, &registry::logical_model_id(A, M))
        .unwrap();
    let before = state(&shell);
    assert!(shell.apply_custom_providers(changed.clone()).is_err());
    assert_eq!(state(&shell), before);
    commit(&mut shell);
    shell.prepare_send("Hello", &TurnIds::new(), NOW).unwrap();
    commit(&mut shell);
    let before = state(&shell);
    assert!(shell.apply_custom_providers(changed).is_err());
    assert_eq!(state(&shell), before);
}

#[test]
fn agent_driver_blocks_registry_refresh_after_its_checkpoint_commits() {
    let initial = registry();
    let changed = save(&initial, provider(A, "Renamed"));
    let mut shell = ready(initial);
    shell
        .create_conversation(C, NOW, &registry::logical_model_id(A, M))
        .unwrap();
    commit(&mut shell);
    shell
        .prepare_agent_send("Hello", &TurnIds::new(), NOW)
        .unwrap();
    commit(&mut shell);
    assert!(shell.agent_run.is_some());
    let before = state(&shell);
    assert!(shell.apply_custom_providers(changed).is_err());
    assert!(shell.apply_catalog(json!({"schema_version":1,"models":[{"id":"deepseek-v4-flash","name":"Flash","supports_images":false}],"retired_models":[]})).is_err());
    assert_eq!(state(&shell), before);
    assert!(shell.agent_run.is_some());
}

#[test]
fn unknown_or_forged_native_bindings_do_not_attest_custom_models() {
    let mut shell = ready(registry());
    let logical = registry::logical_model_id(A, M);
    let valid = json!({"model":logical,"provider_configuration":binding()});
    assert_eq!(binding_valid(&valid, &shell.environment), Some(true));
    let mut forged = valid.clone();
    forged["provider_configuration"]["endpoint_url"] =
        json!("https://evil.example/v1/chat/completions");
    assert_eq!(binding_valid(&forged, &shell.environment), Some(false));
    let mut unknown = valid;
    unknown["model"] = json!(registry::logical_model_id(B, M));
    assert_eq!(binding_valid(&unknown, &shell.environment), Some(false));
    let before = state(&shell);
    let mut bad_snapshot = model::empty_session();
    bad_snapshot["untrusted_custom_binding"] = forged;
    assert!(shell.load_snapshot(snapshot(&bad_snapshot)).is_err());
    assert_eq!(state(&shell), before);
    model::native_binding_facts(&unknown, &mut shell.environment);
    assert!(!shell
        .environment
        .supported_models
        .contains(&registry::logical_model_id(B, M)));
    assert_eq!(
        shell.environment.provider_bindings.last().unwrap().valid,
        false
    );
}

#[test]
fn legacy_opaque_custom_prefix_keeps_dsh_route_but_uuid_collision_is_registry_only() {
    let mut shell = ready(Value::Null);
    let logical = registry::logical_model_id(A, M);
    shell
        .apply_catalog(json!({"schema_version":1,"models":[
        {"id":"custom:my-llama","name":"Legacy Llama","supports_images":false},
        {"id":logical,"name":"Ambiguous legacy UUID entry","supports_images":false}],"retired_models":[]}))
        .unwrap();
    assert!(shell
        .models()
        .iter()
        .any(|model| model.id == "custom:my-llama" && model.harness == "dsh"));
    assert!(!shell.models().iter().any(|model| model.id == logical));
    assert!(!shell.environment.supported_models.contains(&logical));
    assert!(shell.create_conversation(C, NOW, &logical).is_err());
    shell
        .create_conversation(C, NOW, "custom:my-llama")
        .unwrap();
    commit(&mut shell);
    shell
        .prepare_send("Use existing legacy provider", &TurnIds::new(), NOW)
        .unwrap();
    let command = commit(&mut shell).unwrap();
    let request: Value = serde_json::from_str(command.args[0].as_str().unwrap()).unwrap();
    assert_eq!(request["harness_id"], "dsh");
    assert_eq!(request["model"], "custom:my-llama");
    let mut response = reply(&command);
    response
        .as_object_mut()
        .unwrap()
        .remove("provider_configuration");
    shell.accept_completion(response, LATER).unwrap();
    commit(&mut shell);
    let history = shell.session.clone();
    shell.apply_custom_providers(registry()).unwrap();
    assert!(shell
        .models()
        .iter()
        .any(|model| model.id == logical && model.harness == format!("custom-{A}")));
    assert_eq!(shell.selected_model(), "custom:my-llama");
    assert_eq!(shell.session, history);
    assert!(
        session_schema::validate_candidate(history.to_string().as_bytes(), &shell.environment)
            .is_ok()
    );
}

#[test]
fn model_discovery_setup_keeps_empty_provider_metadata_without_a_selectable_model() {
    let mut draft = provider(A, "Before discovery");
    draft["models"] = json!([]);
    draft["configuration"]["model_mappings"] = json!({});
    let empty_provider = save(&Value::Null, draft);
    let mut shell = ready(empty_provider.clone());
    assert_eq!(
        shell.provider_display_name(&format!("custom-{A}")),
        Some("Before discovery")
    );
    assert!(shell
        .environment
        .provider_ids
        .contains(&format!("custom-{A}")));
    assert!(!shell
        .models()
        .iter()
        .any(|model| model.harness == format!("custom-{A}")));
    let before = shell.session.clone();
    let configured = save(&empty_provider, provider(A, "Before discovery"));
    shell.apply_custom_providers(configured).unwrap();
    assert!(shell
        .models()
        .iter()
        .any(|model| model.id == registry::logical_model_id(A, M)));
    assert_eq!(shell.session, before);
}
