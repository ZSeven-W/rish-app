use super::*;

#[test]
fn group_lane_authorization_and_receipts_survive_membership_changes() {
    let dir = Directory::new();
    let store = dir.store();
    let a = add_bot(&store, "A");
    let b = add_bot(&store, "B");
    let g = group(&store, &a);
    let full = store.load().unwrap();
    let lane = full.groups[0].members[1].conversation_id.clone();
    let auth = store
        .task_tool(&json!({"action":"authorize","conversation_id":lane}))
        .unwrap();
    assert_eq!(auth["assistant_context"]["name"], "A");
    let mut req = request(
        &lane,
        "remember_assistant_memory",
        json!({"title":"Group preference","content":"Use Chinese","kind":"preference"}),
    );
    let effect = apply(&store, &mut req);
    let full = store
        .update_group(
            store.load().unwrap().revision,
            &g,
            "New team",
            &[DEFAULT_BOT_ID.into(), b],
        )
        .unwrap();
    assert_eq!(full.conversation_bot_id(&lane), Some(a.as_str()));
    req["action"] = json!("recover");
    assert_eq!(store.task_tool(&req).unwrap(), effect);
    assert_eq!(
        dir.store().load().unwrap().bots[0].memories[0]
            .source_conversation_id
            .as_deref(),
        Some(lane.as_str())
    );
    let full = store
        .update_group(full.revision, &g, "Team", &[DEFAULT_BOT_ID.into(), a])
        .unwrap();
    assert_eq!(full.groups[0].members[1].conversation_id, lane);
}

#[test]
fn group_claims_are_durable_serial_and_never_create_saved_tasks() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    let g = group(&store, &bot);
    start(
        &store,
        &g,
        &[DEFAULT_BOT_ID.into(), bot.clone()],
        "Discuss this plan",
    );
    let first = store
        .claim_group_next(store.load().unwrap().revision, &g, NOW)
        .unwrap()
        .unwrap();
    assert_eq!(first.bot_id, DEFAULT_BOT_ID);
    assert!(first.claim.snapshot.all_tasks().is_empty());
    assert_eq!(dir.store().load().unwrap().group_claim(&g).unwrap(), first);
    assert!(matches!(
        store.claim_group_next(first.claim.snapshot.revision, &g, NOW),
        Err(AssistantStoreError::Running)
    ));
    assert!(store
        .update_group(
            first.claim.snapshot.revision,
            &g,
            "Changed",
            &[DEFAULT_BOT_ID.into(), bot.clone()]
        )
        .is_err());
    let full = store
        .finish_group_member(
            first.claim.snapshot.revision,
            &g,
            &first.claim.run.run_id,
            complete(),
            Some("First reply"),
            NOW + 1,
        )
        .unwrap();
    assert_eq!(
        store
            .finish_group_member(
                0,
                &g,
                &first.claim.run.run_id,
                complete(),
                Some("First reply"),
                NOW + 1
            )
            .unwrap(),
        full
    );
    let second = store
        .claim_group_next(full.revision, &g, NOW + 2)
        .unwrap()
        .unwrap();
    assert_eq!(second.bot_id, bot);
    assert_eq!(second.claim.run.snapshot.name, "Other");
    assert!(second
        .claim
        .run
        .snapshot
        .instructions
        .contains("First reply"));
    let full = store
        .finish_group_member(
            second.claim.snapshot.revision,
            &g,
            &second.claim.run.run_id,
            complete(),
            Some("Second reply"),
            NOW + 3,
        )
        .unwrap();
    assert!(store
        .claim_group_next(full.revision, &g, NOW + 4)
        .unwrap()
        .is_none());
    assert!(full.all_tasks().is_empty());
    assert_eq!(
        full.groups[0].rounds[0].replies[1].text.as_deref(),
        Some("Second reply")
    );
    start(&store, &g, &[DEFAULT_BOT_ID.into(), bot], "Next question");
    let next = store
        .claim_group_next(store.load().unwrap().revision, &g, NOW + 5)
        .unwrap()
        .unwrap();
    assert!(!next
        .claim
        .run
        .snapshot
        .instructions
        .contains("Discuss this plan"));
    assert!(!next.claim.run.snapshot.instructions.contains("First reply"));
    assert!(next
        .claim
        .run
        .snapshot
        .instructions
        .contains("Second reply"));
}

