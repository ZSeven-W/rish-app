use super::*;
use crate::ui::settings_runtime_engines::{AuthenticationCapabilities, EngineInstallation};
use gpui::{
    Modifiers, ScrollDelta, ScrollWheelEvent, TestAppContext, TouchPhase, VisualTestContext, point,
    size,
};
use rish_shell_core::assistant_store::AssistantSnapshot;
use serde_json::json;

fn harness(key: AccountKey, status: &str) -> Value {
    json!({
        "schema_version":1, "harness_id":key.id(),
        "runtime":{"kind":"official-cli","available":true},
        "status":status, "auth_method":if status == "signed_in" { "subscription" } else { "none" },
        "account":if status == "signed_in" { json!({"label":"subscription"}) } else { Value::Null },
    })
}

fn authorizing(key: AccountKey) -> Value {
    let mut value = harness(key, "authorizing");
    value["auth_method"] = json!("subscription");
    value["login"] = json!({
        "session_id":"test-session-1", "phase":"waiting_for_browser",
        "verification_url":"https://login.example.test/authorize?state=private-test-value",
        "user_code":"ABCD-EFGH", "can_submit_code":key == AccountKey::Claude,
        "expires_at":1234567890,
    });
    value
}

fn zcode(key: AccountKey, status: &str) -> Value {
    json!({
        "schema_version":1,"provider":key.id(),"status":status,
        "mode":if status == "signed_in" { Some("account_only") } else { None },
        "account_label":if status == "signed_in" { Some("Test account") } else { None },
        "authorize_url":if status == "pending" { Some("https://login.example.test/?private=test") } else { None },
        "expires_at":null,"error_code":null,
    })
}

fn source(id: &str, ready: bool) -> Value {
    json!({"schema_version":1,"source":id,"ready":ready,"error_code":null})
}

fn with_account(key: AccountKey, value: Value) -> RuntimeSubscriptionsUi {
    let mut ui = RuntimeSubscriptionsUi::default();
    ui.accounts[key as usize] = parse_account(key, &value).unwrap();
    ui
}

#[test]
fn native_harness_commands_use_only_identity_session_and_locale() {
    for key in [AccountKey::Claude, AccountKey::Codex] {
        for (action, method, status) in [
            (
                SubscriptionAction::Refresh,
                "harnessAuthStatus",
                "signed_out",
            ),
            (SubscriptionAction::Login, "startHarnessLogin", "signed_out"),
            (SubscriptionAction::Logout, "logoutHarness", "signed_in"),
        ] {
            let mut ui = with_account(key, harness(key, status));
            let (_, command) = ui.prepare(key, action, Locale::Zh).unwrap();
            assert_eq!(command.module, "LocalRuntime");
            assert_eq!(command.method, method);
            assert_eq!(command.args, vec![json!(key.id())]);
        }
        for (action, method) in [
            (SubscriptionAction::Open, "openHarnessAuthorization"),
            (SubscriptionAction::Cancel, "cancelHarnessLogin"),
        ] {
            let mut ui = with_account(key, authorizing(key));
            let (_, command) = ui.prepare(key, action, Locale::En).unwrap();
            assert_eq!(command.method, method);
            assert_eq!(command.args, vec![json!(key.id()), json!("test-session-1")]);
            let wire = serde_json::to_string(&command.args).unwrap();
            assert!(!wire.contains("https://") && !wire.contains("ABCD-EFGH"));
        }
    }
    let mut ui = with_account(AccountKey::Claude, authorizing(AccountKey::Claude));
    let (_, command) = ui
        .prepare(
            AccountKey::Claude,
            SubscriptionAction::SubmitCode,
            Locale::Zh,
        )
        .unwrap();
    assert_eq!(command.method, "presentHarnessLoginCode");
    assert_eq!(
        command.args,
        vec![
            json!("claude-code"),
            json!("test-session-1"),
            json!(Locale::Zh.code())
        ]
    );
}

