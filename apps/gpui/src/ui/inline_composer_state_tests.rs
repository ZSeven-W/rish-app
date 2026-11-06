use super::*;

fn state(text: &str) -> InlineComposerState {
    let mut state = InlineComposerState::default();
    assert!(state.begin_session("conversation-a", text));
    state.set_viewport_height(800.);
    state
}

fn snapshot(state: &InlineComposerState, revision: u64, text: &str) -> Snapshot {
    Snapshot {
        session_id: state.session_id().unwrap().to_owned(),
        status: SnapshotStatus::Ready,
        revision,
        applied_text_revision: state.text_revision(),
        text: text.to_owned(),
        composing: false,
        focused: true,
        keyboard_bottom: 300.,
        content_height: 90.,
    }
}

fn payload(state: &InlineComposerState) -> Value {
    json!({
        "session_id": state.session_id(), "status": "ready", "revision": 1,
        "applied_text_revision": state.text_revision(), "text": "你好",
        "composing": true, "focused": true, "keyboard_bottom": 300.,
        "content_height": 90.,
    })
}

#[test]
fn one_session_per_conversation_and_new_uuid_on_switch_back() {
    let mut state = state("first");
    let first_id = state.session_id().unwrap().to_owned();
    assert!(!state.begin_session("conversation-a", "stale render"));
    assert_eq!(state.text(), "first");
    assert_eq!(state.session_id(), Some(first_id.as_str()));
    assert!(state.begin_session("conversation-b", "second"));
    assert_ne!(state.session_id(), Some(first_id.as_str()));
    assert_eq!(state.current_conversation_key(), Some("conversation-b"));
    assert_eq!(state.text_revision(), 1);
    assert_eq!(state.native_revision(), 0);
    assert!(state.begin_session("conversation-a", "restored first"));
    assert_ne!(state.session_id(), Some(first_id.as_str()));
}

#[test]
fn unsaved_conversation_can_use_an_empty_key() {
    let mut state = InlineComposerState::default();
    assert!(state.begin_session("", "draft"));
    assert!(!state.begin_session("", "draft"));
    assert!(Uuid::parse_str(state.session_id().unwrap()).is_ok());
    assert_eq!(state.text_revision(), 1);
}

#[test]
fn native_ime_changes_never_increment_rust_text_revision() {
    let mut state = state("");
    let mut marked = snapshot(&state, 1, "ni");
    marked.composing = true;
    assert_eq!(state.accept(marked), SnapshotAcceptance::Applied);
    assert!(state.composing());
    assert_eq!(state.text(), "ni");
    assert!(!state.observe_external_text("ni"));
    assert_eq!(state.text_revision(), 1);

    let committed = snapshot(&state, 2, "你\n好👨‍👩‍👧‍👦");
    assert_eq!(state.accept(committed), SnapshotAcceptance::Applied);
    assert!(!state.composing());
    let rendered_text = state.text().to_owned();
    assert!(!state.observe_external_text(&rendered_text));
    assert_eq!(state.text_revision(), 1);
}

#[test]
fn earlier_native_revision_cannot_replace_later_text_or_composition() {
    let mut state = state("");
    let mut old = snapshot(&state, 1, "n");
    old.composing = true;
    let newer = snapshot(&state, 2, "你");
    assert_eq!(state.accept(newer), SnapshotAcceptance::Applied);
    assert_eq!(state.accept(old), SnapshotAcceptance::StaleRevision);
    assert_eq!(state.text(), "你");
    assert!(!state.composing());
    assert_eq!(state.native_revision(), 2);
}

#[test]
fn heartbeat_cannot_mutate_text_at_same_native_revision() {
    let mut state = state("");
    let current = snapshot(&state, 1, "committed");
    assert_eq!(state.accept(current.clone()), SnapshotAcceptance::Applied);
    assert_eq!(state.accept(current), SnapshotAcceptance::Unchanged);
    let inconsistent = snapshot(&state, 1, "different text with same revision");
    assert_eq!(state.accept(inconsistent), SnapshotAcceptance::Unchanged);
    assert_eq!(state.text(), "committed");
}

#[test]
fn initial_native_zero_revision_is_valid_once() {
    let mut state = state("initial");
    let initial = snapshot(&state, 0, "initial");
    assert_eq!(state.accept(initial.clone()), SnapshotAcceptance::Applied);
    assert!(state.focused());
    assert_eq!(state.accept(initial), SnapshotAcceptance::Unchanged);
}

