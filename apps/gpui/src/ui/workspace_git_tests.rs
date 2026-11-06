use super::{
    i18n::{Locale, Text},
    screens::Browser,
    workspace_git::{GitOperation, GitRequest, GitState, git_error_message},
};
use serde_json::{Value, json};

const WORKSPACE: &str = "845d980b-8acd-4710-a54c-7975b6839024";
const OTHER_WORKSPACE: &str = "e8ab9203-333e-4eb4-82a1-6423e90dc042";
const PROJECT: &str = "85ac8af6-b884-4b55-b63a-b46cabf56296";
const OTHER_PROJECT: &str = "223a22b5-ff4f-480e-b730-c67685809822";

fn root(project: Option<&str>) -> Value {
    json!({
        "schema_version": 1,
        "workspace_id": WORKSPACE,
        "binding_revision": 4,
        "project_id": project,
    })
}

fn browser(project: Option<&str>) -> Browser {
    Browser {
        root: Some(root(project)),
        generation: 7,
        ..Browser::default()
    }
}

fn attached(status: &str) -> Value {
    json!({
        "schema_version": 1,
        "status": status,
        "project": {
            "schema_version": 2,
            "project_id": PROJECT,
            "workspace_id": WORKSPACE,
            "workspace_binding_revision": 4,
            "display_name": "Project",
            "git_topology": "private_split_gitdir",
        },
    })
}

fn status() -> Value {
    json!({
        "schema_version": 2,
        "root": root(Some(PROJECT)),
        "project_id": PROJECT,
        "branch": null,
        "head_oid": null,
        "clean": true,
        "has_conflicts": false,
        "ahead": 0,
        "behind": 0,
        "entries": [],
    })
}

#[test]
fn native_none_is_a_missing_repository_instead_of_an_error() {
    let mut browser = browser(None);
    browser.git = GitState::Loading;
    let original = browser.root.clone();

    assert_eq!(
        browser
            .accept_project(json!({"schema_version": 1, "status": "none"}))
            .unwrap(),
        None
    );
    assert!(matches!(browser.git, GitState::Missing));
    assert_eq!(browser.root, original);
}

#[test]
fn attached_and_already_attached_enrich_only_the_project_identity() {
    for response_status in ["attached", "already_attached"] {
        let mut browser = browser(None);
        let enriched = browser
            .accept_project(attached(response_status))
            .unwrap()
            .unwrap();

        assert_eq!(enriched, root(Some(PROJECT)));
        assert_eq!(browser.root, Some(enriched));
    }
}

#[test]
fn native_none_cannot_silently_detach_a_bound_project() {
    let mut browser = browser(Some(PROJECT));
    let original = browser.root.clone();
    assert!(
        browser
            .accept_project(json!({"schema_version": 1, "status": "none"}))
            .is_err()
    );
    assert_eq!(browser.root, original);
}

#[test]
fn unknown_or_incomplete_project_envelopes_are_rejected() {
    for response in [
        Value::Null,
        json!({"schema_version": 2, "status": "none"}),
        json!({"schema_version": 1}),
        json!({"schema_version": 1, "status": "unknown"}),
        json!({"schema_version": 1, "status": "attached"}),
        json!({"schema_version": 1, "status": "already_attached", "project": null}),
    ] {
        let mut browser = browser(None);
        let original = browser.root.clone();
        assert!(
            browser.accept_project(response.clone()).is_err(),
            "unexpected acceptance: {response}"
        );
        assert_eq!(browser.root, original);
    }
}

#[test]
fn malformed_or_foreign_project_identity_never_changes_the_root() {
    for (field, invalid) in [
        ("schema_version", json!(1)),
        ("project_id", json!("not-a-project-id")),
        ("project_id", Value::Null),
        ("workspace_id", json!(OTHER_WORKSPACE)),
        ("workspace_binding_revision", json!(5)),
        ("workspace_binding_revision", json!("4")),
        ("git_topology", json!("unknown")),
    ] {
        let mut response = attached("attached");
        response["project"][field] = invalid;
        let mut browser = browser(None);
        let original = browser.root.clone();
        assert!(
            browser.accept_project(response.clone()).is_err(),
            "unexpected acceptance: {response}"
        );
        assert_eq!(browser.root, original);
    }
}

