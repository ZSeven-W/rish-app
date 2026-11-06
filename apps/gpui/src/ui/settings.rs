use super::*;
use crate::icons::{Icon, icon};
use gpui::{Div, FontWeight};
use serde_json::json;

const TWO_COLUMN_WIDTH: f32 = 760.;

#[path = "settings_models.rs"]
mod models;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum PreferenceGroup {
    Models,
    Accounts,
    Runtime,
    Appearance,
    Language,
}

pub(super) fn section_title(label: &'static str, p: Palette) -> Div {
    div()
        .px_1()
        .text_size(px(13.))
        .font_weight(FontWeight::MEDIUM)
        .text_color(p.muted)
        .child(label)
}
pub(super) fn group(p: Palette) -> Div {
    div()
        .w_full()
        .flex_shrink_0()
        .rounded(px(22.))
        .border_1()
        .border_color(p.line.opacity(0.6))
        .bg(p.composer)
        .overflow_hidden()
}
pub(super) fn separator(p: Palette) -> Div {
    div().h(px(1.)).ml(px(48.)).mr_4().bg(p.line.opacity(0.6))
}

impl Shell {
    pub fn settings_screen(&self, content_width: f32, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let two_columns = content_width >= TWO_COLUMN_WIDTH;
        let gutter = if two_columns { 24. } else { 20. };
        div()
            .id("settings-content")
            .debug_selector(|| "settings-content".into())
            .w_full()
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll()
            .px(px(gutter))
            .pt_3()
            .pb_8()
            .child(
                div()
                    .w_full()
                    .max_w(px(1080.))
                    .mx_auto()
                    .flex()
                    .flex_col()
                    .gap_6()
                    .child(self.settings_identity(p, cx))
                    .child(
                        div()
                            .id("settings-columns")
                            .debug_selector(|| "settings-columns".into())
                            .w_full()
                            .flex()
                            .items_start()
                            .gap(px(if two_columns { 24. } else { 28. }))
                            .when(!two_columns, |content| content.flex_col())
                            .child(self.settings_accounts(two_columns, p, cx))
                            .child(self.settings_preferences(two_columns, p, cx)),
                    ),
            )
    }