#[test]
fn send_clear_rejects_late_snapshot_even_with_higher_native_revision() {
    let mut state = state("");
    let typed = snapshot(&state, 2, "send this");
    assert_eq!(state.accept(typed), SnapshotAcceptance::Applied);
    let late = snapshot(&state, 3, "send this");
    assert!(state.observe_external_text(""));
    assert_eq!(state.text_revision(), 2);
    assert_eq!(state.accept(late), SnapshotAcceptance::StaleTextRevision);
    assert_eq!(state.text(), "");
    assert_eq!(state.native_revision(), 2);
    let acknowledged = snapshot(&state, 4, "");
    assert_eq!(state.accept(acknowledged), SnapshotAcceptance::Applied);
    assert_eq!(state.text_revision(), 2);
}

#[test]
fn two_rapid_external_replacements_only_accept_latest_acknowledgement() {
    let mut state = state("original");
    let initial = snapshot(&state, 8, "original");
    state.accept(initial);
    assert!(state.observe_external_text("first preset"));
    let first_ack = snapshot(&state, 20, "first preset");
    assert!(state.observe_external_text("second preset"));
    assert_eq!(state.text_revision(), 3);
    assert_eq!(
        state.accept(first_ack),
        SnapshotAcceptance::StaleTextRevision
    );
    assert_eq!(state.native_revision(), 8);
    assert_eq!(state.text(), "second preset");
    let second_ack = snapshot(&state, 21, "second preset");
    assert_eq!(state.accept(second_ack), SnapshotAcceptance::Applied);
    assert_eq!(state.native_revision(), 21);
    assert!(!state.observe_external_text("second preset"));
    assert_eq!(state.text_revision(), 3);
}

#[test]
fn unexpected_future_text_revision_is_rejected_without_advancing_state() {
    let mut state = state("mine");
    let mut unexpected = snapshot(&state, 99, "not mine");
    unexpected.applied_text_revision += 1;
    assert_eq!(
        state.accept(unexpected),
        SnapshotAcceptance::StaleTextRevision
    );
    assert_eq!(state.text(), "mine");
    assert_eq!(state.native_revision(), 0);
}

#[test]
fn conversation_change_rejects_old_text_and_old_close() {
    let mut state = state("first");
    let old = snapshot(&state, 70, "first draft");
    let mut old_close = old.clone();
    old_close.status = SnapshotStatus::Closed;
    state.begin_session("conversation-b", "second");
    assert_eq!(state.accept(old), SnapshotAcceptance::StaleSession);
    assert_eq!(state.accept(old_close), SnapshotAcceptance::StaleSession);
    assert_eq!(state.text(), "second");
    assert!(!state.is_closed());
}

#[test]
fn closed_snapshot_retains_final_draft_and_cannot_be_reopened_by_late_ready() {
    let mut state = state("draft");
    let mut closed = snapshot(&state, 4, "final draft");
    closed.status = SnapshotStatus::Closed;
    closed.composing = true;
    assert_eq!(state.accept(closed.clone()), SnapshotAcceptance::Closed);
    assert_eq!(state.text(), "final draft");
    assert!(!state.focused());
    assert!(!state.composing());
    assert_eq!(state.keyboard_bottom(), 0.);
    assert_eq!(state.accept(closed), SnapshotAcceptance::Unchanged);
    let late = snapshot(&state, 5, "late edit");
    assert_eq!(state.accept(late), SnapshotAcceptance::SessionClosed);
    assert_eq!(state.text(), "final draft");
    assert!(!state.observe_external_text("cannot resurrect"));
    let prior_id = state.session_id().unwrap().to_owned();
    assert!(state.begin_session("conversation-a", "final draft"));
    assert_ne!(state.session_id(), Some(prior_id.as_str()));
}

#[test]
fn close_at_same_native_revision_still_installs_terminal_session_fence() {
    let mut state = state("draft");
    let current = snapshot(&state, 3, "final draft");
    state.accept(current);
    let mut closed = snapshot(&state, 3, "cannot change text without revision");
    closed.status = SnapshotStatus::Closed;
    assert_eq!(state.accept(closed), SnapshotAcceptance::Closed);
    assert!(state.is_closed());
    assert_eq!(state.text(), "final draft");
    assert_eq!(state.keyboard_bottom(), 0.);
    let late = snapshot(&state, 4, "late");
    assert_eq!(state.accept(late), SnapshotAcceptance::SessionClosed);
}

