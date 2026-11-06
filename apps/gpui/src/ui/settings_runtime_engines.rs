//! Downloaded runtime products are separate from API credential providers.
//! Installation is not proof that an assistant execution adapter is ready.
use super::{assistant_copy::copy, *};
use crate::providers::RuntimeProduct;
use gpui::AnyElement;
use serde_json::json;
use std::time::Duration;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) enum EngineInstallation {
    #[default]
    Unknown,
    NotInstalled,
    Installing {
        progress: Option<u8>,
    },
    Downloaded {
        version: Option<String>,
    },
    Installed {
        version: Option<String>,
    },
    Unavailable {
        reason: String,
    },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum EngineIntegrity {
    #[default]
    Unknown,
    Unverified,
    Verified,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum EngineExecution {
    Unavailable,
}

#[derive(Clone, Copy, Debug, Default)]
pub(super) struct AuthenticationCapabilities {
    pub supported: bool,
    pub source_selection: bool,
    pub authorization_browser: bool,
    pub native_code_entry: bool,
    pub provider_selection: bool,
}

#[derive(Clone, Debug)]
pub(super) struct RuntimeEngineState {
    pub product: RuntimeProduct,
    pub installation: EngineInstallation,
    pub integrity: EngineIntegrity,
    pub download_supported: bool,
    pub download_error: bool,
    pub execution: EngineExecution,
    pub authentication: AuthenticationCapabilities,
}

#[derive(Clone)]
struct EngineRequest {
    token: String,
    install: Option<RuntimeProduct>,
}

pub(super) struct RuntimeEnginesUi {
    pub entries: [RuntimeEngineState; 4],
    pub loading: bool,
    pub error: Option<String>,
    request: Option<EngineRequest>,
    poll_generation: u64,
}

impl Default for RuntimeEnginesUi {
    fn default() -> Self {
        Self {
            entries: RuntimeProduct::ALL.map(|product| RuntimeEngineState {
                product,
                installation: EngineInstallation::Unknown,
                integrity: EngineIntegrity::Unknown,
                download_supported: false,
                download_error: false,
                execution: EngineExecution::Unavailable,
                authentication: AuthenticationCapabilities::default(),
            }),
            loading: false,
            error: None,
            request: None,
            poll_generation: 0,
        }
    }
}

impl RuntimeProduct {
    pub(super) fn settings_selector(self) -> &'static str {
        match self {
            Self::Dsh => "settings-runtime-dsh",
            Self::ClaudeCode => "settings-runtime-claude-code",
            Self::Codex => "settings-runtime-codex",
            Self::Zcode => "settings-runtime-zcode",
        }
    }
    fn engine_id(self) -> &'static str {
        match self {
            Self::Dsh => "dsh",
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
            Self::Zcode => "zcode",
        }
    }
    fn download_selector(self) -> &'static str {
        match self {
            Self::Dsh => "settings-runtime-download-dsh",
            Self::ClaudeCode => "settings-runtime-download-claude-code",
            Self::Codex => "settings-runtime-download-codex",
            Self::Zcode => "settings-runtime-download-zcode",
        }
    }
}

