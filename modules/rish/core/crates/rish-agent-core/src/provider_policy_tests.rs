use super::*;
use crate::canonical::canonical_json;

fn invoke(request: Value) -> Value {
    serde_json::from_str(&reduce_json(&request.to_string())).unwrap()
}

fn value(request: Value) -> Value {
    let result = invoke(request);
    assert_eq!(result["ok"], true, "{result}");
    result["value"].clone()
}

fn refused(request: Value) {
    assert_eq!(
        invoke(request),
        json!({"ok": false, "error": "E_PROVIDER_CONFIGURATION"})
    );
}

fn profile() -> Value {
    json!({"schema_version": 1, "harness_id": "codex", "name": "Relay",
        "endpoint_url": "https://relay.example/v1/responses", "protocol": "responses",
        "auth_type": "bearer", "send_reasoning": true, "model_mappings": {"gpt-5.6": "wire/model"}})
}

fn validate(config: Value) -> Value {
    json!({"op": "validate_configuration", "configuration": config,
        "harness_by_model": {"gpt-5.6": "codex"}})
}

fn bind(config: Value) -> Value {
    json!({"op": "binding", "configuration": config, "logical_model": "gpt-5.6", "model_harness": "codex"})
}

fn account(config: Value) -> Value {
    json!({"op": "credential_account", "slot": "OPENAI_API_KEY", "configuration": config})
}

fn endpoint(path: &str, dialect: &str, full: bool) -> Value {
    json!({"op": "endpoint_plan", "codec": "foundation", "raw": format!("https://relay.example{path}"),
        "protocol": dialect, "full_url": full, "parts": {"scheme": "https",
        "host": "relay.example", "port": null, "has_user": false, "has_password": false,
        "has_query": false, "has_fragment": false, "path": path}})
}

#[test]
fn codec_is_explicit_and_only_known_compatibility_rules_are_accepted() {
    let mut request = endpoint("/responses/responses", "responses", false);
    assert_eq!(value(request.clone())["path"], "/responses");
    request["codec"] = json!("okhttp");
    assert_eq!(value(request.clone())["path"], "/responses/responses");
    for bad in [
        Value::Null,
        json!(true),
        json!("unknown"),
        json!("Foundation"),
    ] {
        request["codec"] = bad;
        refused(request.clone());
    }
    request.as_object_mut().unwrap().remove("codec");
    refused(request);
}

#[test]
fn repeated_suffix_save_read_and_credential_identity_preserve_each_old_codec() {
    let corpus: Value = serde_json::from_str(include_str!(
        "../../../fixtures/provider-policy-codec-golden.json"
    ))
    .unwrap();
    for case in corpus["cases"].as_array().unwrap() {
        let normalize = |config: &Value| {
            let raw = config["endpoint_url"].as_str().unwrap();
            let mut request = endpoint(
                raw.strip_prefix("https://relay.example").unwrap(),
                config["protocol"].as_str().unwrap(),
                false,
            );
            request["codec"] = case["codec"].clone();
            let plan = value(request);
            let mut changed = config.clone();
            changed["endpoint_url"] = json!(format!(
                "https://relay.example{}",
                plan["path"].as_str().unwrap()
            ));
            value(
                json!({"op": "validate_configuration", "configuration": changed,
                "harness_by_model": {"claude-sonnet-5": "claude-code"}}),
            )
        };
        let saved = normalize(&case["configuration"]);
        assert_eq!(saved, case["saved"], "{} save", case["name"]);
        let read = normalize(&saved);
        assert_eq!(read, case["read"], "{} read", case["name"]);
        assert_eq!(
            value(
                json!({"op": "binding", "configuration": read, "logical_model": "claude-sonnet-5",
            "model_harness": "claude-code"})
            ),
            case["binding"],
            "{} binding",
            case["name"]
        );
        assert_eq!(
            value(
                json!({"op": "credential_account", "slot": "ANTHROPIC_API_KEY", "configuration": read})
            ),
            case["credential_account"],
            "{} account",
            case["name"]
        );
    }
}

