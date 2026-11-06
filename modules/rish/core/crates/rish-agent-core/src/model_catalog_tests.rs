use super::*;

fn entry(id: &str, name: &str, supports_images: bool) -> Value {
    json!({"id": id, "name": name, "supports_images": supports_images})
}

fn catalog(models: Vec<Value>, retired: Vec<Value>) -> Value {
    json!({"schema_version": 1, "models": models, "retired_models": retired})
}

fn request(models: Vec<Value>) -> Value {
    json!({"schema_version": 1, "models": models})
}

fn reduce(request: Value) -> Value {
    serde_json::from_str(&reduce_json(&request.to_string())).unwrap()
}

#[test]
fn missing_catalog_has_no_active_choices_but_recognizes_legacy_identities() {
    let defaults = default_catalog();
    assert!(defaults.models().is_empty());
    assert!(defaults.retired_models().is_empty());
    assert!(defaults.supports_images("deepseek-v4-flash"));
    assert!(!defaults.supports_images("deepseek-v4-pro"));
    assert!(defaults.supports_images("deepseek-v4-flash-vision-exp"));
    assert!(!defaults.supports_images("not-registered"));
    assert!(!defaults.is_known("gpt-5.6"));
    assert_eq!(read_catalog(&Value::Null).unwrap(), defaults);
}

#[test]
fn custom_model_survives_retirement_and_can_be_reactivated() {
    let custom = entry("custom/model:v1", "Custom Model", true);
    let saved = save_catalog(&Value::Null, &request(vec![custom.clone()])).unwrap();
    assert_eq!(saved.retired_models().len(), 3);
    assert!(saved.is_known("deepseek-v4-flash"));
    assert!(saved.supports_images("custom/model:v1"));
    let retired = save_catalog(
        &saved.to_json(),
        &request(
            default_catalog().to_json()["models"]
                .as_array()
                .unwrap()
                .clone(),
        ),
    )
    .unwrap();
    assert_eq!(retired.retired_models().len(), 4);
    assert_eq!(retired.lookup("custom/model:v1").unwrap().to_json(), custom);
    assert_eq!(model_harness(&retired, "custom/model:v1", &[]), Some("dsh"));
    assert!(retired.supports_images("custom/model:v1"));
    let reactivated = save_catalog(
        &retired.to_json(),
        &request(vec![entry("custom/model:v1", "Updated", false)]),
    )
    .unwrap();
    assert!(!reactivated.supports_images("custom/model:v1"));
    assert_eq!(
        reactivated.lookup("custom/model:v1").unwrap().name,
        "Updated"
    );
    assert!(!reactivated
        .retired_models()
        .iter()
        .any(|row| row.id == "custom/model:v1"));
}

#[test]
fn older_catalogs_keep_builtin_knowledge_and_image_capabilities() {
    let old = read_catalog(&catalog(vec![entry("custom", "Custom", false)], vec![])).unwrap();
    assert!(old.is_known("deepseek-v4-flash"));
    assert!(old.supports_images("deepseek-v4-flash"));
    assert!(!old.supports_images("deepseek-v4-pro"));
    assert_eq!(old.lookup("deepseek-v4-flash").unwrap().name, "V4 Flash");
}

#[test]
fn active_then_retired_then_default_precedence_is_preserved_on_save() {
    let old = catalog(
        vec![entry("deepseek-v4-flash", "Active Flash", false)],
        vec![
            entry("deepseek-v4-flash", "Old Flash", true),
            entry("deepseek-v4-pro", "Retired Pro", true),
        ],
    );
    let read = read_catalog(&old).unwrap();
    assert_eq!(
        read.lookup("deepseek-v4-flash").unwrap().name,
        "Active Flash"
    );
    assert!(!read.supports_images("deepseek-v4-flash"));
    assert!(read.supports_images("deepseek-v4-pro"));
    let saved = save_catalog(&old, &request(vec![entry("next", "Next", false)])).unwrap();
    assert_eq!(
        saved.lookup("deepseek-v4-flash").unwrap().name,
        "Active Flash"
    );
    assert!(!saved.supports_images("deepseek-v4-flash"));
    assert!(saved.supports_images("deepseek-v4-pro"));
    assert_eq!(saved.retired_models().len(), 3);
}