#[test]
fn a_project_response_cannot_replace_an_existing_project_binding() {
    let mut browser = browser(Some(OTHER_PROJECT));
    let original = browser.root.clone();
    assert!(browser.accept_project(attached("attached")).is_err());
    assert_eq!(browser.root, original);
}

#[test]
fn no_selected_workspace_cannot_accept_a_project() {
    let mut browser = Browser::default();
    assert!(browser.accept_project(attached("attached")).is_err());
    assert!(browser.root.is_none());
}

#[test]
fn an_unborn_native_repository_has_valid_null_branch_and_head() {
    let mut browser = browser(Some(PROJECT));
    let response = status();
    browser.accept_git(response.clone()).unwrap();
    assert!(matches!(&browser.git, GitState::Attached(value) if value == &response));
}

#[test]
fn status_must_match_the_exact_workspace_binding_and_project() {
    let mut responses = Vec::new();
    let mut wrong_schema = status();
    wrong_schema["schema_version"] = json!(1);
    responses.push(wrong_schema);
    let mut wrong_root = status();
    wrong_root["root"]["workspace_id"] = json!(OTHER_WORKSPACE);
    responses.push(wrong_root);
    let mut wrong_revision = status();
    wrong_revision["root"]["binding_revision"] = json!(5);
    responses.push(wrong_revision);
    let mut wrong_project_root = status();
    wrong_project_root["root"]["project_id"] = json!(OTHER_PROJECT);
    responses.push(wrong_project_root);
    let mut wrong_project = status();
    wrong_project["project_id"] = json!(OTHER_PROJECT);
    responses.push(wrong_project);

    for response in responses {
        let mut browser = browser(Some(PROJECT));
        let previous = status();
        browser.accept_git(previous.clone()).unwrap();
        let original = browser.root.clone();
        assert!(
            browser.accept_git(response.clone()).is_err(),
            "unexpected acceptance: {response}"
        );
        assert_eq!(browser.root, original);
        assert!(matches!(&browser.git, GitState::Attached(value) if value == &previous));
    }
}

#[test]
fn status_requires_all_native_fields_including_explicit_nullable_fields() {
    for field in [
        "project_id",
        "branch",
        "head_oid",
        "clean",
        "has_conflicts",
        "ahead",
        "behind",
        "entries",
    ] {
        let mut response = status();
        response.as_object_mut().unwrap().remove(field);
        assert!(
            browser(Some(PROJECT)).accept_git(response).is_err(),
            "missing field was accepted: {field}"
        );
    }
}

#[test]
fn malformed_status_fields_do_not_become_a_clean_repository() {
    for (field, invalid) in [
        ("branch", json!(false)),
        ("head_oid", json!(12)),
        ("clean", json!("true")),
        ("has_conflicts", Value::Null),
        ("ahead", json!(-1)),
        ("behind", json!("0")),
        ("entries", Value::Null),
        ("entries", json!({})),
    ] {
        let mut response = status();
        response[field] = invalid;
        let mut browser = browser(Some(PROJECT));
        browser.git = GitState::Loading;
        assert!(
            browser.accept_git(response.clone()).is_err(),
            "unexpected acceptance: {response}"
        );
        assert!(!matches!(browser.git, GitState::Attached(_)));
    }
}