#[test]
fn background_close_with_old_text_ack_preserves_queued_rust_replacement() {
    let mut state = state("native draft");
    let current = snapshot(&state, 7, "native draft");
    state.accept(current);
    let mut closed = snapshot(&state, 8, "native draft");
    closed.status = SnapshotStatus::Closed;
    let old_session = closed.session_id.clone();
    assert!(state.observe_external_text("new preset not sent yet"));
    assert_eq!(state.accept(closed), SnapshotAcceptance::StaleTextRevision);
    assert!(state.mark_closed(&old_session));
    assert_eq!(state.text(), "new preset not sent yet");
    assert_eq!(state.text_revision(), 2);
    assert_eq!(state.native_revision(), 7);
    assert!(!state.focused());
    assert!(!state.composing());
    assert_eq!(state.keyboard_bottom(), 0.);
    let text = state.text().to_owned();
    assert!(state.begin_session("conversation-a", &text));
    assert_ne!(state.session_id(), Some(old_session.as_str()));
    assert_eq!(state.text(), "new preset not sent yet");
    assert!(!state.mark_closed(&old_session));
    assert!(!state.is_closed());
}

#[test]
fn keyboard_bottom_is_focus_scoped_clamped_and_not_added_to_safe_area() {
    let mut state = state("");
    let focused = snapshot(&state, 1, "");
    state.accept(focused);
    assert_eq!(state.bottom_inset(34.), 300.);
    state.set_viewport_height(100.);
    assert_eq!(state.keyboard_bottom(), 100.);
    assert_eq!(state.bottom_inset(134.), 100.);
    state.set_viewport_height(800.);
    assert_eq!(state.keyboard_bottom(), 300.);
    let mut blurred = snapshot(&state, 2, "");
    blurred.focused = false;
    state.accept(blurred);
    assert_eq!(state.keyboard_bottom(), 0.);
    assert_eq!(state.bottom_inset(34.), 34.);
}

#[test]
fn short_viewport_clips_native_hit_rectangle_without_changing_text() {
    let mut state = state("short screen draft");
    state.set_viewport_height(50.);
    let geometry = InputGeometry::new([12., 35., 300., 80.], [320., 50.], 3.);
    assert_eq!(geometry.rect, [12., 35., 300., 15.]);
    let value = state
        .sync_payload(geometry, true, None, "light", "Write")
        .unwrap();
    assert_eq!(value["visible"], true);
    assert_eq!(value["focus"], Value::Null);
    assert_eq!(value["rect"], json!([12., 35., 300., 15.]));
    assert_eq!(state.text(), "short screen draft");
    assert_eq!(state.text_revision(), 1);
}

#[test]
fn offscreen_editor_is_hidden_and_resigned() {
    let state = state("preserved");
    let geometry = InputGeometry::new([12., 100., 300., 80.], [320., 50.], 3.);
    let value = state
        .sync_payload(geometry, true, Some(true), "dark", "Write")
        .unwrap();
    assert_eq!(value["visible"], false);
    assert_eq!(value["focus"], false);
    assert_eq!(value["text"], "preserved");
    assert_eq!(value["appearance"], "dark");
}

#[test]
fn geometry_and_focus_syncs_never_advance_text_revision_or_reset_ime() {
    let mut state = state("");
    let mut marked = snapshot(&state, 1, "zhong");
    marked.composing = true;
    state.accept(marked);
    for height in [800., 500., 450.] {
        let geometry = InputGeometry::new([10., 10., 300., 80.], [320., height], 3.);
        let value = state
            .sync_payload(geometry, true, None, "light", "Write")
            .unwrap();
        assert_eq!(value["text_revision"], 1);
        assert_eq!(value["text"], "zhong");
        assert_eq!(value.as_object().unwrap().len(), 10);
    }
    assert!(state.composing());
    assert_eq!(state.native_revision(), 1);
}

