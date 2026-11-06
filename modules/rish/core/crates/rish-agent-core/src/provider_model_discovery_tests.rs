use super::*;

fn invoke(request: Value) -> Value {
    serde_json::from_str(&crate::provider_policy::reduce_json(&request.to_string())).unwrap()
}
fn value(request: Value) -> Value {
    let response = invoke(request);
    assert_eq!(response["ok"], true, "{response}");
    response["value"].clone()
}
fn page(protocol: &str, body: Value) -> Value {
    json!({"op":"models_parse_page","protocol":protocol,"response_body":body.to_string()})
}
fn refused(request: Value, error: DiscoveryError) {
    assert_eq!(invoke(request), json!({"ok":false,"error":error.code()}));
}

#[test]
fn endpoint_derivation_changes_only_one_known_suffix_and_preserves_prefix() {
    for (path, expected) in [
        ("/v1/chat/completions", "/v1/models"),
        ("/vendor/tenant/v2/responses", "/vendor/tenant/v2/models"),
        ("/api/anthropic/v1/messages/", "/api/anthropic/v1/models"),
        ("/responses/responses", "/responses/models"),
        ("/models/messages", "/models/models"),
        ("/messages", "/models"),
    ] {
        assert_eq!(
            value(json!({"op":"models_endpoint_path","path":path,"protocol":"messages"})),
            expected
        );
    }
    for path in ["/custom-completion-path", "/v1", "/v1/models"] {
        refused(
            json!({"op":"models_endpoint_path","path":path,"protocol":"responses"}),
            DiscoveryError::Unsupported,
        );
    }
    for path in [
        "https://evil.example/messages",
        "/v1/\nmessages",
        "/v1/\u{202e}/messages",
    ] {
        refused(
            json!({"op":"models_endpoint_path","path":path,"protocol":"messages"}),
            DiscoveryError::Invalid,
        );
    }
}

#[test]
fn openai_and_compatible_model_rows_are_non_secret_and_do_not_infer_capabilities() {
    let body = json!({"object":"list","next":"https://evil.example/steal","token":"private",
    "has_more":true,"last_id":"ignored","data":[
        {"id":"vision-model","object":"model","owned_by":"private","url":"https://evil.example","capabilities":["vision"]},
        {"id":"vendor/model:latest","name":"Local model","supports_images":true,"api_key":"private"},
        {"id":"third","display_name":"Human label","name":"Ignored label","supports_images":false}
    ]});
    for protocol in ["responses", "chat-completions"] {
        let result = value(page(protocol, body.clone()));
        assert_eq!(
            result,
            json!({"models":[
            {"wire_model":"vision-model","name":"vision-model","supports_images":false},
            {"wire_model":"vendor/model:latest","name":"Local model","supports_images":true},
            {"wire_model":"third","name":"Human label","supports_images":false}],
            "has_more":false,"last_id":null})
        );
        assert!(!result.to_string().contains("private"));
        assert!(!result.to_string().contains("evil.example"));
        assert!(validate_candidates(&result["models"]).is_ok());
    }
    assert_eq!(
        value(page("responses", json!({"data":[]})))["models"],
        json!([])
    );
}

#[test]
fn anthropic_pagination_uses_only_a_bounded_cursor_matching_the_last_row() {
    let result = value(page(
        "messages",
        json!({"data":[{"id":"claude-one","display_name":"Claude One"}],
        "has_more":true,"last_id":"claude-one","first_id":"ignored","next":"https://evil.example"}),
    ));
    assert_eq!(result["has_more"], true);
    assert_eq!(result["last_id"], "claude-one");
    for body in [
        json!({"data":[{"id":"one"}],"has_more":true}),
        json!({"data":[{"id":"one"}],"has_more":true,"last_id":"other"}),
        json!({"data":[],"has_more":true,"last_id":"one"}),
        json!({"data":[],"has_more":"true"}),
    ] {
        refused(page("messages", body), DiscoveryError::Invalid);
    }
    assert_eq!(
        value(page(
            "messages",
            json!({"data":[{"id":"one"}],"has_more":false,"last_id":"one"})
        ))["last_id"],
        Value::Null
    );
}

#[test]
fn malformed_rows_duplicates_and_unbounded_labels_fail_or_use_the_identifier() {
    for id in ["", "has space", "control\n", "hidden\u{200b}id"] {
        refused(
            page("responses", json!({"data":[{"id":id}]})),
            DiscoveryError::Invalid,
        );
    }
    refused(
        page("responses", json!({"data":[{"id":"x".repeat(129)}]})),
        DiscoveryError::Invalid,
    );
    for body in [
        json!({"data":[{"id":"same"},{"id":"same"}]}),
        json!({"data":[{"id":"model","supports_images":"true"}]}),
        json!({"data":["model"]}),
        json!({"error":{"message":"secret"}}),
    ] {
        refused(page("responses", body), DiscoveryError::Invalid);
    }
    let result = value(page(
        "responses",
        json!({"data":[
        {"id":"fallback","display_name":"n".repeat(129)},
        {"id":"named","display_name":"\u{202e}hidden","name":"Safe label"}]}),
    ));
    assert_eq!(result["models"][0]["name"], "fallback");
    assert_eq!(result["models"][1]["name"], "Safe label");
    refused(
        json!({"op":"models_parse_page","protocol":"responses",
        "response_body":"{\"data\":[{\"id\":\"a\",\"id\":\"b\"}]}"}),
        DiscoveryError::Invalid,
    );
}