#[test]
fn zcode_commands_select_region_explicitly_without_auth_urls_or_trial_fallback() {
    for key in [AccountKey::Bigmodel, AccountKey::Zai] {
        for (action, method, status) in [
            (
                SubscriptionAction::Refresh,
                "zcodeAccountStatus",
                "signed_out",
            ),
            (
                SubscriptionAction::Login,
                "startZcodeAccountLogin",
                "signed_out",
            ),
            (
                SubscriptionAction::Open,
                "openZcodeAccountAuthorization",
                "pending",
            ),
            (
                SubscriptionAction::Cancel,
                "cancelZcodeAccountLogin",
                "pending",
            ),
            (
                SubscriptionAction::Logout,
                "logoutZcodeAccount",
                "signed_in",
            ),
        ] {
            let mut ui = with_account(key, zcode(key, status));
            let (_, command) = ui.prepare(key, action, Locale::En).unwrap();
            assert_eq!(command.method, method);
            assert_eq!(command.args, vec![json!(key.id())]);
        }
        let mut ui = with_account(key, zcode(key, "signed_in"));
        ui.sources[source_index(key)] = parse_source(key, &source("api_key", true)).unwrap();
        let (_, command) = ui
            .prepare(key, SubscriptionAction::UseSubscription, Locale::En)
            .unwrap();
        assert_eq!(command.method, "selectGlmCredentialSource");
        assert_eq!(command.args, vec![json!(key.id())]);
        assert!(!command.args[0].as_str().unwrap().contains("trial"));
    }
}

#[test]
fn source_switches_require_confirmed_native_status_and_keep_account_source_separate() {
    for key in [AccountKey::Claude, AccountKey::Codex] {
        let mut ui = with_account(key, harness(key, "signed_in"));
        assert!(!ui.can_action(key, SubscriptionAction::UseSubscription));
        ui.sources[source_index(key)] = parse_source(key, &source("api_key", true)).unwrap();
        let (_, command) = ui
            .prepare(key, SubscriptionAction::UseSubscription, Locale::En)
            .unwrap();
        assert_eq!(command.method, key.source_methods().1);
        assert_eq!(command.args, vec![json!("subscription")]);
        assert_eq!(
            ui.source(key).source.as_deref(),
            Some("api_key"),
            "dispatch is not confirmation"
        );
        assert!(parse_source(key, &source("bigmodel", true)).is_err());
    }
    assert!(parse_source(AccountKey::Bigmodel, &source("subscription", true)).is_err());
    assert!(
        parse_source(
            AccountKey::Codex,
            &json!({"schema_version":1,"source":"api_key","ready":"yes"})
        )
        .is_err()
    );
    let mut unexpected_code = authorizing(AccountKey::Codex);
    unexpected_code["login"]["can_submit_code"] = json!(true);
    let ui = with_account(AccountKey::Codex, unexpected_code);
    assert!(!ui.can_action(AccountKey::Codex, SubscriptionAction::SubmitCode));
}