#[test]
fn official_defaults_and_slots_remain_unchanged() {
    assert_eq!(
        value(json!({"op": "harnesses"})),
        json!(["claude-code", "codex", "dsh", "glm"])
    );
    for (harness, slot, url, dialect, auth) in [
        (
            "claude-code",
            "ANTHROPIC_API_KEY",
            "https://api.anthropic.com/v1/messages",
            "messages",
            "x-api-key",
        ),
        (
            "codex",
            "OPENAI_API_KEY",
            "https://api.openai.com/v1/responses",
            "responses",
            "bearer",
        ),
        (
            "dsh",
            "DEEPSEEK_API_KEY",
            "https://api.deepseek.com/chat/completions",
            "chat-completions",
            "bearer",
        ),
        (
            "glm",
            "BIGMODEL_API_KEY",
            "https://open.bigmodel.cn/api/anthropic/v1/messages",
            "messages",
            "x-api-key",
        ),
    ] {
        let expected = json!({"schema_version": 1, "harness_id": harness, "name": "", "endpoint_url": url,
            "protocol": dialect, "auth_type": auth, "model_mappings": {}, "send_reasoning": true, "official": true});
        assert_eq!(
            value(json!({"op": "defaults", "harness_id": harness})),
            expected
        );
        assert_eq!(
            value(json!({"op": "harness_for_slot", "slot": slot})),
            harness
        );
        assert_eq!(
            value(json!({"op": "slot_for_harness", "harness_id": harness})),
            slot
        );
        assert_eq!(
            value(json!({"op": "credential_account", "slot": slot, "configuration": expected})),
            slot
        );
        assert_eq!(
            value(
                json!({"op": "binding", "configuration": expected, "logical_model": "official-model", "model_harness": harness})
            ),
            Value::Null
        );
    }
    assert_eq!(
        value(json!({"op": "harness_for_slot", "slot": "OTHER_KEY"})),
        Value::Null
    );
    assert_eq!(
        value(json!({"op": "slot_for_harness", "harness_id": "unknown"})),
        Value::Null
    );
    refused(json!({"op": "defaults", "harness_id": "unknown"}));
}

#[test]
fn endpoint_policy_changes_only_the_suffix_and_case() {
    for (path, dialect, expected) in [
        ("", "messages", "/v1/messages"),
        ("/", "responses", "/v1/responses"),
        ("/v1///", "chat-completions", "/v1/chat/completions"),
        ("/api/anthropic", "messages", "/api/anthropic/v1/messages"),
        (
            "/api/anthropic/v1/messages",
            "responses",
            "/api/anthropic/v1/responses",
        ),
        ("/chat/completions", "messages", "/messages"),
        ("/v1/responses/", "chat-completions", "/v1/chat/completions"),
        ("/x%2Fy", "messages", "/x%2Fy/v1/messages"),
        ("/x/y", "messages", "/x/y/v1/messages"),
        ("/中文", "messages", "/中文/v1/messages"),
    ] {
        let mut request = endpoint(path, dialect, false);
        request["parts"]["scheme"] = json!("HTTPS");
        request["parts"]["host"] = json!("Relay.Example");
        assert_eq!(
            value(request),
            json!({"scheme": "https", "host": "relay.example", "path": expected})
        );
    }
    for path in [
        "",
        "/custom/",
        "/x%2Fy",
        "/x%2fy",
        "/foo/../bar",
        "/messages",
    ] {
        assert_eq!(value(endpoint(path, "messages", true))["path"], path);
    }
}

#[test]
fn endpoint_facts_reject_unsafe_transport_and_ambiguous_types() {
    for key in ["has_user", "has_password", "has_query", "has_fragment"] {
        let mut request = endpoint("/v1", "messages", false);
        request["parts"][key] = json!(true);
        refused(request.clone());
        request["parts"][key] = json!(0);
        refused(request);
    }
    for host in ["localhost", "127.0.0.1", "::1", "[::1]"] {
        let mut request = endpoint("/v1", "messages", false);
        request["parts"]["scheme"] = json!("HTTP");
        request["parts"]["host"] = json!(host);
        assert_eq!(value(request)["scheme"], "http");
    }
    for (key, bad) in [
        ("scheme", json!("http")),
        ("scheme", json!("ftp")),
        ("host", json!("")),
        ("host", json!("bad host")),
        ("port", json!(0)),
        ("port", json!(65536)),
        ("port", json!(-1)),
        ("port", json!(443.5)),
        ("port", json!(true)),
        ("path", json!("relative")),
    ] {
        let mut request = endpoint("/v1", "messages", false);
        request["parts"][key] = bad;
        refused(request);
    }
    for port in [1, 80, 443, 65535] {
        let mut request = endpoint("/", "messages", false);
        request["parts"]["port"] = json!(port);
        assert_eq!(value(request)["path"], "/v1/messages");
    }
    let mut extra = endpoint("/", "messages", false);
    extra["parts"]["userinfo"] = json!(false);
    refused(extra);
    let mut bad_protocol = endpoint("/", "messages", false);
    bad_protocol["protocol"] = json!("openai-chat");
    refused(bad_protocol);
}