#[test]
fn group_stop_preserves_running_claim_and_failed_member_stops_future_replies() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    let g = group(&store, &bot);
    start(&store, &g, &[DEFAULT_BOT_ID.into(), bot], "Question");
    let claim = store
        .claim_group_next(store.load().unwrap().revision, &g, NOW)
        .unwrap()
        .unwrap();
    let full = store.stop_group(claim.claim.snapshot.revision, &g).unwrap();
    assert!(full.group_claim(&g).is_some());
    assert!(full.groups[0].rounds[0].stopped);
    let outcome = AssistantRunOutcome {
        status: AssistantRunStatus::Cancelled,
        result_summary: None,
        failure_code: Some("E_CANCELLED".into()),
    };
    let full = store
        .finish_group_member(
            full.revision,
            &g,
            &claim.claim.run.run_id,
            outcome,
            None,
            NOW + 1,
        )
        .unwrap();
    assert!(full.group_claim(&g).is_none());
    assert!(store
        .claim_group_next(full.revision, &g, NOW + 2)
        .unwrap()
        .is_none());
    assert!(full.groups[0].rounds[0].replies[1].run.is_none());
}

#[test]
fn bot_group_create_and_round_create_retries_have_stable_identities() {
    let dir = Directory::new();
    let store = dir.store();
    let id = crate::model::id();
    let profile = AssistantProfile {
        name: "Bot".into(),
        ..Default::default()
    };
    let full = store.create_bot_with_id(0, &id, profile.clone()).unwrap();
    assert_eq!(store.create_bot_with_id(0, &id, profile).unwrap(), full);
    let g = crate::model::id();
    let members = vec![DEFAULT_BOT_ID.into(), id];
    let full = store
        .create_group_with_id(full.revision, &g, "Team", &members)
        .unwrap();
    assert_eq!(
        store.create_group_with_id(0, &g, "Team", &members).unwrap(),
        full
    );
    let round = crate::model::id();
    let full = store
        .start_group_round(
            full.revision,
            &g,
            &round,
            "Question",
            &members,
            &config(),
            NOW,
        )
        .unwrap();
    assert_eq!(
        store
            .start_group_round(0, &g, &round, "Question", &members, &config(), NOW)
            .unwrap(),
        full
    );
    assert!(store
        .start_group_round(
            full.revision,
            &g,
            &round,
            "Different",
            &members,
            &config(),
            NOW
        )
        .is_err());
}

#[test]
fn group_frozen_profile_completion_text_and_workspace_invariants() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Original");
    let g = group(&store, &bot);
    start(&store, &g, &[bot.clone()], "Question");
    let claim = store
        .claim_group_next(store.load().unwrap().revision, &g, NOW)
        .unwrap()
        .unwrap();
    let full = store
        .for_bot(&bot)
        .unwrap()
        .set_profile(
            claim.claim.snapshot.revision,
            AssistantProfile {
                name: "Changed".into(),
                soul: "New soul".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let auth = store
        .task_tool(&json!({"action":"authorize","conversation_id":claim.claim.conversation_id}))
        .unwrap();
    assert_eq!(auth["assistant_context"]["name"], "Original");
    assert_eq!(auth["assistant_context"]["soul"], "Soul for Original");
    let before = dir.bytes();
    assert!(store
        .finish_group_member(
            full.revision,
            &g,
            &claim.claim.run.run_id,
            complete(),
            None,
            NOW + 1
        )
        .is_err());
    assert_eq!(before, dir.bytes());
    let full = store
        .finish_group_member(
            full.revision,
            &g,
            &claim.claim.run.run_id,
            complete(),
            Some(""),
            NOW + 1,
        )
        .unwrap();
    let mut rebound = config();
    rebound.workspace_binding = json!({"workspace_id":"different"});
    assert!(store
        .start_group_round(
            full.revision,
            &g,
            &crate::model::id(),
            "Next",
            &[bot],
            &rebound,
            NOW + 2
        )
        .is_err());
    assert_eq!(store.load().unwrap(), full);
}

#[test]
fn attention_and_failure_never_release_an_unstarted_group_reply() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    let g = group(&store, &bot);
    start(&store, &g, &[DEFAULT_BOT_ID.into(), bot], "Question");
    let claim = store
        .claim_group_next(store.load().unwrap().revision, &g, NOW)
        .unwrap()
        .unwrap();
    let full = store
        .mark_group_attention(
            claim.claim.snapshot.revision,
            &g,
            &claim.claim.run.run_id,
            "E_NEEDS_REVIEW",
            NOW + 1,
        )
        .unwrap();
    assert_eq!(
        full.group_claim(&g).unwrap().claim.run.ids,
        claim.claim.run.ids
    );
    assert!(store.claim_group_next(full.revision, &g, NOW + 2).is_err());
    let outcome = AssistantRunOutcome {
        status: AssistantRunStatus::Failed,
        result_summary: None,
        failure_code: Some("E_FAILED".into()),
    };
    assert!(store
        .finish_group_member(
            full.revision,
            &g,
            &claim.claim.run.run_id,
            outcome.clone(),
            Some("unproven text"),
            NOW + 2
        )
        .is_err());
    let full = store
        .finish_group_member(
            full.revision,
            &g,
            &claim.claim.run.run_id,
            outcome,
            None,
            NOW + 2,
        )
        .unwrap();
    assert!(full.groups[0].rounds[0].stopped);
    assert!(store
        .claim_group_next(full.revision, &g, NOW + 3)
        .unwrap()
        .is_none());
}