#[test]
fn selected_zcode_subscription_can_renew_an_unready_source_without_trial_fallback() {
    let key = AccountKey::Bigmodel;
    let mut ui = with_account(key, zcode(key, "signed_in"));
    ui.sources[source_index(key)] = parse_source(key, &source("bigmodel", false)).unwrap();
    assert!(ui.source(key).selected_subscription(key));
    assert!(!ui.source(key).ready);
    assert!(ui.can_action(key, SubscriptionAction::UseSubscription));
    let (request, command) = ui
        .prepare(key, SubscriptionAction::UseSubscription, Locale::En)
        .unwrap();
    assert_eq!(command.method, "selectGlmCredentialSource");
    assert_eq!(command.args, vec![json!("bigmodel")]);
    assert!(ui.accept(
        &request,
        Ok(zcode(key, "signed_in")),
        Some(Ok(source("bigmodel", true))),
        false,
        Locale::En,
    ));
    assert!(ui.source(key).ready);
    assert!(!ui.can_action(key, SubscriptionAction::UseSubscription));

    let (refresh, _) = ui
        .prepare(key, SubscriptionAction::Refresh, Locale::En)
        .unwrap();
    assert!(ui.accept(
        &refresh,
        Ok(zcode(key, "signed_in")),
        Some(Ok(source("bigmodel", false))),
        false,
        Locale::En
    ));
    let (retry, _) = ui
        .prepare(key, SubscriptionAction::UseSubscription, Locale::En)
        .unwrap();
    assert!(ui.accept(
        &retry,
        Ok(zcode(key, "signed_in")),
        Some(Err("private lease failure".into())),
        true,
        Locale::En
    ));
    assert_eq!(ui.source(key).source.as_deref(), Some("bigmodel"));
    assert!(!ui.source(key).ready);
    assert!(!ui.can_action(key, SubscriptionAction::UseSubscription));
    assert!(!ui.can_action(key, SubscriptionAction::UseApi));
    let (refresh, _) = ui
        .prepare(key, SubscriptionAction::Refresh, Locale::En)
        .unwrap();
    assert!(ui.accept(
        &refresh,
        Ok(zcode(key, "signed_in")),
        Some(Ok(source("bigmodel", false))),
        false,
        Locale::En
    ));
    assert!(ui.can_action(key, SubscriptionAction::UseSubscription));
}

#[test]
fn signed_in_harness_requires_explicit_subscription_authentication_receipt() {
    for key in [AccountKey::Claude, AccountKey::Codex] {
        for method in [Some("api_key"), Some("none"), None] {
            let mut value = harness(key, "signed_in");
            if let Some(method) = method {
                value["auth_method"] = json!(method);
            } else {
                value.as_object_mut().unwrap().remove("auth_method");
            }
            assert!(parse_account(key, &value).is_err());
            let mut ui = with_account(key, harness(key, "signed_out"));
            let (request, _) = ui
                .prepare(key, SubscriptionAction::Refresh, Locale::En)
                .unwrap();
            assert!(ui.accept(
                &request,
                Ok(value),
                Some(Ok(source("subscription", true))),
                false,
                Locale::En
            ));
            assert!(ui.account(key).phase == AccountPhase::SignedOut);
            assert!(!ui.can_action(key, SubscriptionAction::UseSubscription));
        }
    }
}

#[test]
fn authorization_display_is_transient_and_cannot_grant_cli_execution_or_source() {
    let key = AccountKey::Codex;
    let mut ui = with_account(key, authorizing(key));
    assert!(ui.account(key).phase == AccountPhase::Pending);
    assert_eq!(
        ui.account(key).login.device_code.as_deref(),
        Some("ABCD-EFGH")
    );
    assert!(ui.account(key).login.can_open);
    assert!(!ui.account(key).login.can_submit);
    assert!(ui.source(key).source.is_none());
    let (request, _) = ui
        .prepare(key, SubscriptionAction::Refresh, Locale::En)
        .unwrap();
    assert!(ui.accept(
        &request,
        Ok(harness(key, "signed_in")),
        Some(Ok(source("api_key", true))),
        false,
        Locale::En
    ));
    assert!(ui.account(key).phase == AccountPhase::SignedIn);
    assert!(ui.account(key).login.session.is_none());
    assert!(ui.account(key).login.device_code.is_none());
    assert!(!ui.account(key).login.can_open && !ui.account(key).login.can_submit);
    assert_eq!(ui.source(key).source.as_deref(), Some("api_key"));
    assert!(ui.can_action(key, SubscriptionAction::UseSubscription));
}

