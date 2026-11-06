//! Model setup reuses the provider editors without leaving the chat or
//! committing its configuration draft. Only explicit selection and Done write
//! the conversation; catalog saves still use the existing native CAS path.
use super::model_picker::{ConfigurationPage, PickerBounds};
use super::*;
use crate::icons::{Icon, icon};
use gpui::AnyElement;

impl Shell {
    pub(super) fn open_model_setup(&mut self, cx: &mut Context<Self>) {
        if self.native_form_active {
            return;
        }
        if self.model_picker {
            self.show_configuration_page(ConfigurationPage::Providers, cx);
        } else {
            self.open_provider_settings(cx);
        }
        if !self.custom_providers.loaded {
            self.reload_custom_providers(cx);
        }
        cx.notify();
    }

    pub(super) fn model_setup_entry(
        &self,
        selector: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let label = assistant_copy::copy(self.locale, "Add / custom model", "添加 / 自定义模型");
        div()
            .id(selector)
            .debug_selector(move || selector.into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .min_h(px(48.))
            .flex_shrink_0()
            .px_4()
            .py_3()
            .flex()
            .items_center()
            .gap_3()
            .text_size(px(14.))
            .text_color(p.accent)
            .cursor_pointer()
            .hover(|v| v.bg(p.surface))
            .child(icon(Icon::Plus, 18., p.accent))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .whitespace_normal()
                    .child(label),
            )
            .child(icon(Icon::ChevronRight, 16., p.muted))
            .on_click(cx.listener(|this, _, _, cx| {
                this.open_model_setup(cx);
                cx.stop_propagation();
            }))
            .into_any_element()
    }

    pub(super) fn model_setup_options(
        &self,
        bounds: PickerBounds,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id("model-picker-provider-setup")
            .debug_selector(|| "model-picker-provider-setup".into())
            .h(px((bounds.height - bounds.header_height).max(0.)))
            .min_h(px(0.))
            .w_full()
            .overflow_y_scroll()
            .track_scroll(&self.model_picker_scroll)
            .px_3()
            .pb(px(bounds.bottom_padding))
            .child(self.settings_account_section(Palette::get(cx), cx))
    }

    pub(super) fn model_setup_return_to_defaults(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let label = assistant_copy::copy(self.locale, "Choose default model", "选择默认模型");
        div()
            .id("model-setup-return-defaults")
            .debug_selector(|| "model-setup-return-defaults".into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .min_h(px(48.))
            .px_4()
            .py_3()
            .flex()
            .items_center()
            .gap_3()
            .text_size(px(14.))
            .cursor_pointer()
            .hover(|v| v.bg(p.surface))
            .child(icon(Icon::ChevronLeft, 18., p.muted))
            .child(label)
            .on_click(cx.listener(|this, _, _, cx| {
                this.settings_expanded = Some(settings::PreferenceGroup::Models);
                cx.notify();
            }))
            .into_any_element()
    }
}
