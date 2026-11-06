use crate::{model::*, RuntimeCommand, ShellState};
use rish_agent_core::session_schema::{self, Env};
use serde_json::{json, Value};

const NOW: &str = "2026-10-29T01:00:00.000Z";
const LATER: &str = "2026-10-29T01:00:01.000Z";
const CONVERSATION: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

fn ready() -> ShellState {
    let mut shell = ShellState::new();
    shell
        .apply_catalog(json!({"schema_version":1,
            "models":[{"id":"deepseek-custom-current","name":"Current","supports_images":false}],
            "retired_models":[{"id":"deepseek-custom-retired","name":"Retired","supports_images":false}]}))
        .unwrap();
    shell
        .load_snapshot(json!({"schema_version":1,"status":"missing"}))
        .unwrap();
    shell.set_default_workspace(json!({"schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":1,"display_name":"Default","status":"ok","capabilities":{"read":true,"write":true,"git":true}})).unwrap();
    shell
}

fn commit(shell: &mut ShellState) -> Option<RuntimeCommand> {
    let pending = shell.pending.as_ref().unwrap();
    shell
        .accept_persist(json!({"schema_version":1,"status":"committed","snapshot":{
            "schema_version":1,
            "generation":shell.authority["snapshot"]["generation"].as_u64().unwrap_or(0)+1,
            "session_sha256":pending.digest}}))
        .unwrap()
}

fn models() -> Value {
    json!([
        {"id":"gpt-subscription-current","name":"Subscription Current"},
        {"id":"codex-special_1.0","name":"Special 编程"},
        {"id":"o3","name":"o3"}
    ])
}

fn environment(env: &Env) -> Value {
    json!({
        "models":env.supported_models,"harnesses":env.harness_by_model,
        "hosts":env.host_by_model,"providers":env.provider_ids,
        "bindings":env.provider_bindings.iter().map(|binding| json!({
            "key":binding.canonical_sha256,"valid":binding.valid,"host":binding.host
        })).collect::<Vec<_>>()
    })
}

fn state(shell: &ShellState) -> Value {
    json!({
        "session":shell.session,"authority":shell.authority,
        "environment":environment(&shell.environment),
        "catalog":shell.models().into_iter().map(|model| json!({
            "id":model.id,"name":model.name,"harness":model.harness
        })).collect::<Vec<_>>(),
        "pending":shell.query_pending_commit().map(|command|json!({
            "module":command.module,"method":command.method,"args":command.args
        })),"loaded":shell.loaded,"busy":shell.is_busy(),"error":shell.error,
        "workspace":shell.default_workspace
    })
}

#[test]
fn refresh_without_active_chat_changes_only_codex_choices() {
    let mut shell = ready();
    let session = shell.session.clone();
    let authority = shell.authority.clone();
    let other_models: Vec<_> = shell
        .models()
        .into_iter()
        .filter(|m| m.harness != "codex")
        .collect();
    shell.record_error("Retain unrelated native error");
    shell
        .apply_codex_subscription_models(json!(models().to_string()))
        .unwrap();
    assert_eq!(shell.session, session);
    assert_eq!(shell.authority, authority);
    assert_eq!(shell.last_error(), Some("Retain unrelated native error"));
    assert_eq!(shell.active_conversation_id(), None);
    assert_eq!(
        shell
            .models()
            .into_iter()
            .filter(|m| m.harness != "codex")
            .collect::<Vec<_>>(),
        other_models
    );
    assert!(!shell.is_busy());
    assert!(shell.query_pending_commit().is_none());
    assert_eq!(
        shell.environment.harness_for_model(Some(&json!("o3"))),
        Some("codex")
    );
    assert_eq!(
        shell.environment.host_for_model(Some(&json!("o3"))),
        Some("api.openai.com")
    );
    let command = shell.set_default_model("gpt-subscription-current").unwrap();
    assert_eq!(command.method, "casPersistSession");
    assert_eq!(
        shell.session, session,
        "selection still waits for native CAS"
    );
    commit(&mut shell);
    assert_eq!(
        shell.preferences()["default_model"],
        "gpt-subscription-current"
    );
}