#[test]
fn retired_metadata_is_sorted_without_reordering_active_choices() {
    let old = catalog(
        vec![entry("z-custom", "Z", false), entry("a-custom", "A", true)],
        vec![entry("m-custom", "M", false)],
    );
    let saved = save_catalog(
        &old,
        &request(vec![
            entry("second", "Second", false),
            entry("first", "First", false),
        ]),
    )
    .unwrap();
    let ids = saved
        .retired_models()
        .iter()
        .map(|entry| entry.id.as_str())
        .collect::<Vec<_>>();
    let mut sorted = ids.clone();
    sorted.sort();
    assert_eq!(ids, sorted);
    assert_eq!(saved.models()[0].id, "second");
    assert_eq!(saved.models()[1].id, "first");
}

#[test]
fn repeated_save_is_idempotent_and_does_not_mutate_inputs() {
    let old = default_catalog().to_json();
    let save = request(vec![entry("custom", "Custom", true)]);
    let old_copy = old.clone();
    let save_copy = save.clone();
    let once = save_catalog(&old, &save).unwrap();
    let twice = save_catalog(&once.to_json(), &save).unwrap();
    assert_eq!(once, twice);
    assert_eq!(old, old_copy);
    assert_eq!(save, save_copy);
}

#[test]
fn labels_trim_unicode_whitespace_and_keep_utf16_limits() {
    let valid = entry(
        "custom",
        &format!("\u{3000}{}\u{a0}\n", "🙂".repeat(40)),
        true,
    );
    let models = validate_models(&json!([valid]), false).unwrap();
    assert_eq!(models[0].name, "🙂".repeat(40));
    assert!(validate_models(&json!([entry("custom", &"🙂".repeat(41), false)]), false).is_err());
    assert!(validate_models(&json!([entry("custom", &"中".repeat(80), false)]), false).is_ok());
    assert!(validate_models(&json!([entry("custom", &"中".repeat(81), false)]), false).is_err());
    assert!(validate_models(&json!([entry("custom", " \t\n", false)]), false).is_err());
}

#[test]
fn labels_reject_embedded_control_and_format_characters() {
    for forbidden in [
        '\0', '\n', '\t', '\u{0085}', '\u{200b}', '\u{202e}', '\u{feff}',
    ] {
        let name = format!("Before{forbidden}After");
        assert!(
            validate_models(&json!([entry("custom", &name, false)]), false).is_err(),
            "{forbidden:?}"
        );
    }
    // Ordinary combining marks do not need normalization or rejection.
    assert!(validate_models(&json!([entry("custom", "e\u{301}", false)]), false).is_ok());
}

#[test]
fn stored_legacy_format_labels_are_preserved_without_relaxing_new_input() {
    for name in ["👩‍💻", "Old\u{200b}Name", "  👩‍💻  ", "\u{200b}"] {
        let row = entry("legacy", name, true);
        let stored = catalog(vec![row.clone()], vec![]);
        let before = stored.clone();
        let read = read_catalog(&stored).unwrap();
        assert_eq!(read.to_json(), before);
        assert_eq!(read.lookup("legacy").unwrap().name, name);
        assert_eq!(stored, before);
        assert!(read.supports_images("legacy"));
        assert!(validate_models(&json!([row.clone()]), false).is_err());
        assert!(validate_models(&json!([row.clone()]), true).is_err());
        assert!(save_catalog(&Value::Null, &request(vec![row])).is_err());
    }
}

