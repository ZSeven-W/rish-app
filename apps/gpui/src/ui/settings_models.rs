//! The default for new conversations comes from the model catalog. Account
//! credentials and execution engines are deliberately different settings.
use super::*;
use gpui::AnyElement;
use rish_shell_core::Model;

impl Shell {
    pub(super) fn settings_model_section(&self, p: Palette, cx: &mut Context<Self>) -> AnyElement {
        let expanded = self.settings_expanded == Some(PreferenceGroup::Models);
        let selected = self.settings_default_model_id();
        let catalog = self.state.models();
        let name = if catalog.iter().any(|model| model.id == selected) {
            self.model_display_label(selected)
        } else {
            assistant_copy::copy(self.locale, "Choose a model", "选择模型").into()
        };
        let mut card = group(p)
            .id("settings-models-card")
            .debug_selector(|| "settings-models-card".into())
            .child(self.preference_row(
                "settings-model",
                PreferenceGroup::Models,
                Icon::Box,
                assistant_copy::copy(self.locale, "Default model", "默认模型"),
                name,
                cx,
            ));
        card = card
            .child(separator(p))
            .child(self.model_setup_entry("settings-add-model", cx));
        if expanded {
            if catalog.is_empty() {
                card = card.child(self.model_catalog_empty_state("settings-models-empty", cx));
            }
            for model in catalog {
                card = card
                    .child(separator(p))
                    .child(self.settings_model_option(model, cx));
            }
        }
        div()
            .id("settings-models")
            .debug_selector(|| "settings-models".into())
            .w_full()
            .flex()
            .flex_col()
            .gap_3()
            .child(section_title(
                assistant_copy::copy(self.locale, "Models", "模型"),
                p,
            ))
            .child(card)
            .when(expanded, |section| {
                section.child(
                    div()
                        .px_1()
                        .text_size(px(12.))
                        .line_height(px(19.))
                        .text_color(p.muted)
                        .whitespace_normal()
                        .child(assistant_copy::copy(
                            self.locale,
                            "Used for new conversations. Existing conversations keep their model.",
                            "用于新建对话，已有对话继续使用原来的模型。",
                        )),
                )
            })
            .into_any_element()
    }

    fn settings_model_option(&self, model: Model, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let selected = self.settings_default_model_id() == model.id;
        let enabled = self.runtime.is_native()
            && self.state.is_loaded()
            && !self.loading
            && !self.aux_busy
            && !self.state.is_busy()
            && !self.assistant_writer_lease
            && !self.provider_models.request_pending()
            && !self.custom_providers.request_pending();
        let detail = self.custom_providers.model_detail(&model.id).or_else(|| {
            let provider = provider_models::provider_label(&model.harness);
            (!provider.is_empty()).then(|| format!("{provider} · {}", model.id))
        });
        let selector = format!("settings-default-model-{}", model.id);
        div()
            .id(selector.clone())
            .debug_selector(move || selector.clone())
            .role(gpui::Role::RadioButton)
            .aria_label(model.name.clone())
            .aria_toggled(if selected {
                gpui::Toggled::True
            } else {
                gpui::Toggled::False
            })
            .min_h(px(48.))
            .flex_shrink_0()
            .px_4()
            .py_3()
            .flex()
            .items_center()
            .gap_3()
            .when(enabled, |row| {
                row.cursor_pointer().hover(|s| s.bg(p.surface))
            })
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .text_size(px(14.))
                    .text_color(p.text)
                    .whitespace_normal()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(model.name)
                    .when_some(detail, |column, detail| {
                        column.child(
                            div()
                                .truncate()
                                .text_size(px(11.))
                                .text_color(p.muted)
                                .child(detail),
                        )
                    }),
            )
            .child(
                div()
                    .size(px(20.))
                    .flex_shrink_0()
                    .when(selected, |mark| mark.child(icon(Icon::Check, 18., p.text))),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                if !this.runtime.is_native() {
                    return;
                }
                match this.prepare_settings_default_model(&model.id) {
                    Ok(Some(command)) => {
                        this.settings_expanded = None;
                        this.commit(Ok(command), cx);
                    }
                    Ok(None) => {}
                    Err(error) => {
                        this.notice = Some(error);
                        cx.notify();
                    }
                }
            }))
            .into_any_element()
    }

    pub(in crate::ui) fn settings_default_model_id(&self) -> &str {
        self.state.preferences()["default_model"]
            .as_str()
            .unwrap_or("")
    }

    pub(in crate::ui) fn prepare_settings_default_model(
        &mut self,
        model: &str,
    ) -> Result<Option<RuntimeCommand>, String> {
        if self.loading
            || self.aux_busy
            || self.state.is_busy()
            || self.assistant_writer_lease
            || self.provider_models.request_pending()
            || self.custom_providers.request_pending()
        {
            return Ok(None);
        }
        if self.settings_default_model_id() == model {
            return Ok(None);
        }
        // Shared validation owns catalog membership and the session CAS.
        self.state.set_default_model(model).map(Some)
    }
}

impl Shell {
    pub(in crate::ui) fn model_catalog_empty_state(
        &self,
        selector: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        div().id(selector).debug_selector(move || selector.into()).w_full().p_4().flex().flex_col().gap_3()
            .child(div().text_size(px(14.)).font_weight(gpui::FontWeight::MEDIUM)
                .child(assistant_copy::copy(self.locale, "No configured models", "尚未配置模型")))
            .child(div().text_size(px(12.)).line_height(px(20.)).text_color(p.muted).whitespace_normal()
                .child(assistant_copy::copy(self.locale, "Configure a provider or add a model first. Models come from your saved provider catalogs.",
                    "请先配置服务商或添加模型，模型列表来自已保存的服务商目录。")))
            .into_any_element()
    }
}
