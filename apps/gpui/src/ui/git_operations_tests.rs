use super::{git_commands::*, git_operations::*, screens::Browser, workspace_git::GitState};
use serde_json::{Value, json};

fn root() -> Value {
    json!({"schema_version":1,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024","binding_revision":4,"project_id":"85ac8af6-b884-4b55-b63a-b46cabf56296"})
}
fn oid() -> Value {
    json!("a".repeat(40))
}
fn request(action: GitAction, step: GitStep) -> GitActionRequest {
    GitActionRequest {
        generation: 7,
        root: root(),
        action,
        step,
        id: "1c9b27cd-ebde-490c-b1f0-6edc886a5d72".into(),
        head: oid(),
        branch: json!("main"),
        host: json!("example.test"),
        origin: json!("https://example.test/repo.git"),
        fields: Value::Null,
        receipts: vec![],
        acknowledged: false,
    }
}
fn envelope(mut value: Value) -> Value {
    value["schema_version"] = json!(2);
    value["root"] = root();
    value["project_id"] = root()["project_id"].clone();
    value
}
fn browser() -> Browser {
    let mut browser = Browser {
        root: Some(root()),
        generation: 7,
        capabilities: json!({"read":true,"write":true,"git":true}),
        ..Default::default()
    };
    browser.git = GitState::Attached(envelope(
        json!({"head_oid":oid(),"branch":"main","clean":true,"has_conflicts":false,"ahead":1,"behind":0,"entries":[]}),
    ));
    browser.git_actions.metadata_root = Some(root());
    browser.git_actions.remote = Some(envelope(
        json!({"remote":"origin","url":"https://example.test/repo.git","host":"example.test"}),
    ));
    browser.git_actions.credential =
        Some(envelope(json!({"configured":true,"host":"example.test"})));
    browser
}
fn receipt() -> Value {
    json!({"schema_version":1,"remote":"origin","host":"example.test","branch":"main","local_oid":oid(),"remote_oid":oid(),"pushed_at":"2026-10-14T12:00:00Z"})
}

#[test]
fn native_mutation_commands_keep_exact_keys_and_captured_preconditions() {
    let mut request = request(GitAction::Commit, GitStep::Commit);
    request.fields =
        json!({"message":"修复保存","author_name":"Test User","author_email":"test@example.test"});
    let command = request.command();
    assert_eq!(command.method, "commitV2");
    assert_eq!(
        command.args,
        vec![
            json!({"schema_version":1,"root":root(),"operation_id":request.id,"message":"修复保存","author_name":"Test User","author_email":"test@example.test","expected_head_oid":oid()})
        ]
    );
    request.step = GitStep::Pull;
    assert_eq!(
        request.command().args,
        vec![json!({"schema_version":1,"root":root(),"expected_head_oid":oid()})]
    );
    request.step = GitStep::Push;
    assert_eq!(
        request.command().args,
        vec![
            json!({"schema_version":1,"root":root(),"operation_id":request.id,"remote":"origin","expected_local_oid":oid(),"credential_reference":"native-keychain","https_proxy_url":null})
        ]
    );
    assert!(
        !request.command().args[0]
            .as_object()
            .unwrap()
            .contains_key("force")
    );
}

#[test]
fn unborn_commit_preserves_null_expected_head_and_does_not_invent_identity() {
    let mut request = request(GitAction::Commit, GitStep::Commit);
    request.head = Value::Null;
    request.fields =
        json!({"message":"Initial","author_name":"User","author_email":"user@example.test"});
    assert!(request.command().args[0]["expected_head_oid"].is_null());
    assert!(
        validate_fields(
            GitAction::Commit,
            &json!({"message":"Initial","author_name":"","author_email":""})
        )
        .is_err()
    );
}

#[test]
fn fetch_credentials_and_cancel_use_the_native_root_contract() {
    let mut request = request(GitAction::Fetch, GitStep::Fetch);
    assert_eq!(
        request.command().args,
        vec![
            json!({"schema_version":1,"root":root(),"operation_id":request.id,"remote":"origin","https_proxy_url":null})
        ]
    );
    assert_eq!(
        request.cancel_command().args,
        vec![json!({"schema_version":1,"root":root(),"operation_id":request.id})]
    );
    request.step = GitStep::PromptCredential;
    request.fields = json!({"locale":"zh-CN"});
    assert_eq!(
        request.command().args,
        vec![json!({"schema_version":1,"root":root(),"locale":"zh-CN"})]
    );
}

#[test]
fn dirty_conflicted_and_unborn_workspaces_cannot_pull() {
    let mut browser = browser();
    assert!(action_available(&browser, GitAction::Pull));
    for (key, value) in [
        ("clean", json!(false)),
        ("has_conflicts", json!(true)),
        ("head_oid", Value::Null),
        ("branch", Value::Null),
    ] {
        let previous = match &mut browser.git {
            GitState::Attached(s) => {
                let old = s[key].clone();
                s[key] = value;
                old
            }
            _ => unreachable!(),
        };
        assert!(!action_available(&browser, GitAction::Pull), "{key}");
        if let GitState::Attached(s) = &mut browser.git {
            s[key] = previous;
        }
    }
}

#[test]
fn stale_metadata_or_missing_credentials_cannot_authorize_push() {
    let mut browser = browser();
    assert!(action_available(&browser, GitAction::Push));
    browser.git_actions.credential.as_mut().unwrap()["configured"] = json!(false);
    assert!(!action_available(&browser, GitAction::Push));
    browser.git_actions.credential.as_mut().unwrap()["configured"] = json!(true);
    browser.git_actions.metadata_root.as_mut().unwrap()["binding_revision"] = json!(5);
    assert!(!action_available(&browser, GitAction::Push));
}

#[test]
fn ambiguous_push_blocks_resending_and_origin_changes_until_a_new_matching_receipt() {
    let mut browser = browser();
    let mut request = request(GitAction::Push, GitStep::Push);
    request.receipts = vec![receipt()];
    browser
        .git_actions
        .uncertain
        .insert(root().to_string(), request.clone());
    assert!(!action_available(&browser, GitAction::Push));
    assert!(!action_available(&browser, GitAction::Remote));
    assert!(action_available(&browser, GitAction::CheckPush));
    assert!(!confirms_push(&request, &[receipt()]));
    let mut fresh = receipt();
    fresh["pushed_at"] = json!("2026-10-14T13:00:00Z");
    assert!(confirms_push(&request, &[fresh.clone()]));
    fresh["host"] = json!("other.test");
    assert!(!confirms_push(&request, &[fresh]));
}

#[test]
fn stage_commit_and_remote_field_validation_enforce_native_boundaries() {
    let mut browser = browser();
    assert!(!action_available(&browser, GitAction::Stage));
    assert!(!action_available(&browser, GitAction::Commit));
    if let GitState::Attached(s) = &mut browser.git {
        s["entries"] =
            json!([{"path":"a.txt","index_status":"unmodified","worktree_status":"modified"}]);
    }
    assert!(action_available(&browser, GitAction::Stage));
    assert!(!action_available(&browser, GitAction::Commit));
    if let GitState::Attached(s) = &mut browser.git {
        s["entries"][0]["index_status"] = json!("modified");
    }
    assert!(action_available(&browser, GitAction::Commit));
    for url in [
        "ssh://example.test/repo",
        "https://token@example.test/repo",
        "https://example.test/repo?token=secret",
        "https://example.test/repo#secret",
    ] {
        assert!(validate_fields(GitAction::Remote, &json!({"url":url})).is_err());
    }
    for message in ["line one\nline two".to_owned(), "文".repeat(167)] {
        assert!(
            validate_fields(
                GitAction::Commit,
                &json!({"message":message,"author_name":"User","author_email":"user@example.test"})
            )
            .is_err()
        );
    }
}

#[test]
fn requests_and_response_envelopes_are_bound_to_generation_and_identity() {
    let mut browser = browser();
    let request = request(GitAction::Stage, GitStep::Stage);
    assert!(request.current(&browser));
    browser.generation += 1;
    assert!(!request.current(&browser));
    browser.generation -= 1;
    browser.root.as_mut().unwrap()["binding_revision"] = json!(5);
    assert!(!request.current(&browser));
    let mut response = envelope(json!({}));
    assert!(request.validate_envelope(&response).is_ok());
    response["root"]["binding_revision"] = json!(5);
    assert!(request.validate_envelope(&response).is_err());
}

#[test]
fn only_proven_pretransport_or_explicit_ref_rejections_clear_write_uncertainty() {
    for code in [
        "E_PROJECT_REQUEST_INVALID",
        "E_PROJECT_CONFLICT",
        "E_PROJECT_NON_FAST_FORWARD",
        "E_WORKSPACE_CONFIRMATION",
    ] {
        assert!(definitely_not_written(code));
    }
    for code in [
        "E_PROJECT_UNAVAILABLE",
        "E_PROJECT_CREDENTIAL",
        "E_PROJECT_CANCELLED",
        "E_PROJECT_TIMEOUT",
        "E_PROJECT_NATIVE",
        "Disconnected",
    ] {
        assert!(!definitely_not_written(code));
    }
}

#[test]
fn metadata_reads_are_allowed_during_cancel_fence_but_scope_mismatched_status_is_not() {
    let mut browser = browser();
    browser.git_actions.cancelling = Some(request(GitAction::Fetch, GitStep::Fetch));
    assert!(action_available(&browser, GitAction::Refresh));
    assert!(!action_available(&browser, GitAction::Push));
    browser.root.as_mut().unwrap()["binding_revision"] = json!(5);
    assert!(!action_available(&browser, GitAction::Refresh));
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
mod controller {
    use super::*;
    use crate::ui::{Reply, Shell};
    use gpui::{Context, TestAppContext, px, size};
    fn with_shell(test: impl FnOnce(&mut Shell, &mut Context<Shell>)) {
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
        window
            .update(&mut cx, |shell, _, cx| {
                shell.browser = browser();
                test(shell, cx);
            })
            .unwrap();
    }
    #[test]
    fn navigation_while_cancelled_recovery_is_deferred_releases_its_busy_state() {
        with_shell(|shell, cx| {
            let cancelled = request(GitAction::Push, GitStep::Push);
            let deferred = GitActionRequest {
                step: GitStep::VerifyPush,
                ..cancelled.clone()
            };
            shell.browser.git_actions.cancelling = Some(cancelled.clone());
            shell.browser.git_actions.resume_after_cancel = Some(deferred.clone());
            shell.browser.git_actions.pending = Some(deferred);
            shell
                .browser
                .git_actions
                .uncertain
                .insert(root().to_string(), cancelled.clone());
            shell.browser.generation += 1;
            shell.aux_busy = true;
            shell.accept_git_cancel(
                cancelled,
                Ok(envelope(json!({"status":"cancel_requested"}))),
                cx,
            );
            assert!(shell.browser.git_actions.pending.is_none());
            assert!(shell.browser.git_actions.resume_after_cancel.is_none());
            assert!(!shell.aux_busy);
            assert!(shell.browser.git_actions.has_uncertain_push(Some(&root())));
        });
    }
    #[test]
    fn abandoning_deferred_recovery_never_releases_a_newer_requests_busy_state() {
        with_shell(|shell, cx| {
            let cancelled = request(GitAction::Push, GitStep::Push);
            let deferred = GitActionRequest {
                step: GitStep::VerifyPush,
                ..cancelled.clone()
            };
            shell.browser.git_actions.cancelling = Some(cancelled.clone());
            shell.browser.git_actions.resume_after_cancel = Some(deferred);
            shell.browser.generation += 1;
            let newer = GitActionRequest {
                generation: shell.browser.generation,
                id: uuid::Uuid::new_v4().to_string(),
                action: GitAction::Diff,
                step: GitStep::Diff,
                ..cancelled.clone()
            };
            shell.browser.git_actions.pending = Some(newer.clone());
            shell.aux_busy = true;
            shell.accept_git_cancel(
                cancelled,
                Ok(envelope(json!({"status":"cancel_requested"}))),
                cx,
            );
            assert_eq!(shell.browser.git_actions.pending, Some(newer));
            assert!(shell.aux_busy);
            assert!(shell.browser.git_actions.resume_after_cancel.is_none());
        });
    }
    #[test]
    fn another_projects_cancel_intent_cannot_cancel_the_selected_projects_pull() {
        with_shell(|shell, cx| {
            let mut old = request(GitAction::Fetch, GitStep::Fetch);
            old.root["project_id"] = json!("223a22b5-ff4f-480e-b730-c67685809822");
            shell.browser.git_actions.cancelling = Some(old.clone());
            shell.browser.git_actions.cancelled_operation = Some(old.id);
            shell.browser.git_actions.cancel_requested = true;
            let current = GitActionRequest {
                id: uuid::Uuid::new_v4().to_string(),
                ..request(GitAction::Pull, GitStep::Fetch)
            };
            shell.browser.git_actions.pending = Some(current.clone());
            shell.aux_busy = true;
            shell.accept(
                Reply::GitAction(current),
                Ok(envelope(
                    json!({"remote":"origin","branch":"main","remote_oid":oid()}),
                )),
                cx,
            );
            assert_eq!(
                shell.browser.git_actions.pending.as_ref().unwrap().step,
                GitStep::Pull
            );
            assert!(!shell.browser.git_actions.cancel_requested);
        });
    }
    #[test]
    fn status_refresh_invalidates_old_diff_without_dropping_uncertain_pushes() {
        with_shell(|shell, cx| {
            shell.browser.git_actions.diff = Some(envelope(
                json!({"staged":false,"patch":"old patch","files":[],"truncated":false}),
            ));
            shell
                .browser
                .git_actions
                .uncertain
                .insert(root().to_string(), request(GitAction::Push, GitStep::Push));
            shell.load_git_metadata(cx);
            assert!(shell.browser.git_actions.diff.is_none());
            assert!(shell.browser.git_actions.remote.is_none());
            assert!(shell.browser.git_actions.credential.is_none());
            assert!(shell.browser.git_actions.metadata_root.is_none());
            assert!(shell.browser.git_actions.has_uncertain_push(Some(&root())));
        });
    }
    #[test]
    fn stale_diff_reply_cannot_replace_the_selected_workspaces_current_diff() {
        with_shell(|shell, cx| {
            let old = request(GitAction::Diff, GitStep::Diff);
            shell.browser.generation += 1;
            let newer = GitActionRequest {
                generation: shell.browser.generation,
                id: uuid::Uuid::new_v4().to_string(),
                ..old.clone()
            };
            shell.browser.git_actions.pending = Some(newer.clone());
            shell.aux_busy = true;
            shell.browser.git_actions.diff = Some(json!({"patch":"current"}));
            shell.accept(
                Reply::GitAction(old),
                Ok(envelope(
                    json!({"staged":false,"patch":"stale","files":[],"truncated":false}),
                )),
                cx,
            );
            assert_eq!(
                shell.browser.git_actions.diff.as_ref().unwrap()["patch"],
                "current"
            );
            assert_eq!(shell.browser.git_actions.pending, Some(newer));
            assert!(shell.aux_busy);
        });
    }
    #[test]
    fn stale_definite_rejection_settles_only_its_captured_push_attempt() {
        with_shell(|shell, cx| {
            let old = request(GitAction::Push, GitStep::Push);
            shell
                .browser
                .git_actions
                .uncertain
                .insert(root().to_string(), old.clone());
            shell.browser.generation += 1;
            let current = GitActionRequest {
                generation: shell.browser.generation,
                id: uuid::Uuid::new_v4().to_string(),
                ..request(GitAction::Diff, GitStep::Diff)
            };
            shell.browser.git_actions.pending = Some(current.clone());
            shell.aux_busy = true;
            shell.accept(
                Reply::GitAction(old),
                Err("E_PROJECT_NON_FAST_FORWARD".into()),
                cx,
            );
            assert!(!shell.browser.git_actions.has_uncertain_push(Some(&root())));
            assert_eq!(shell.browser.git_actions.pending, Some(current));
            assert!(shell.aux_busy);
            assert!(shell.browser.git_actions.feedback.is_none());
        });
    }
    #[test]
    fn cancel_ack_fence_blocks_new_network_operations_after_original_completion() {
        with_shell(|shell, cx| {
            let cancelled = request(GitAction::Fetch, GitStep::Fetch);
            shell.browser.git_actions.pending = Some(cancelled.clone());
            shell.browser.git_actions.cancelling = Some(cancelled.clone());
            shell.browser.git_actions.cancelled_operation = Some(cancelled.id.clone());
            shell.browser.git_actions.cancel_requested = true;
            shell.accept(
                Reply::GitAction(cancelled.clone()),
                Err("E_PROJECT_CANCELLED".into()),
                cx,
            );
            assert!(shell.browser.git_actions.pending.is_none());
            assert!(shell.browser.git_actions.cancelling.is_some());
            assert!(!action_available(&shell.browser, GitAction::Push));
            shell.accept_git_cancel(
                cancelled,
                Ok(envelope(json!({"status":"cancel_requested"}))),
                cx,
            );
            assert!(shell.browser.git_actions.cancelling.is_none());
            assert!(action_available(&shell.browser, GitAction::Push));
        });
    }
    #[test]
    fn early_cancel_ack_preserves_cancel_intent_until_fetch_finishes() {
        with_shell(|shell, cx| {
            let cancelled = request(GitAction::Pull, GitStep::Fetch);
            shell.browser.git_actions.pending = Some(cancelled.clone());
            shell.browser.git_actions.cancelling = Some(cancelled.clone());
            shell.browser.git_actions.cancelled_operation = Some(cancelled.id.clone());
            shell.browser.git_actions.cancel_requested = true;
            shell.accept_git_cancel(
                cancelled.clone(),
                Ok(envelope(json!({"status":"cancel_requested"}))),
                cx,
            );
            assert!(shell.browser.git_actions.cancelling.is_none());
            assert!(shell.browser.git_actions.cancel_requested);
            shell.accept(
                Reply::GitAction(cancelled),
                Ok(envelope(
                    json!({"remote":"origin","branch":"main","remote_oid":oid()}),
                )),
                cx,
            );
            assert_eq!(
                shell.browser.git_actions.pending.as_ref().unwrap().step,
                GitStep::Status
            );
            assert!(matches!(
                shell.browser.git_actions.feedback,
                Some(GitFeedback::Cancelled)
            ));
        });
    }
    #[test]
    fn a_late_cancel_ack_cannot_release_a_newer_cancel_fence() {
        with_shell(|shell, cx| {
            let old = request(GitAction::Fetch, GitStep::Fetch);
            let mut new = old.clone();
            new.id = uuid::Uuid::new_v4().to_string();
            shell.browser.git_actions.cancelling = Some(new.clone());
            shell.browser.git_actions.cancel_requested = true;
            shell.accept_git_cancel(old, Ok(envelope(json!({"status":"cancel_requested"}))), cx);
            assert_eq!(shell.browser.git_actions.cancelling, Some(new));
            assert!(shell.browser.git_actions.cancel_requested);
        });
    }
    #[test]
    fn a_definite_push_rejection_refreshes_without_a_retry_or_uncertainty_lock() {
        with_shell(|shell, cx| {
            let push = request(GitAction::Push, GitStep::Push);
            shell.browser.git_actions.pending = Some(push.clone());
            shell
                .browser
                .git_actions
                .uncertain
                .insert(root().to_string(), push.clone());
            shell.accept(
                Reply::GitAction(push),
                Err("E_PROJECT_NON_FAST_FORWARD".into()),
                cx,
            );
            assert!(!shell.browser.git_actions.has_uncertain_push(Some(&root())));
            assert_eq!(
                shell.browser.git_actions.pending.as_ref().unwrap().step,
                GitStep::Status
            );
            assert!(matches!(
                shell.browser.git_actions.feedback,
                Some(GitFeedback::Error(_))
            ));
        });
    }
    #[test]
    fn a_late_reply_never_clears_another_operations_busy_ownership() {
        with_shell(|shell, cx| {
            let old = request(GitAction::Stage, GitStep::Stage);
            let mut new = old.clone();
            new.id = uuid::Uuid::new_v4().to_string();
            shell.browser.git_actions.pending = Some(new.clone());
            shell.aux_busy = true;
            shell.accept(Reply::GitAction(old), Err("stale failure".into()), cx);
            assert!(shell.aux_busy);
            assert_eq!(shell.browser.git_actions.pending, Some(new));
            assert!(shell.browser.git_actions.feedback.is_none());
        });
    }
    #[test]
    fn failed_push_queries_receipts_instead_of_resending_the_write() {
        with_shell(|shell, cx| {
            let request = request(GitAction::Push, GitStep::Push);
            shell.browser.git_actions.pending = Some(request.clone());
            shell
                .browser
                .git_actions
                .uncertain
                .insert(root().to_string(), request.clone());
            shell.aux_busy = true;
            shell.accept(
                Reply::GitAction(request),
                Err("Native operation disconnected".into()),
                cx,
            );
            assert_eq!(
                shell.browser.git_actions.pending.as_ref().unwrap().step,
                GitStep::VerifyRemote
            );
            assert!(shell.browser.git_actions.has_uncertain_push(Some(&root())));
            assert!(matches!(
                shell.browser.git_actions.feedback,
                Some(GitFeedback::PushUncertain)
            ));
        });
    }
    #[test]
    fn receipt_absence_uses_read_only_fetch_and_only_exact_remote_tip_confirms() {
        with_shell(|shell, cx| {
            let check = request(GitAction::Push, GitStep::CheckPush);
            shell.browser.git_actions.pending = Some(check.clone());
            shell
                .browser
                .git_actions
                .uncertain
                .insert(root().to_string(), check.clone());
            shell.accept(
                Reply::GitAction(check),
                Ok(envelope(json!({"receipts":[]}))),
                cx,
            );
            let verify = shell.browser.git_actions.pending.clone().unwrap();
            assert_eq!(verify.step, GitStep::VerifyPush);
            assert_eq!(verify.command().method, "fetchV2");
            shell.accept(
                Reply::GitAction(verify),
                Ok(envelope(
                    json!({"remote":"origin","branch":"main","remote_oid":"b".repeat(40)}),
                )),
                cx,
            );
            assert_eq!(
                shell.browser.git_actions.pending.as_ref().unwrap().step,
                GitStep::Status
            );
            assert!(!shell.browser.git_actions.has_uncertain_push(Some(&root())));
            assert!(matches!(
                shell.browser.git_actions.feedback,
                Some(GitFeedback::PushNotConfirmed)
            ));
            let verify = request(GitAction::CheckPush, GitStep::VerifyPush);
            shell.browser.git_actions.pending = Some(verify.clone());
            shell.accept(
                Reply::GitAction(verify),
                Ok(envelope(
                    json!({"remote":"origin","branch":"main","remote_oid":oid()}),
                )),
                cx,
            );
            assert!(!shell.browser.git_actions.has_uncertain_push(Some(&root())));
            assert!(matches!(
                shell.browser.git_actions.feedback,
                Some(GitFeedback::PushConfirmed)
            ));
        });
    }
    #[test]
    fn cancellation_racing_a_successful_fetch_does_not_continue_into_pull() {
        with_shell(|shell, cx| {
            let request = request(GitAction::Pull, GitStep::Fetch);
            shell.browser.git_actions.pending = Some(request.clone());
            shell.browser.git_actions.cancel_requested = true;
            shell.browser.git_actions.cancelled_operation = Some(request.id.clone());
            shell.aux_busy = true;
            shell.accept(Reply::GitAction(request),Ok(envelope(json!({"remote":"origin","branch":"main","remote_oid":oid(),"ahead":0,"behind":1,"fetched_at":"now"}))),cx);
            assert_eq!(
                shell.browser.git_actions.pending.as_ref().unwrap().step,
                GitStep::Status
            );
            assert!(matches!(
                shell.browser.git_actions.feedback,
                Some(GitFeedback::Cancelled)
            ));
        });
    }
    #[test]
    fn stale_push_success_settles_only_its_original_root() {
        with_shell(|shell, cx| {
            let request = request(GitAction::Push, GitStep::Push);
            shell
                .browser
                .git_actions
                .uncertain
                .insert(root().to_string(), request.clone());
            shell.browser.git_actions.pending = Some(request.clone());
            shell.browser.generation += 1;
            shell.aux_busy = true;
            shell.accept(
                Reply::GitAction(request),
                Ok(envelope(
                    json!({"remote":"origin","branch":"main","oid":oid(),"pushed_at":"now"}),
                )),
                cx,
            );
            assert!(!shell.browser.git_actions.has_uncertain_push(Some(&root())));
            assert!(!shell.aux_busy);
            assert!(shell.browser.git_actions.feedback.is_none());
        });
    }
    #[test]
    fn returning_a_commit_form_after_navigation_never_dispatches_commit() {
        with_shell(|shell, cx| {
            let request = request(GitAction::Commit, GitStep::Form);
            shell.browser.git_actions.pending = Some(request.clone());
            shell.browser.generation += 1;
            shell.aux_busy = true;
            shell.accept(Reply::GitAction(request),Ok(json!({"message":"Initial","author_name":"User","author_email":"user@example.test"})),cx);
            assert!(shell.browser.git_actions.pending.is_none());
            assert!(!shell.aux_busy);
        });
    }
}