fn parse_catalog(value: Value) -> Result<[RuntimeEngineState; 4], ()> {
    if value["schema_version"] != 1 {
        return Err(());
    }
    let rows = value["engines"].as_array().ok_or(())?;
    let mut entries = Vec::with_capacity(4);
    for product in RuntimeProduct::ALL {
        let matches: Vec<_> = rows
            .iter()
            .filter(|row| row["id"].as_str() == Some(product.engine_id()))
            .collect();
        if matches.len() != 1 {
            return Err(());
        }
        let row = matches[0];
        let installation = &row["installation"];
        let version = match &installation["version"] {
            Value::Null => None,
            Value::String(version)
                if version.len() <= 128 && !version.chars().any(char::is_control) =>
            {
                Some(version.clone())
            }
            _ => return Err(()),
        };
        let integrity = match installation["integrity"].as_str() {
            Some("verified") => EngineIntegrity::Verified,
            Some("unverified") => EngineIntegrity::Unverified,
            Some("unknown") => EngineIntegrity::Unknown,
            _ => return Err(()),
        };
        let download_supported = installation["download_supported"].as_bool().ok_or(())?;
        let download_error = match &installation["error"] {
            Value::Null => false,
            Value::String(code) if !code.is_empty() && code.len() <= 128 => true,
            _ => return Err(()),
        };
        if integrity != EngineIntegrity::Verified && version.is_some() {
            return Err(());
        }
        let state = match installation["state"].as_str() {
            Some("not_installed") => EngineInstallation::NotInstalled,
            Some("installing") => {
                let progress = match &installation["progress"] {
                    Value::Null => None,
                    value => Some(
                        value
                            .as_u64()
                            .filter(|progress| *progress <= 100)
                            .ok_or(())? as u8,
                    ),
                };
                EngineInstallation::Installing { progress }
            }
            Some("downloaded") => EngineInstallation::Downloaded { version },
            Some("installed") if integrity == EngineIntegrity::Verified => {
                EngineInstallation::Installed { version }
            }
            Some("unavailable") if !download_supported => EngineInstallation::Unavailable {
                reason: "download_unavailable".into(),
            },
            _ => return Err(()),
        };
        // No CLI assistant adapter exists yet. A changed native capability
        // cannot silently turn a product download into Pi or provider routing.
        if row["execution"]["state"] != "unavailable" {
            return Err(());
        }
        let authentication = if row["authentication"].is_null() {
            AuthenticationCapabilities::default()
        } else {
            let auth = &row["authentication"];
            AuthenticationCapabilities {
                supported: auth["supported"].as_bool().ok_or(())?,
                source_selection: auth["source_selection"].as_bool().ok_or(())?,
                authorization_browser: auth["authorization_browser"].as_bool().ok_or(())?,
                native_code_entry: auth["native_code_entry"].as_bool().ok_or(())?,
                provider_selection: auth["provider_selection"].as_bool().ok_or(())?,
            }
        };
        if !authentication.supported
            && (authentication.source_selection
                || authentication.authorization_browser
                || authentication.native_code_entry
                || authentication.provider_selection)
        {
            return Err(());
        }
        entries.push(RuntimeEngineState {
            product,
            installation: state,
            integrity,
            download_supported,
            download_error,
            execution: EngineExecution::Unavailable,
            authentication,
        });
    }
    entries.try_into().map_err(|_| ())
}

impl RuntimeEngineState {
    fn can_download(&self) -> bool {
        self.download_supported
            && (self.installation == EngineInstallation::NotInstalled
                || (matches!(self.installation, EngineInstallation::Downloaded { .. })
                    && self.integrity != EngineIntegrity::Verified))
    }
    fn installation_label(&self, locale: Locale) -> String {
        if self.download_error {
            return copy(locale, "Download failed", "下载失败").into();
        }
        if matches!(self.installation, EngineInstallation::Installed { .. })
            && self.integrity != EngineIntegrity::Verified
        {
            return copy(locale, "Downloaded, not verified", "已下载，未验证").into();
        }
        match &self.installation {
            EngineInstallation::Unknown => copy(locale, "Not checked", "尚未检查").into(),
            EngineInstallation::NotInstalled => copy(locale, "Not installed", "未安装").into(),
            EngineInstallation::Installing {
                progress: Some(progress),
            } => format!("{} {progress}%", copy(locale, "Downloading", "正在下载")),
            EngineInstallation::Installing { progress: None } => {
                copy(locale, "Downloading", "正在下载").into()
            }
            EngineInstallation::Downloaded { version } => {
                if self.integrity == EngineIntegrity::Verified {
                    let label = copy(locale, "Downloaded", "已下载");
                    version
                        .as_ref()
                        .map(|version| format!("{label} · {version}"))
                        .unwrap_or_else(|| label.into())
                } else {
                    copy(locale, "Downloaded, not verified", "已下载，未验证").into()
                }
            }
            EngineInstallation::Installed {
                version: Some(version),
            } => format!("{} · {version}", copy(locale, "Installed", "已安装")),
            EngineInstallation::Installed { version: None } => {
                copy(locale, "Installed", "已安装").into()
            }
            EngineInstallation::Unavailable { .. } => {
                copy(locale, "Download unavailable", "暂无下载").into()
            }
        }
    }
}

