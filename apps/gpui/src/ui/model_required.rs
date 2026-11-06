//! Missing provider configuration is a setup step, never a guessed model.
use super::*;

impl Shell {
    pub(super) fn choose_configured_model(&mut self, cx: &mut Context<Self>) {
        if self.state.models().is_empty() {
            self.open_provider_settings(cx);
            self.navigation_flow.feedback = Some(
                assistant_copy::copy(
                    self.locale,
                    "Add a model from a provider to continue. Your draft is kept.",
                    "请先从服务商添加模型，输入草稿已保留。",
                )
                .into(),
            );
        } else {
            self.config_draft = Some(model_picker::ConfigurationDraft {
                error: None,
                model: if self.state.model_is_configured(self.state.selected_model()) {
                    self.state.selected_model().to_owned()
                } else {
                    self.state
                        .configured_default_model()
                        .unwrap_or("")
                        .to_owned()
                },
                thinking: self.state.selected_thinking().to_owned(),
            });
            self.config_page = model_picker::ConfigurationPage::Models;
            self.model_picker = true;
            self.model_picker_previous_focus = None;
            self.model_picker_focus_pending = true;
            self.model_picker_scroll
                .set_offset(gpui::point(px(0.), px(0.)));
        }
        cx.notify();
    }
}