#[test]
fn requests_are_bound_to_generation_workspace_revision_and_project_identity() {
    for operation in [
        GitOperation::Lookup,
        GitOperation::Status,
        GitOperation::Initialize,
    ] {
        let mut browser = browser(Some(PROJECT));
        let request = GitRequest {
            generation: browser.generation,
            root: browser.root.clone().unwrap(),
            operation,
        };
        assert!(request.current(&browser));
        browser.generation += 1;
        assert!(!request.current(&browser));
        browser.generation = request.generation;
        browser.root.as_mut().unwrap()["workspace_id"] = json!(OTHER_WORKSPACE);
        assert!(!request.current(&browser));
        browser.root = Some(root(Some(PROJECT)));
        browser.root.as_mut().unwrap()["binding_revision"] = json!(5);
        assert!(!request.current(&browser));
        browser.root = Some(root(Some(OTHER_PROJECT)));
        assert!(!request.current(&browser));
        browser.root = None;
        assert!(!request.current(&browser));
        browser.root = Some(root(Some(PROJECT)));
        assert!(request.current(&browser));
    }
}

#[test]
fn initialization_requires_a_confirmed_missing_repository_and_all_capabilities() {
    let mut browser = browser(None);
    browser.capabilities = json!({"read": true, "write": true, "git": true});
    assert!(!browser.can_initialize_git());
    browser.git = GitState::Missing;
    assert!(browser.can_initialize_git());

    for capability in ["read", "write", "git"] {
        for invalid in [Value::Null, json!(false), json!("true")] {
            browser.capabilities[capability] = invalid;
            assert!(!browser.can_initialize_git(), "{capability}");
        }
        browser
            .capabilities
            .as_object_mut()
            .unwrap()
            .remove(capability);
        assert!(!browser.can_initialize_git(), "missing {capability}");
        browser.capabilities[capability] = json!(true);
        assert!(browser.can_initialize_git());
    }

    browser.root = Some(root(Some(PROJECT)));
    assert!(!browser.can_initialize_git());
    browser.root = None;
    assert!(!browser.can_initialize_git());
    browser.root = Some(root(None));
    for state in [
        GitState::Idle,
        GitState::Loading,
        GitState::Attached(status()),
        GitState::Failed("E_NATIVE_UNAVAILABLE".into()),
    ] {
        browser.git = state;
        assert!(!browser.can_initialize_git());
    }
}

#[test]
fn lookup_and_status_commands_keep_the_native_request_envelopes() {
    let request = GitRequest {
        generation: 7,
        root: root(None),
        operation: GitOperation::Lookup,
    };
    let lookup = request.command();
    assert_eq!(lookup.module, "LocalProjects");
    assert_eq!(lookup.method, "projectForWorkspaceV2");
    assert_eq!(lookup.args, vec![root(None)]);

    let request = GitRequest {
        root: root(Some(PROJECT)),
        operation: GitOperation::Status,
        ..request
    };
    let status = request.command();
    assert_eq!(status.module, "LocalProjects");
    assert_eq!(status.method, "statusV2");
    assert_eq!(
        status.args,
        vec![json!({"schema_version": 1, "root": root(Some(PROJECT))})]
    );
}

#[test]
fn initialization_uses_the_captured_root_and_a_fresh_operation_identifier() {
    let request = GitRequest {
        generation: 7,
        root: root(None),
        operation: GitOperation::Initialize,
    };
    let command = request.command();
    let another = request.command();
    assert_eq!(command.module, "LocalProjects");
    assert_eq!(command.method, "attachWorkspaceProject");
    assert_eq!(command.args.len(), 1);
    let payload = &command.args[0];
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["root"], request.root);
    assert_eq!(payload["mode"], "init");
    assert_eq!(payload.as_object().unwrap().len(), 4);
    assert!(uuid::Uuid::parse_str(payload["operation_id"].as_str().unwrap()).is_ok());
    assert_ne!(payload["operation_id"], another.args[0]["operation_id"]);
}

#[test]
fn unavailable_git_service_errors_explain_recovery_and_keep_one_error_code() {
    for locale in [Locale::Zh, Locale::En] {
        let code = "E_NATIVE_UNAVAILABLE";
        let message = git_error_message(&format!("{code}: {code}"), locale);
        assert!(message.contains(locale.text(Text::GitNativeUnavailable)));
        assert_eq!(message.matches(code).count(), 1);
    }
}

