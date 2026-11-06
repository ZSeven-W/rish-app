use super::*;
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};

impl Shell {
    pub(in crate::ui) fn render_custom_provider_rows(
        &self,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let mut rows = vec![
            super::super::settings::separator(p).into_any_element(),
            self.custom_control(
                "settings-add-custom-provider",
                copy(self.locale, "Add custom provider", "添加自定义服务商"),
                String::new(),
                false,
                self.custom_provider_idle() && self.custom_providers.editor.is_none(),
                Action::Add,
                cx,
            ),
        ];
        for provider in self.custom_providers.providers() {
            let id = provider["id"].as_str().unwrap();
            let name = provider["configuration"]["name"].as_str().unwrap();
            rows.push(super::super::settings::separator(p).into_any_element());
            rows.push(self.custom_control(
                &format!("settings-custom-provider-{id}"),
                name,
                self.custom_providers.phase(id).label(self.locale).into(),
                false,
                self.custom_provider_idle() && self.custom_providers.editor.is_none(),
                Action::Edit(id.into()),
                cx,
            ));
        }
        if let Some(error) = self.custom_providers.error {
            rows.push(
                div()
                    .px_4()
                    .py_3()
                    .text_size(px(12.))
                    .line_height(px(19.))
                    .text_color(p.danger)
                    .whitespace_normal()
                    .child(error)
                    .into_any_element(),
            );
        }
        if self.custom_providers.needs_reload || !self.custom_providers.loaded {
            rows.push(self.custom_control(
                "settings-custom-provider-reload",
                copy(self.locale, "Reload providers", "重新加载服务商"),
                String::new(),
                false,
                self.runtime.is_native() && self.custom_provider_idle(),
                Action::Reload,
                cx,
            ));
        }
        if let Some(editor) = &self.custom_providers.editor {
            rows.push(self.custom_provider_editor(editor, p, cx));
        }
        rows
    }
    pub(super) fn custom_control(
        &self,
        id: &str,
        label: &str,
        detail: String,
        selected: bool,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let selector = id.to_owned();
        div()
            .id(id.to_owned())
            .debug_selector(move || selector.clone())
            .role(gpui::Role::Button)
            .aria_label(if detail.is_empty() {
                label.into()
            } else {
                format!("{label}: {detail}")
            })
            .min_h(px(52.))
            .w_full()
            .flex_shrink_0()
            .px_4()
            .py_3()
            .flex()
            .items_center()
            .gap_3()
            .when(enabled, |row| {
                row.cursor_pointer().hover(|s| s.bg(p.surface))
            })
            .when(!enabled, |row| row.opacity(0.55))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_size(px(14.))
                            .text_color(p.text)
                            .whitespace_normal()
                            .child(label.to_owned()),
                    )
                    .when(!detail.is_empty(), |column| {
                        column.child(
                            div()
                                .text_size(px(11.))
                                .text_color(p.muted)
                                .truncate()
                                .child(detail),
                        )
                    }),
            )
            .child(icon(
                if selected {
                    Icon::Check
                } else {
                    Icon::ChevronRight
                },
                16.,
                if selected { p.accent } else { p.faint },
            ))
            .on_click(cx.listener(move |this, _, _, cx| {
                if enabled {
                    this.custom_provider_action(action.clone(), cx);
                }
            }))
            .into_any_element()
    }
    fn custom_provider_editor(
        &self,
        editor: &ProviderEditor,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let idle = self.custom_provider_idle();
        let input = idle && self.runtime.is_native();
        let write = self.custom_provider_write_enabled();
        let mut form = div()
            .id("settings-custom-provider-editor")
            .debug_selector(|| "settings-custom-provider-editor".into())
            .m_3()
            .min_w(px(0.))
            .flex()
            .flex_col()
            .rounded(px(16.))
            .border_1()
            .border_color(p.line)
            .overflow_hidden()
            .child(
                div()
                    .px_4()
                    .pt_4()
                    .pb_2()
                    .text_size(px(15.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(p.text)
                    .child(if editor.baseline.is_some() {
                        copy(self.locale, "Edit provider", "编辑服务商")
                    } else {
                        copy(self.locale, "New provider", "新服务商")
                    }),
            )
            .child(self.custom_control(
                "custom-provider-name",
                copy(self.locale, "Name", "名称"),
                if editor.name.is_empty() {
                    copy(self.locale, "Required", "必填").into()
                } else {
                    editor.name.clone()
                },
                false,
                input,
                Action::Field(Field::Name),
                cx,
            ))
            .child(self.custom_control(
                "custom-provider-url",
                "API URL",
                if editor.endpoint.is_empty() {
                    "https://api.example.com/v1".into()
                } else {
                    editor.endpoint.clone()
                },
                false,
                input,
                Action::Field(Field::Endpoint),
                cx,
            ))
            .child(
                self.custom_control(
                    "custom-provider-full-url",
                    copy(
                        self.locale,
                        "URL is a complete endpoint",
                        "URL 为完整请求地址",
                    ),
                    if editor.full_url {
                        copy(self.locale, "Use this path exactly", "直接使用此路径")
                    } else {
                        copy(
                            self.locale,
                            "Append the selected protocol path to the base URL",
                            "在基础 URL 后追加所选协议路径",
                        )
                    }
                    .into(),
                    editor.full_url,
                    idle,
                    Action::FullUrl,
                    cx,
                ),
            )
            .child(self.custom_form_label(copy(self.locale, "Protocol", "协议"), p));
        for (id, label, value) in [
            (
                "custom-protocol-chat",
                "Chat Completions",
                "chat-completions",
            ),
            ("custom-protocol-responses", "Responses", "responses"),
            ("custom-protocol-messages", "Anthropic Messages", "messages"),
        ] {
            form = form.child(self.custom_control(
                id,
                label,
                String::new(),
                editor.protocol == value,
                idle,
                Action::Protocol(value),
                cx,
            ));
        }
        form =
            form.child(self.custom_form_label(copy(self.locale, "Authentication", "鉴权方式"), p));
        for (id, label, value) in [
            ("custom-auth-bearer", "Bearer", "bearer"),
            ("custom-auth-x-api-key", "X-API-Key", "x-api-key"),
            ("custom-auth-api-key", "API-Key", "api-key"),
            (
                "custom-auth-none",
                copy(self.locale, "No authentication", "无需鉴权"),
                "none",
            ),
        ] {
            form = form.child(self.custom_control(
                id,
                label,
                String::new(),
                editor.auth == value,
                idle,
                Action::Auth(value),
                cx,
            ));
        }
        form = form
            .child(self.custom_form_label(copy(self.locale, "Models", "模型"), p))
            .child(
                self.custom_control(
                    "custom-provider-models",
                    copy(self.locale, "Edit model IDs", "编辑模型 ID"),
                    copy(
                        self.locale,
                        "One per line · optional: ID | display name",
                        "每行一个 · 可选：ID | 显示名称",
                    )
                    .into(),
                    false,
                    input,
                    Action::Field(Field::Models),
                    cx,
                ),
            );
        form = form.child(self.custom_discovery_view(editor, p, cx));
        for model in &editor.models {
            let id = model["id"].as_str().unwrap();
            let name = model["name"].as_str().unwrap();
            form = form.child(self.custom_control(
                &format!("custom-model-images-{id}"),
                name,
                format!(
                    "{} · {}",
                    model["wire_model"].as_str().unwrap(),
                    if model["supports_images"] == true {
                        copy(self.locale, "Image input enabled", "已启用图片输入")
                    } else {
                        copy(
                            self.locale,
                            "Text only · tap to enable images",
                            "仅文本 · 点击启用图片",
                        )
                    }
                ),
                model["supports_images"] == true,
                idle,
                Action::Images(id.into()),
                cx,
            ));
        }
        form = form.child(
            self.custom_control(
                "custom-provider-reasoning",
                copy(self.locale, "Send reasoning options", "发送思考参数"),
                copy(
                    self.locale,
                    "Enable only if this API supports them",
                    "仅在此 API 支持时启用",
                )
                .into(),
                editor.send_reasoning,
                idle,
                Action::Reasoning,
                cx,
            ),
        );
        if let Some(error) = editor.error {
            form = form.child(
                div()
                    .px_4()
                    .py_3()
                    .text_size(px(12.))
                    .line_height(px(19.))
                    .text_color(p.danger)
                    .whitespace_normal()
                    .child(error),
            );
        }
        if editor.baseline.is_some() {
            form = form.child(self.custom_form_label(
                self.custom_providers.phase(&editor.id).label(self.locale),
                p,
            ));
            if editor.auth != "none" {
                form = form
                    .child(
                        self.custom_control(
                            "custom-provider-set-key",
                            copy(self.locale, "Set or replace key", "设置或更换密钥"),
                            copy(
                                self.locale,
                                "Entered only in the device’s secure prompt",
                                "仅在设备安全窗口中输入",
                            )
                            .into(),
                            false,
                            write,
                            Action::SetKey,
                            cx,
                        ),
                    )
                    .child(self.custom_control(
                        "custom-provider-clear-key",
                        copy(self.locale, "Clear saved key", "清除已保存密钥"),
                        String::new(),
                        false,
                        write,
                        Action::ClearKey,
                        cx,
                    ));
            }
        }
        form = form.child(self.custom_control(
            "custom-provider-save",
            copy(self.locale, "Save provider", "保存服务商"),
            String::new(),
            false,
            write,
            Action::Save(false),
            cx,
        ));
        if editor.auth != "none" {
            form = form.child(self.custom_control(
                "custom-provider-save-key",
                copy(self.locale, "Save and set key", "保存并设置密钥"),
                String::new(),
                false,
                write,
                Action::Save(true),
                cx,
            ));
        }
        if editor.baseline.is_some() {
            form = form.child(
                self.custom_control(
                    "custom-provider-remove",
                    copy(self.locale, "Remove provider", "移除服务商"),
                    copy(
                        self.locale,
                        "History is kept; its models become unavailable",
                        "保留历史记录，其模型将不可用",
                    )
                    .into(),
                    false,
                    write,
                    Action::Remove,
                    cx,
                ),
            );
            if editor.remove_confirm {
                form = form.child(self.custom_control(
                    "custom-provider-confirm-remove",
                    copy(self.locale, "Confirm removal", "确认移除"),
                    editor.name.clone(),
                    false,
                    write,
                    Action::ConfirmRemove,
                    cx,
                ));
            }
        }
        form = form.child(self.custom_control(
            "custom-provider-cancel",
            copy(self.locale, "Close editor", "关闭编辑"),
            String::new(),
            false,
            idle,
            Action::Cancel,
            cx,
        ));
        if !idle {
            form = form.child(
                div()
                    .px_4()
                    .py_3()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .child(copy(self.locale, "Waiting for device…", "正在等待设备…")),
            );
        }
        form.into_any_element()
    }
    fn custom_form_label(&self, label: &str, p: Palette) -> AnyElement {
        div()
            .px_4()
            .pt_3()
            .pb_1()
            .min_w(px(0.))
            .whitespace_normal()
            .text_size(px(11.))
            .line_height(px(18.))
            .font_weight(FontWeight::MEDIUM)
            .text_color(p.muted)
            .child(label.to_owned())
            .into_any_element()
    }
}