#[test]
fn raw_endpoint_limits_apply_before_platform_decoding() {
    let mut request = endpoint("/", "messages", false);
    request["raw"] = json!("é".repeat(1024));
    assert!(invoke(request.clone())["ok"].as_bool().unwrap());
    for bad in [
        "é".repeat(1025),
        "".into(),
        "https://a/\n".into(),
        "https://a/\u{200b}".into(),
    ] {
        request["raw"] = json!(bad);
        refused(request.clone());
    }
    // The native codec owns decoding/re-encoding of a percent escape. Applying
    // raw-text policy to these decoded path facts would alter existing URLs.
    request["raw"] = json!("https://relay.example/%0A");
    request["parts"]["path"] = json!("/\n");
    assert_eq!(value(request)["path"], "/\n/v1/messages");
}

#[test]
fn configuration_is_strict_and_normalization_is_non_destructive() {
    let original = profile();
    let normalized = value(validate(original.clone()));
    let mut expected = original.clone();
    expected["full_url"] = json!(false);
    assert_eq!(normalized, expected);
    for (key, bad) in [
        ("schema_version", json!(true)),
        ("schema_version", json!(1.5)),
        ("harness_id", json!("unknown")),
        ("protocol", json!("openai-chat")),
        ("auth_type", json!("query-key")),
        ("name", json!("")),
        ("name", json!("中".repeat(27))),
        ("name", json!("x\u{0085}")),
        ("send_reasoning", json!(1)),
        ("full_url", Value::Null),
        ("model_mappings", json!([])),
        ("endpoint_url", json!("")),
        ("api_key", json!("do-not-persist")),
        ("official", json!(true)),
    ] {
        let mut invalid = original.clone();
        invalid[key] = bad;
        refused(validate(invalid));
    }
    for key in CONFIG_KEYS {
        let mut invalid = original.clone();
        invalid.as_object_mut().unwrap().remove(key);
        refused(validate(invalid));
    }
    let mut unicode = original;
    unicode["name"] = json!("é".repeat(40));
    unicode["model_mappings"]["gpt-5.6"] = json!("é".repeat(64));
    assert_eq!(
        value(validate(unicode.clone()))["model_mappings"],
        unicode["model_mappings"]
    );
    unicode["model_mappings"]["gpt-5.6"] = json!("é".repeat(65));
    refused(validate(unicode));
}

#[test]
fn mappings_follow_host_catalog_including_retired_dynamic_models() {
    let mut config = profile();
    config["harness_id"] = json!("dsh");
    config["model_mappings"] = json!({"retired-custom-dsh": "vendor/retired"});
    assert!(invoke(
        json!({"op": "validate_configuration", "configuration": config,
        "harness_by_model": {"retired-custom-dsh": "dsh"}})
    )["ok"]
        .as_bool()
        .unwrap());
    for catalog in [
        json!({}),
        json!({"retired-custom-dsh": "codex"}),
        json!({"retired-custom-dsh": true}),
    ] {
        refused(
            json!({"op": "validate_configuration", "configuration": config, "harness_by_model": catalog}),
        );
    }
    let mut mappings = Map::new();
    let mut catalog = Map::new();
    for index in 0..33 {
        let model = format!("custom-{index}");
        mappings.insert(model.clone(), json!("wire"));
        catalog.insert(model, json!("dsh"));
    }
    config["model_mappings"] = json!(mappings);
    refused(
        json!({"op": "validate_configuration", "configuration": config, "harness_by_model": catalog}),
    );
    config["model_mappings"]
        .as_object_mut()
        .unwrap()
        .remove("custom-32");
    assert!(invoke(json!({"op": "validate_configuration", "configuration": config, "harness_by_model": catalog}))["ok"].as_bool().unwrap());
}