#[test]
fn legacy_labels_survive_retirement_reopening_and_an_explicit_rename() {
    let stored = catalog(
        vec![entry("legacy", "  👩‍💻  ", true)],
        vec![entry("older", "Old\u{200b}Name", false)],
    );
    let active = default_catalog().to_json()["models"]
        .as_array()
        .unwrap()
        .clone();
    let saved = save_catalog(&stored, &request(active)).unwrap();
    assert_eq!(saved.retired_models().len(), 5);
    let reopened = read_catalog(&saved.to_json()).unwrap();
    assert_eq!(reopened.lookup("legacy").unwrap().name, "  👩‍💻  ");
    assert_eq!(reopened.lookup("older").unwrap().name, "Old\u{200b}Name");
    assert!(reopened.is_known("legacy"));
    assert!(reopened.supports_images("legacy"));
    assert_eq!(model_harness(&reopened, "legacy", &[]), Some("dsh"));
    let renamed = save_catalog(
        &reopened.to_json(),
        &request(vec![entry("legacy", " Renamed model ", true)]),
    )
    .unwrap();
    assert_eq!(renamed.lookup("legacy").unwrap().name, "Renamed model");
    assert!(!renamed
        .retired_models()
        .iter()
        .any(|row| row.id == "legacy"));
    assert_eq!(read_catalog(&renamed.to_json()).unwrap(), renamed);
    assert_eq!(renamed.lookup("older").unwrap().name, "Old\u{200b}Name");
}

#[test]
fn legacy_label_compatibility_does_not_accept_controls_or_oversized_names() {
    for name in [
        "Old\nName".into(),
        "Old\0Name".into(),
        "Name\n".into(),
        " \t ".into(),
        " ".into(),
        "".into(),
        "👩‍💻".repeat(17),
    ] {
        let stored = catalog(vec![entry("legacy", &name, true)], vec![]);
        assert!(read_catalog(&stored).is_err(), "{name:?}");
    }
    // ZWJ is one UTF-16 unit; this sequence occupies five, so 16 = 80.
    let name = "👩‍💻".repeat(16);
    let stored = catalog(vec![entry("legacy", &name, true)], vec![]);
    assert_eq!(
        read_catalog(&stored)
            .unwrap()
            .lookup("legacy")
            .unwrap()
            .name,
        name
    );
}

#[test]
fn legacy_label_compatibility_cannot_bypass_catalog_shape_or_identity_validation() {
    let valid = entry("legacy", "👩‍💻", true);
    for (key, bad) in [
        ("id", json!("gpt-5.6")),
        ("id", json!("invalid id")),
        ("supports_images", json!(1)),
        ("name", json!(null)),
        ("extra", json!(true)),
    ] {
        let mut row = valid.clone();
        row[key] = bad;
        let stored = catalog(vec![row], vec![]);
        assert!(read_catalog(&stored).is_err());
        assert!(save_catalog(&stored, &request(vec![entry("new", "New", false)])).is_err());
    }
    let duplicates = catalog(vec![valid.clone(), valid], vec![]);
    assert!(read_catalog(&duplicates).is_err());
}

#[test]
fn ids_match_the_bounded_ascii_grammar_without_trimming() {
    for valid in ["a", "9._:/-", &"a".repeat(128)] {
        assert!(
            validate_models(&json!([entry(valid, "Label", false)]), false).is_ok(),
            "{valid:?}"
        );
    }
    for invalid in [
        "",
        " a",
        "a ",
        ".a",
        "/a",
        "a?b",
        "a#b",
        "a\\b",
        "模型",
        "a\n",
        &"a".repeat(129),
    ] {
        assert!(
            validate_models(&json!([entry(invalid, "Label", false)]), false).is_err(),
            "{invalid:?}"
        );
    }
}

#[test]
fn other_harness_ids_cannot_be_registered_as_dsh() {
    for (id, harness) in BUILTIN_MODELS {
        let result = validate_models(&json!([entry(id, "Label", true)]), false);
        assert_eq!(result.is_ok(), *harness == "dsh", "{id}");
    }
}

