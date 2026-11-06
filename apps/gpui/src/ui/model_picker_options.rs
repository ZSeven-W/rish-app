use super::model_picker::{PickerBounds, thinking_label};
use super::*;
use crate::icons::{Icon, icon};
use rish_shell_core::Model;

const ROW_HEIGHT: f32 = 48.;
const GROUP_HEIGHT: f32 = 36.;

fn grouped_models(models: Vec<Model>) -> Vec<(String, Vec<Model>)> {
    let mut groups: Vec<(String, Vec<Model>)> = Vec::new();
    for model in models {
        if let Some((_, items)) = groups
            .iter_mut()
            .find(|(harness, _)| *harness == model.harness)
        {
            items.push(model);
        } else {
            groups.push((model.harness.clone(), vec![model]));
        }
    }
    groups
}

fn group_label(harness: &str, locale: Locale) -> &'static str {
    match harness {
        "dsh" => "DeepSeek",
        "claude-code" => "Anthropic",
        "codex" => "OpenAI",
        "glm" => "Z.AI",
        _ if harness.starts_with("custom-") => {
            assistant_copy::copy(locale, "Custom provider", "自定义服务商")
        }
        _ => locale.text(Text::OtherModels),
    }
}

impl Shell {
    fn model_option(&self, model: Model, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let selected = self
            .config_draft
            .as_ref()
            .is_some_and(|draft| draft.model == model.id);
        let enabled = selected
            || (!self.loading
                && !self.state.is_busy()
                && !self.provider_models.request_pending()
                && !self.custom_providers.request_pending());
        let detail = self.custom_providers.model_detail(&model.id);
        let selector = format!("model-picker-row-{}", model.id);
        div()
            .id(model.id.clone())
            .debug_selector(move || selector.clone())
            .role(gpui::Role::ListBoxOption)
            .aria_label(model.name.clone())
            .aria_selected(selected)
            .when(selected, |row| {
                row.aria_description(self.locale.text(Text::CurrentModel))
                    .aria_active_descendant()
            })
            .h(px(ROW_HEIGHT))
            .min_h(px(ROW_HEIGHT))
            .flex_shrink_0()
            .px_3()
            .rounded(px(12.))
            .flex()
            .items_center()
            .gap_3()
            .text_size(px(15.))
            .text_color(if enabled { p.text } else { p.muted })
            .when(enabled, |row| {
                row.cursor_pointer().hover(|s| s.bg(p.surface))
            })
            .when(selected, |row| {
                row.bg(p.accent_soft).font_weight(gpui::FontWeight::MEDIUM)
            })
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .child(div().truncate().child(model.name))
                    .when_some(detail, |column, detail| {
                        column.child(
                            div()
                                .truncate()
                                .text_size(px(10.))
                                .text_color(p.muted)
                                .child(detail),
                        )
                    }),
            )
            .child(
                div()
                    .size(px(22.))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .when(selected, |check| {
                        check.child(
                            div()
                                .id("model-picker-selected")
                                .debug_selector(|| "model-picker-selected".into())
                                .child(icon(Icon::Check, 18., p.accent)),
                        )
                    }),
            )
            .on_click(cx.listener(move |this, _, window, cx| {
                this.choose_model(&model.id, window, cx);
                cx.stop_propagation();
            }))
    }

    pub(super) fn model_options(
        &self,
        bounds: PickerBounds,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let mut list = div()
            .id("model-picker-list")
            .debug_selector(|| "model-picker-list".into())
            .role(gpui::Role::ListBox)
            .aria_label(self.locale.text(Text::Models))
            .h(px((bounds.height - bounds.header_height).max(0.)))
            .min_h(px(0.))
            .w_full()
            .overflow_y_scroll()
            .track_scroll(&self.model_picker_scroll)
            .px_3()
            .pb(px(bounds.bottom_padding))
            .flex()
            .flex_col();
        if self.state.models().is_empty() {
            list = list.child(self.model_catalog_empty_state("model-picker-empty", cx));
        }
        for (harness, models) in grouped_models(self.state.models()) {
            let selector = format!("model-picker-group-{harness}");
            list = list.child(
                div()
                    .id(harness.clone())
                    .debug_selector(move || selector.clone())
                    .h(px(GROUP_HEIGHT))
                    .flex_shrink_0()
                    .px_3()
                    .pt_2()
                    .flex()
                    .items_center()
                    .text_size(px(12.))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(p.muted)
                    .child(
                        self.state
                            .provider_display_name(&harness)
                            .unwrap_or_else(|| group_label(&harness, self.locale))
                            .to_owned(),
                    ),
            );
            for model in models {
                list = list.child(self.model_option(model, cx));
            }
        }
        list
    }

    pub(super) fn thinking_options(
        &self,
        bounds: PickerBounds,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let mut list = div()
            .id("thinking-picker-list")
            .debug_selector(|| "thinking-picker-list".into())
            .role(gpui::Role::ListBox)
            .aria_label(self.locale.text(Text::ThinkingIntensity))
            .h(px((bounds.height - bounds.header_height).max(0.)))
            .min_h(px(0.))
            .w_full()
            .overflow_y_scroll()
            .track_scroll(&self.model_picker_scroll)
            .px_3()
            .pb(px(bounds.bottom_padding))
            .flex()
            .flex_col();
        for mode in ["off", "high", "max"] {
            let selected = self
                .config_draft
                .as_ref()
                .is_some_and(|draft| draft.thinking == mode);
            let enabled = selected
                || (!self.loading
                    && !self.state.is_busy()
                    && !self.provider_models.request_pending()
                    && !self.custom_providers.request_pending());
            let selector = format!("thinking-picker-row-{mode}");
            list = list.child(
                div()
                    .id(mode)
                    .debug_selector(move || selector.clone())
                    .role(gpui::Role::ListBoxOption)
                    .aria_label(self.locale.text(thinking_label(mode)))
                    .aria_selected(selected)
                    .h(px(54.))
                    .min_h(px(54.))
                    .flex_shrink_0()
                    .px_3()
                    .rounded(px(12.))
                    .flex()
                    .items_center()
                    .gap_3()
                    .text_size(px(15.))
                    .text_color(if enabled { p.text } else { p.muted })
                    .when(enabled, |row| {
                        row.cursor_pointer().hover(|s| s.bg(p.surface))
                    })
                    .when(selected, |row| {
                        row.bg(p.accent_soft).font_weight(gpui::FontWeight::MEDIUM)
                    })
                    .child(div().flex_1().child(self.locale.text(thinking_label(mode))))
                    .when(selected, |row| row.child(icon(Icon::Check, 18., p.accent)))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.choose_thinking(mode, window, cx);
                        cx.stop_propagation();
                    })),
            );
        }
        list
    }
}
