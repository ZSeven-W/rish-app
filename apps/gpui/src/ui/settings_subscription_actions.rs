use super::{settings_runtime_engines::AuthenticationCapabilities, settings_subscriptions::*, *};
use crate::providers::RuntimeProduct;
use serde_json::json;
use std::time::Duration;

impl Shell {
    pub(super) fn subscription_capabilities(
        &self,
        product: RuntimeProduct,
    ) -> AuthenticationCapabilities {
        self.runtime_engines
            .entries
            .iter()
            .find(|entry| entry.product == product)
            .map(|entry| entry.authentication)
            .unwrap_or_default()
    }

    pub(super) fn toggle_runtime_subscription(
        &mut self,
        product: RuntimeProduct,
        cx: &mut Context<Self>,
    ) {
        self.runtime_subscriptions.expanded =
            if self.runtime_subscriptions.expanded == Some(product) {
                None
            } else {
                Some(product)
            };
        self.runtime_subscriptions.poll_generation =
            self.runtime_subscriptions.poll_generation.wrapping_add(1);
        self.refresh_visible_subscription(cx);
        cx.notify();
    }

    pub(super) fn select_subscription_region(&mut self, key: AccountKey, cx: &mut Context<Self>) {
        if !key.is_zcode()
            || !self
                .subscription_capabilities(RuntimeProduct::Zcode)
                .provider_selection
        {
            return;
        }
        self.runtime_subscriptions.zcode_region = key;
        self.runtime_subscriptions.poll_generation =
            self.runtime_subscriptions.poll_generation.wrapping_add(1);
        self.refresh_visible_subscription(cx);
        cx.notify();
    }

    pub(super) fn refresh_visible_subscription(&mut self, cx: &mut Context<Self>) {
        let Some(key) = self
            .runtime_subscriptions
            .expanded
            .and_then(|product| self.runtime_subscriptions.key(product))
        else {
            return;
        };
        self.subscription_action(key, SubscriptionAction::Refresh, cx);
    }

    pub(super) fn subscription_mutation_enabled(&self) -> bool {
        !self.loading
            && !self.aux_busy
            && !self.state.is_busy()
            && !self.assistant_writer_lease
            && !self.native_form_active
    }

    pub(super) fn subscription_lifecycle(&mut self, value: &Value, cx: &mut Context<Self>) {
        if value["schema_version"] != 1 {
            return;
        }
        let Some(foreground) = value["foreground"].as_bool() else {
            return;
        };
        self.runtime_subscriptions.foreground = foreground;
        self.runtime_subscriptions.poll_generation =
            self.runtime_subscriptions.poll_generation.wrapping_add(1);
        if foreground {
            self.refresh_visible_subscription(cx);
        }
    }

