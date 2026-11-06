//! Schema 10 is a CAS migration, not an unversioned schema-9 extension.
use rish_agent_core::canonical::canonical_json;
use rish_agent_core::prepared_attempt::session_conversation;
use rish_agent_core::runtime_coordinator::{
    cancel_source_proof, cleanup_outbox_proof, session_proof,
};
use rish_agent_core::session_schema::cas::{
    cas_plan, cas_precheck, cas_verified, query_commit, Loaded, Plan, Precheck, TombstoneView,
};
use rish_agent_core::session_schema::{
    candidate_digest, session_digest, validate_candidate, validate_composer_drafts,
    validate_envelope, validate_schema9_root, validate_session_root, Env, Envelope,
    MAX_COMPOSER_DRAFTS, MAX_COMPOSER_DRAFT_BYTES,
};
use serde_json::{json, Map, Value};

const LAUNCH: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const FIRST: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const SECOND: &str = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const NOW: &str = "2026-11-06T00:00:00.000Z";

fn empty(version: u64) -> Value {
    let mut session = json!({"schema_version":version,"workspace_authority_outbox":[],
        "agent_transcript_cleanup_outbox":[],"project_context_destructive_epoch":0,
        "project_context_destructive_transition":null,"active_conversation_id":null,
        "conversations":[],"messages":[],"session_events":[],
        "preferences":{"schema_version":1,"theme_mode":"system","locale":"system",
            "default_model":null,"selected_harness_id":null,"thinking_mode":"high",
            "tool_permission":"read-only","show_reasoning":false,"auto_expand_tools":false,
            "confirm_destructive_file_actions":true}});
    if version == 10 {
        session["composer_drafts"] = json!({});
    }
    session
}

fn write(
    session: &Value,
    operation: &str,
    current: &Loaded,
) -> rish_agent_core::session_schema::cas::WritePlan {
    let Plan::Write(plan) = cas_plan(
        operation,
        &current.authority(),
        session.to_string().as_bytes(),
        &Env::default(),
        current,
        Some(&TombstoneView {
            missing: true,
            ..Default::default()
        }),
        LAUNCH,
    )
    .unwrap() else {
        panic!("expected CAS write")
    };
    plan
}

#[test]
fn schema9_remains_exact_and_schema10_requires_its_draft_map() {
    let old = empty(9);
    assert!(validate_schema9_root(&old, &Env::default()));
    assert!(validate_session_root(&old, &Env::default()));
    let mut current = empty(10);
    current["composer_drafts"] = json!({
        "new-draft":"  中文\nunsent  ", LAUNCH:"another chat",
        "assistant-group-example":"group draft"
    });
    assert!(validate_session_root(&current, &Env::default()));
    assert!(!validate_schema9_root(&current, &Env::default()));
    let accepted = validate_candidate(current.to_string().as_bytes(), &Env::default()).unwrap();
    assert_eq!(
        accepted.session, current,
        "validation must preserve exact draft text"
    );
    current["schema_version"] = json!(9);
    assert!(!validate_session_root(&current, &Env::default()));
    current = empty(10);
    current.as_object_mut().unwrap().remove("composer_drafts");
    assert!(!validate_session_root(&current, &Env::default()));
}

#[test]
fn draft_map_rejects_wrong_shapes_empty_text_and_unbounded_keys() {
    for invalid in [
        Value::Null,
        json!([]),
        json!("text"),
        json!({"new-draft":null}),
        json!({"new-draft":1}),
        json!({"new-draft":""}),
        json!({"":"text"}),
        json!({" \n":"text"}),
        json!({"x".repeat(257):"text"}),
    ] {
        assert!(!validate_composer_drafts(&invalid), "{invalid}");
        let mut session = empty(10);
        session["composer_drafts"] = invalid;
        assert!(validate_candidate(session.to_string().as_bytes(), &Env::default()).is_err());
    }
    assert!(validate_composer_drafts(&json!({"x".repeat(256):" \n "})));
}

