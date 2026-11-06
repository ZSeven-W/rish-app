//! Account authorization is independent of engine installation and selection.
//! Only display-safe status is retained; URLs, tokens and pasted codes stay native.
use super::{assistant_copy::copy, *};
use crate::providers::RuntimeProduct;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum AccountKey {
    Claude,
    Codex,
    Bigmodel,
    Zai,
}
impl AccountKey {
    pub const ALL: [Self; 4] = [Self::Claude, Self::Codex, Self::Bigmodel, Self::Zai];
    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude-code",
            Self::Codex => "codex",
            Self::Bigmodel => "bigmodel",
            Self::Zai => "zai",
        }
    }
    pub fn product(self) -> RuntimeProduct {
        match self {
            Self::Claude => RuntimeProduct::ClaudeCode,
            Self::Codex => RuntimeProduct::Codex,
            Self::Bigmodel | Self::Zai => RuntimeProduct::Zcode,
        }
    }
    pub fn is_zcode(self) -> bool {
        matches!(self, Self::Bigmodel | Self::Zai)
    }
    pub fn source_methods(self) -> (&'static str, &'static str) {
        match self {
            Self::Claude => ("claudeChatSource", "selectClaudeChatSource"),
            Self::Codex => ("codexChatSource", "selectCodexChatSource"),
            Self::Bigmodel | Self::Zai => ("glmCredentialSource", "selectGlmCredentialSource"),
        }
    }
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum AccountPhase {
    #[default]
    Unknown,
    Unavailable,
    SignedOut,
    Starting,
    Pending,
    Verifying,
    SignedIn,
    Failed,
    Expired,
}
impl AccountPhase {
    pub fn active(self) -> bool {
        matches!(self, Self::Starting | Self::Pending | Self::Verifying)
    }
    pub fn label(self, locale: Locale) -> &'static str {
        match self {
            Self::Unknown => copy(locale, "Sign in to subscription", "登录订阅"),
            Self::Unavailable => copy(locale, "Sign-in unavailable", "暂不支持登录"),
            Self::SignedOut => copy(locale, "Not signed in", "未登录"),
            Self::Starting => copy(locale, "Preparing sign-in", "正在准备登录"),
            Self::Pending => copy(locale, "Awaiting authorization", "等待授权"),
            Self::Verifying => copy(locale, "Verifying sign-in", "正在验证登录"),
            Self::SignedIn => copy(locale, "Signed in", "已登录"),
            Self::Failed => copy(locale, "Sign-in failed", "登录失败"),
            Self::Expired => copy(locale, "Sign-in expired", "登录已过期"),
        }
    }
}

#[derive(Clone, Default)]
pub(super) struct LoginDisplay {
    pub session: Option<String>,
    pub device_code: Option<String>,
    pub can_open: bool,
    pub can_submit: bool,
}

#[derive(Clone)]
pub(super) struct AccountState {
    pub phase: AccountPhase,
    pub available: bool,
    pub needs_download: bool,
    pub label: Option<String>,
    pub login: LoginDisplay,
    pub error: Option<&'static str>,
}
impl AccountState {
    fn new() -> Self {
        Self {
            phase: AccountPhase::Unknown,
            available: false,
            needs_download: false,
            label: None,
            login: LoginDisplay::default(),
            error: None,
        }
    }
}