impl RuntimeEnginesUi {
    fn prepare_request(
        &mut self,
        install: Option<RuntimeProduct>,
        user_initiated: bool,
    ) -> Option<(EngineRequest, RuntimeCommand)> {
        if self.request.is_some() {
            return None;
        }
        if let Some(product) = install {
            if !user_initiated
                || self.error.is_some()
                || !self
                    .entries
                    .iter()
                    .any(|entry| entry.product == product && entry.can_download())
            {
                return None;
            }
        }
        let request = EngineRequest {
            token: uuid::Uuid::new_v4().to_string(),
            install,
        };
        let command = match install {
            Some(product) => RuntimeCommand::new(
                "ShellRuntimeEngines",
                "install",
                vec![
                    json!({"schema_version":1,"engine_id":product.engine_id(),"userInitiated":true}),
                ],
            ),
            None => RuntimeCommand::new("ShellRuntimeEngines", "catalog", vec![]),
        };
        self.request = Some(request.clone());
        self.loading = true;
        self.error = None;
        self.poll_generation = self.poll_generation.wrapping_add(1);
        Some((request, command))
    }
    fn install_pending(&self, product: RuntimeProduct) -> bool {
        self.request
            .as_ref()
            .is_some_and(|request| request.install == Some(product))
    }
    fn accept_result(
        &mut self,
        request: &EngineRequest,
        result: Result<Value, String>,
        locale: Locale,
    ) -> bool {
        if self.request.as_ref().map(|current| &current.token) != Some(&request.token) {
            return false;
        }
        self.request = None;
        self.loading = false;
        match result.map_err(|_| ()).and_then(parse_catalog) {
            Ok(entries) => {
                self.entries = entries;
                self.error = None;
            }
            Err(()) => {
                self.error = Some(copy(locale,
                    "Couldn't refresh the engine status. Refresh to check the download before retrying.",
                    "暂时无法更新引擎状态。请刷新并核对下载结果后重试。",
                ).into());
            }
        }
        true
    }
}