#[test]
fn draft_limits_cover_individual_utf8_bytes_total_bytes_and_entry_count() {
    let text = "x".repeat(MAX_COMPOSER_DRAFT_BYTES);
    assert!(validate_composer_drafts(&json!({"new-draft":text})));
    assert!(!validate_composer_drafts(
        &json!({"new-draft":format!("{text}x")})
    ));
    assert!(!validate_composer_drafts(
        &json!({"new-draft":"界".repeat(MAX_COMPOSER_DRAFT_BYTES / 3 + 1)})
    ));
    let mut drafts = Map::new();
    for i in 0..4 {
        drafts.insert(format!("chat-{i}"), json!(text));
    }
    assert!(validate_composer_drafts(&Value::Object(drafts.clone())));
    drafts.insert("one-more-byte".into(), json!("x"));
    assert!(!validate_composer_drafts(&Value::Object(drafts)));
    let mut drafts: Map<String, Value> = (0..MAX_COMPOSER_DRAFTS)
        .map(|i| (format!("chat-{i}"), json!("x")))
        .collect();
    assert!(validate_composer_drafts(&Value::Object(drafts.clone())));
    drafts.insert("overflow".into(), json!("x"));
    assert!(!validate_composer_drafts(&Value::Object(drafts)));
}

#[test]
fn native_v3_envelope_reads_both_versions_without_rewriting_content_or_digest() {
    for version in [9, 10] {
        let mut session = empty(version);
        if version == 10 {
            session["composer_drafts"] = json!({"new-draft":"saved text"});
        }
        let raw = session.to_string();
        let digest = candidate_digest(raw.as_bytes()).unwrap();
        let plan = write(&session, FIRST, &Loaded::Missing);
        let Envelope::Current {
            session_sha256,
            generation,
            ..
        } = validate_envelope(plan.envelope_json.as_bytes(), &Env::default()).unwrap()
        else {
            panic!("current envelope expected")
        };
        assert_eq!(generation, 1);
        assert_eq!(session_sha256, digest);
        let stored: Value = serde_json::from_str(&plan.envelope_json).unwrap();
        assert_eq!(stored["schema_version"], 3);
        assert_eq!(stored["session"], session);
        assert_eq!(
            candidate_digest(canonical_json(&stored["session"]).unwrap().as_slice()),
            Some(digest)
        );
    }
}

#[test]
fn first_draft_commit_upgrades9_to10_under_existing_authority_and_operation_id() {
    let old = empty(9);
    let first = write(&old, FIRST, &Loaded::Missing);
    let old_digest = candidate_digest(old.to_string().as_bytes()).unwrap();
    let current = Loaded::Present {
        generation: 1,
        session_sha256: old_digest.clone(),
        recent_commits: first.recent_commits,
        tombstones: None,
        outbox_operation_ids: vec![],
    };
    let mut new = old.clone();
    new["schema_version"] = json!(10);
    new["composer_drafts"] = json!({"new-draft":"recover after restart"});
    let upgraded = write(&new, SECOND, &current);
    let digest = candidate_digest(new.to_string().as_bytes()).unwrap();
    assert_eq!(upgraded.next_generation, 2);
    assert_ne!(digest, old_digest);
    let persisted = Loaded::Present {
        generation: 2,
        session_sha256: digest.clone(),
        recent_commits: upgraded.recent_commits,
        tombstones: None,
        outbox_operation_ids: vec![],
    };
    assert!(cas_verified(SECOND, 2, &digest, Some(&persisted)));
    assert!(matches!(
        cas_precheck(SECOND, &current.authority(), &digest, &persisted),
        Precheck::Committed { .. }
    ));
    assert_eq!(
        query_commit(SECOND, Some(&persisted))["status"],
        "committed"
    );
    assert_eq!(query_commit(SECOND, None)["status"], "unknown");
    assert!(matches!(
        cas_plan(
            FIRST,
            &current.authority(),
            new.to_string().as_bytes(),
            &Env::default(),
            &persisted,
            Some(&TombstoneView::default()),
            LAUNCH
        )
        .unwrap(),
        Plan::Conflict { .. }
    ));
}

