use super::{assistant_copy::copy, settings_subscriptions::*, *};
use crate::providers::RuntimeProduct;
use gpui::{AnyElement, Div};

impl Shell {
    pub(super) fn subscription_row_label(&self, product: RuntimeProduct) -> &'static str {
        if !self.subscription_capabilities(product).supported {
            return copy(self.locale, "Sign-in unavailable", "暂不支持登录");
        }
        self.runtime_subscriptions
            .key(product)
            .map(|key| {
                self.runtime_subscriptions
                    .account(key)
                    .phase
                    .label(self.locale)
            })
            .unwrap_or(copy(self.locale, "No account sign-in", "无需账号登录"))
    }

    pub(super) fn settings_subscription_detail(
        &self,
        product: RuntimeProduct,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let caps = self.subscription_capabilities(product);
        let id = format!(
            "settings-subscription-detail-{}",
            product.settings_selector()
        );
        let mut content = div()
            .id(id.clone())
            .debug_selector(move || id.clone())
            .px_4()
            .pb_3()
            .w_full()
            .min_w(px(0.))
            .flex()
            .flex_col()
            .gap_2();
        if !caps.supported {
            return content
                .child(subscription_text(
                    copy(
                        self.locale,
                        "Subscription sign-in is not available for this engine on this platform.",
                        "此平台暂不支持该引擎的订阅登录。",
                    ),
                    p,
                ))
                .into_any_element();
        }
        let Some(key) = self.runtime_subscriptions.key(product) else {
            return content.into_any_element();
        };
        let account = self.runtime_subscriptions.account(key);
        if caps.provider_selection {
            let mut regions = div().w_full().min_w(px(0.)).flex().gap_2();
            for (region, label) in [
                (AccountKey::Bigmodel, copy(self.locale, "BigModel", "智谱")),
                (AccountKey::Zai, "Z.AI"),
            ] {
                let id = format!("settings-subscription-region-{}", region.id());
                regions = regions.child(
                    div()
                        .id(id.clone())
                        .debug_selector(move || id.clone())
                        .role(gpui::Role::RadioButton)
                        .aria_label(label)
                        .aria_toggled(if region == key {
                            gpui::Toggled::True
                        } else {
                            gpui::Toggled::False
                        })
                        .min_h(px(44.))
                        .flex_1()
                        .min_w(px(0.))
                        .rounded(px(12.))
                        .bg(if region == key { p.surface } else { p.composer })
                        .text_size(px(13.))
                        .text_color(p.text)
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .child(label)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.select_subscription_region(region, cx)
                        })),
                );
            }
            content = content.child(regions);
        }
        let status = account.phase.label(self.locale);
        content = content.child(subscription_text(
            match &account.label {
                Some(label) => format!("{status} · {label}"),
                None => status.into(),
            },
            p,
        ));
        if account.needs_download {
            content = content.child(subscription_text(
                copy(
                    self.locale,
                    "Download this engine, then refresh to sign in.",
                    "请先下载此引擎，再刷新并登录。",
                ),
                p,
            ));
        }
        if let Some(code) = &account.login.device_code {
            content = content.child(
                div()
                    .id("settings-subscription-device-code")
                    .debug_selector(|| "settings-subscription-device-code".into())
                    .min_h(px(44.))
                    .px_3()
                    .py_2()
                    .rounded(px(12.))
                    .bg(p.surface)
                    .text_size(px(16.))
                    .text_color(p.text)
                    .whitespace_normal()
                    .child(format!(
                        "{}: {code}",
                        copy(self.locale, "Device code", "设备验证码")
                    )),
            );
        }
        if account.phase.active() {
            content = content.child(subscription_text(copy(self.locale,
                "Complete authorization in your browser, then return here. This page updates while open.",
                "请在浏览器中完成授权后返回，此页面打开时会自动更新。"), p));
            if account.login.can_open && caps.authorization_browser {
                content = content.child(self.subscription_button(
                    key,
                    SubscriptionAction::Open,
                    "open",
                    copy(self.locale, "Open sign-in page", "打开登录页面"),
                    cx,
                ));
            }
            if account.login.can_submit && caps.native_code_entry {
                content = content.child(self.subscription_button(
                    key,
                    SubscriptionAction::SubmitCode,
                    "submit-code",
                    copy(self.locale, "Enter authorization code", "输入授权码"),
                    cx,
                ));
            }
            content = content.child(self.subscription_button(
                key,
                SubscriptionAction::Cancel,
                "cancel",
                copy(self.locale, "Cancel sign-in", "取消登录"),
                cx,
            ));
        } else if account.phase == AccountPhase::SignedIn {
            content = content.child(self.subscription_button(
                key,
                SubscriptionAction::Logout,
                "logout",
                copy(self.locale, "Sign out", "退出登录"),
                cx,
            ));
        } else {
            content = content.child(self.subscription_button(
                key,
                SubscriptionAction::Login,
                "login",
                copy(self.locale, "Sign in to subscription", "登录订阅"),
                cx,
            ));
        }
        if caps.source_selection {
            let source = self.runtime_subscriptions.source(key);
            content = content.child(subscription_text(
                format!(
                    "{}: {}",
                    copy(self.locale, "Model source", "模型来源"),
                    source.label(self.locale)
                ),
                p,
            ));
            if account.phase == AccountPhase::SignedIn {
                content = content.child(self.subscription_button(
                    key,
                    SubscriptionAction::UseSubscription,
                    "use-subscription",
                    if source.selected_subscription(key) {
                        if source.ready {
                            copy(self.locale, "Subscription selected", "已选择订阅")
                        } else {
                            copy(self.locale, "Verify subscription", "验证订阅")
                        }
                    } else {
                        copy(self.locale, "Use subscription", "使用订阅")
                    },
                    cx,
                ));
            }
            content = content.child(self.subscription_button(
                key,
                SubscriptionAction::UseApi,
                "use-api",
                if source.source.as_deref() == Some("api_key") {
                    copy(self.locale, "API selected", "已选择 API")
                } else {
                    copy(self.locale, "Use API", "使用 API")
                },
                cx,
            ));
            content = content.child(subscription_text(if key.is_zcode() {
                copy(self.locale, "Signing in connects the account. Choose subscription to verify your plan. API credentials are managed in Model & API.", "登录仅连接账号；选择订阅后会验证套餐。API 凭据在「模型与 API」中管理。")
            } else {
                copy(self.locale, "Account and model source are separate from the selected runtime. API credentials are managed in Model & API.", "账号和模型来源与运行时选择独立。API 凭据在「模型与 API」中管理。")
            }, p));
        }
        if let Some(error) = account.error {
            content = content.child(subscription_text(error, p).text_color(p.danger));
        }
        if key == AccountKey::Codex && self.runtime_subscriptions.models_error {
            content = content.child(subscription_text(copy(self.locale,
                "Account status is unchanged. Refresh when idle to update the available models.",
                "账号状态未改变，请在空闲时刷新以更新可用模型。"), p));
        }
        content = content.child(self.subscription_button(
            key,
            SubscriptionAction::Refresh,
            "refresh",
            copy(self.locale, "Refresh account status", "刷新账号状态"),
            cx,
        ));
        content.child(subscription_text(copy(self.locale,
            "Signing in does not make this CLI available for tasks or change the selected engine.",
            "登录不会让此 CLI 自动具备任务执行能力，也不会更改已选引擎。"), p)).into_any_element()
    }

    fn subscription_button(
        &self,
        key: AccountKey,
        action: SubscriptionAction,
        suffix: &'static str,
        label: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let enabled = self.runtime.is_native()
            && self.runtime_subscriptions.can_action(key, action)
            && (action == SubscriptionAction::Refresh || self.subscription_mutation_enabled());
        let pending = self
            .runtime_subscriptions
            .request
            .as_ref()
            .is_some_and(|request| request.key == key && request.action == action);
        let id = format!("settings-subscription-{suffix}-{}", key.id());
        div()
            .id(id.clone())
            .debug_selector(move || id.clone())
            .role(gpui::Role::Button)
            .aria_label(label)
            .w_full()
            .min_h(px(44.))
            .min_w(px(0.))
            .px_3()
            .py_2()
            .rounded(px(12.))
            .bg(p.surface)
            .text_size(px(13.))
            .text_color(if enabled { p.text } else { p.muted })
            .whitespace_normal()
            .flex()
            .items_center()
            .justify_center()
            .when(enabled, |button| button.cursor_pointer())
            .child(if pending {
                copy(self.locale, "Working…", "正在处理…")
            } else {
                label
            })
            .on_click(cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                if enabled {
                    this.subscription_action(key, action, cx);
                }
            }))
            .into_any_element()
    }
}

fn subscription_text(text: impl Into<String>, p: Palette) -> Div {
    div()
        .min_w(px(0.))
        .text_size(px(12.))
        .line_height(px(19.))
        .text_color(p.muted)
        .whitespace_normal()
        .child(text.into())
}
