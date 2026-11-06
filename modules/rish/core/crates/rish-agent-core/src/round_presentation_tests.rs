use super::*;
const CONVERSATION: &str = "11111111-1111-4111-8111-111111111111";
const ATTEMPT: &str = "22222222-2222-4222-8222-222222222222";
const OTHER: &str = "99999999-9999-4999-8999-999999999999";
const ROUND: &str = "33333333-3333-4333-8333-333333333333";
const ROUND2: &str = "44444444-4444-4444-8444-444444444444";
const REFERENCE: &str = "55555555-5555-4555-8555-555555555555";

fn base(op: &str) -> Value {
    json!({"schema_version":1,"op":op,"conversation_id":CONVERSATION,"attempt_id":ATTEMPT})
}
fn insert(prior: Value, id: &str, index: Value, body: &str) -> Result<Value, StoreError> {
    let mut q = base("upsert");
    q.as_object_mut().unwrap().extend(json!({"prior":prior,"round_id":id,"round_index":index,"kind":"tool_batch","text":body,"reasoning":"推理 🧪"}).as_object().unwrap().clone());
    reduce(&q)
}
fn cached() -> Value {
    insert(Value::Null, ROUND, json!(0), "cached").unwrap()
}
fn projection() -> Value {
    let mut q = base("project");
    q["cached"] = cached();
    q["rounds"] = json!([{"locator":{"attempt_id":ATTEMPT,"round_id":ROUND,"round_index":0},"state":"completed","terminal_kind":"tool_batch","transcript_after":{"transcript_ref":REFERENCE,"generation":1}}]);
    q["transcripts"] = json!([{"attempt_id":ATTEMPT,"transcript_ref":REFERENCE,"generation":2,"messages":[
        {"role":"assistant","round_index":0,"content":"older","reasoning_content":""},
        {"role":"tool","round_index":0,"content":"not assistant"},
        {"role":"assistant","round_index":0,"content":"最新","reasoning_content":"new reasoning"}]}]);
    q
}

#[test]
fn unicode_round_trip_and_index_order_are_shared() {
    let a = insert(Value::Null, ROUND2, json!(5), "Cafe\u{301}\0你好🧪").unwrap();
    let b = insert(a, ROUND, json!(0), "first").unwrap();
    assert_eq!(b["rounds"][0]["round_id"], ROUND);
    assert_eq!(b["rounds"][1]["text"], "Cafe\u{301}\0你好🧪");
    assert_eq!(
        decode_archive(&b.to_string(), CONVERSATION, ATTEMPT).unwrap(),
        b
    );
    assert_eq!(reduce(&base("identity")).unwrap(), true);
}

#[test]
fn record_and_archive_fields_are_closed_and_identity_bound() {
    let original = cached();
    for key in [
        "round_id",
        "round_index",
        "kind",
        "text",
        "reasoning",
        "assistant_text_sha256",
        "reasoning_text_sha256",
    ] {
        let mut changed = original.clone();
        changed["rounds"][0].as_object_mut().unwrap().remove(key);
        assert!(
            validate_archive(&changed, CONVERSATION, ATTEMPT, ArchiveBudget::Native).is_err(),
            "{key}"
        );
    }
    for key in ["schema_version", "conversation_id", "attempt_id", "rounds"] {
        let mut changed = original.clone();
        changed.as_object_mut().unwrap().remove(key);
        assert!(validate_archive(&changed, CONVERSATION, ATTEMPT, ArchiveBudget::Native).is_err());
    }
    let mut changed = original.clone();
    changed["extra"] = json!(true);
    assert!(validate_archive(&changed, CONVERSATION, ATTEMPT, ArchiveBudget::Native).is_err());
    changed = original.clone();
    changed["rounds"][0]["extra"] = json!(true);
    assert!(validate_archive(&changed, CONVERSATION, ATTEMPT, ArchiveBudget::Native).is_err());
    assert!(validate_archive(&original, OTHER, ATTEMPT, ArchiveBudget::Native).is_err());
    assert!(validate_archive(&original, CONVERSATION, OTHER, ArchiveBudget::Native).is_err());
    for bad in ["", "../../private", "AAAAAAAA-1111-4111-8111-111111111111"] {
        assert!(validate_identity(bad, ATTEMPT).is_err());
        assert!(insert(Value::Null, bad, json!(0), "x").is_err());
    }
}

#[test]
fn type_coercion_duplicate_keys_and_duplicate_ids_are_refused() {
    for i in [
        json!(true),
        json!(1.0),
        json!(-0.0),
        json!(-1),
        json!(8),
        json!("1"),
        Value::Null,
    ] {
        assert!(insert(Value::Null, ROUND, i, "x").is_err());
    }
    let a = cached();
    let raw = a.to_string();
    for bad in [
        raw.replace("\"round_index\":0", "\"round_index\":1.0"),
        raw.replace("\"round_index\":0", "\"round_index\":-0"),
        raw.replace("\"schema_version\":1", "\"schema_version\":true"),
        raw.replace(
            "\"schema_version\":1",
            "\"schema_version\":1,\"schema_version\":1",
        ),
    ] {
        assert!(decode_archive(&bad, CONVERSATION, ATTEMPT).is_err());
    }
    assert!(insert(a.clone(), ROUND, json!(1), "same id different index").is_err());
    let mut duplicate = a.clone();
    duplicate["rounds"]
        .as_array_mut()
        .unwrap()
        .push(a["rounds"][0].clone());
    assert!(validate_archive(&duplicate, CONVERSATION, ATTEMPT, ArchiveBudget::Native).is_err());
    let mut q = base("identity");
    q["unexpected"] = json!(true);
    assert!(reduce(&q).is_err());
}