#[test]
fn unknown_native_errors_keep_a_single_code_without_repeating_the_banner() {
    for locale in [Locale::Zh, Locale::En] {
        for code in ["E_PROJECT_NATIVE", "E_PROJECT_UNAVAILABLE"] {
            let message = git_error_message(&format!("{code}: {code}"), locale);
            assert!(message.contains(locale.text(Text::GitRetryHint)));
            assert_eq!(message.matches(code).count(), 1);
        }
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
mod controller {
    use super::*;
    use crate::ui::{Page, Reply, Shell};
    use gpui::{Context, TestAppContext, VisualTestContext, px, size};

    fn with_shell(test: impl FnOnce(&mut Shell, &mut Context<Shell>)) {
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
        window
            .update(&mut cx, |shell, _, cx| {
                shell.browser = browser(None);
                shell.page = Page::Git;
                shell.notice = None;
                test(shell, cx);
            })
            .unwrap();
    }

    fn request(shell: &Shell, operation: GitOperation) -> GitRequest {
        GitRequest {
            generation: shell.browser.generation,
            root: shell.browser.root.clone().unwrap(),
            operation,
        }
    }

    #[test]
    fn a_stale_git_failure_cannot_clear_a_new_request_or_replace_its_state() {
        with_shell(|shell, cx| {
            let old = request(shell, GitOperation::Lookup);
            shell.browser.generation += 1;
            shell.browser.git = GitState::Loading;
            shell.aux_busy = true;
            shell.notice = Some("Keep the current notice".into());
            shell.accept(
                Reply::Git(old),
                Err("E_NATIVE_UNAVAILABLE: E_NATIVE_UNAVAILABLE".into()),
                cx,
            );
            assert!(shell.aux_busy);
            assert!(matches!(shell.browser.git, GitState::Loading));
            assert_eq!(shell.notice.as_deref(), Some("Keep the current notice"));
        });
    }

    #[test]
    fn an_abandoned_git_reply_releases_only_its_own_busy_state() {
        with_shell(|shell, cx| {
            let abandoned = request(shell, GitOperation::Lookup);
            shell.git_pending = Some(abandoned.clone());
            shell.browser.generation += 1;
            shell.browser.git = GitState::Idle;
            shell.aux_busy = true;
            shell.accept(
                Reply::Git(abandoned),
                Err("E_NATIVE_UNAVAILABLE".into()),
                cx,
            );
            assert!(!shell.aux_busy);
            assert!(shell.git_pending.is_none());
            assert!(matches!(shell.browser.git, GitState::Idle));
            assert!(shell.notice.is_none());
        });
    }

    #[test]
    fn a_newer_git_request_retains_ownership_when_an_older_request_finishes() {
        with_shell(|shell, cx| {
            let older = request(shell, GitOperation::Lookup);
            shell.browser.generation += 1;
            let newer = request(shell, GitOperation::Lookup);
            shell.git_pending = Some(newer.clone());
            shell.browser.git = GitState::Loading;
            shell.aux_busy = true;
            shell.accept(
                Reply::Git(older),
                Ok(json!({"schema_version": 1, "status": "none"})),
                cx,
            );
            assert!(shell.aux_busy);
            assert_eq!(shell.git_pending.as_ref(), Some(&newer));
            assert!(matches!(shell.browser.git, GitState::Loading));
            assert!(shell.notice.is_none());
        });
    }

    #[test]
    fn a_rebound_workspace_cannot_receive_an_old_none_reply() {
        with_shell(|shell, cx| {
            let old = request(shell, GitOperation::Lookup);
            shell.browser.root.as_mut().unwrap()["binding_revision"] = json!(5);
            shell.browser.git = GitState::Loading;
            shell.aux_busy = true;
            shell.accept(
                Reply::Git(old),
                Ok(json!({"schema_version": 1, "status": "none"})),
                cx,
            );
            assert!(shell.aux_busy);
            assert!(matches!(shell.browser.git, GitState::Loading));
            assert_eq!(shell.browser.root.as_ref().unwrap()["binding_revision"], 5);
        });
    }

    #[test]
    fn a_current_native_service_failure_is_failed_instead_of_missing() {
        with_shell(|shell, cx| {
            let current = request(shell, GitOperation::Lookup);
            shell.browser.git = GitState::Loading;
            shell.aux_busy = true;
            let error = "E_NATIVE_UNAVAILABLE: E_NATIVE_UNAVAILABLE";
            shell.accept(Reply::Git(current), Err(error.into()), cx);
            assert!(!shell.aux_busy);
            assert!(matches!(&shell.browser.git, GitState::Failed(value) if value == error));
            assert!(shell.notice.is_none());
            assert_eq!(shell.browser.root, Some(root(None)));
        });
    }

    #[test]
    fn a_current_none_lookup_finishes_with_a_missing_repository_and_no_notice() {
        with_shell(|shell, cx| {
            let current = request(shell, GitOperation::Lookup);
            shell.browser.git = GitState::Loading;
            shell.aux_busy = true;
            shell.accept(
                Reply::Git(current),
                Ok(json!({"schema_version": 1, "status": "none"})),
                cx,
            );
            assert!(!shell.aux_busy);
            assert!(matches!(shell.browser.git, GitState::Missing));
            assert!(shell.notice.is_none());
        });
    }

    #[test]
    fn an_initialization_none_reply_is_not_a_successful_repository_creation() {
        with_shell(|shell, cx| {
            let current = request(shell, GitOperation::Initialize);
            shell.browser.git = GitState::Loading;
            shell.aux_busy = true;
            shell.accept(
                Reply::Git(current),
                Ok(json!({"schema_version": 1, "status": "none"})),
                cx,
            );
            assert!(!shell.aux_busy);
            assert!(matches!(shell.browser.git, GitState::Failed(_)));
            assert_eq!(shell.browser.root, Some(root(None)));
        });
    }

    #[test]
    fn rendered_git_actions_distinguish_missing_failed_and_loading_states() {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(390.), px(844.)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();

        for (state, initialize_visible, retry_visible, load_visible) in [
            (GitState::Loading, false, false, false),
            (GitState::Missing, true, false, false),
            (GitState::Loading, false, false, false),
            (
                GitState::Failed("E_PROJECT_NATIVE".into()),
                false,
                true,
                false,
            ),
            (GitState::Loading, false, false, false),
            (GitState::Idle, false, false, true),
        ] {
            window
                .update(&mut cx, |shell, _, cx| {
                    shell.page = Page::Git;
                    shell.browser = browser(None);
                    shell.browser.capabilities = json!({"read": true, "write": true, "git": true});
                    shell.browser.git = state;
                    shell.aux_busy = false;
                    cx.notify();
                })
                .unwrap();
            // Current actions must appear from the ordinary notified frame,
            // before any full refresh. This checks Loading -> Missing/Failed
            // updates while the same sheet and underlying chat stay mounted.
            for (selector, visible) in [
                ("initialize-repository", initialize_visible),
                ("retry-git", retry_visible),
                ("load-git", load_visible),
            ] {
                if visible {
                    assert!(
                        cx.debug_bounds(selector).is_some(),
                        "Missing current action {selector}"
                    );
                }
            }
            // gpui-fast 0.1.7 keeps all prior debug selectors whenever any
            // subtree is retained. The mounted chat behind this sheet triggers
            // that test-only fallback, including selectors removed from Git.
            // A full frame refresh gives absence assertions current bounds;
            // keep one Shell/window so every transition still exercises state.
            cx.update(|window, cx| {
                window.refresh();
                window.draw(cx).clear(cx);
            });
            assert_eq!(
                cx.debug_bounds("initialize-repository").is_some(),
                initialize_visible
            );
            assert_eq!(cx.debug_bounds("retry-git").is_some(), retry_visible);
            assert_eq!(cx.debug_bounds("load-git").is_some(), load_visible);
        }
    }
}