#[test]
fn independent_legacy_hash_vectors_remain_byte_exact() {
    let golden: Value = serde_json::from_str(include_str!(
        "../../../fixtures/provider-policy-golden.json"
    ))
    .unwrap();
    for case in golden["cases"].as_array().unwrap() {
        let identity = &case["identity"];
        assert_eq!(
            String::from_utf8(canonical_json(identity).unwrap()).unwrap(),
            case["binding_canonical"].as_str().unwrap()
        );
        assert_eq!(
            value(json!({"op": "profile_digest", "identity": identity})),
            case["profile_id"]
        );
        assert_eq!(
            String::from_utf8(canonical_json(&case["credential_identity"]).unwrap()).unwrap(),
            case["credential_canonical"].as_str().unwrap()
        );
        let mut config = identity.clone();
        config.as_object_mut().unwrap().remove("model_id");
        config["name"] = json!("姓名不参与摘要😀");
        config["model_mappings"] =
            json!({case["logical_model"].as_str().unwrap(): identity["model_id"]});
        let mut binding = identity.clone();
        binding["profile_id"] = case["profile_id"].clone();
        assert_eq!(
            value(json!({"op": "binding", "configuration": config,
            "logical_model": case["logical_model"], "model_harness": identity["harness_id"]})),
            binding
        );
        let slot = slot_for_harness(identity["harness_id"].as_str().unwrap()).unwrap();
        assert_eq!(
            value(json!({"op": "credential_account", "slot": slot, "configuration": config})),
            case["credential_account"]
        );
    }
}

#[test]
fn actual_pre_migration_ios_binding_and_account_outputs_remain_unchanged() {
    let golden: Value = serde_json::from_str(include_str!(
        "../../../fixtures/provider-policy-golden.json"
    ))
    .unwrap();
    for case in golden["legacy_ios_cases"].as_array().unwrap() {
        let profile = &case["normalized"];
        let model = "claude-sonnet-5";
        assert_eq!(
            value(
                json!({"op": "validate_configuration", "configuration": profile,
            "harness_by_model": {model: "claude-code"}})
            ),
            *profile
        );
        assert_eq!(
            value(json!({"op": "binding", "configuration": profile,
            "logical_model": model, "model_harness": "claude-code"})),
            case["binding"]
        );
        assert_eq!(
            value(
                json!({"op": "credential_account", "slot": "ANTHROPIC_API_KEY",
            "configuration": profile})
            ),
            case["credential_account"]
        );
        assert_eq!(
            value(json!({"op": "validate_binding", "binding": case["binding"],
            "logical_model": model, "model_harness": "claude-code", "endpoint_is_canonical": true})),
            true
        );
    }
}

#[test]
fn account_identity_ignores_presentation_model_and_reasoning_but_not_transport() {
    let config = profile();
    let initial = value(account(config.clone()));
    for (key, changed) in [
        ("name", json!("Renamed")),
        ("send_reasoning", json!(false)),
        ("model_mappings", json!({"gpt-5.6": "other-model"})),
        ("full_url", json!(true)),
    ] {
        let mut edited = config.clone();
        edited[key] = changed;
        assert_eq!(value(account(edited)), initial);
    }
    for (key, changed) in [
        ("endpoint_url", json!("https://other.example/v1/responses")),
        ("protocol", json!("messages")),
        ("auth_type", json!("api-key")),
    ] {
        let mut edited = config.clone();
        edited[key] = changed;
        assert_ne!(value(account(edited)), initial);
    }
    assert_eq!(value(account(Value::Null)), Value::Null);
    assert_eq!(
        value(json!({"op": "credential_account", "slot": "OTHER_SLOT", "configuration": null})),
        "OTHER_SLOT"
    );
    let mut wrong = config.clone();
    wrong["harness_id"] = json!("dsh");
    refused(account(wrong));
    let mut forged = config;
    forged["official"] = json!(true);
    refused(account(forged));
}