#[test]
fn malformed_identity_status_and_display_data_are_rejected_without_changing_account() {
    let key = AccountKey::Claude;
    let mut invalid = Vec::new();
    for (field, value) in [
        ("schema_version", json!(2)),
        ("harness_id", json!("codex")),
        ("status", json!("ready")),
    ] {
        let mut reply = authorizing(key);
        reply[field] = value;
        invalid.push(reply);
    }
    let mut reply = authorizing(key);
    reply["runtime"]["available"] = json!("true");
    invalid.push(reply);
    let mut reply = authorizing(key);
    reply["login"]["session_id"] = Value::Null;
    invalid.push(reply);
    let mut reply = authorizing(key);
    reply["login"]["user_code"] = json!("line\nbreak");
    invalid.push(reply);
    let mut reply = authorizing(key);
    reply["account"] = json!({"label":"x".repeat(201)});
    invalid.push(reply);
    for reply in invalid {
        let mut ui = with_account(key, harness(key, "signed_out"));
        let (request, _) = ui
            .prepare(key, SubscriptionAction::Refresh, Locale::En)
            .unwrap();
        assert!(ui.accept(&request, Ok(reply), None, false, Locale::En));
        assert!(ui.account(key).phase == AccountPhase::SignedOut);
        assert!(ui.account(key).error.is_some());
        assert!(ui.account(key).login.session.is_none());
        assert!(!ui.can_action(key, SubscriptionAction::Login));
    }
    assert!(parse_account(AccountKey::Bigmodel, &zcode(AccountKey::Zai, "pending")).is_err());
}

#[test]
fn stale_reply_cannot_replace_new_request_and_errors_preserve_confirmed_source() {
    let key = AccountKey::Codex;
    let mut ui = with_account(key, harness(key, "signed_in"));
    ui.sources[source_index(key)] = parse_source(key, &source("api_key", true)).unwrap();
    let (request, _) = ui
        .prepare(key, SubscriptionAction::UseSubscription, Locale::En)
        .unwrap();
    let stale = SubscriptionRequest {
        token: "stale-request".into(),
        key,
        action: SubscriptionAction::Refresh,
    };
    assert!(!ui.accept(
        &stale,
        Ok(harness(key, "signed_out")),
        Some(Ok(source("subscription", true))),
        false,
        Locale::En
    ));
    assert_eq!(ui.request.as_ref().unwrap().token, request.token);
    assert!(ui.account(key).phase == AccountPhase::SignedIn);
    assert!(
        ui.prepare(key, SubscriptionAction::Refresh, Locale::En)
            .is_none()
    );
    assert!(ui.accept(
        &request,
        Ok(harness(key, "signed_in")),
        Some(Err("token=private-test-value /private/cache".into())),
        true,
        Locale::Zh
    ));
    assert_eq!(ui.source(key).source.as_deref(), Some("api_key"));
    let error = ui.account(key).error.unwrap();
    assert!(!error.contains("private") && !error.contains("token="));
    assert!(!ui.can_action(key, SubscriptionAction::UseSubscription));
    let (refresh, _) = ui
        .prepare(key, SubscriptionAction::Refresh, Locale::En)
        .unwrap();
    assert!(ui.accept(
        &refresh,
        Ok(harness(key, "signed_in")),
        Some(Ok(source("api_key", true))),
        false,
        Locale::En
    ));
    assert!(ui.account(key).error.is_none());
    assert!(ui.can_action(key, SubscriptionAction::UseSubscription));
}

fn seed_shell(shell: &mut Shell, locale: Locale) {
    shell.page = Page::Settings;
    shell.settings_expanded = Some(settings::PreferenceGroup::Runtime);
    shell.locale = locale;
    shell.assistant.snapshot.store = Some(AssistantSnapshot::default());
    for entry in &mut shell.runtime_engines.entries {
        entry.installation = EngineInstallation::NotInstalled;
        entry.download_supported = matches!(
            entry.product,
            RuntimeProduct::ClaudeCode | RuntimeProduct::Codex
        );
        entry.authentication = AuthenticationCapabilities {
            supported: entry.product != RuntimeProduct::Dsh,
            source_selection: entry.product != RuntimeProduct::Dsh,
            authorization_browser: entry.product != RuntimeProduct::Dsh,
            native_code_entry: entry.product == RuntimeProduct::ClaudeCode,
            provider_selection: entry.product == RuntimeProduct::Zcode,
        };
    }
    for key in AccountKey::ALL {
        shell.runtime_subscriptions.accounts[key as usize] = parse_account(
            key,
            &if key.is_zcode() {
                zcode(key, "signed_out")
            } else {
                harness(key, "signed_out")
            },
        )
        .unwrap();
        shell.runtime_subscriptions.sources[source_index(key)] =
            parse_source(key, &source("api_key", true)).unwrap();
    }
}

