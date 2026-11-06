//! An unconfigured model is a draft state, never an execution identity.
use rish_agent_core::session_schema::{validate_candidate, validate_schema9_root, Env};
use serde_json::{json, Value};

fn empty() -> Value {
    json!({"schema_version":9,"workspace_authority_outbox":[],"agent_transcript_cleanup_outbox":[],
        "project_context_destructive_epoch":0,"project_context_destructive_transition":null,
        "active_conversation_id":null,"conversations":[],"messages":[],"session_events":[],
        "preferences":{"schema_version":1,"theme_mode":"system","locale":"system","default_model":null,
            "selected_harness_id":null,"thinking_mode":"high","tool_permission":"read-only",
            "show_reasoning":false,"auto_expand_tools":false,"confirm_destructive_file_actions":true}})
}
fn draft() -> Value {
    let mut session = empty();
    let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    let workspace = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    session["active_conversation_id"] = json!(id);
    session["conversations"] = json!([{"id":id,"project_id":null,"workspace_id":workspace,"runtime_context_id":null,
        "project_context":null,"workspace_binding":{"schema_version":1,"workspace_id":workspace,"binding_revision":1,"project_id":null},
        "workspace_bootstrap_state":"none","title":"New conversation","title_source":"auto","model_id":null,
        "thinking_mode":"high","messages":[],"turns":[],"attempts":[],"agent_grants":[],
        "created_at":"2026-10-30T00:00:00.000Z","updated_at":"2026-10-30T00:00:00.000Z"}]);
    session
}
fn historical_env() -> Env {
    let mut env = Env::default();
    env.supported_models
        .push("historical-provider-model".into());
    env.harness_by_model
        .insert("historical-provider-model".into(), "dsh".into());
    env.host_by_model.insert(
        "historical-provider-model".into(),
        "api.deepseek.com".into(),
    );
    env.provider_ids.push("deepseek".into());
    env
}

#[test]
fn empty_session_and_workspace_bound_draft_need_no_fake_model_or_provider() {
    for session in [empty(), draft()] {
        assert!(validate_schema9_root(&session, &Env::default()));
        assert!(validate_candidate(session.to_string().as_bytes(), &Env::default()).is_ok());
    }
}

#[test]
fn default_and_draft_accept_only_explicit_null_not_unknown_strings_or_missing_fields() {
    for replacement in [
        json!(""),
        json!("not-configured"),
        json!(true),
        json!(0),
        json!([]),
    ] {
        let mut value = empty();
        value["preferences"]["default_model"] = replacement.clone();
        assert!(!validate_schema9_root(&value, &Env::default()));
        let mut value = draft();
        value["conversations"][0]["model_id"] = replacement;
        assert!(!validate_schema9_root(&value, &Env::default()));
    }
    let mut value = empty();
    value["preferences"]
        .as_object_mut()
        .unwrap()
        .remove("default_model");
    assert!(!validate_schema9_root(&value, &Env::default()));
    let mut value = draft();
    value["conversations"][0]
        .as_object_mut()
        .unwrap()
        .remove("model_id");
    assert!(!validate_schema9_root(&value, &Env::default()));
}

#[test]
fn historical_configured_models_remain_unchanged_when_the_new_default_is_unset() {
    let mut value = draft();
    value["conversations"][0]["model_id"] = json!("historical-provider-model");
    assert!(validate_schema9_root(&value, &historical_env()));
    value["preferences"]["default_model"] = json!("historical-provider-model");
    value["preferences"]["selected_harness_id"] = json!("dsh");
    assert!(validate_schema9_root(&value, &historical_env()));
    assert!(
        !validate_schema9_root(&value, &Env::default()),
        "History still needs trusted identity facts"
    );
}

#[test]
fn nullable_draft_exception_never_carries_messages_attempts_grants_or_context() {
    let baseline = draft();
    assert!(validate_schema9_root(&baseline, &Env::default()));
    for key in ["messages", "turns", "attempts", "agent_grants"] {
        let mut value = baseline.clone();
        value["conversations"][0][key] = json!([{}]);
        assert!(!validate_schema9_root(&value, &Env::default()), "{key}");
        for malformed in [Value::Null, json!(false), json!({})] {
            let mut value = baseline.clone();
            value["conversations"][0][key] = malformed;
            assert!(!validate_schema9_root(&value, &Env::default()), "{key}");
        }
    }
    for key in ["project_id", "runtime_context_id", "project_context"] {
        let mut value = baseline.clone();
        value["conversations"][0][key] = json!("cccccccc-cccc-4ccc-8ccc-cccccccccccc");
        assert!(!validate_schema9_root(&value, &Env::default()), "{key}");
    }
    let mut value = baseline;
    value["conversations"][0]["workspace_binding"]["binding_revision"] = json!(0);
    assert!(
        !validate_schema9_root(&value, &Env::default()),
        "Unconfigured drafts still require valid workspace authority"
    );
}

#[test]
fn valid_message_history_cannot_be_changed_to_a_null_conversation_model() {
    let mut value = draft();
    value["conversations"][0]["model_id"] = json!("historical-provider-model");
    let message = json!({"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","role":"user","text":"hello",
        "created_at":"2026-10-30T00:00:00.000Z","attachments":[]});
    value["conversations"][0]["messages"] = json!([message.clone()]);
    value["messages"] = json!([message]);
    assert!(validate_schema9_root(&value, &historical_env()));
    value["conversations"][0]["model_id"] = Value::Null;
    assert!(!validate_schema9_root(&value, &historical_env()));
}