#[test]
fn geometry_normalizes_invalid_metrics_and_intersects_negative_origin() {
    assert_eq!(
        InputGeometry::new([-10., -20., 100., 100.], [320., 800.], 2.).rect,
        [0., 0., 90., 80.]
    );
    let bad = InputGeometry::new([f32::NAN, f32::INFINITY, -10., 200.], [-2., 50.], 0.);
    assert_eq!(bad.rect, [0., 0., 0., 50.]);
    assert_eq!(bad.scale, 1.);
    assert!(bad.is_empty());
    let huge = InputGeometry::new([0., 0., f32::MAX, f32::MAX], [320., 800.], 3.);
    assert_eq!(huge.rect, [0., 0., 320., 800.]);
}

#[test]
fn snapshot_parser_enforces_exact_types_and_bounds_without_echoing_text() {
    let state = state("");
    assert!(Snapshot::parse(&payload(&state)).is_ok());
    for (key, invalid) in [
        ("status", json!("error")),
        ("session_id", json!("not-uuid")),
        ("revision", json!(-1)),
        ("revision", json!(1.5)),
        ("applied_text_revision", json!(0)),
        ("focused", json!(1)),
        ("keyboard_bottom", json!(-20)),
        ("content_height", json!("80")),
        ("text", json!("秘密".repeat(MAX_TEXT_BYTES / 6 + 1))),
    ] {
        let mut value = payload(&state);
        value[key] = invalid;
        assert_eq!(
            Snapshot::parse(&value),
            Err("E_INLINE_COMPOSER_INVALID"),
            "{key}"
        );
    }
    let mut extra = payload(&state);
    extra["unexpected"] = json!(true);
    assert!(Snapshot::parse(&extra).is_err());
    extra.as_object_mut().unwrap().remove("unexpected");
    extra.as_object_mut().unwrap().remove("text");
    assert!(Snapshot::parse(&extra).is_err());
}

#[test]
fn preferred_content_height_is_clamped() {
    let mut state = state("");
    let mut small = payload(&state);
    small["content_height"] = json!(1);
    let small = Snapshot::parse(&small).unwrap();
    assert_eq!(small.content_height, 80.);
    state.accept(small);
    let mut tall = payload(&state);
    tall["revision"] = json!(2);
    tall["content_height"] = json!(9999);
    state.accept(Snapshot::parse(&tall).unwrap());
    assert_eq!(state.content_height(), 168.);
    assert!(state.observe_external_text(""));
    assert_eq!(state.content_height(), 80.);
}

#[test]
fn unstarted_or_closed_state_never_emits_sync() {
    let geometry = InputGeometry::new([0., 0., 300., 80.], [320., 800.], 3.);
    let mut state = InlineComposerState::default();
    assert!(
        state
            .sync_payload(geometry, true, None, "light", "Write")
            .is_none()
    );
    assert!(!state.observe_external_text("not yet"));
    state.begin_session("", "draft");
    let mut closed = snapshot(&state, 1, "draft");
    closed.status = SnapshotStatus::Closed;
    state.accept(closed);
    assert!(
        state
            .sync_payload(geometry, true, None, "light", "Write")
            .is_none()
    );
}

#[test]
fn revision_exhaustion_closes_instead_of_accepting_old_revision() {
    let mut state = state("last");
    state.text_revision = u64::MAX;
    state.allocated_text_revision = u64::MAX;
    assert!(!state.observe_external_text("cannot wrap"));
    assert!(state.is_closed());
    assert_eq!(state.text_revision(), u64::MAX);
    assert_eq!(state.text(), "last");
}

fn prepared_clear() -> (InlineComposerState, Snapshot, u64, u64) {
    let mut state = state("sent text");
    let current = snapshot(&state, 7, "sent text");
    state.accept(current);
    let previous = state.text_revision();
    let reserved = state.reserve_text_revision().unwrap();
    let mut cleared = snapshot(&state, 8, "");
    cleared.applied_text_revision = reserved;
    (state, cleared, reserved, previous)
}

#[test]
fn revision_reservation_does_not_change_active_text_or_sync_payload() {
    let (state, _, reserved, previous) = prepared_clear();
    assert_eq!(reserved, previous + 1);
    assert_eq!(state.text_revision(), previous);
    assert_eq!(state.text(), "sent text");
    let geometry = InputGeometry::new([0., 0., 300., 80.], [320., 800.], 3.);
    let value = state
        .sync_payload(geometry, true, None, "light", "Write")
        .unwrap();
    assert_eq!(value["text_revision"], previous);
    assert_eq!(value["text"], "sent text");
}