#[test]
fn account_acceptance_preserves_profile_session_and_polls_only_visible_active_login() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(393.), px(844.)), |_, cx| Shell::new(cx));
    window
        .update(&mut app, |shell, _, _| {
            seed_shell(shell, Locale::En);
            shell.runtime_subscriptions.expanded = Some(RuntimeProduct::Codex);
            let profile = shell
                .assistant
                .snapshot
                .store
                .as_ref()
                .unwrap()
                .profile
                .clone();
            let session = shell.state.raw_session().clone();
            let (request, _) = shell
                .runtime_subscriptions
                .prepare(AccountKey::Codex, SubscriptionAction::Login, Locale::En)
                .unwrap();
            assert!(shell.runtime_subscriptions.accept(
                &request,
                Ok(authorizing(AccountKey::Codex)),
                Some(Ok(source("api_key", true))),
                false,
                Locale::En
            ));
            assert_eq!(
                shell.assistant.snapshot.store.as_ref().unwrap().profile,
                profile
            );
            assert_eq!(shell.state.raw_session(), &session);
            assert!(shell.runtime_editor.is_none() && shell.assistant.profile_draft.is_none());
            assert!(shell.subscription_poll_needed());
            shell.runtime_subscriptions.foreground = false;
            assert!(!shell.subscription_poll_needed());
            shell.runtime_subscriptions.foreground = true;
            assert!(shell.subscription_poll_needed());
            shell.page = Page::Chat;
            assert!(!shell.subscription_poll_needed());
            shell.page = Page::Settings;
            shell.settings_expanded = Some(settings::PreferenceGroup::Models);
            assert!(!shell.subscription_poll_needed());
            shell.settings_expanded = Some(settings::PreferenceGroup::Runtime);
            shell.runtime_subscriptions.expanded = Some(RuntimeProduct::ClaudeCode);
            assert!(!shell.subscription_poll_needed());
            shell.runtime_subscriptions.expanded = Some(RuntimeProduct::Codex);
            shell.runtime_subscriptions.accounts[AccountKey::Codex as usize].error =
                Some("Refresh required");
            assert!(!shell.subscription_poll_needed());
        })
        .unwrap();
}

fn reveal(cx: &mut VisualTestContext, selector: &'static str) {
    cx.run_until_parked();
    cx.update(|window, cx| window.draw(cx).clear(cx));
    let viewport = cx.debug_bounds("settings-content").unwrap();
    let bounds = cx.debug_bounds(selector).unwrap();
    let delta = if bounds.top() < viewport.top() {
        viewport.top() - bounds.top() + px(1.)
    } else if bounds.bottom() > viewport.bottom() {
        viewport.bottom() - bounds.bottom() - px(1.)
    } else {
        px(0.)
    };
    if delta != px(0.) {
        cx.simulate_event(ScrollWheelEvent {
            position: point(viewport.left() + px(2.), viewport.center().y),
            delta: ScrollDelta::Pixels(point(px(0.), delta)),
            modifiers: Modifiers::none(),
            touch_phase: TouchPhase::Moved,
        });
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
    }
    let bounds = cx.debug_bounds(selector).unwrap();
    assert!(
        bounds.top() >= viewport.top() && bounds.bottom() <= viewport.bottom(),
        "control is reachable by scrolling: {selector}"
    );
}