#[test]
fn corrupted_group_lane_alias_cannot_authorize_another_bot() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    let full = store
        .ensure_conversation(store.load().unwrap().revision)
        .unwrap();
    let private = full.conversation_id.unwrap();
    let _ = group(&store, &bot);
    let mut raw: Value = serde_json::from_slice(&dir.bytes()).unwrap();
    raw["groups"][0]["members"][1]["conversation_id"] = json!(private);
    let bytes = serde_json::to_vec(&raw).unwrap();
    fs::write(dir.0.join("assistant-v1.json"), &bytes).unwrap();
    assert!(matches!(
        AssistantStore::open(&dir.0),
        Err(AssistantStoreError::Corrupt)
    ));
    assert_eq!(dir.bytes(), bytes);
}

#[test]
fn group_prompt_is_bounded_utf8_and_does_not_copy_private_bot_notes() {
    let dir = Directory::new();
    let store = dir.store();
    let bot = add_bot(&store, "Other");
    let g = group(&store, &bot);
    let full = store
        .set_profile(
            store.load().unwrap().revision,
            AssistantProfile {
                notes: "PRIVATE ONLY".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let round = crate::model::id();
    store
        .start_group_round(
            full.revision,
            &g,
            &round,
            &"中".repeat(2700),
            &[DEFAULT_BOT_ID.into(), bot],
            &config(),
            NOW,
        )
        .unwrap();
    let first = store
        .claim_group_next(store.load().unwrap().revision, &g, NOW)
        .unwrap()
        .unwrap();
    let full = store
        .finish_group_member(
            first.claim.snapshot.revision,
            &g,
            &first.claim.run.run_id,
            complete(),
            Some(&"文".repeat(21000)),
            NOW + 1,
        )
        .unwrap();
    let next = store
        .claim_group_next(full.revision, &g, NOW + 2)
        .unwrap()
        .unwrap();
    assert!(next.claim.run.snapshot.instructions.len() <= MAX_TEXT_BYTES);
    assert!(!next
        .claim
        .run
        .snapshot
        .instructions
        .contains("PRIVATE ONLY"));
}

#[test]
fn directory_bounds_and_duplicate_group_members_fail_without_mutation() {
    let dir = Directory::new();
    let store = dir.store();
    for index in 1..MAX_BOTS {
        add_bot(&store, &format!("Bot {index}"));
    }
    let full = store.load().unwrap();
    let before = dir.bytes();
    assert!(store
        .create_bot_with_id(
            full.revision,
            &crate::model::id(),
            AssistantProfile::default()
        )
        .is_err());
    assert!(store
        .create_group_with_id(
            full.revision,
            &crate::model::id(),
            "Team",
            &[DEFAULT_BOT_ID.into()]
        )
        .is_err());
    assert!(store
        .create_group_with_id(
            full.revision,
            &crate::model::id(),
            "Team",
            &[DEFAULT_BOT_ID.into(), DEFAULT_BOT_ID.into()]
        )
        .is_err());
    assert!(store
        .create_group_with_id(
            full.revision,
            &crate::model::id(),
            "Team",
            &[DEFAULT_BOT_ID.into(), crate::model::id()]
        )
        .is_err());
    assert_eq!(dir.bytes(), before);
}
