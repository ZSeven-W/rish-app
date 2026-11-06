use super::*;

fn row(id: &str) -> Value {
    json!({"id":id,"name":id,"supports_images":false})
}
fn request(revision: u64, harness: &str, models: Vec<Value>) -> Value {
    json!({"schema_version":1,"expected_revision":revision,"harness_id":harness,"models":models})
}
fn save(old: &Value, harness: &str, models: Vec<Value>) -> Value {
    save_registry(
        old,
        &request(old["revision"].as_u64().unwrap_or(0), harness, models),
        &Value::Null,
        &[],
    )
    .unwrap()
}
fn empty() -> Value {
    read_registry(&Value::Null, &Value::Null, &[]).unwrap()
}
fn active(registry: &Value) -> Value {
    models(registry, &Value::Null, &[], false).unwrap()
}

#[test]
fn absence_publishes_no_models_but_keeps_legacy_history_routing() {
    let registry = empty();
    assert_eq!(registry["providers"].as_array().unwrap().len(), 4);
    assert_eq!(active(&registry), json!([]));
    assert_eq!(
        models(&registry, &Value::Null, &[], true).unwrap(),
        json!([])
    );
    for (id, owner) in model_catalog::BUILTIN_MODELS {
        assert_eq!(
            harness(&registry, &Value::Null, &[], id)
                .unwrap()
                .as_deref(),
            Some(*owner)
        );
    }
    assert_eq!(
        harness(&registry, &Value::Null, &[], "unknown").unwrap(),
        None
    );
}

