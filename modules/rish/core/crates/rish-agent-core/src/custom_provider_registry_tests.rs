use serde_json::{json, Value};

const PROVIDER_A: &str = "11111111-1111-4111-8111-111111111111";
const PROVIDER_B: &str = "22222222-2222-4222-8222-222222222222";
const MODEL_A: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const MODEL_B: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const INVALID: &str = "E_CUSTOM_PROVIDER_REGISTRY_INVALID";
const CONFLICT: &str = "E_CUSTOM_PROVIDER_REGISTRY_CONFLICT";
const CAPACITY: &str = "E_CUSTOM_PROVIDER_REGISTRY_CAPACITY";

fn invoke(request: Value) -> Value {
    serde_json::from_str(&crate::provider_policy::reduce_json(&request.to_string())).unwrap()
}

fn value(request: Value) -> Value {
    let result = invoke(request);
    assert_eq!(result["ok"], true, "{result}");
    result["value"].clone()
}

fn refused(request: Value, code: &str) {
    assert_eq!(invoke(request), json!({"ok": false, "error": code}));
}

fn logical(provider: &str, model: &str) -> String {
    format!("custom:{provider}:{model}")
}

fn provider(id: &str, model: &str) -> Value {
    json!({
        "id": id,
        "active": true,
        "configuration": {
            "schema_version": 1,
            "harness_id": format!("custom-{id}"),
            "name": "My relay",
            "endpoint_url": "https://relay.example/v1/chat/completions",
            "protocol": "chat-completions",
            "auth_type": "bearer",
            "send_reasoning": true,
            "model_mappings": {logical(id, model): "same-wire-model"},
            "full_url": true
        },
        "models": [{
            "id": model,
            "name": "My model",
            "wire_model": "same-wire-model",
            "supports_images": true,
            "active": true
        }]
    })
}

fn empty() -> Value {
    value(json!({"op": "registry_read", "registry": null}))
}

fn save(registry: &Value, provider: &Value) -> Value {
    value(json!({
        "op": "registry_save", "registry": registry,
        "expected_revision": registry["revision"], "provider": provider
    }))
}

fn route(registry: &Value, model: &str, require_active: bool) -> Value {
    value(json!({
        "op": "registry_route", "registry": registry,
        "model_id": model, "require_active": require_active
    }))
}

fn account(provider: &Value) -> Value {
    value(json!({
        "op": "credential_account",
        "slot": format!("CUSTOM_API_KEY_{}", provider["id"].as_str().unwrap()),
        "configuration": provider["configuration"]
    }))
}

fn bind(provider: &Value, model: &str) -> Value {
    value(json!({
        "op": "binding", "configuration": provider["configuration"],
        "logical_model": logical(provider["id"].as_str().unwrap(), model),
        "model_harness": provider["configuration"]["harness_id"]
    }))
}

#[test]
fn absent_registry_is_empty_and_only_null_selects_default() {
    assert_eq!(
        empty(),
        json!({"schema_version": 1, "revision": 0, "providers": []})
    );
    for invalid in [json!({}), json!([]), json!(""), json!(false)] {
        refused(json!({"op": "registry_read", "registry": invalid}), INVALID);
    }
    let mut stored = empty();
    stored["schema_version"] = json!(1.0);
    refused(json!({"op": "registry_read", "registry": stored}), INVALID);
}