#[test]
fn response_and_row_limits_are_bounded_without_widening_ordinary_policy_envelopes() {
    let body = json!({"data":[{"id":"one"}],"ignored_metadata":"x".repeat(300_000)}).to_string();
    assert!(body.len() > crate::strict_json::MAX_ARGUMENTS_BYTES);
    assert_eq!(
        value(json!({"op":"models_parse_page","protocol":"responses","response_body":body}))
            ["models"][0]["wire_model"],
        "one"
    );
    refused(
        json!({"op":"models_parse_page","protocol":"responses","response_body":"x".repeat(MAX_RESPONSE_BYTES+1)}),
        DiscoveryError::Limit,
    );
    refused(
        page(
            "responses",
            json!({"data":(0..513).map(|id|json!({"id":id.to_string()})).collect::<Vec<_>>()}),
        ),
        DiscoveryError::Limit,
    );
    assert_eq!(
        invoke(json!({"op":"profile_digest","identity":{"padding":"x".repeat(300_000)}})),
        json!({"ok":false,"error":"E_PROVIDER_CONFIGURATION"})
    );
}

#[test]
fn candidate_import_validation_accepts_only_explicit_bounded_non_secret_rows() {
    let rows = json!([{"wire_model":"model","name":"Model","supports_images":false}]);
    assert_eq!(validate_candidates(&rows).unwrap(), rows);
    for invalid in [
        json!([{"wire_model":"model","name":"Model","supports_images":false,"api_key":"secret"}]),
        json!([{"wire_model":"model","name":"Model","supports_images":null}]),
        json!([{"wire_model":"model","name":" ","supports_images":false}]),
        json!([{"wire_model":"model","name":"模".repeat(27),"supports_images":false}]),
    ] {
        assert_eq!(validate_candidates(&invalid), Err(DiscoveryError::Invalid));
    }
    let duplicate = json!([rows[0], rows[0]]);
    assert_eq!(
        validate_candidates(&duplicate),
        Err(DiscoveryError::Invalid)
    );
}

#[test]
fn long_unicode_labels_and_wire_ids_remain_importable_without_changing_wire_identity() {
    let ascii_id = "m".repeat(100);
    let unicode_id = "模".repeat(33);
    let rows = value(page(
        "responses",
        json!({"data":[
            {"id":"short-id","display_name":"模".repeat(27)},
            {"id":ascii_id,"display_name":"🌏".repeat(21)},
            {"id":unicode_id},
            {"id":"valid-unicode","display_name":"模".repeat(26)}
        ]}),
    ))["models"]
        .clone();
    assert_eq!(rows[0]["name"], "short-id");
    assert_eq!(rows[1]["wire_model"], ascii_id);
    assert_eq!(rows[1]["name"], format!("{}…", "m".repeat(77)));
    assert_eq!(rows[2]["wire_model"], unicode_id);
    assert_eq!(rows[2]["name"], format!("{}…", "模".repeat(25)));
    assert_eq!(rows[3]["name"], "模".repeat(26));
    assert!(validate_candidates(&rows).is_ok());
    let provider = "11111111-1111-4111-8111-111111111111";
    let mut mappings = serde_json::Map::new();
    let models=rows.as_array().unwrap().iter().enumerate().map(|(index,row)|{
        let id=format!("{:08x}-2222-4222-8222-222222222222",index+1);
        mappings.insert(crate::custom_provider_registry::logical_model_id(provider,&id),row["wire_model"].clone());
        json!({"id":id,"name":row["name"],"wire_model":row["wire_model"],"supports_images":row["supports_images"],"active":true})
    }).collect::<Vec<_>>();
    let saved = value(
        json!({"op":"registry_save","registry":null,"expected_revision":0,"provider":{
        "id":provider,"active":true,"models":models,"configuration":{
            "schema_version":1,"harness_id":format!("custom-{provider}"),"name":"Discovery import",
            "endpoint_url":"https://relay.example/v1/responses","protocol":"responses","auth_type":"bearer",
            "send_reasoning":true,"full_url":true,"model_mappings":mappings}}}),
    );
    assert_eq!(saved["providers"][0]["models"][1]["wire_model"], ascii_id);
    assert_eq!(saved["providers"][0]["models"][2]["wire_model"], unicode_id);
}

#[test]
fn anthropic_explicit_image_capability_and_lifecycle_control_choices_without_guessing() {
    let result = value(page(
        "messages",
        json!({"data":[
        {"id":"with-images","capabilities":{"image_input":{"supported":true}}},
        {"id":"without-images","supports_images":false,"capabilities":{"image_input":{"supported":true}}},
        {"id":"vision-by-name-only","retirement_date":"2001-01-01"},
        {"id":"retired-id","lifecycle":"retired","capabilities":{"image_input":{"supported":true}}}
    ],"has_more":true,"last_id":"retired-id"}),
    ));
    assert_eq!(result["models"].as_array().unwrap().len(), 3);
    assert_eq!(result["models"][0]["supports_images"], true);
    assert_eq!(result["models"][1]["supports_images"], false);
    assert_eq!(result["models"][2]["supports_images"], false);
    assert_eq!(result["last_id"], "retired-id");
    let retired_page = value(page(
        "messages",
        json!({"data":[{"id":"retired-id","lifecycle":"retired"}],
        "has_more":true,"last_id":"retired-id"}),
    ));
    assert_eq!(retired_page["models"], json!([]));
    assert_eq!(retired_page["last_id"], "retired-id");
    refused(
        page(
            "messages",
            json!({"data":[{"id":"model","capabilities":{"image_input":{"supported":"true"}}}]}),
        ),
        DiscoveryError::Invalid,
    );
}