#[test]
fn corrupt_cache_is_ignored_but_never_repaired_into_authority() {
    let mut bad = cached();
    bad["rounds"][0]["text"] = json!("tampered");
    assert!(validate_archive(&bad, CONVERSATION, ATTEMPT, ArchiveBudget::Native).is_err());
    let replaced = insert(bad, ROUND2, json!(1), "new").unwrap();
    assert_eq!(replaced["rounds"].as_array().unwrap().len(), 1);
    let mut foreign = cached();
    foreign["conversation_id"] = json!(OTHER);
    let replaced = insert(foreign, ROUND2, json!(1), "new").unwrap();
    assert_eq!(replaced["rounds"].as_array().unwrap().len(), 1);
}

#[test]
fn wal_wins_and_reverse_assistant_selection_matches_both_hosts() {
    let q = projection();
    let before = q.clone();
    let value = reduce(&q).unwrap();
    assert_eq!(value["rounds"][0]["text"], "最新");
    assert_eq!(q, before, "display projection must not mutate WAL");
    let mut q = q;
    q["transcripts"][0]["messages"][2]["content"] = json!(7);
    assert_eq!(
        reduce(&q).unwrap()["rounds"][0]["text"],
        "cached",
        "malformed last match must not select the older assistant"
    );
}

#[test]
fn foreign_incomplete_and_older_wal_rows_cannot_replace_cache() {
    for target in [
        "attempt",
        "state",
        "kind",
        "reference",
        "generation",
        "transcript_attempt",
        "message_index",
    ] {
        let mut q = projection();
        match target {
            "attempt" => q["rounds"][0]["locator"]["attempt_id"] = json!(OTHER),
            "state" => q["rounds"][0]["state"] = json!("in_flight"),
            "kind" => q["rounds"][0]["terminal_kind"] = json!("unknown"),
            "reference" => q["transcripts"][0]["transcript_ref"] = json!(OTHER),
            "generation" => q["transcripts"][0]["generation"] = json!(0),
            "transcript_attempt" => q["transcripts"][0]["attempt_id"] = json!(OTHER),
            _ => {
                q["transcripts"][0]["messages"][0]["round_index"] = json!(1);
                q["transcripts"][0]["messages"][2]["round_index"] = json!(1);
            }
        }
        assert_eq!(
            reduce(&q).unwrap()["rounds"][0]["text"],
            "cached",
            "{target}"
        );
    }
    for kind in ["tool_batch", "final", "blocked"] {
        let mut q = projection();
        q["rounds"][0]["terminal_kind"] = json!(kind);
        assert_eq!(reduce(&q).unwrap()["rounds"][0]["kind"], kind);
    }
}

#[test]
fn native_projection_and_ui_total_budgets_remain_distinct() {
    let body = "x".repeat(MAX_TEXT_BYTES / 2 + 1);
    let a = insert(Value::Null, ROUND, json!(0), &body).unwrap();
    let b = insert(a, ROUND2, json!(1), &body).unwrap();
    assert!(validate_archive(&b, CONVERSATION, ATTEMPT, ArchiveBudget::Native).is_ok());
    assert_eq!(
        validate_archive(&b, CONVERSATION, ATTEMPT, ArchiveBudget::Display),
        Err(StoreError::Capacity)
    );
    assert!(
        decode_archive(&b.to_string(), CONVERSATION, ATTEMPT).is_err(),
        "encoded disk budget is independent"
    );
    let mut q = projection();
    q["cached"] = b;
    q["rounds"] = json!([]);
    q["transcripts"] = json!([]);
    assert_eq!(reduce(&q).unwrap()["rounds"].as_array().unwrap().len(), 2);
    let body = "中".repeat(MAX_TEXT_BYTES / 3);
    assert!(insert(Value::Null, ROUND, json!(0), &body).is_ok());
    assert!(insert(Value::Null, ROUND, json!(0), &(body + "🧪")).is_err());
}

#[test]
fn raw_parser_accepts_valid_archives_above_tool_argument_limit() {
    let a = insert(Value::Null, ROUND, json!(0), &"a".repeat(300_000)).unwrap();
    let mut q = base("decode");
    q["archive_json"] = json!(a.to_string());
    let result: Value = serde_json::from_str(&reduce_json(&q.to_string())).unwrap();
    assert_eq!(result["ok"], true);
    for raw in [
        "",
        "[]",
        "null",
        "{\"op\":\"identity\",\"op\":\"identity\"}",
    ] {
        let reply: Value = serde_json::from_str(&reduce_json(raw)).unwrap();
        assert_eq!(reply["ok"], false);
    }
    let many = (0..20_000)
        .map(|i| format!("\"k{i}\":0"))
        .collect::<Vec<_>>()
        .join(",");
    assert!(workspace_json::bounded_exact_structure(
        format!("{{{many}}}").as_bytes()
    ));
    assert!(!workspace_json::bounded_exact_structure(
        format!("{{{many},\"k19999\":0}}").as_bytes()
    ));
}