#[test]
fn identical_upstream_settings_keep_provider_model_profile_and_key_identities_separate() {
    let first = provider(PROVIDER_A, MODEL_A);
    let second = provider(PROVIDER_B, MODEL_A);
    let registry = save(&save(&empty(), &first), &second);
    let first_route = route(&registry, &logical(PROVIDER_A, MODEL_A), true);
    let second_route = route(&registry, &logical(PROVIDER_B, MODEL_A), true);
    assert_ne!(first_route["id"], second_route["id"]);
    assert_ne!(first_route["harness_id"], second_route["harness_id"]);
    assert_ne!(first_route["provider_id"], second_route["provider_id"]);
    assert_eq!(first_route["wire_model"], second_route["wire_model"]);
    assert_eq!(first_route["provider_name"], "My relay");
    assert_eq!(first_route["name"], "My model");
    assert_eq!(first_route["supports_images"], true);
    assert_ne!(account(&first), account(&second));
    assert_ne!(
        bind(&first, MODEL_A)["profile_id"],
        bind(&second, MODEL_A)["profile_id"]
    );
    assert_eq!(route(&registry, "same-wire-model", true), Value::Null);
    assert_eq!(logical(PROVIDER_A, MODEL_A).len(), 80);
    for id in [PROVIDER_A, PROVIDER_B] {
        let slot = format!("CUSTOM_API_KEY_{id}");
        let harness = format!("custom-{id}");
        assert_eq!(
            value(json!({"op": "harness_for_slot", "slot": slot})),
            harness
        );
        assert_eq!(
            value(json!({"op": "slot_for_harness", "harness_id": harness})),
            slot
        );
    }
}

#[test]
fn label_changes_preserve_credentials_but_endpoint_changes_rotate_account_and_profile() {
    let first = provider(PROVIDER_A, MODEL_A);
    let mut renamed = first.clone();
    renamed["configuration"]["name"] = json!("Renamed relay");
    renamed["models"][0]["name"] = json!("Renamed model");
    assert_eq!(account(&first), account(&renamed));
    assert_eq!(bind(&first, MODEL_A), bind(&renamed, MODEL_A));
    let mut moved = renamed.clone();
    moved["configuration"]["endpoint_url"] = json!("https://other.example/v1/chat/completions");
    assert_ne!(account(&first), account(&moved));
    assert_ne!(bind(&first, MODEL_A), bind(&moved, MODEL_A));
    let saved = save(&save(&empty(), &first), &moved);
    assert_eq!(saved["revision"], 2);
    assert_eq!(
        route(&saved, &logical(PROVIDER_A, MODEL_A), true)["provider_name"],
        "Renamed relay"
    );
    // A captured historical binding stays self-validating after live settings change.
    assert_eq!(
        value(json!({
            "op": "validate_binding", "binding": bind(&first, MODEL_A),
            "logical_model": logical(PROVIDER_A, MODEL_A),
            "model_harness": format!("custom-{PROVIDER_A}"),
            "endpoint_is_canonical": true
        })),
        true
    );
}

#[test]
fn exact_retry_is_idempotent_and_conflict_does_not_replace_registry() {
    let first = provider(PROVIDER_A, MODEL_A);
    let saved = save(&empty(), &first);
    assert_eq!(
        value(json!({
            "op": "registry_save", "registry": saved,
            "expected_revision": 0, "provider": first
        })),
        saved
    );
    let mut changed = first.clone();
    changed["configuration"]["name"] = json!("Concurrent edit");
    refused(
        json!({
            "op": "registry_save", "registry": saved,
            "expected_revision": 0, "provider": changed
        }),
        CONFLICT,
    );
    refused(
        json!({
            "op": "registry_save", "registry": saved,
            "expected_revision": 3, "provider": first
        }),
        CONFLICT,
    );
    assert_eq!(
        value(json!({"op": "registry_read", "registry": saved})),
        saved
    );
}