#[test]
fn each_list_rejects_duplicate_ids_and_wrong_field_types() {
    let valid = entry("custom", "Label", false);
    assert!(validate_models(&json!([valid.clone(), valid.clone()]), false).is_err());
    assert!(validate_models(&json!([valid.clone(), valid.clone()]), true).is_err());
    for field in ["id", "name", "supports_images"] {
        let mut missing = valid.clone();
        missing.as_object_mut().unwrap().remove(field);
        assert!(validate_models(&json!([missing]), false).is_err());
        for wrong in [Value::Null, json!(1), json!([]), json!({})] {
            let mut malformed = valid.clone();
            malformed[field] = wrong;
            assert!(validate_models(&json!([malformed]), false).is_err());
        }
    }
    let mut extra = valid.clone();
    extra["extra"] = json!(true);
    assert!(validate_models(&json!([extra]), false).is_err());
    let mut coerced = valid;
    coerced["supports_images"] = json!("false");
    assert!(validate_models(&json!([coerced]), false).is_err());
    assert!(validate_models(&json!([false]), false).is_err());
}

#[test]
fn list_limits_are_exact() {
    let models = |count| {
        Value::Array(
            (0..count)
                .map(|index| entry(&format!("model-{index}"), "Label", false))
                .collect(),
        )
    };
    assert!(validate_models(&json!([]), true).is_ok());
    assert!(validate_models(&json!([]), false).is_ok());
    assert!(validate_models(&models(32), false).is_ok());
    assert!(validate_models(&models(33), false).is_err());
    assert!(validate_models(&models(256), true).is_ok());
    assert!(validate_models(&models(257), true).is_err());
}

#[test]
fn retirement_capacity_rejects_without_dropping_history() {
    let retired = (0..253)
        .map(|i| entry(&format!("retired-{i:03}"), "Retired", false))
        .collect();
    let old = catalog(
        default_catalog().to_json()["models"]
            .as_array()
            .unwrap()
            .clone(),
        retired,
    );
    let full = save_catalog(&old, &request(vec![entry("custom-1", "Custom", false)])).unwrap();
    assert_eq!(full.retired_models().len(), MAX_RETIRED_MODELS);
    let before = full.to_json();
    assert!(save_catalog(&before, &request(vec![entry("custom-2", "Custom", false)])).is_err());
    assert_eq!(full.to_json(), before);
    // Reactivating a retired ID frees the slot needed by the previous active ID.
    let next = save_catalog(
        &before,
        &request(vec![entry("retired-000", "Active", true)]),
    )
    .unwrap();
    assert_eq!(next.retired_models().len(), MAX_RETIRED_MODELS);
    assert!(next.is_known("custom-1"));
}

#[test]
fn damaged_storage_never_becomes_defaults_or_a_save_base() {
    for stored in [
        json!({}),
        json!([]),
        json!("bad"),
        json!(false),
        json!({"schema_version": 1, "models": false, "retired_models": []}),
    ] {
        assert!(read_catalog(&stored).is_err());
        assert!(save_catalog(&stored, &request(vec![entry("custom", "Custom", true)])).is_err());
        for op in ["read", "lookup", "is_known", "supports_images"] {
            let query = if op == "read" {
                json!({"op":op,"catalog":stored})
            } else {
                json!({"op":op,"catalog":stored,"model":"deepseek-v4-flash"})
            };
            assert_eq!(reduce(query)["ok"], false);
        }
    }
}

#[test]
fn stored_schema_and_save_request_are_exact_and_do_not_coerce_versions() {
    for schema in [
        json!(true),
        json!("1"),
        json!(1.0),
        json!(0),
        json!(2),
        Value::Null,
    ] {
        let mut stored = default_catalog().to_json();
        stored["schema_version"] = schema.clone();
        assert!(read_catalog(&stored).is_err(), "{schema}");
        let mut save = request(vec![entry("custom", "Custom", true)]);
        save["schema_version"] = schema.clone();
        assert!(save_catalog(&Value::Null, &save).is_err(), "{schema}");
    }
    let mut stored = default_catalog().to_json();
    stored["extra"] = Value::Null;
    assert!(read_catalog(&stored).is_err());
    let mut save = request(vec![entry("custom", "Custom", true)]);
    save["retired_models"] = json!([]);
    assert!(save_catalog(&Value::Null, &save).is_err());
}

