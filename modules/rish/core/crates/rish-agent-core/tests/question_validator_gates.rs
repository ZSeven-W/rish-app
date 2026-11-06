//! Additive ask_user gates never turn persisted pre-v4 denials into authority.
use rish_agent_core::{
    provider_round, runtime_tools, session_schema::Env, tool_registry, wal_state,
};
use serde_json::{json, Value};
const ID: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const TIME: &str = "2026-10-16T00:00:00.000Z";

fn root() -> Value {
    json!({"schema_version":1,"kind":"project","workspace_id":ID,"workspace_binding_revision":1,
        "project_id":ID,"root_fingerprint_sha256":"a".repeat(64),
        "capabilities":["file_read","file_write","git_status","git_commit","git_push","guest_service"]})
}
fn registry(guest: bool, runtime: bool) -> Value {
    let value: Value = serde_json::from_str(&tool_registry::reduce_json(
        &json!({"op":"registry",
        "registry_version":4,"guest_cgi":guest,"runtime_tools":runtime,"root":root()})
        .to_string(),
    ))
    .unwrap();
    assert_eq!(value["ok"], true, "{value}");
    value["registry"].clone()
}
fn authority(registry: Value) -> Value {
    json!({"schema_version":2,"task_id":ID,"conversation_id":ID,"attempt_id":ID,"root":root(),
      "policy":{"schema_version":1,"policy_version":"agent-v1","max_single_write_bytes":32768,"max_batch_write_bytes":524288,"max_attempt_write_bytes":4194304},
      "registry":registry,"transport_schema_version":2,"model":"test-model","thinking_mode":"off",
      "visible_message_ids":[],"visible_history_sha256":"a".repeat(64),"visible_message_count":0,"project_context_sha256":null,
      "transcript":{"schema_version":1,"transcript_ref":ID,"generation":0,"transcript_sha256":"a".repeat(64),"transcript_bytes":2},
      "reserved_write_bytes":0,"authority_revision":1,"state":"prepared","cleanup_id":null,"created_at":TIME,"updated_at":TIME})
}
fn contract(op: &str, value: Value) -> Value {
    serde_json::from_str(&wal_state::reduce_json(
        &json!({"op":op,"value":value}).to_string(),
    ))
    .unwrap()
}
fn round_v2() -> Value {
    json!({"schema_version":2,"locator":{},"row_revision":1,"root_fingerprint_sha256":"a".repeat(64),
      "binding_revision":1,"request_sha256":"b".repeat(64),"transcript_before":{},"launch_attempt":1,
      "state":"completed","owner":null,"failure_code":null,"completion_receipt":{},"transcript_after":{},
      "calls":[{"schema_version":1,"call_id":"question_1","name":"ask_user","arguments_sha256":"c".repeat(64),
        "safe_summary_key":"agent.unknown","access":"auto"}],
      "terminal_kind":"tool_batch","created_at":TIME,"updated_at":TIME})
}

#[test]
fn v4_wal_authority_accepts_both_platform_tables_and_rejects_forged_projection() {
    let env = Env {
        supported_models: vec!["test-model".into()],
        ..Default::default()
    };
    for guest in [false, true] {
        for runtime in [false, true] {
            let registry = registry(guest, runtime);
            assert!(wal_state::registry_shape(Some(&registry)));
            let authority = authority(registry);
            assert!(
                wal_state::authority_shape(&authority, &env),
                "guest={guest},runtime={runtime}"
            );
            let tools = authority["registry"]["tools"].as_array().unwrap();
            assert_eq!(
                tools.iter().any(|tool| tool["name"] == "run_program"),
                runtime
            );
            assert!(tools
                .iter()
                .any(|tool| tool["name"] == "ask_user" && tool["access"] == "auto"));
            let mut forged = authority.clone();
            forged["registry"]["tools"]
                .as_array_mut()
                .unwrap()
                .retain(|tool| tool["name"] != "ask_user");
            assert!(!wal_state::authority_shape(&forged, &env));
            let mut forged = authority.clone();
            forged["registry"]["toolset_sha256"] = json!("0".repeat(64));
            assert!(!wal_state::authority_shape(&forged, &env));
            for version in [1, 2, 3, 6] {
                let mut wrong = authority["registry"].clone();
                wrong["registry_version"] = json!(version);
                assert!(!wal_state::registry_shape(Some(&wrong)), "v{version}");
            }
            // The shape gate allows v5's superset of names, but an authority
            // cannot relabel the frozen v4 table and digest as a v5 identity.
            let mut wrong_identity = authority.clone();
            wrong_identity["registry"]["registry_version"] = json!(5);
            assert!(wal_state::registry_shape(Some(&wrong_identity["registry"])));
            assert!(!wal_state::authority_shape(&wrong_identity, &env));
        }
    }
    assert_eq!(registry(true, true)["tools"].as_array().unwrap().len(), 14);
}

#[test]
fn existing_wal_bridge_exposes_shared_question_validation() {
    let args = json!({"question":"选择一个方向","input_mode":"options","options":[
        {"id":"phone","label":"手机"},{"id":"tablet","label":"平板"}]});
    let precondition = json!({"schema_version":1,"kind":"ask_user","question":args});
    let facts = json!({"schema_version":1,"kind":"ask_user","response_sha256":"a".repeat(64)});
    for (op, value) in [
        ("question_arguments", args),
        ("question_precondition", precondition),
        ("question_facts", facts),
    ] {
        assert_eq!(contract(op, value), json!({"ok":true,"valid":true}));
        assert_eq!(contract(op, json!({})), json!({"ok":true,"valid":false}));
        assert_eq!(contract(op, Value::Null), json!({"ok":true,"valid":false}));
    }
    assert!(provider_round::tool_description("ask_user")
        .unwrap()
        .contains("actual response"));
}

#[test]
fn pre_v4_question_round_migration_preserves_durable_unknown_denial() {
    let (migrated, _) = wal_state::migrate_round_v2_to_v3(&round_v2()).unwrap();
    assert_eq!(migrated["calls"][0]["access"], "durable_deny");
    assert_eq!(migrated["calls"][0]["safe_summary_key"], "agent.unknown");
    assert_eq!(migrated["calls"][0]["approval_state"], "durable_denied");
    assert_eq!(migrated["executable_call_count"], 0);
    assert_eq!(migrated["denied_call_count"], 1);
    let mut upgraded = migrated.clone();
    upgraded["calls"][0]["access"] = json!("auto");
    upgraded["calls"][0]["approval_state"] = json!("deferred");
    upgraded["executable_call_count"] = json!(1);
    upgraded["denied_call_count"] = json!(0);
    upgraded["batch_class"] = json!("executable");
    assert!(wal_state::round_v3_projection(&upgraded).is_none());
    upgraded["calls"][0]["safe_summary_key"] = json!("agent.ask_user");
    assert!(wal_state::round_v3_projection(&upgraded).is_some());
}

#[test]
fn runtime_grants_accept_v5_without_backporting_runtime_to_v1_or_v2() {
    for version in 1..=6 {
        assert_eq!(
            runtime_tools::registry_version(Some(&json!(version))),
            version <= 5
        );
        for name in runtime_tools::NAMES {
            assert_eq!(
                runtime_tools::grant_supports_tool(Some(&json!(version)), name),
                matches!(version, 3..=5)
            );
        }
        assert_eq!(
            runtime_tools::grant_supports_tool(Some(&json!(version)), "start_guest_cgi"),
            matches!(version, 2..=5)
        );
    }
    assert!(!runtime_tools::registry_version(Some(&json!(true))));
}