#[test]
fn successful_conditional_clear_authorizes_only_its_reserved_revision() {
    let (mut state, cleared, reserved, previous) = prepared_clear();
    assert_eq!(
        state.accept_reserved_clear(cleared, reserved, previous, true),
        SnapshotAcceptance::Applied
    );
    assert_eq!(state.text_revision(), reserved);
    assert_eq!(state.text(), "");
    assert_eq!(state.native_revision(), 8);
    assert!(state.observe_external_text("next preset"));
    assert_eq!(state.text_revision(), reserved + 1);
}

#[test]
fn preset_during_native_clear_uses_later_revision_and_rejects_clear_ack() {
    let (mut state, cleared, reserved, previous) = prepared_clear();
    assert!(state.observe_external_text("new preset"));
    assert_eq!(state.text_revision(), reserved + 1);
    assert_eq!(
        state.accept_reserved_clear(cleared, reserved, previous, true),
        SnapshotAcceptance::StaleTextRevision
    );
    assert_eq!(state.text(), "new preset");
    assert_eq!(state.text_revision(), reserved + 1);
    assert_eq!(state.native_revision(), 7);
}

#[test]
fn failed_clear_preserves_concurrent_ime_and_never_reclaims_reserved_revision() {
    let (mut state, _, reserved, previous) = prepared_clear();
    let mut composing = snapshot(&state, 8, "sent text 新");
    composing.composing = true;
    assert_eq!(
        state.accept_reserved_clear(composing, reserved, previous, false),
        SnapshotAcceptance::Applied
    );
    assert_eq!(state.text(), "sent text 新");
    assert!(state.composing());
    assert_eq!(state.text_revision(), previous);
    assert_eq!(state.native_revision(), 8);
    assert!(state.observe_external_text("explicit preset"));
    assert_eq!(state.text_revision(), reserved + 1);
}

#[test]
fn failed_clear_then_another_send_clear_skips_the_failed_reservation() {
    let (mut state, _, first, previous) = prepared_clear();
    let changed = snapshot(&state, 8, "next message");
    state.accept_reserved_clear(changed, first, previous, false);
    let second = state.reserve_text_revision().unwrap();
    assert_eq!(second, first + 1);
    assert_eq!(state.text_revision(), previous);
    let mut cleared = snapshot(&state, 9, "");
    cleared.applied_text_revision = second;
    assert_eq!(
        state.accept_reserved_clear(cleared, second, previous, true),
        SnapshotAcceptance::Applied
    );
    assert_eq!(state.text_revision(), second);
    assert_eq!(state.text(), "");
}

#[test]
fn late_clear_from_another_session_cannot_consume_new_sessions_same_number() {
    let (mut state, old_clear, reserved, previous) = prepared_clear();
    state.begin_session("conversation-b", "second draft");
    let new_reserved = state.reserve_text_revision().unwrap();
    assert_eq!(new_reserved, reserved);
    assert_eq!(
        state.accept_reserved_clear(old_clear, reserved, previous, true),
        SnapshotAcceptance::StaleSession
    );
    assert_eq!(state.text(), "second draft");
    let mut current_clear = snapshot(&state, 1, "");
    current_clear.applied_text_revision = new_reserved;
    assert_eq!(
        state.accept_reserved_clear(current_clear, new_reserved, previous, true),
        SnapshotAcceptance::Applied
    );
}

#[test]
fn old_or_equal_native_clear_revision_cannot_authorize_reserved_text_revision() {
    for revision in [6, 7] {
        let (mut state, mut cleared, reserved, previous) = prepared_clear();
        cleared.revision = revision;
        assert_eq!(
            state.accept_reserved_clear(cleared, reserved, previous, true),
            SnapshotAcceptance::StaleRevision
        );
        assert_eq!(state.text_revision(), previous);
        assert_eq!(state.text(), "sent text");
        assert_eq!(state.native_revision(), 7);
    }
}

#[test]
fn invalid_clear_payload_never_authorizes_reserved_text_revision() {
    for invalid in 0..5 {
        let (mut state, mut cleared, reserved, previous) = prepared_clear();
        match invalid {
            0 => cleared.text = "unexpected text".to_owned(),
            1 => cleared.composing = true,
            2 => cleared.status = SnapshotStatus::Closed,
            3 => cleared.keyboard_bottom = f32::NAN,
            _ => cleared.content_height = -1.,
        }
        assert_eq!(
            state.accept_reserved_clear(cleared, reserved, previous, true),
            SnapshotAcceptance::InvalidSnapshot
        );
        assert_eq!(state.text_revision(), previous);
        assert_eq!(state.text(), "sent text");
        assert_eq!(state.native_revision(), 7);
    }
}