#[test]
fn builtin_harness_and_codex_discovery_have_stable_precedence() {
    let known = read_catalog(&catalog(
        vec![entry("gpt-custom", "Custom DSH", false)],
        vec![],
    ))
    .unwrap();
    for (id, harness) in BUILTIN_MODELS {
        assert_eq!(model_harness(&known, id, &[]), Some(*harness));
    }
    let discovery = vec!["gpt-custom".into(), "gpt-future".into(), "o9-new".into()];
    assert_eq!(model_harness(&known, "gpt-custom", &discovery), Some("dsh"));
    assert_eq!(
        model_harness(&known, "gpt-future", &discovery),
        Some("codex")
    );
    assert_eq!(model_harness(&known, "o9-new", &discovery), Some("codex"));
    assert_eq!(model_harness(&known, "gpt-unknown", &discovery), None);
    assert_eq!(
        model_harness(&known, "not-a-model", &["not-a-model".into()]),
        None
    );
}

#[test]
fn codex_discovery_grammar_matches_the_native_registration_boundary() {
    for valid in [
        "gpt-1",
        "codex-model",
        "o1",
        "o9._-A",
        &format!("gpt-{}", "a".repeat(76)),
    ] {
        assert!(valid_codex_discovery_id(valid), "{valid}");
    }
    for invalid in [
        "gpt-",
        "codex-_x",
        "o",
        "oA",
        "GPT-1",
        "gpt-a/b",
        "gpt-模型",
        "gpt-a\n",
        &format!("gpt-{}", "a".repeat(77)),
    ] {
        assert!(!valid_codex_discovery_id(invalid), "{invalid}");
    }
}

#[test]
fn builtin_harness_is_independent_of_damaged_dsh_storage() {
    for stored in [json!({}), json!(false), json!("bad"), json!([])] {
        for (id, harness) in BUILTIN_MODELS {
            let answer = reduce(json!({"op":"harness_for_model","catalog":stored,
                "model":id,"discovered_models":[]}));
            assert_eq!(answer, json!({"ok":true,"value":harness}));
        }
        // The ID might be registered to DSH in the damaged preference, so
        // discovery cannot safely infer a different provider for it.
        let discovered = reduce(json!({"op":"harness_for_model","catalog":stored,
            "model":"gpt-future","discovered_models":["gpt-future"]}));
        assert_eq!(discovered["ok"], false);
        let custom = reduce(json!({"op":"harness_for_model","catalog":stored,
            "model":"custom","discovered_models":[]}));
        assert_eq!(custom["ok"], false);
    }
}

#[test]
fn builtin_shortcut_does_not_skip_envelope_and_discovery_validation() {
    for discovered in [json!(null), json!(false), json!([1]), json!(["invalid"])] {
        assert_eq!(
            reduce(json!({"op":"harness_for_model","catalog":null,
            "model":"gpt-5.6","discovered_models":discovered}))["ok"],
            false
        );
    }
    assert_eq!(
        reduce(json!({"op":"harness_for_model","catalog":null,
        "model":"gpt-5.6","discovered_models":[],"extra":true}))["ok"],
        false
    );
    assert_eq!(
        reduce(json!({"op":"harness_for_model",
        "model":"gpt-5.6","discovered_models":[]}))["ok"],
        false
    );
}