#[test]
fn refresh_and_api_restore_preserve_selected_retired_history_and_native_binding() {
    let mut shell = ready();
    shell
        .create_conversation(CONVERSATION, NOW, "deepseek-custom-current")
        .unwrap();
    commit(&mut shell);
    shell
        .prepare_send("retain this history", &TurnIds::new(), NOW)
        .unwrap();
    let command = commit(&mut shell).unwrap();
    let request: Value = serde_json::from_str(command.args[0].as_str().unwrap()).unwrap();
    let binding = json!({"schema_version":1,"harness_id":"dsh","endpoint_url":"https://models.example.test/v1/chat/completions","protocol":"chat-completions","auth_type":"bearer","send_reasoning":true,"model_id":"deepseek-provider-alias","profile_id":"d".repeat(64)});
    let response = json!({"schema_version":2,"harness_id":"dsh","round_index":0,
        "turn_id":request["turn_id"],"attempt_id":request["attempt_id"],"round_id":request["round_id"],
        "provider_request_id":id(),"provider_response_id":"response-1",
        "requested_model":"deepseek-custom-current","model":"deepseek-custom-current",
        "thinking_mode":"high","text":"Saved native history","reasoning":"Native reasoning",
        "tool_calls":[],"finish_reason":"stop","latency_ms":12,
        "visible_history_sha256":"a".repeat(64),"model_input_sha256":"b".repeat(64),
        "request_body_sha256":"c".repeat(64),"project_context_receipt":null,
        "provider_configuration":binding});
    shell.accept_completion(response, LATER).unwrap();
    commit(&mut shell);
    shell
        .apply_codex_subscription_models(json!([{"id":"gpt-old-subscription","name":"Previous"}]))
        .unwrap();
    shell
        .create_conversation(OTHER, LATER, "gpt-old-subscription")
        .unwrap();
    commit(&mut shell);
    shell.set_default_model("gpt-old-subscription").unwrap();
    commit(&mut shell);

    // A fresh native snapshot supplies both historic model and binding facts.
    let session = shell.session.clone();
    let raw = session.to_string();
    let mut shell = ready();
    shell.load_snapshot(json!({"schema_version":1,"status":"present","session_json":raw,
        "snapshot":{"schema_version":1,"generation":8,"session_sha256":session_schema::candidate_digest(raw.as_bytes()).unwrap()}})).unwrap();
    let authority = shell.authority.clone();
    let bindings = environment(&shell.environment)["bindings"].clone();
    assert_eq!(bindings.as_array().unwrap().len(), 1);
    shell.apply_codex_subscription_models(models()).unwrap();
    assert_eq!(shell.session, session);
    assert_eq!(shell.authority, authority);
    assert_eq!(shell.selected_model(), "gpt-old-subscription");
    assert_eq!(shell.preferences()["default_model"], "gpt-old-subscription");
    assert!(!shell
        .models()
        .iter()
        .any(|m| m.id == "gpt-old-subscription"));
    assert!(shell
        .environment
        .supported_models
        .contains(&"deepseek-custom-retired".into()));
    assert_eq!(environment(&shell.environment)["bindings"], bindings);

    let before_reset = environment(&shell.environment);
    shell.reset_codex_subscription_models().unwrap();
    assert_eq!(environment(&shell.environment), before_reset);
    assert_eq!(shell.session, session);
    assert_eq!(shell.authority, authority);
    assert_eq!(
        shell
            .models()
            .into_iter()
            .filter(|m| m.harness == "codex")
            .collect::<Vec<_>>(),
        Vec::<crate::Model>::new(),
        "No Codex API catalog was configured; restoring API mode must not invent fixed choices"
    );
    assert!(shell.query_pending_commit().is_none());
    // Revalidating the entire session must retain the retired model and the
    // configured native receipt rather than stranding subsequent writes.
    shell.set_preference("locale", json!("zh-CN")).unwrap();
    commit(&mut shell);
    assert_eq!(shell.selected_model(), "gpt-old-subscription");
    assert_eq!(shell.session["conversations"], session["conversations"]);
}