#[test]
fn wire_change_requires_new_model_id_and_retains_old_model_for_history() {
    let first = provider(PROVIDER_A, MODEL_A);
    let saved = save(&empty(), &first);
    let old_id = logical(PROVIDER_A, MODEL_A);
    let mut rebound = first.clone();
    rebound["models"][0]["wire_model"] = json!("different-wire");
    rebound["configuration"]["model_mappings"][&old_id] = json!("different-wire");
    refused(
        json!({
            "op": "registry_save", "registry": saved,
            "expected_revision": 1, "provider": rebound
        }),
        INVALID,
    );
    let replacement = provider(PROVIDER_A, MODEL_B);
    let edited = save(&saved, &replacement);
    assert_eq!(route(&edited, &old_id, true), Value::Null);
    let historical = route(&edited, &old_id, false);
    assert_eq!(historical["active"], false);
    assert_eq!(historical["wire_model"], "same-wire-model");
    assert_eq!(
        route(&edited, &logical(PROVIDER_A, MODEL_B), true)["active"],
        true
    );
    assert_eq!(
        value(json!({"op": "registry_models", "registry": edited, "include_retired": false}))
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        value(json!({"op": "registry_models", "registry": edited, "include_retired": true}))
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn removing_provider_keeps_history_and_disables_dispatch() {
    let first = provider(PROVIDER_A, MODEL_A);
    let saved = save(&empty(), &first);
    let removed = value(json!({
        "op": "registry_remove", "registry": saved,
        "expected_revision": 1, "provider_id": PROVIDER_A
    }));
    assert_eq!(removed["revision"], 2);
    assert_eq!(
        route(&removed, &logical(PROVIDER_A, MODEL_A), true),
        Value::Null
    );
    assert_eq!(
        route(&removed, &logical(PROVIDER_A, MODEL_A), false)["active"],
        false
    );
    assert_eq!(
        value(json!({"op": "registry_models", "registry": removed, "include_retired": false})),
        json!([])
    );
    assert_eq!(
        value(json!({"op": "registry_read", "registry": removed})),
        removed
    );
}

#[test]
fn corrupt_storage_or_secret_fields_are_never_repaired_or_persisted() {
    let first = provider(PROVIDER_A, MODEL_A);
    let mut unnamed = first.clone();
    unnamed["configuration"]["name"] = json!(" \t ");
    refused(
        json!({"op": "registry_save", "registry": null,
        "expected_revision": 0, "provider": unnamed}),
        INVALID,
    );
    let saved = save(&empty(), &first);
    let mut damaged = saved.clone();
    damaged["providers"][0]["models"][0]["id"] = json!("not-a-uuid");
    refused(json!({"op": "registry_read", "registry": damaged}), INVALID);
    refused(
        json!({
            "op": "registry_save", "registry": damaged,
            "expected_revision": 1, "provider": provider(PROVIDER_B, MODEL_B)
        }),
        INVALID,
    );
    for secret in ["api_key", "token", "authorization"] {
        let mut injected = first.clone();
        injected[secret] = json!("sensitive");
        refused(
            json!({"op": "registry_save", "registry": null, "expected_revision": 0, "provider": injected}),
            INVALID,
        );
        let mut injected = first.clone();
        injected["configuration"][secret] = json!("sensitive");
        refused(
            json!({"op": "registry_save", "registry": null, "expected_revision": 0, "provider": injected}),
            INVALID,
        );
    }
}

#[test]
fn custom_binding_requires_exact_namespaced_mapping_and_strict_uuid_harness() {
    let first = provider(PROVIDER_A, MODEL_A);
    let mut unmapped = first.clone();
    unmapped["configuration"]["model_mappings"] = json!({});
    refused(
        json!({
            "op": "binding", "configuration": unmapped["configuration"],
            "logical_model": logical(PROVIDER_A, MODEL_A), "model_harness": format!("custom-{PROVIDER_A}")
        }),
        "E_PROVIDER_CONFIGURATION",
    );
    refused(
        json!({
            "op": "binding", "configuration": first["configuration"],
            "logical_model": logical(PROVIDER_B, MODEL_A), "model_harness": format!("custom-{PROVIDER_A}")
        }),
        "E_PROVIDER_CONFIGURATION",
    );
    for id in [
        "custom-anything",
        "custom-11111111-1111-4111-8111-11111111111G",
    ] {
        let mut invalid = first["configuration"].clone();
        invalid["harness_id"] = json!(id);
        refused(
            json!({
                "op": "validate_configuration", "configuration": invalid,
                "harness_by_model": {logical(PROVIDER_A, MODEL_A): id}
            }),
            "E_PROVIDER_CONFIGURATION",
        );
    }
}

#[test]
fn no_key_auth_is_explicit_and_limited_to_custom_providers() {
    let mut local = provider(PROVIDER_A, MODEL_A);
    local["configuration"]["auth_type"] = json!("none");
    local["configuration"]["endpoint_url"] = json!("http://127.0.0.1:8080/v1/chat/completions");
    assert_eq!(
        value(json!({"op": "credential_required", "configuration": local["configuration"]})),
        false
    );
    assert_eq!(account(&local), Value::Null);
    assert_eq!(bind(&local, MODEL_A)["auth_type"], "none");
    let saved = save(&empty(), &local);
    assert_eq!(
        route(&saved, &logical(PROVIDER_A, MODEL_A), true)["active"],
        true
    );
    let mut builtin = local["configuration"].clone();
    builtin["harness_id"] = json!("codex");
    builtin["model_mappings"] = json!({"gpt-5.6": "same-wire-model"});
    refused(
        json!({
            "op": "validate_configuration", "configuration": builtin,
            "harness_by_model": {"gpt-5.6": "codex"}
        }),
        "E_PROVIDER_CONFIGURATION",
    );
}

#[test]
fn active_provider_capacity_refuses_addition_without_evicting_history() {
    let mut registry = empty();
    for index in 0..16 {
        let id = format!("00000000-0000-4000-8000-{index:012x}");
        registry = save(&registry, &provider(&id, MODEL_A));
    }
    let before = registry.clone();
    refused(
        json!({
            "op": "registry_save", "registry": registry,
            "expected_revision": 16, "provider": provider(PROVIDER_A, MODEL_A)
        }),
        CAPACITY,
    );
    assert_eq!(
        value(json!({"op": "registry_read", "registry": registry})),
        before
    );
}

#[test]
fn retired_providers_count_toward_total_capacity_and_remain_resolvable() {
    let mut registry = empty();
    for index in 0..32 {
        let id = format!("00000000-0000-4000-8000-{index:012x}");
        registry = save(&registry, &provider(&id, MODEL_A));
        registry = value(json!({
            "op": "registry_remove", "registry": registry,
            "expected_revision": registry["revision"], "provider_id": id
        }));
    }
    refused(
        json!({
            "op": "registry_save", "registry": registry,
            "expected_revision": registry["revision"], "provider": provider(PROVIDER_A, MODEL_A)
        }),
        CAPACITY,
    );
    let known = value(json!({
        "op": "registry_models", "registry": registry, "include_retired": true
    }));
    assert_eq!(known.as_array().unwrap().len(), 32);
    assert!(known
        .as_array()
        .unwrap()
        .iter()
        .all(|row| row["active"] == false));
}

#[test]
fn retiring_models_does_not_free_global_identity_capacity() {
    let mut registry = empty();
    for provider_index in 0..8 {
        let id = format!("00000000-0000-4000-8000-{provider_index:012x}");
        let mut entry = provider(&id, MODEL_A);
        let mut models = Vec::new();
        let mut mappings = serde_json::Map::new();
        for model_index in 0..32 {
            let model_id = format!("aaaaaaaa-aaaa-4aaa-8aaa-{model_index:012x}");
            models.push(json!({
                "id": model_id, "name": format!("Model {model_index}"),
                "wire_model": "same-wire-model", "supports_images": false, "active": true
            }));
            mappings.insert(logical(&id, &model_id), json!("same-wire-model"));
        }
        entry["models"] = json!(models);
        entry["configuration"]["model_mappings"] = Value::Object(mappings);
        registry = save(&registry, &entry);
    }
    registry = value(json!({
        "op": "registry_remove", "registry": registry,
        "expected_revision": registry["revision"],
        "provider_id": "00000000-0000-4000-8000-000000000000"
    }));
    refused(
        json!({
            "op": "registry_save", "registry": registry,
            "expected_revision": registry["revision"], "provider": provider(PROVIDER_A, MODEL_A)
        }),
        CAPACITY,
    );
    assert_eq!(
        value(json!({
            "op": "registry_models", "registry": registry, "include_retired": true
        }))
        .as_array()
        .unwrap()
        .len(),
        256
    );
}

#[test]
fn custom_session_records_require_a_trusted_model_specific_binding() {
    use crate::session_schema::{binding_key, Env, ProviderBinding};

    let custom_id = logical(PROVIDER_A, MODEL_A);
    let custom_harness = format!("custom-{PROVIDER_A}");
    let mut env = Env::default();
    env.supported_models = vec![custom_id.clone(), "gpt-5.6".into()];
    env.harness_by_model
        .insert(custom_id.clone(), custom_harness);
    env.harness_by_model
        .insert("gpt-5.6".into(), "codex".into());
    let custom_record = json!({"model": custom_id, "content": "History"});
    assert!(env.record_without_configuration(&custom_record).is_none());
    // A missing host harness mapping must not bypass the required binding.
    assert!(Env::default()
        .record_without_configuration(&custom_record)
        .is_none());
    let builtin_record = json!({"model": "gpt-5.6", "content": "Legacy history"});
    let (plain_builtin, binding) = env.record_without_configuration(&builtin_record).unwrap();
    assert_eq!(plain_builtin.as_ref(), &builtin_record);
    assert!(binding.is_none());

    let captured = bind(&provider(PROVIDER_A, MODEL_A), MODEL_A);
    let mut bound_record = custom_record.clone();
    bound_record["provider_configuration"] = captured.clone();
    // A self-consistent JSON binding alone does not establish a trusted host fact.
    assert!(env.record_without_configuration(&bound_record).is_none());
    env.provider_bindings.push(ProviderBinding {
        canonical_sha256: binding_key(&captured, bound_record.get("model")).unwrap(),
        valid: true,
        host: Some("relay.example".into()),
    });
    let (plain_custom, binding) = env.record_without_configuration(&bound_record).unwrap();
    assert_eq!(plain_custom.as_ref(), &custom_record);
    assert_eq!(binding.unwrap().host.as_deref(), Some("relay.example"));

    let mut altered = bound_record.clone();
    altered["provider_configuration"]["endpoint_url"] =
        json!("https://other.example/v1/chat/completions");
    assert!(env.record_without_configuration(&altered).is_none());
    let mut another_model = bound_record.clone();
    another_model["model"] = json!(logical(PROVIDER_A, MODEL_B));
    assert!(env.record_without_configuration(&another_model).is_none());
    env.provider_bindings[0].valid = false;
    assert!(env.record_without_configuration(&bound_record).is_none());
}

#[test]
fn retired_model_and_provider_uuids_cannot_be_reactivated() {
    let first = provider(PROVIDER_A, MODEL_A);
    let saved = save(&empty(), &first);
    let replacement = provider(PROVIDER_A, MODEL_B);
    let changed = save(&saved, &replacement);
    refused(
        json!({
            "op": "registry_save", "registry": changed,
            "expected_revision": changed["revision"], "provider": first
        }),
        INVALID,
    );
    assert_eq!(
        route(&changed, &logical(PROVIDER_A, MODEL_A), false)["active"],
        false
    );

    let removed = value(json!({
        "op": "registry_remove", "registry": changed,
        "expected_revision": changed["revision"], "provider_id": PROVIDER_A
    }));
    refused(
        json!({
            "op": "registry_save", "registry": removed,
            "expected_revision": removed["revision"], "provider": replacement
        }),
        INVALID,
    );
    assert_eq!(
        route(&removed, &logical(PROVIDER_A, MODEL_B), false)["active"],
        false
    );
}

#[test]
fn serialized_capacity_never_saves_a_registry_that_cannot_be_read_or_edited() {
    let mut registry = empty();
    for provider_index in 1..=16 {
        let id = format!("{provider_index:08x}-1111-4111-8111-111111111111");
        let mut next = provider(&id, MODEL_A);
        next["configuration"]["endpoint_url"] =
            json!(format!("https://relay.example/{}", "x".repeat(2000)));
        let mut mappings = serde_json::Map::new();
        let mut models = Vec::new();
        for model_index in 1..=16 {
            let model = format!("{model_index:08x}-2222-4222-8222-222222222222");
            let wire = "w".repeat(128);
            mappings.insert(logical(&id, &model), json!(wire));
            models.push(json!({"id":model,"name":"模".repeat(80),"wire_model":wire,
                "supports_images":false,"active":true}));
        }
        next["models"] = json!(models);
        next["configuration"]["model_mappings"] = json!(mappings);
        let result = invoke(json!({"op":"registry_save","registry":registry,
            "expected_revision":registry["revision"],"provider":next}));
        if result["ok"] == false {
            assert_eq!(result["error"], CAPACITY);
            let mut oversized = registry.clone();
            oversized["providers"].as_array_mut().unwrap().push(next);
            assert!(oversized.to_string().len() > super::MAX_REGISTRY_BYTES);
            assert!(oversized.to_string().len() < crate::strict_json::MAX_ARGUMENTS_BYTES - 100);
            refused(json!({"op":"registry_read","registry":oversized}), CAPACITY);
            assert_eq!(
                value(json!({"op":"registry_read","registry":registry})),
                registry
            );
            return;
        }
        registry = result["value"].clone();
        assert!(registry.to_string().len() <= super::MAX_REGISTRY_BYTES);
    }
    panic!("long bounded metadata should hit the serialized limit before entity limits");
}

#[test]
fn custom_model_namespace_query_preserves_opaque_legacy_dsh_identities() {
    assert_eq!(
        value(json!({"op":"is_custom_model","model_id":logical(PROVIDER_A,MODEL_A)})),
        true
    );
    for model in [
        "custom:my-llama",
        "custom:",
        "gpt-5.6",
        "custom:11111111-1111-4111-8111-111111111111:not-uuid",
    ] {
        assert_eq!(
            value(json!({"op":"is_custom_model","model_id":model})),
            false
        );
    }
}

#[test]
fn provider_can_store_credentials_before_discovery_and_retire_last_model_without_deletion() {
    let mut waiting = provider(PROVIDER_A, MODEL_A);
    waiting["models"] = json!([]);
    waiting["configuration"]["model_mappings"] = json!({});
    let initial = save(&empty(), &waiting);
    assert_eq!(initial["providers"][0]["active"], true);
    assert!(
        value(json!({"op":"registry_models","registry":initial,"include_retired":true}))
            .as_array()
            .unwrap()
            .is_empty()
    );
    let before = value(
        json!({"op":"credential_account","slot":format!("CUSTOM_API_KEY_{PROVIDER_A}"),"configuration":waiting["configuration"]}),
    );
    let configured = save(&initial, &provider(PROVIDER_A, MODEL_A));
    let retired = save(&configured, &waiting);
    assert_eq!(retired["providers"][0]["active"], true);
    assert_eq!(retired["providers"][0]["models"][0]["active"], false);
    assert_eq!(
        route(&retired, &logical(PROVIDER_A, MODEL_A), true),
        Value::Null
    );
    assert_eq!(
        value(
            json!({"op":"credential_account","slot":format!("CUSTOM_API_KEY_{PROVIDER_A}"),"configuration":retired["providers"][0]["configuration"]})
        ),
        before
    );
    assert_eq!(
        value(json!({"op":"registry_read","registry":retired})),
        retired
    );
}