#[test]
fn supported_model_set_includes_history_and_discovery_without_duplicates() {
    let stored = catalog(
        vec![
            entry("custom", "Custom", false),
            entry("gpt-custom", "Custom GPT", false),
        ],
        vec![
            entry("retired", "Retired", true),
            entry("custom", "Older", true),
        ],
    );
    let reply = reduce(json!({"op":"supported_models","catalog":stored,
        "discovered_models":["gpt-custom","gpt-future","gpt-future","gpt-5.6"]}));
    assert_eq!(reply["ok"], true);
    let values = reply["value"].as_array().unwrap();
    assert_eq!(values.len(), BUILTIN_MODELS.len() + 4);
    for model in ["custom", "retired", "gpt-custom", "gpt-future", "gpt-5.6"] {
        assert_eq!(
            values
                .iter()
                .filter(|value| value.as_str() == Some(model))
                .count(),
            1
        );
    }
    let names = values
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect::<Vec<_>>();
    let mut sorted = names.clone();
    sorted.sort();
    assert_eq!(names, sorted);
}

#[test]
fn complete_model_set_cannot_ignore_a_damaged_catalog_or_bad_discovery() {
    for stored in [json!({}), json!(false), json!([])] {
        assert_eq!(
            reduce(json!({"op":"supported_models","catalog":stored,
            "discovered_models":[]}))["ok"],
            false
        );
    }
    for discovered in [
        json!(null),
        json!(["invalid"]),
        json!([1]),
        json!(vec!["gpt-new"; 257]),
    ] {
        assert_eq!(
            reduce(json!({"op":"supported_models","catalog":null,
            "discovered_models":discovered}))["ok"],
            false
        );
    }
    assert_eq!(
        reduce(json!({"op":"supported_models","catalog":null,
        "discovered_models":[],"extra":true}))["ok"],
        false
    );
}

#[test]
fn reducer_is_strict_and_errors_do_not_echo_inputs() {
    for text in [
        r#"{"op":"default","extra":"private"}"#,
        r#"{"op":"default","op":"default"}"#,
        r#"{"op":"read"}"#,
        r#"{"op":"read","catalog":null,"extra":null}"#,
        r#"{"op":"unknown"}"#,
        r#"{"op":"lookup","catalog":null,"model":1}"#,
        r#"{"op":"validate_models","models":[],"retired":1}"#,
        r#"{"op":"harness_for_model","catalog":null,"model":"gpt-new","discovered_models":["invalid"]}"#,
        "[]",
        "null",
        "{}",
        "not-json",
    ] {
        assert_eq!(
            reduce_json(text),
            r#"{"error":"E_MODEL_CATALOG_INVALID","ok":false}"#
        );
    }
    let too_many = vec![json!("gpt-new"); 257];
    assert_eq!(
        reduce(
            json!({"op":"harness_for_model","catalog":null,"model":"gpt-new","discovered_models":too_many})
        )["ok"],
        false
    );
}

#[test]
fn native_policy_fixture_has_identical_outputs() {
    let fixture: Value =
        serde_json::from_str(include_str!("../../../fixtures/model-catalog-policy.json")).unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 12);
    for case in cases {
        assert_eq!(
            reduce(case["input"].clone()),
            case["expected"],
            "{}",
            case["name"]
        );
    }
}

#[test]
fn new_dsh_entries_cannot_claim_independent_provider_namespace() {
    let reserved = entry(
        "custom:11111111-1111-4111-8111-111111111111:22222222-2222-4222-8222-222222222222",
        "Reserved provider model",
        false,
    );
    assert!(save_catalog(&Value::Null, &request(vec![reserved.clone()])).is_err());
    // Historical DSH data remains readable; native custom routing must require
    // an explicit registry row before dispatching any newly reserved identity.
    let collision = read_catalog(&catalog(vec![reserved.clone()], vec![])).unwrap();
    let id = reserved["id"].as_str().unwrap();
    assert_eq!(model_harness(&collision, id, &[]), None);
    assert!(!supported_models(&collision, &[])
        .iter()
        .any(|model| model == id));
    let opaque = entry("custom:my-llama", "Legacy Llama", false);
    assert!(save_catalog(&Value::Null, &request(vec![opaque.clone()])).is_err());
    let legacy = read_catalog(&catalog(vec![opaque], vec![])).unwrap();
    assert_eq!(model_harness(&legacy, "custom:my-llama", &[]), Some("dsh"));
}