#[derive(Clone, Default)]
pub(super) struct AccountSource {
    pub source: Option<String>,
    pub ready: bool,
    verified: bool,
}
impl AccountSource {
    pub fn verified(&self) -> bool {
        self.verified
    }
    pub fn selected_subscription(&self, key: AccountKey) -> bool {
        self.source.as_deref()
            == Some(if key.is_zcode() {
                key.id()
            } else {
                "subscription"
            })
    }
    pub fn label(&self, locale: Locale) -> String {
        let label = match self.source.as_deref() {
            Some("api_key") => "API",
            Some("subscription") => copy(locale, "Subscription", "订阅"),
            Some("bigmodel") => copy(locale, "BigModel subscription", "智谱订阅"),
            Some("zai") => "Z.AI",
            Some("bigmodel_trial") => copy(locale, "BigModel trial", "智谱试用"),
            Some("zai_trial") => copy(locale, "Z.AI trial", "Z.AI 试用"),
            _ => return copy(locale, "Not selected", "未选择").into(),
        };
        format!(
            "{label} · {}",
            if self.ready {
                copy(locale, "Ready", "可用")
            } else {
                copy(locale, "Not ready", "尚不可用")
            }
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum SubscriptionAction {
    Refresh,
    Login,
    Open,
    SubmitCode,
    Cancel,
    Logout,
    UseSubscription,
    UseApi,
}
#[derive(Clone)]
pub(super) struct SubscriptionRequest {
    pub token: String,
    pub key: AccountKey,
    pub action: SubscriptionAction,
}
pub(super) struct RuntimeSubscriptionsUi {
    pub expanded: Option<RuntimeProduct>,
    pub zcode_region: AccountKey,
    pub accounts: [AccountState; 4],
    pub sources: [AccountSource; 3],
    pub request: Option<SubscriptionRequest>,
    pub poll_generation: u64,
    pub foreground: bool,
    pub models_error: bool,
}
impl Default for RuntimeSubscriptionsUi {
    fn default() -> Self {
        Self {
            expanded: None,
            zcode_region: AccountKey::Bigmodel,
            accounts: AccountKey::ALL.map(|_| AccountState::new()),
            sources: Default::default(),
            request: None,
            poll_generation: 0,
            foreground: true,
            models_error: false,
        }
    }
}
impl RuntimeSubscriptionsUi {
    pub fn accept_source(&mut self, key: AccountKey, value: Result<Value, String>) -> bool {
        if let Ok(source) = value
            .map_err(|_| ())
            .and_then(|value| parse_source(key, &value))
        {
            self.sources[source_index(key)] = source;
            true
        } else {
            self.sources[source_index(key)].verified = false;
            false
        }
    }
    pub fn key(&self, product: RuntimeProduct) -> Option<AccountKey> {
        match product {
            RuntimeProduct::Dsh => None,
            RuntimeProduct::ClaudeCode => Some(AccountKey::Claude),
            RuntimeProduct::Codex => Some(AccountKey::Codex),
            RuntimeProduct::Zcode => Some(self.zcode_region),
        }
    }
    pub fn account(&self, key: AccountKey) -> &AccountState {
        &self.accounts[key as usize]
    }
    pub fn source(&self, key: AccountKey) -> &AccountSource {
        &self.sources[source_index(key)]
    }
    pub fn can_action(&self, key: AccountKey, action: SubscriptionAction) -> bool {
        if self.request.is_some() {
            return false;
        }
        let account = self.account(key);
        if account.error.is_some()
            && !matches!(
                action,
                SubscriptionAction::Refresh | SubscriptionAction::Cancel
            )
        {
            return false;
        }
        match action {
            SubscriptionAction::Refresh => true,
            SubscriptionAction::Login => {
                account.available
                    && !account.phase.active()
                    && account.phase != AccountPhase::SignedIn
            }
            SubscriptionAction::Open => account.phase.active() && account.login.can_open,
            SubscriptionAction::SubmitCode => account.phase.active() && account.login.can_submit,
            SubscriptionAction::Cancel => account.phase.active(),
            SubscriptionAction::Logout => account.phase == AccountPhase::SignedIn,
            SubscriptionAction::UseSubscription => {
                account.phase == AccountPhase::SignedIn
                    && self.source(key).verified
                    && (!self.source(key).selected_subscription(key) || !self.source(key).ready)
            }
            SubscriptionAction::UseApi => {
                self.source(key).verified && self.source(key).source.as_deref() != Some("api_key")
            }
        }
    }
    pub fn prepare(
        &mut self,
        key: AccountKey,
        action: SubscriptionAction,
        locale: Locale,
    ) -> Option<(SubscriptionRequest, RuntimeCommand)> {
        if !self.can_action(key, action) {
            return None;
        }
        let account = self.account(key);
        let mut args = vec![serde_json::json!(key.id())];
        let method = match action {
            SubscriptionAction::Refresh => {
                if key.is_zcode() {
                    "zcodeAccountStatus"
                } else {
                    "harnessAuthStatus"
                }
            }
            SubscriptionAction::Login => {
                if key.is_zcode() {
                    "startZcodeAccountLogin"
                } else {
                    "startHarnessLogin"
                }
            }
            SubscriptionAction::Open | SubscriptionAction::Cancel => {
                if !key.is_zcode() {
                    args.push(serde_json::json!(account.login.session.as_ref()?));
                }
                match (key.is_zcode(), action) {
                    (true, SubscriptionAction::Open) => "openZcodeAccountAuthorization",
                    (true, _) => "cancelZcodeAccountLogin",
                    (false, SubscriptionAction::Open) => "openHarnessAuthorization",
                    (false, _) => "cancelHarnessLogin",
                }
            }
            SubscriptionAction::SubmitCode => {
                args.push(serde_json::json!(account.login.session.as_ref()?));
                args.push(serde_json::json!(locale.code()));
                "presentHarnessLoginCode"
            }
            SubscriptionAction::Logout => {
                if key.is_zcode() {
                    "logoutZcodeAccount"
                } else {
                    "logoutHarness"
                }
            }
            SubscriptionAction::UseSubscription | SubscriptionAction::UseApi => {
                let source = if action == SubscriptionAction::UseApi {
                    "api_key"
                } else if key.is_zcode() {
                    key.id()
                } else {
                    "subscription"
                };
                args = vec![serde_json::json!(source)];
                key.source_methods().1
            }
        };
        let request = SubscriptionRequest {
            token: uuid::Uuid::new_v4().to_string(),
            key,
            action,
        };
        self.request = Some(request.clone());
        self.accounts[key as usize].error = None;
        self.poll_generation = self.poll_generation.wrapping_add(1);
        Some((request, RuntimeCommand::new("LocalRuntime", method, args)))
    }
    pub fn accept(
        &mut self,
        request: &SubscriptionRequest,
        status: Result<Value, String>,
        source: Option<Result<Value, String>>,
        operation_error: bool,
        locale: Locale,
    ) -> bool {
        if self.request.as_ref().map(|r| &r.token) != Some(&request.token) {
            return false;
        }
        self.request = None;
        let account = &mut self.accounts[request.key as usize];
        match status
            .map_err(|_| ())
            .and_then(|v| parse_account(request.key, &v))
        {
            Ok(updated) => *account = updated,
            Err(()) => {
                account.error = Some(copy(
                    locale,
                    "Couldn't refresh account status. Try again.",
                    "暂时无法更新账号状态，请重试。",
                ))
            }
        }
        if let Some(source) = source {
            if let Ok(source) = source
                .map_err(|_| ())
                .and_then(|v| parse_source(request.key, &v))
            {
                self.sources[source_index(request.key)] = source;
            } else {
                self.sources[source_index(request.key)].verified = false;
                account.error = Some(copy(
                    locale,
                    "Couldn't verify the selected source. Refresh before changing it.",
                    "暂时无法核对当前来源，请刷新后再切换。",
                ));
            }
        }
        if operation_error {
            account.error = Some(copy(
                locale,
                "The account action couldn't finish. Check the status and try again.",
                "账号操作未完成，请核对状态后重试。",
            ));
        }
        true
    }
}
fn source_index(key: AccountKey) -> usize {
    match key {
        AccountKey::Claude => 0,
        AccountKey::Codex => 1,
        _ => 2,
    }
}
fn safe_text(value: &Value, max: usize) -> Result<Option<String>, ()> {
    match value {
        Value::Null => Ok(None),
        Value::String(value)
            if !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control) =>
        {
            Ok(Some(value.clone()))
        }
        _ => Err(()),
    }
}
fn parse_source(key: AccountKey, value: &Value) -> Result<AccountSource, ()> {
    if value["schema_version"] != 1 {
        return Err(());
    }
    let source = safe_text(&value["source"], 32)?;
    if source.as_deref().is_some_and(|source| match source {
        "api_key" | "unavailable" => false,
        "subscription" => key.is_zcode(),
        "bigmodel" | "zai" | "bigmodel_trial" | "zai_trial" => !key.is_zcode(),
        _ => true,
    }) {
        return Err(());
    }
    Ok(AccountSource {
        source,
        ready: value["ready"].as_bool().ok_or(())?,
        verified: true,
    })
}
fn parse_account(key: AccountKey, value: &Value) -> Result<AccountState, ()> {
    if value["schema_version"] != 1 {
        return Err(());
    }
    let mut account = AccountState::new();
    if key.is_zcode() {
        if value["provider"].as_str() != Some(key.id()) {
            return Err(());
        }
        account.available = true;
        account.phase = match value["status"].as_str() {
            Some("signed_out") => AccountPhase::SignedOut,
            Some("starting") => AccountPhase::Starting,
            Some("pending") => AccountPhase::Pending,
            Some("signed_in") => AccountPhase::SignedIn,
            Some("failed") => AccountPhase::Failed,
            Some("expired") => AccountPhase::Expired,
            _ => return Err(()),
        };
        account.label = safe_text(&value["account_label"], 200)?;
        account.login.can_open = account.phase == AccountPhase::Pending
            && value["authorize_url"]
                .as_str()
                .is_some_and(|url| !url.is_empty());
    } else {
        if value["harness_id"].as_str() != Some(key.id()) {
            return Err(());
        }
        account.available = value["runtime"]["available"].as_bool().ok_or(())?;
        account.needs_download = value["runtime"]["reason"] == "cli-not-installed";
        account.phase = match value["status"].as_str() {
            Some("unavailable") => AccountPhase::Unavailable,
            Some("signed_out") => AccountPhase::SignedOut,
            Some("signed_in") => AccountPhase::SignedIn,
            Some("error") => AccountPhase::Failed,
            Some("authorizing") => match value["login"]["phase"].as_str() {
                Some("starting") => AccountPhase::Starting,
                Some("verifying") => AccountPhase::Verifying,
                Some("waiting_for_browser") | None => AccountPhase::Pending,
                _ => return Err(()),
            },
            _ => return Err(()),
        };
        if (account.phase == AccountPhase::SignedIn || account.phase.active())
            && value["auth_method"] != "subscription"
        {
            return Err(());
        }
        account.label = safe_text(&value["account"]["label"], 200)?;
        if account.phase.active() {
            account.login.session = safe_text(&value["login"]["session_id"], 128)?;
            if account.login.session.is_none() {
                return Err(());
            }
            account.login.device_code = safe_text(&value["login"]["user_code"], 32)?;
            account.login.can_open = value["login"]["verification_url"]
                .as_str()
                .is_some_and(|url| !url.is_empty());
            account.login.can_submit = key == AccountKey::Claude
                && value["login"]["can_submit_code"].as_bool().unwrap_or(false);
        }
    }
    Ok(account)
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "settings_subscriptions_tests.rs"]
mod tests;