    pub(super) fn subscription_action(
        &mut self,
        key: AccountKey,
        action: SubscriptionAction,
        cx: &mut Context<Self>,
    ) {
        let caps = self.subscription_capabilities(key.product());
        if !self.runtime.is_native()
            || !self.runtime_catalog_visible()
            || !self.runtime_subscriptions.foreground
            || !caps.supported
            || (action != SubscriptionAction::Refresh && !self.subscription_mutation_enabled())
            || (matches!(
                action,
                SubscriptionAction::UseApi | SubscriptionAction::UseSubscription
            ) && !caps.source_selection)
            || (action == SubscriptionAction::Open && !caps.authorization_browser)
            || (action == SubscriptionAction::SubmitCode && !caps.native_code_entry)
        {
            return;
        }
        let Some((request, command)) = self.runtime_subscriptions.prepare(key, action, self.locale)
        else {
            return;
        };
        if action == SubscriptionAction::SubmitCode {
            self.set_inline_native_form(true, cx);
        }
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let operation = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            // Always re-read native state after an action, including errors. A
            // browser dismissal or failed source switch is not an auth receipt.
            let status = if action == SubscriptionAction::Refresh {
                operation.clone()
            } else {
                runtime
                    .call(
                        "LocalRuntime",
                        if key.is_zcode() {
                            "zcodeAccountStatus"
                        } else {
                            "harnessAuthStatus"
                        },
                        json!([key.id()]),
                    )
                    .await
            };
            let source = if caps.source_selection {
                Some(
                    runtime
                        .call("LocalRuntime", key.source_methods().0, json!([]))
                        .await,
                )
            } else {
                None
            };
            let _ = this.update(cx, |this, cx| {
                if action == SubscriptionAction::SubmitCode {
                    this.set_inline_native_form(false, cx);
                }
                if this.runtime_subscriptions.accept(
                    &request,
                    status,
                    source,
                    operation.is_err(),
                    this.locale,
                ) {
                    let signed_in =
                        this.runtime_subscriptions.account(key).phase == AccountPhase::SignedIn;
                    if caps.source_selection
                        && key == AccountKey::Codex
                        && signed_in
                        && this.runtime_subscriptions.account(key).error.is_none()
                        && this.runtime_subscriptions.source(key).verified()
                        && this
                            .runtime_subscriptions
                            .source(key)
                            .selected_subscription(key)
                    {
                        this.refresh_subscription_codex_models(cx);
                    }
                    if key == AccountKey::Codex
                        && caps.source_selection
                        && this.runtime_subscriptions.source(key).verified()
                        && this.runtime_subscriptions.source(key).source.as_deref()
                            == Some("api_key")
                    {
                        this.runtime_subscriptions.models_error = !this
                            .subscription_mutation_enabled()
                            || this.state.reset_codex_subscription_models().is_err();
                    }
                    let visible = this
                        .runtime_subscriptions
                        .expanded
                        .and_then(|product| this.runtime_subscriptions.key(product));
                    if visible.is_some_and(|visible| visible != key) {
                        this.refresh_visible_subscription(cx);
                    } else {
                        this.poll_runtime_subscription(cx);
                    }
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn refresh_subscription_codex_models(&mut self, cx: &mut Context<Self>) {
        if !self.runtime_catalog_visible() || !self.runtime_subscriptions.foreground {
            return;
        }
        let runtime = self.runtime.clone();
        let generation = self.runtime_subscriptions.poll_generation;
        self.runtime_subscriptions.models_error = false;
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call("LocalRuntime", "codexAvailableModels", json!([]))
                .await;
            let _ = this.update(cx, |this, cx| {
                let current = this.runtime_subscriptions.poll_generation == generation
                    && this.runtime_catalog_visible()
                    && this.runtime_subscriptions.foreground
                    && this.runtime_subscriptions.account(AccountKey::Codex).phase
                        == AccountPhase::SignedIn
                    && this
                        .runtime_subscriptions
                        .account(AccountKey::Codex)
                        .error
                        .is_none()
                    && this
                        .runtime_subscriptions
                        .source(AccountKey::Codex)
                        .verified()
                    && this
                        .runtime_subscriptions
                        .source(AccountKey::Codex)
                        .selected_subscription(AccountKey::Codex);
                if !current {
                    return;
                }
                // Catalog-only updates preserve session/model/engine identity;
                // never bootstrap or load persisted state from this callback.
                this.runtime_subscriptions.models_error = match result {
                    Ok(models) if this.subscription_mutation_enabled() => {
                        this.state.apply_codex_subscription_models(models).is_err()
                    }
                    _ => true,
                };
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn refresh_subscription_after_credentials(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || !self
                .subscription_capabilities(RuntimeProduct::Codex)
                .source_selection
        {
            return;
        }
        self.runtime_subscriptions.poll_generation =
            self.runtime_subscriptions.poll_generation.wrapping_add(1);
        let generation = self.runtime_subscriptions.poll_generation;
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call("LocalRuntime", "codexChatSource", json!([]))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.runtime_subscriptions.poll_generation != generation {
                    return;
                }
                let confirmed = this
                    .runtime_subscriptions
                    .accept_source(AccountKey::Codex, result);
                if confirmed
                    && this
                        .runtime_subscriptions
                        .source(AccountKey::Codex)
                        .source
                        .as_deref()
                        == Some("api_key")
                {
                    this.runtime_subscriptions.models_error = !this.subscription_mutation_enabled()
                        || this.state.reset_codex_subscription_models().is_err();
                } else if !confirmed {
                    this.runtime_subscriptions.models_error = true;
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn subscription_poll_needed(&self) -> bool {
        self.runtime_catalog_visible()
            && self.runtime_subscriptions.foreground
            && self.runtime_subscriptions.request.is_none()
            && self
                .runtime_subscriptions
                .expanded
                .and_then(|product| self.runtime_subscriptions.key(product))
                .is_some_and(|key| {
                    let account = self.runtime_subscriptions.account(key);
                    account.phase.active() && account.error.is_none()
                })
    }

    fn poll_runtime_subscription(&mut self, cx: &mut Context<Self>) {
        if !self.subscription_poll_needed() {
            return;
        }
        let generation = self.runtime_subscriptions.poll_generation;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            let _ = this.update(cx, |this, cx| {
                if this.runtime_subscriptions.poll_generation == generation
                    && this.subscription_poll_needed()
                {
                    this.refresh_visible_subscription(cx);
                }
            });
        })
        .detach();
    }
}