    fn settings_identity(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let store = self.assistant.snapshot.store.as_ref();
        let name = store
            .map(|store| store.profile.name.as_str())
            .unwrap_or("Rish");
        let status = if store.is_some() {
            assistant_copy::runner(self.locale, &self.assistant.snapshot.status)
        } else if !self.runtime.is_native() {
            assistant_copy::copy(self.locale, "Interface preview", "界面预览")
        } else if self.assistant.error.is_some() {
            assistant_copy::copy(self.locale, "Not ready", "暂未就绪")
        } else {
            assistant_copy::copy(self.locale, "Preparing", "正在准备")
        };
        let status_color = if store.is_none() {
            p.faint
        } else {
            match self.assistant.snapshot.status {
                crate::assistant_runtime::RunnerStatus::NeedsAttention => p.danger,
                crate::assistant_runtime::RunnerStatus::Running => p.success,
                _ => p.info,
            }
        };
        group(p)
            .id("settings-identity")
            .debug_selector(|| "settings-identity".into())
            .role(gpui::Role::Button)
            .aria_label(assistant_copy::copy(
                self.locale,
                "Open local assistant",
                "打开本机助手",
            ))
            .min_h(px(84.))
            .p_4()
            .flex()
            .items_center()
            .gap_3()
            .cursor_pointer()
            .hover(|s| s.bg(p.surface))
            .child(self.assistant_avatar_button("settings-profile-avatar", 46., cx))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .truncate()
                            .text_size(px(17.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.text)
                            .child(name.to_owned()),
                    )
                    .child(
                        div()
                            .debug_selector(|| "settings-identity-status".into())
                            .flex()
                            .items_center()
                            .gap_1()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .child(
                                div()
                                    .debug_selector(|| "settings-status-dot".into())
                                    .size(px(6.))
                                    .flex_shrink_0()
                                    .rounded_full()
                                    .bg(status_color),
                            )
                            .child(status),
                    ),
            )
            .child(icon(Icon::ChevronRight, 16., p.faint))
            .on_click(cx.listener(|this, _, _, cx| this.navigate(Page::Assistant, cx)))
    }

    fn settings_accounts(
        &self,
        two_columns: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id("settings-accounts")
            .debug_selector(|| "settings-accounts".into())
            .min_w(px(0.))
            .when(two_columns, |column| column.flex_1())
            .when(!two_columns, |column| column.w_full())
            .flex()
            .flex_col()
            .gap_6()
            .child(self.settings_model_section(p, cx))
            .child(self.settings_account_section(p, cx))
    }

    fn settings_account_section(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let expanded = self.settings_expanded == Some(PreferenceGroup::Accounts);
        let mut accounts = group(p)
            .id("settings-accounts-card")
            .debug_selector(|| "settings-accounts-card".into())
            .child(self.preference_row(
                "settings-account-access",
                PreferenceGroup::Accounts,
                Icon::Settings2,
                assistant_copy::copy(self.locale, "API providers", "API 服务商"),
                "API Key".into(),
                cx,
            ));
        for provider in crate::providers::ApiProvider::ALL
            .into_iter()
            .filter(|_| expanded)
        {
            let name = provider.label();
            let slot = provider.credential_slot();
            let harness = provider_models::provider_harness(provider);
            let enabled = !self.native_form_active;
            let model_count = self.provider_models.model_count(harness);
            accounts = accounts.child(separator(p));
            accounts = accounts.child(
                div()
                    .id(slot)
                    .debug_selector(move || slot.into())
                    .role(gpui::Role::Button)
                    .aria_label(format!("{} {}", name, self.locale.text(Text::Configure)))
                    .min_h(px(60.))
                    .px_4()
                    .py_2()
                    .flex()
                    .items_center()
                    .gap_3()
                    .when(enabled, |row| {
                        row.cursor_pointer().hover(|s| s.bg(p.surface))
                    })
                    .child(icon(Icon::Globe, 20., p.muted))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .truncate()
                            .text_size(px(15.))
                            .text_color(p.text)
                            .child(name),
                    )
                    .child(div().text_size(px(12.)).text_color(p.muted).child(
                        if model_count == 0 {
                            self.locale.text(Text::Configure).to_owned()
                        } else if self.locale == Locale::Zh {
                            format!("{model_count} 个模型")
                        } else {
                            format!("{model_count} models")
                        },
                    ))
                    .child(icon(Icon::ChevronRight, 16., p.faint))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if enabled {
                            this.open_provider_models(harness, cx);
                        }
                    })),
            );
        }
        if expanded {
            if let Some(editor) = self.provider_models_editor(cx) {
                accounts = accounts.child(editor);
            }
            accounts = accounts.children(self.render_custom_provider_rows(p, cx));
        }
        div()
            .id("settings-provider-accounts")
            .debug_selector(|| "settings-provider-accounts".into())
            .w_full()
            .flex()
            .flex_col()
            .gap_3()
            .child(section_title(
                assistant_copy::copy(self.locale, "Accounts & API", "账号与 API"),
                p,
            ))
            .child(accounts)
            .when(expanded, |column| {
                column.child(
                    div()
                        .px_1()
                        .text_size(px(12.))
                        .line_height(px(19.))
                        .text_color(p.muted)
                        .whitespace_normal()
                        .child(assistant_copy::copy(
                            self.locale,
                            "Credentials stay in your device’s secure storage.",
                            "凭据保存在设备的安全存储中。",
                        )),
                )
            })
    }

    fn settings_preferences(
        &self,
        two_columns: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let appearance_open = self.settings_expanded == Some(PreferenceGroup::Appearance);
        let language_open = self.settings_expanded == Some(PreferenceGroup::Language);
        let mode = cx
            .try_global::<theme::ThemeState>()
            .map(|t| t.mode)
            .unwrap_or(theme::ThemeMode::Light);
        let appearance = self.locale.text(match mode {
            theme::ThemeMode::Light => Text::Light,
            theme::ThemeMode::Dark => Text::Dark,
            theme::ThemeMode::System => Text::System,
        });
        div()
            .id("settings-preferences")
            .debug_selector(|| "settings-preferences".into())
            .min_w(px(0.))
            .when(two_columns, |column| column.flex_1())
            .when(!two_columns, |column| column.w_full())
            .flex()
            .flex_col()
            .gap_6()
            .child(self.settings_runtime_section(p, cx))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(section_title(
                        assistant_copy::copy(self.locale, "Appearance & language", "外观与语言"),
                        p,
                    ))
                    .child(
                        group(p)
                            .id("settings-preferences-card")
                            .debug_selector(|| "settings-preferences-card".into())
                            .child(self.preference_row(
                                "settings-appearance",
                                PreferenceGroup::Appearance,
                                Icon::Sun,
                                self.locale.text(Text::Appearance),
                                appearance.to_owned(),
                                cx,
                            ))
                            .when(appearance_open, |card| {
                                card.child(
                                    div()
                                        .id("settings-appearance-card")
                                        .debug_selector(|| "settings-appearance-card".into())
                                        .px_3()
                                        .pb_3()
                                        .flex()
                                        .gap_1()
                                        .child(self.theme_button(
                                            "theme-light",
                                            theme::ThemeMode::Light,
                                            Text::Light,
                                            cx,
                                        ))
                                        .child(self.theme_button(
                                            "theme-dark",
                                            theme::ThemeMode::Dark,
                                            Text::Dark,
                                            cx,
                                        ))
                                        .child(self.theme_button(
                                            "theme-system",
                                            theme::ThemeMode::System,
                                            Text::System,
                                            cx,
                                        )),
                                )
                            })
                            .child(separator(p))
                            .child(
                                self.preference_row(
                                    "settings-language",
                                    PreferenceGroup::Language,
                                    Icon::Globe,
                                    self.locale.text(Text::Language),
                                    self.locale
                                        .text(if self.locale == Locale::Zh {
                                            Text::Chinese
                                        } else {
                                            Text::English
                                        })
                                        .to_owned(),
                                    cx,
                                ),
                            )
                            .when(language_open, |card| {
                                card.child(
                                    div()
                                        .id("settings-language-card")
                                        .debug_selector(|| "settings-language-card".into())
                                        .px_3()
                                        .pb_3()
                                        .flex()
                                        .gap_1()
                                        .child(self.language_button(
                                            "language-zh",
                                            Locale::Zh,
                                            Text::Chinese,
                                            cx,
                                        ))
                                        .child(self.language_button(
                                            "language-en",
                                            Locale::En,
                                            Text::English,
                                            cx,
                                        )),
                                )
                            }),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(section_title(
                        assistant_copy::copy(self.locale, "App settings", "应用设置"),
                        p,
                    ))
                    .child(self.assistant_platform_bar(cx)),
            )
    }

    pub(super) fn preference_row(
        &self,
        id: &'static str,
        group: PreferenceGroup,
        glyph: Icon,
        label: &'static str,
        value: String,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let expanded = self.settings_expanded == Some(group);
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(format!("{label}: {value}"))
            .min_h(px(58.))
            .px_4()
            .py_3()
            .flex()
            .items_center()
            .gap_3()
            .cursor_pointer()
            .hover(|s| s.bg(p.surface))
            .child(icon(glyph, 18., p.text))
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(15.))
                    .text_color(p.text)
                    .child(label),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .text_right()
                    .text_size(px(13.))
                    .text_color(p.muted)
                    .child(value),
            )
            .child(icon(
                if expanded {
                    Icon::ChevronDown
                } else {
                    Icon::ChevronRight
                },
                16.,
                p.faint,
            ))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.settings_expanded = if this.settings_expanded == Some(group) {
                    None
                } else {
                    Some(group)
                };
                if group == PreferenceGroup::Accounts && this.settings_expanded == Some(group) {
                    if this.custom_providers.loaded {
                        this.refresh_custom_provider_statuses(cx);
                    } else {
                        this.reload_custom_providers(cx);
                    }
                }
                if group == PreferenceGroup::Runtime && this.settings_expanded == Some(group) {
                    this.refresh_runtime_engines(cx);
                }
                cx.notify();
            }))
    }

    fn theme_button(
        &self,
        id: &'static str,
        mode: theme::ThemeMode,
        label: Text,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let selected = cx
            .try_global::<theme::ThemeState>()
            .map(|t| t.mode == mode)
            .unwrap_or(false);
        let enabled = !self.loading && !self.state.is_busy() && !self.assistant_writer_lease;
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::RadioButton)
            .aria_label(self.locale.text(label))
            .aria_toggled(if selected {
                gpui::Toggled::True
            } else {
                gpui::Toggled::False
            })
            .flex_1()
            .min_w(px(0.))
            .min_h(px(44.))
            .px_1()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(12.))
            .when(selected, |button| {
                button.bg(p.surface).font_weight(FontWeight::MEDIUM)
            })
            .when(enabled, |button| button.cursor_pointer())
            .when(!enabled, |button| button.opacity(0.5))
            .text_size(px(13.))
            .text_color(if selected { p.text } else { p.muted })
            .child(self.locale.text(label))
            .on_click(cx.listener(move |this, _, _, cx| {
                if this.loading || this.state.is_busy() || this.assistant_writer_lease {
                    return;
                }
                if this.state.is_loaded() {
                    let command = this.state.set_preference("theme_mode", json!(mode.code()));
                    this.commit(command, cx);
                } else {
                    theme::set_mode(mode, cx);
                    cx.notify();
                }
            }))
    }

    fn language_button(
        &self,
        id: &'static str,
        locale: Locale,
        label: Text,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let selected = self.locale == locale;
        let enabled = !self.loading && !self.state.is_busy() && !self.assistant_writer_lease;
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::RadioButton)
            .aria_label(self.locale.text(label))
            .aria_toggled(if selected {
                gpui::Toggled::True
            } else {
                gpui::Toggled::False
            })
            .flex_1()
            .min_w(px(0.))
            .min_h(px(44.))
            .px_1()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(12.))
            .when(selected, |button| {
                button.bg(p.surface).font_weight(FontWeight::MEDIUM)
            })
            .when(enabled, |button| button.cursor_pointer())
            .when(!enabled, |button| button.opacity(0.5))
            .text_size(px(14.))
            .text_color(if selected { p.text } else { p.muted })
            .child(self.locale.text(label))
            .on_click(cx.listener(move |this, _, _, cx| {
                if this.loading || this.state.is_busy() || this.assistant_writer_lease {
                    return;
                }
                if this.state.is_loaded() {
                    let command = this.state.set_preference("locale", json!(locale.code()));
                    this.commit(command, cx);
                } else {
                    this.locale = locale;
                    this.update_placeholders(cx);
                    this.sync_transcript(cx);
                    cx.notify();
                }
            }))
    }
}