#[test]
fn unknown_versions_fail_closed_in_candidates_envelopes_and_prepared_reads() {
    for version in [0, 8, 11, 100] {
        let mut session = empty(10);
        session["schema_version"] = json!(version);
        session["composer_drafts"] = json!({"new-draft":"must not be discarded"});
        let raw = canonical_json(&session).unwrap();
        assert!(validate_candidate(&raw, &Env::default()).is_err());
        assert_eq!(candidate_digest(&raw), None);
        assert!(cas_plan(
            SECOND,
            &Loaded::Missing.authority(),
            &raw,
            &Env::default(),
            &Loaded::Missing,
            Some(&TombstoneView {
                missing: true,
                ..Default::default()
            }),
            LAUNCH,
        )
        .is_err());
        assert!(session_conversation(&raw, &json!({"conversation_id":LAUNCH})).is_err());
        let plan = write(&empty(10), FIRST, &Loaded::Missing);
        let mut envelope: Value = serde_json::from_str(&plan.envelope_json).unwrap();
        envelope["session"] = session.clone();
        let unknown_digest = session_digest(&session).unwrap();
        envelope["session_sha256"] = json!(unknown_digest);
        envelope["recent_commits"][0]["session_sha256"] = json!(unknown_digest);
        assert!(validate_envelope(envelope.to_string().as_bytes(), &Env::default()).is_err());
        assert_eq!(
            session["composer_drafts"]["new-draft"],
            "must not be discarded"
        );
    }
}

#[test]
fn prepared_and_runtime_proofs_keep_the_same_authority_rules_for_schema10() {
    let conversation = json!({"id":LAUNCH,"attempts":[{"attempt_id":FIRST,"turn_id":SECOND,
        "journal_revision":2,"agent":{"controller_generation":3,"phase":"round_in_flight"}}]});
    let cleanup = json!({"schema_version":1,"cleanup_id":FIRST,"conversation_id":LAUNCH,
        "task_id":SECOND,"attempt_id":FIRST,"transcript_ref":LAUNCH,"transcript_sha256":"a".repeat(64),
        "reason":"completed","created_at":NOW});
    let event = json!({"schema_version":2,"event_id":LAUNCH,"attempt_id":FIRST,"seq":0,
        "kind":"cancel","round_index":null,"call_id":null,"status":"cancelled","safe_summary_key":null,
        "arguments_sha256":null,"result_sha256":null,"approval_reference":LAUNCH,
        "failure_code":"E_AGENT_CANCELLED","created_at":NOW});
    let request = json!({"target":{"kind":"attempt","task_id":SECOND,"attempt_id":FIRST},
        "controller_cas":{"conversation_id":LAUNCH},"cancel_token":{"schema_version":2,
        "issuer":"completion_controller","source_event_id":LAUNCH,"token":LAUNCH,"task_id":SECOND,
        "attempt_id":FIRST,"expected_phase":"round_in_flight","reason_code":"E_AGENT_CANCELLED"}});
    let facts = json!({"session_generation":4,"session_sha256":"b".repeat(64)});
    let expectations = json!({"conversation_id":LAUNCH,"attempt_id":FIRST,"task_id":SECOND,
        "expected_controller_generation":3,"expected_journal_revision":2,
        "expected_session_generation":4,"expected_session_sha256":"b".repeat(64)});
    for version in [9, 10] {
        let mut session = empty(version);
        session["conversations"] = json!([conversation.clone()]);
        session["agent_transcript_cleanup_outbox"] = json!([cleanup.clone()]);
        session["session_events"] = json!([event.clone()]);
        assert_eq!(
            session_conversation(&canonical_json(&session).unwrap(), &expectations).unwrap(),
            Some(conversation.clone())
        );
        assert_eq!(
            session_proof(&session, &facts, &expectations).unwrap()["matches"],
            true
        );
        assert!(cleanup_outbox_proof(&session, &cleanup));
        assert!(cancel_source_proof(&session, &request));
        session["schema_version"] = json!(11);
        assert!(session_proof(&session, &facts, &expectations).is_err());
        assert!(!cleanup_outbox_proof(&session, &cleanup));
        assert!(!cancel_source_proof(&session, &request));
    }
}