#[test]
fn unreserved_future_or_mismatched_clear_revision_cannot_authorize_text() {
    for invalid in 0..3 {
        let (mut state, mut cleared, reserved, previous) = prepared_clear();
        let (request_reserved, request_previous) = match invalid {
            0 => {
                cleared.applied_text_revision += 1;
                (reserved + 1, previous)
            }
            1 => {
                cleared.applied_text_revision += 1;
                (reserved, previous)
            }
            _ => (reserved, previous + 1),
        };
        assert_eq!(
            state.accept_reserved_clear(cleared, request_reserved, request_previous, true),
            SnapshotAcceptance::StaleTextRevision
        );
        assert_eq!(state.text_revision(), previous);
        assert_eq!(state.text(), "sent text");
    }
}

#[test]
fn reservation_high_water_never_rolls_back_when_an_earlier_clear_succeeds() {
    let (mut state, cleared, first, previous) = prepared_clear();
    let second = state.reserve_text_revision().unwrap();
    assert_eq!(
        state.accept_reserved_clear(cleared, first, previous, true),
        SnapshotAcceptance::Applied
    );
    assert_eq!(state.text_revision(), first);
    assert!(state.observe_external_text("later preset"));
    assert_eq!(state.text_revision(), second + 1);
}

#[test]
fn no_revision_can_be_reserved_before_start_after_close_or_at_exhaustion() {
    let mut state = InlineComposerState::default();
    assert_eq!(state.reserve_text_revision(), None);
    state.begin_session("a", "draft");
    let session = state.session_id().unwrap().to_owned();
    state.mark_closed(&session);
    assert_eq!(state.reserve_text_revision(), None);
    state.begin_session("a", "retained");
    state.allocated_text_revision = u64::MAX;
    assert_eq!(state.reserve_text_revision(), None);
    assert_eq!(state.text_revision(), 1);
    assert_eq!(state.text(), "retained");
}

#[test]
fn first_conversation_adopts_live_draft_without_resetting_ime_or_revisions() {
    let mut state = InlineComposerState::default();
    state.begin_session("new-draft", "preset");
    state.set_viewport_height(800.);
    assert!(state.observe_external_text("updated preset"));
    let mut marked = snapshot(&state, 9, "updated preset 新");
    marked.composing = true;
    state.accept(marked);
    let original_session = state.session_id().unwrap().to_owned();
    let reserved = state.reserve_text_revision().unwrap();

    assert!(state.adopt_initial_conversation("conversation-created"));
    assert_eq!(
        state.current_conversation_key(),
        Some("conversation-created")
    );
    assert_eq!(state.session_id(), Some(original_session.as_str()));
    assert_eq!(state.text(), "updated preset 新");
    assert_eq!(state.text_revision(), 2);
    assert_eq!(state.native_revision(), 9);
    assert!(state.composing());
    assert!(state.focused());
    assert_eq!(state.keyboard_bottom(), 300.);
    assert_eq!(state.content_height(), 90.);
    assert!(!state.begin_session("conversation-created", "stale CAS draft"));
    assert!(state.observe_external_text("later explicit replacement"));
    assert_eq!(state.text_revision(), reserved + 1);

    assert!(state.begin_session("another-conversation", "other draft"));
    assert_ne!(state.session_id(), Some(original_session.as_str()));
    assert_eq!(state.text(), "other draft");
}

#[test]
fn initial_conversation_adoption_rejects_non_draft_closed_or_unchanged_keys() {
    let mut state = InlineComposerState::default();
    assert!(!state.adopt_initial_conversation("created"));
    state.begin_session("new-draft", "draft");
    assert!(!state.adopt_initial_conversation("new-draft"));
    let session = state.session_id().unwrap().to_owned();
    state.mark_closed(&session);
    assert!(!state.adopt_initial_conversation("created"));
    assert_eq!(state.current_conversation_key(), Some("new-draft"));
    state.begin_session("existing-conversation", "existing draft");
    assert!(!state.adopt_initial_conversation("another-conversation"));
    assert_eq!(
        state.current_conversation_key(),
        Some("existing-conversation")
    );
    assert_eq!(state.text(), "existing draft");
}