#[test]
fn human_labels_keep_emoji_format_characters_without_relaxing_identifiers() {
    let original = profile();
    let original_binding = value(bind(original.clone()));
    let original_account = value(account(original.clone()));
    for label in ["👩‍💻 Relay", "团队\u{200b}空间", "\u{200e}Relay"] {
        let mut changed = original.clone();
        changed["name"] = json!(label);
        let normalized = value(validate(changed));
        assert_eq!(normalized["name"], label);
        assert_eq!(value(bind(normalized.clone())), original_binding);
        assert_eq!(value(account(normalized)), original_account);
    }
    assert!(original_binding.get("name").is_none());
    for format in ["\u{200b}", "\u{200d}", "\u{200e}"] {
        let mut invalid = original.clone();
        invalid["model_mappings"]["gpt-5.6"] = json!(format!("wire{format}model"));
        refused(validate(invalid.clone()));
        refused(bind(invalid));
        let mut invalid = original.clone();
        invalid["endpoint_url"] = json!(format!("https://relay.example/{format}responses"));
        refused(validate(invalid));
        let mut invalid = endpoint("/responses", "responses", false);
        invalid["raw"] = json!(format!("https://relay.example/{format}responses"));
        refused(invalid);
    }
    for label in ["", "\n", "Relay\u{007f}", "Relay\u{0085}"] {
        let mut invalid = original.clone();
        invalid["name"] = json!(label);
        refused(validate(invalid));
    }
}

#[test]
fn binding_validation_rejects_tampering_mismatches_and_noncanonical_endpoints() {
    let binding = value(bind(profile()));
    let request = json!({"op": "validate_binding", "binding": binding, "logical_model": "gpt-5.6",
        "model_harness": "codex", "endpoint_is_canonical": true});
    assert_eq!(value(request.clone()), true);
    for (key, bad) in [
        ("model_id", json!("other-model")),
        ("model_id", json!("has space")),
        ("schema_version", json!(true)),
        ("send_reasoning", json!(0)),
        ("extra", json!(1)),
        ("profile_id", json!("0".repeat(64))),
        ("endpoint_url", json!("HTTPS://relay.example/v1/responses")),
    ] {
        let mut invalid = request.clone();
        invalid["binding"][key] = bad;
        assert_eq!(value(invalid), false);
    }
    for (key, bad) in [
        ("logical_model", Value::Null),
        ("model_harness", json!("dsh")),
        ("endpoint_is_canonical", json!(false)),
        ("binding", json!("not-object")),
    ] {
        let mut invalid = request.clone();
        invalid[key] = bad;
        assert_eq!(value(invalid), false);
    }
    let mut wrong = bind(profile());
    wrong["model_harness"] = json!("dsh");
    refused(wrong);
    let mut invalid = profile();
    invalid["model_mappings"]["gpt-5.6"] = json!("中".repeat(43));
    refused(bind(invalid));
}

#[test]
fn strict_envelopes_and_duplicate_keys_fail_without_echoing_values() {
    for input in [
        "null",
        "[]",
        "{}",
        "{\"op\":\"harnesses\",\"op\":\"defaults\"}",
    ] {
        assert_eq!(
            serde_json::from_str::<Value>(&reduce_json(input)).unwrap(),
            json!({"ok": false, "error": "E_PROVIDER_CONFIGURATION"})
        );
    }
    refused(json!({"op": "harnesses", "extra": "secret-value"}));
    refused(json!({"op": "profile_digest", "identity": "secret-value"}));
    refused(json!({"op": "binding", "configuration": profile(), "logical_model": "gpt-5.6"}));
    let mut request = validate(profile());
    request["credential"] = json!("secret-value");
    refused(request);
}

#[test]
fn native_hosts_and_core_share_the_same_request_response_corpus() {
    let corpus: Value =
        serde_json::from_str(include_str!("../../../fixtures/provider-policy.json")).unwrap();
    for case in corpus["cases"].as_array().unwrap() {
        assert_eq!(
            invoke(case["input"].clone()),
            case["expected"],
            "{}",
            case["name"]
        );
    }
}