impl Shell {
    pub(super) fn runtime_catalog_visible(&self) -> bool {
        self.page == Page::Settings
            && self.settings_expanded == Some(settings::PreferenceGroup::Runtime)
    }
    pub(super) fn refresh_runtime_engines(&mut self, cx: &mut Context<Self>) {
        self.request_runtime_engines(None, false, cx);
    }
    fn request_runtime_engines(
        &mut self,
        install: Option<RuntimeProduct>,
        user_initiated: bool,
        cx: &mut Context<Self>,
    ) {
        if !self.runtime.is_native()
            || !self.runtime_catalog_visible()
            || self.runtime_engines.request.is_some()
        {
            return;
        }
        let Some((request, command)) = self
            .runtime_engines
            .prepare_request(install, user_initiated)
        else {
            return;
        };
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this
                    .runtime_engines
                    .accept_result(&request, result, this.locale)
                {
                    this.poll_runtime_engines(cx);
                    this.refresh_visible_subscription(cx);
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }
    fn poll_runtime_engines(&mut self, cx: &mut Context<Self>) {
        if !self.runtime_engine_poll_needed() {
            return;
        }
        let generation = self.runtime_engines.poll_generation;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            let _ = this.update(cx, |this, cx| {
                if this.runtime_engines.poll_generation == generation
                    && this.runtime_engine_poll_needed()
                {
                    this.refresh_runtime_engines(cx);
                }
            });
        })
        .detach();
    }
    fn runtime_engine_poll_needed(&self) -> bool {
        self.runtime_catalog_visible()
            && self.runtime_engines.error.is_none()
            && self.runtime_engines.request.is_none()
            && self
                .runtime_engines
                .entries
                .iter()
                .any(|entry| matches!(entry.installation, EngineInstallation::Installing { .. }))
    }
    pub(super) fn settings_runtime_product_row(
        &self,
        entry: &RuntimeEngineState,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let theme = cx
            .try_global::<theme::ThemeState>()
            .copied()
            .unwrap_or_default();
        let dark = theme.mode == theme::ThemeMode::Dark
            || (theme.mode == theme::ThemeMode::System && theme.system_dark);
        let id = entry.product.settings_selector();
        let installation = if self.runtime_engines.install_pending(entry.product) {
            copy(self.locale, "Starting download", "正在开始下载").into()
        } else if self.runtime_engines.loading && entry.installation == EngineInstallation::Unknown
        {
            copy(self.locale, "Checking", "正在检查").into()
        } else {
            entry.installation_label(self.locale)
        };
        let product = entry.product;
        let execution = match entry.execution {
            EngineExecution::Unavailable => copy(self.locale, "Tasks unavailable", "暂不可运行"),
        };
        let download = entry.can_download();
        let enabled = self.runtime.is_native()
            && self.runtime_engines.request.is_none()
            && self.runtime_engines.error.is_none();
        let trailing = if download {
            let selector = product.download_selector();
            div()
                .id(selector)
                .debug_selector(move || selector.into())
                .role(gpui::Role::Button)
                .aria_label(format!(
                    "{} {}",
                    copy(self.locale, "Download", "下载"),
                    product.label()
                ))
                .min_h(px(44.))
                .min_w(px(68.))
                .flex_shrink_0()
                .px_2()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(12.))
                .bg(p.surface)
                .text_color(if enabled { p.text } else { p.muted })
                .text_size(px(13.))
                .child(copy(self.locale, "Download", "下载"))
                .when(enabled, |button| button.cursor_pointer())
                .on_click(cx.listener(move |this, _, _, cx| {
                    cx.stop_propagation();
                    this.request_runtime_engines(Some(product), true, cx)
                }))
                .into_any_element()
        } else {
            div()
                .max_w(px(100.))
                .text_right()
                .text_size(px(12.))
                .text_color(p.muted)
                .whitespace_normal()
                .child(installation)
                .into_any_element()
        };
        let row = div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(format!(
                "{} · {}",
                entry.product.label(),
                self.subscription_row_label(entry.product)
            ))
            .min_h(px(64.))
            .px_4()
            .py_2()
            .flex()
            .items_center()
            .gap_3()
            .cursor_pointer()
            .hover(|row| row.bg(p.surface))
            .child(entry.product.logo(30., dark))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_size(px(15.))
                            .text_color(p.text)
                            .child(entry.product.label()),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .whitespace_normal()
                            .child(if entry.authentication.supported {
                                self.subscription_row_label(product)
                            } else {
                                execution
                            }),
                    ),
            )
            .child(trailing)
            .on_click(
                cx.listener(move |this, _, _, cx| this.toggle_runtime_subscription(product, cx)),
            );
        div()
            .flex()
            .flex_col()
            .child(row)
            .when(
                self.runtime_subscriptions.expanded == Some(product),
                |container| container.child(self.settings_subscription_detail(product, cx)),
            )
            .into_any_element()
    }
    pub(super) fn runtime_engines_status(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let mut content = div().flex().flex_col().gap_2();
        if let Some(error) = &self.runtime_engines.error {
            content = content.child(
                div()
                    .px_1()
                    .text_size(px(12.))
                    .line_height(px(19.))
                    .text_color(p.danger)
                    .whitespace_normal()
                    .child(error.clone()),
            );
        }
        if self.runtime.is_native()
            && (self.runtime_engines.error.is_some()
                || self
                    .runtime_engines
                    .entries
                    .iter()
                    .any(|entry| entry.installation == EngineInstallation::Unknown))
        {
            content = content.child(
                div()
                    .id("settings-runtime-refresh")
                    .debug_selector(|| "settings-runtime-refresh".into())
                    .role(gpui::Role::Button)
                    .aria_label(copy(self.locale, "Refresh engine status", "刷新引擎状态"))
                    .min_h(px(44.))
                    .px_4()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(12.))
                    .bg(p.surface)
                    .text_size(px(13.))
                    .child(copy(self.locale, "Refresh engine status", "刷新引擎状态"))
                    .when(self.runtime_engines.request.is_none(), |button| {
                        button.cursor_pointer()
                    })
                    .on_click(cx.listener(|this, _, _, cx| this.refresh_runtime_engines(cx))),
            );
        }
        content.into_any_element()
    }
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "settings_runtime_engines_tests.rs"]
mod tests;