#[test]
fn rejects_malformed_catalogs_atomically() {
    let mut shell = ready();
    let before = state(&shell);
    let mut invalid = vec![
        Value::Null,
        json!({"models":models()}),
        json!("not JSON"),
        json!([{"id":"gpt-valid","name":"Valid"},{"id":"gpt-valid","name":"Duplicate"}]),
        json!([{"id":"gpt-valid","name":"Valid","harness":"dsh"}]),
        json!([{"id":"gpt-valid"}]),
        json!([{"id":1,"name":"Invalid"}]),
    ];
    for id in [
        "",
        "gpt-",
        "codex-",
        "gpt-.invalid",
        "gpt-_invalid",
        "o",
        "ox1",
        "GPT-1",
        "claude-sonnet-5",
        "deepseek-v4-flash",
        "gpt-space model",
        "gpt-中文",
    ] {
        invalid.push(json!([{"id":id,"name":"Invalid"}]));
    }
    invalid.push(json!([{"id":format!("gpt-{}", "a".repeat(77)),"name":"Too long"}]));
    for name in [
        "".to_owned(),
        "  ".into(),
        "control\nname".into(),
        "control\u{7f}".into(),
        "a".repeat(257),
    ] {
        invalid.push(json!([{"id":"gpt-valid","name":name}]));
    }
    invalid.push(json!((0..65)
        .map(|index| json!({"id":format!("gpt-{index}"),"name":"Name"}))
        .collect::<Vec<_>>()));
    for value in invalid {
        assert!(
            shell
                .apply_codex_subscription_models(value.clone())
                .is_err(),
            "accepted {value}"
        );
        assert_eq!(state(&shell), before, "mutated for {value}");
    }
}

#[test]
fn empty_subscription_discovery_removes_choices_without_rewriting_saved_selection() {
    let mut shell = ready();
    shell.apply_codex_subscription_models(models()).unwrap();
    shell.set_default_model("gpt-subscription-current").unwrap();
    commit(&mut shell);
    let session = shell.session.clone();
    let authority = shell.authority.clone();
    let prior_environment = environment(&shell.environment);
    shell.apply_codex_subscription_models(json!([])).unwrap();
    assert!(shell.models().iter().all(|model| model.harness != "codex"));
    assert_eq!(shell.session, session);
    assert_eq!(shell.authority, authority);
    assert_eq!(environment(&shell.environment), prior_environment);
    assert_eq!(
        shell.preferences()["default_model"],
        "gpt-subscription-current"
    );
    assert!(shell.query_pending_commit().is_none());
}

#[test]
fn rejects_current_and_retired_cross_harness_collisions_without_partial_refresh() {
    let mut shell = ready();
    shell
        .apply_catalog(json!({"schema_version":1,
        "models":[{"id":"gpt-custom-dsh","name":"DSH current","supports_images":false}],
        "retired_models":[{"id":"codex-retired-dsh","name":"DSH retired","supports_images":false}]}))
        .unwrap();
    let before = state(&shell);
    for id in ["gpt-custom-dsh", "codex-retired-dsh"] {
        assert!(shell
            .apply_codex_subscription_models(json!([
                {"id":"gpt-first-valid","name":"Valid"},{"id":id,"name":"Conflict"}
            ]))
            .is_err());
        assert_eq!(state(&shell), before);
    }
}

#[test]
fn refresh_and_api_restore_require_loaded_idle_native_state() {
    let mut unloaded = ShellState::new();
    let before = state(&unloaded);
    assert!(unloaded.apply_codex_subscription_models(models()).is_err());
    assert!(unloaded.reset_codex_subscription_models().is_err());
    assert_eq!(state(&unloaded), before);

    let mut shell = ready();
    shell
        .create_conversation(CONVERSATION, NOW, "deepseek-custom-current")
        .unwrap();
    let pending = state(&shell);
    assert!(shell.apply_codex_subscription_models(models()).is_err());
    assert!(shell.reset_codex_subscription_models().is_err());
    assert_eq!(state(&shell), pending);
    commit(&mut shell);
    shell
        .prepare_send("waiting for provider", &TurnIds::new(), NOW)
        .unwrap();
    commit(&mut shell);
    let sending = state(&shell);
    assert!(shell.apply_codex_subscription_models(models()).is_err());
    assert!(shell.reset_codex_subscription_models().is_err());
    assert_eq!(state(&shell), sending);
}

#[test]
fn accepts_exact_native_id_and_catalog_boundaries() {
    let mut shell = ready();
    let longest_id = format!("gpt-{}", "a".repeat(76));
    let mut catalog = (0..63)
        .map(|index| json!({"id":format!("codex-{index}"),"name":"Name"}))
        .collect::<Vec<_>>();
    catalog.push(json!({"id":longest_id,"name":"a".repeat(256)}));
    shell
        .apply_codex_subscription_models(json!(catalog))
        .unwrap();
    assert_eq!(
        shell
            .models()
            .iter()
            .filter(|m| m.harness == "codex")
            .count(),
        64
    );
    assert!(shell.models().iter().any(|m| m.id == longest_id));
}