#[test]
fn only_explicit_legacy_dsh_rows_are_projected_without_mutating_storage() {
    let legacy = json!({"schema_version":1,"models":[row("user-saved-model")],"retired_models":[row("older-model")]});
    let before = legacy.clone();
    let registry = read_registry(&Value::Null, &legacy, &[]).unwrap();
    assert_eq!(registry["providers"][0]["models"], legacy["models"]);
    assert_eq!(
        registry["providers"][0]["retired_models"],
        legacy["retired_models"]
    );
    assert_eq!(registry["revision"], 0);
    assert_eq!(legacy, before);
    let saved = save_registry(&registry, &request(0, "dsh", vec![]), &legacy, &[]).unwrap();
    assert!(saved["providers"][0]["models"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        read_registry(&saved, &legacy, &[]).unwrap(),
        saved,
        "Old storage cannot reactivate removed rows"
    );
}

#[test]
fn explicit_models_for_all_providers_have_stable_owner_and_image_capability() {
    let mut registry = empty();
    for (index, owner) in HARNESSES.iter().enumerate() {
        let mut entry = row(&format!("fetched-{index}"));
        entry["supports_images"] = json!(index % 2 == 0);
        registry = save(&registry, owner, vec![entry.clone()]);
        assert_eq!(
            harness(&registry, &Value::Null, &[], entry["id"].as_str().unwrap())
                .unwrap()
                .as_deref(),
            Some(*owner)
        );
    }
    assert_eq!(active(&registry).as_array().unwrap().len(), 4);
    assert_eq!(active(&registry)[0]["supports_images"], true);
    assert_eq!(active(&registry)[1]["supports_images"], false);
    assert_eq!(registry["revision"], 4);
}

#[test]
fn global_cas_and_exact_retry_preserve_concurrent_other_provider_changes() {
    let one = save(&empty(), "dsh", vec![row("one")]);
    let two = save(&one, "glm", vec![row("two")]);
    assert_eq!(
        save_registry(
            &two,
            &request(0, "dsh", vec![row("one")]),
            &Value::Null,
            &[]
        )
        .unwrap(),
        two
    );
    assert!(save_registry(
        &two,
        &request(0, "dsh", vec![row("changed")]),
        &Value::Null,
        &[]
    )
    .is_err());
    assert!(save_registry(
        &two,
        &request(3, "dsh", vec![row("one")]),
        &Value::Null,
        &[]
    )
    .is_err());
    assert_eq!(two["providers"][3]["models"][0]["id"], "two");
}

#[test]
fn retirement_keeps_history_and_explicit_same_owner_reactivation() {
    let first = save(&empty(), "claude-code", vec![row("manual-messages-model")]);
    let removed = save(&first, "claude-code", vec![]);
    assert_eq!(active(&removed), json!([]));
    assert_eq!(
        harness(&removed, &Value::Null, &[], "manual-messages-model")
            .unwrap()
            .as_deref(),
        Some("claude-code")
    );
    assert_eq!(
        models(&removed, &Value::Null, &[], true).unwrap()[0]["active"],
        false
    );
    assert!(
        save_registry(
            &removed,
            &request(1, "claude-code", vec![row("manual-messages-model")]),
            &Value::Null,
            &[]
        )
        .is_err(),
        "Stale retry cannot revive a retired model"
    );
    let revived = save(&removed, "claude-code", vec![row("manual-messages-model")]);
    assert!(revived["providers"][1]["retired_models"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(active(&revived)[0]["harness_id"], "claude-code");
}

#[test]
fn static_legacy_saved_and_retired_ids_cannot_move_to_another_provider() {
    let base = empty();
    for (id, owner) in model_catalog::BUILTIN_MODELS {
        let other = if *owner == "dsh" { "codex" } else { "dsh" };
        assert!(
            save_registry(&base, &request(0, other, vec![row(id)]), &Value::Null, &[]).is_err()
        );
    }
    let own = save(&base, "glm", vec![row("future-model")]);
    let retired = save(&own, "glm", vec![]);
    assert!(save_registry(
        &retired,
        &request(2, "codex", vec![row("future-model")]),
        &Value::Null,
        &[]
    )
    .is_err());
    let legacy = json!({"schema_version":1,"models":[row("gpt-user-relay")],"retired_models":[]});
    assert!(save_registry(
        &base,
        &request(0, "codex", vec![row("gpt-user-relay")]),
        &legacy,
        &[]
    )
    .is_err());
}

#[test]
fn late_subscription_discovery_does_not_reroute_an_existing_registration() {
    let discovered: Vec<String> = vec!["gpt-subscription-new".into()];
    assert!(save_registry(
        &Value::Null,
        &request(0, "dsh", vec![row(&discovered[0])]),
        &Value::Null,
        &discovered
    )
    .is_err());
    let registered_first = save(&empty(), "dsh", vec![row(&discovered[0])]);
    assert_eq!(
        read_registry(&registered_first, &Value::Null, &discovered).unwrap(),
        registered_first
    );
    assert_eq!(
        harness(&registered_first, &Value::Null, &discovered, &discovered[0])
            .unwrap()
            .as_deref(),
        Some("dsh")
    );
    assert_eq!(
        harness(&empty(), &Value::Null, &discovered, &discovered[0])
            .unwrap()
            .as_deref(),
        Some("codex")
    );
    assert_eq!(
        active(&empty()),
        json!([]),
        "Subscription history never becomes API choices"
    );
}

#[test]
fn independent_namespace_cannot_be_claimed_and_opaque_legacy_rows_remain_readable() {
    let independent =
        "custom:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    let legacy = json!({"schema_version":1,"models":[row(independent),row("custom:my-llama")],"retired_models":[]});
    let registry = read_registry(&Value::Null, &legacy, &[]).unwrap();
    assert_eq!(
        registry["providers"][0]["models"],
        json!([row("custom:my-llama")])
    );
    assert_eq!(harness(&registry, &legacy, &[], independent).unwrap(), None);
    assert_eq!(
        harness(&registry, &legacy, &[], "custom:my-llama")
            .unwrap()
            .as_deref(),
        Some("dsh")
    );
    for id in [independent, "custom:new"] {
        assert!(save_registry(
            &empty(),
            &request(0, "dsh", vec![row(id)]),
            &Value::Null,
            &[]
        )
        .is_err());
    }
}

#[test]
fn active_and_history_limits_fail_without_evicting_prior_identity() {
    let rows = |count| {
        (0..count)
            .map(|n| row(&format!("m-{n}")))
            .collect::<Vec<_>>()
    };
    assert!(save_registry(&empty(), &request(0, "glm", rows(32)), &Value::Null, &[]).is_ok());
    assert!(save_registry(&empty(), &request(0, "glm", rows(33)), &Value::Null, &[]).is_err());
    let mut full = empty();
    full["providers"][0]["retired_models"] = json!(rows(256));
    assert!(read_registry(&full, &Value::Null, &[]).is_ok());
    let with_current = save(&full, "codex", vec![row("one-current")]);
    assert!(save_registry(
        &with_current,
        &request(1, "codex", vec![]),
        &Value::Null,
        &[]
    )
    .is_err());
    assert_eq!(
        with_current["providers"][2]["models"],
        json!([row("one-current")])
    );
}

#[test]
fn schema_shape_duplicates_controls_and_revision_bounds_are_strict() {
    let base = empty();
    for bad in [
        json!({}),
        json!(false),
        json!({"schema_version":1,"revision":0,"providers":false}),
    ] {
        assert!(read_registry(&bad, &Value::Null, &[]).is_err());
    }
    for version in [json!(true), json!(1.0), json!("1")] {
        let mut bad = base.clone();
        bad["schema_version"] = version;
        assert!(read_registry(&bad, &Value::Null, &[]).is_err());
    }
    for value in [
        json!(-1),
        json!(1.5),
        json!(true),
        json!(crate::schema::MAX_SAFE_INTEGER + 1),
    ] {
        let mut bad = base.clone();
        bad["revision"] = value;
        assert!(read_registry(&bad, &Value::Null, &[]).is_err());
    }
    let mut bad = base.clone();
    bad["providers"][1]["harness_id"] = json!("dsh");
    assert!(read_registry(&bad, &Value::Null, &[]).is_err());
    for id in ["", " leading", "with space", "secret\nline", "💡"] {
        assert!(
            save_registry(&base, &request(0, "glm", vec![row(id)]), &Value::Null, &[]).is_err()
        );
    }
    let mut label = row("valid");
    label["name"] = json!(" x\u{200d}y ");
    assert!(save_registry(&base, &request(0, "glm", vec![label]), &Value::Null, &[]).is_err());
    let mut label = row("valid");
    label["name"] = json!("  A friendly name  ");
    assert_eq!(
        save(&base, "glm", vec![label])["providers"][3]["models"][0]["name"],
        "A friendly name"
    );
    assert!(save_registry(
        &base,
        &request(0, "glm", vec![row("duplicate"), row("duplicate")]),
        &Value::Null,
        &[]
    )
    .is_err());
}

#[test]
fn damaged_legacy_and_optional_sources_are_not_silently_dropped() {
    assert!(read_registry(&empty(), &json!({"bad":true}), &[]).is_err());
    assert!(read_registry(&empty(), &Value::Null, &["untrusted model".into()]).is_err());
    let mut registry = empty();
    registry["providers"][0]["models"] = json!([row("x")]);
    registry["providers"][1]["retired_models"] = json!([row("x")]);
    assert!(read_registry(&registry, &Value::Null, &[]).is_err());
}

#[test]
fn json_reducer_exposes_only_bounded_explicit_catalog_operations() {
    let call = |value: Value| {
        serde_json::from_str::<Value>(&model_catalog::reduce_json(&value.to_string())).unwrap()
    };
    let registry = call(json!({"op":"provider_read","registry":null}));
    assert_eq!(registry["ok"], true);
    let saved = call(
        json!({"op":"provider_save","registry":registry["value"],"request":request(0,"glm",vec![row("glm-current")])}),
    );
    assert_eq!(saved["ok"], true);
    assert_eq!(
        call(json!({"op":"provider_models","registry":saved["value"],"include_retired":false}))
            ["value"][0]["id"],
        "glm-current"
    );
    assert_eq!(
        call(json!({"op":"provider_harness","registry":saved["value"],"model":"glm-current"}))
            ["value"],
        "glm"
    );
    for bad in [
        json!({"op":"provider_read","registry":null,"extra":true}),
        json!({"op":"provider_models","registry":null}),
        json!({"op":"provider_read","registry":null,"discovered_models":null}),
    ] {
        assert_eq!(call(bad)["ok"], false);
    }
}

#[test]
fn legacy_active_metadata_keeps_precedence_over_duplicate_retired_rows() {
    let mut old = row("same");
    old["name"] = json!("Older label");
    let legacy = json!({"schema_version":1,"models":[row("same")],"retired_models":[old]});
    let registry = read_registry(&Value::Null, &legacy, &[]).unwrap();
    assert_eq!(registry["providers"][0]["models"], json!([row("same")]));
    assert_eq!(registry["providers"][0]["retired_models"], json!([]));
}

#[test]
fn saving_other_models_keeps_existing_opaque_ids_and_unchanged_legacy_labels() {
    let mut opaque = row("custom:my-llama");
    opaque["name"] = json!("  👩‍💻  ");
    let legacy = json!({"schema_version":1,"models":[opaque.clone()],"retired_models":[]});
    let registry = read_registry(&Value::Null, &legacy, &[]).unwrap();
    let added = save_registry(
        &registry,
        &request(0, "dsh", vec![opaque.clone(), row("another-model")]),
        &legacy,
        &[],
    )
    .unwrap();
    assert_eq!(added["providers"][0]["models"][0], opaque);
    let mut renamed = opaque.clone();
    renamed["name"] = json!(" Renamed model ");
    let changed = save_registry(&added, &request(1, "dsh", vec![renamed]), &legacy, &[]).unwrap();
    assert_eq!(
        changed["providers"][0]["models"][0]["name"],
        "Renamed model"
    );
    assert_eq!(
        changed["providers"][0]["models"][0]["id"],
        "custom:my-llama"
    );
    for bad_label in ["Changed\u{200d}label", "bad\nname"] {
        let mut invalid = opaque.clone();
        invalid["name"] = json!(bad_label);
        assert!(save_registry(&changed, &request(2, "dsh", vec![invalid]), &legacy, &[]).is_err());
    }
    assert!(save_registry(
        &changed,
        &request(2, "dsh", vec![row("custom:new-id")]),
        &legacy,
        &[]
    )
    .is_err());
    assert!(save_registry(&changed, &request(2, "codex", vec![opaque]), &legacy, &[]).is_err());
}

#[test]
fn bounded_migration_envelope_does_not_widen_ordinary_policy_arguments() {
    let row = |prefix: &str, index: usize| json!({"id":format!("{prefix}{index:03}{}", "x".repeat(120-prefix.len())),"name":"中".repeat(80),"supports_images":false});
    let legacy = json!({"schema_version":1,"models":(0..32).map(|n|row("legacy-active-",n)).collect::<Vec<_>>(),
        "retired_models":(0..256).map(|n|row("legacy-old-",n)).collect::<Vec<_>>()});
    let mut registry = empty();
    for (index, provider) in registry["providers"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .enumerate()
    {
        provider["models"] = json!((0..32)
            .map(|n| row(&format!("p{index}-"), n))
            .collect::<Vec<_>>());
    }
    registry["providers"][0]["retired_models"] =
        json!((0..256).map(|n| row("old-", n)).collect::<Vec<_>>());
    let input =
        json!({"op":"provider_read","registry":registry,"legacy_dsh_catalog":legacy}).to_string();
    assert!(input.len() > crate::strict_json::MAX_ARGUMENTS_BYTES);
    assert!(input.len() < MAX_PROVIDER_ARGUMENT_BYTES);
    let result: Value = serde_json::from_str(&model_catalog::reduce_json(&input)).unwrap();
    assert_eq!(result["ok"], true);
    let ordinary = format!(
        "{}{}",
        " ".repeat(crate::strict_json::MAX_ARGUMENTS_BYTES),
        json!({"op":"default"})
    );
    assert_eq!(
        serde_json::from_str::<Value>(&model_catalog::reduce_json(&ordinary)).unwrap()["ok"],
        false
    );
    let too_large = format!(
        "{}{}",
        " ".repeat(MAX_PROVIDER_ARGUMENT_BYTES),
        json!({"op":"provider_read","registry":null})
    );
    assert_eq!(
        serde_json::from_str::<Value>(&model_catalog::reduce_json(&too_large)).unwrap()["ok"],
        false
    );
}