#[test]
fn runtime_row_opens_account_detail_while_download_remains_an_independent_action() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(393.), px(844.)), |_, cx| Shell::new(cx));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    cx.run_until_parked();
    window
        .update(&mut cx, |shell, _, cx| {
            seed_shell(shell, Locale::En);
            cx.notify();
        })
        .unwrap();
    reveal(&mut cx, "settings-runtime-download-codex");
    let download = cx.debug_bounds("settings-runtime-download-codex").unwrap();
    cx.simulate_click(download.center(), Modifiers::none());
    cx.run_until_parked();
    window
        .read_with(&cx, |shell, _| {
            assert!(shell.runtime_subscriptions.expanded.is_none())
        })
        .unwrap();
    let row = cx.debug_bounds("settings-runtime-codex").unwrap();
    cx.simulate_click(
        point(row.left() + px(60.), row.center().y),
        Modifiers::none(),
    );
    cx.run_until_parked();
    window
        .read_with(&cx, |shell, _| {
            assert!(shell.runtime_subscriptions.expanded == Some(RuntimeProduct::Codex));
            assert!(shell.runtime_subscriptions.request.is_none());
        })
        .unwrap();
    cx.update(|window, cx| window.draw(cx).clear(cx));
    assert!(
        cx.debug_bounds("settings-subscription-detail-settings-runtime-codex")
            .is_some()
    );
}

#[test]
fn account_controls_fit_phone_and_tablet_in_both_languages_and_preview_never_dispatches() {
    for width in [320., 1194.] {
        for locale in [Locale::Zh, Locale::En] {
            for key in [AccountKey::Claude, AccountKey::Bigmodel] {
                let mut app = TestAppContext::single();
                let window = app.open_window(size(px(width), px(844.)), |_, cx| Shell::new(cx));
                let mut cx = VisualTestContext::from_window(window.into(), &app);
                cx.run_until_parked();
                window
                    .update(&mut cx, |shell, _, cx| {
                        seed_shell(shell, locale);
                        shell.runtime_subscriptions.expanded = Some(key.product());
                        shell.runtime_subscriptions.accounts[key as usize] = parse_account(
                            key,
                            &if key.is_zcode() {
                                zcode(key, "signed_in")
                            } else {
                                authorizing(key)
                            },
                        )
                        .unwrap();
                        cx.notify();
                    })
                    .unwrap();
                let selectors = if key.is_zcode() {
                    vec![
                        "settings-subscription-logout-bigmodel",
                        "settings-subscription-use-subscription-bigmodel",
                        "settings-subscription-use-api-bigmodel",
                        "settings-subscription-refresh-bigmodel",
                    ]
                } else {
                    vec![
                        "settings-subscription-open-claude-code",
                        "settings-subscription-submit-code-claude-code",
                        "settings-subscription-cancel-claude-code",
                        "settings-subscription-use-api-claude-code",
                        "settings-subscription-refresh-claude-code",
                    ]
                };
                for selector in selectors {
                    reveal(&mut cx, selector);
                    let bounds = cx.debug_bounds(selector).unwrap();
                    let viewport = cx.debug_bounds("settings-content").unwrap();
                    assert!(bounds.size.height >= px(44.) && bounds.size.width >= px(44.));
                    assert!(
                        bounds.left() >= viewport.left() && bounds.right() <= viewport.right(),
                        "no horizontal overflow: width={width}, locale={}, selector={selector}",
                        locale.code()
                    );
                    cx.simulate_click(bounds.center(), Modifiers::none());
                    cx.run_until_parked();
                    window
                        .read_with(&cx, |shell, _| {
                            assert!(shell.runtime_subscriptions.request.is_none());
                            assert!(!shell.native_form_active);
                            assert!(shell.runtime_subscriptions.expanded == Some(key.product()));
                        })
                        .unwrap();
                }
            }
        }
    }
}
