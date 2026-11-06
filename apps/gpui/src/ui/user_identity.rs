//! The person's nickname is separate from every Bot profile and model prompt.
use super::*;
use crate::assistant_runtime::RunnerCommand;
use gpui::AnyElement;

impl Shell {
    pub(super) fn sidebar_user_nickname(&self) -> String {
        self.assistant
            .directory()
            .and_then(|d| d.user_nickname.as_deref())
            .unwrap_or(assistant_copy::copy(self.locale, "You", "我"))
            .to_owned()
    }
    pub(super) fn sidebar_user_identity(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let name = self.sidebar_user_nickname();
        let initial = name
            .chars()
            .next()
            .map(|c| c.to_string())
            .unwrap_or_else(|| "R".into());
        div()
            .id("sidebar-user-identity")
            .debug_selector(|| "sidebar-user-identity".into())
            .role(gpui::Role::Button)
            .aria_label(format!(
                "{}: {}",
                assistant_copy::copy(self.locale, "Your nickname", "你的昵称"),
                name
            ))
            .px_3()
            .min_h(px(72.))
            .mb_3()
            .flex()
            .items_center()
            .gap_3()
            .cursor_pointer()
            .child(
                div()
                    .size(px(40.))
                    .flex_shrink_0()
                    .rounded_full()
                    .bg(p.composer)
                    .text_color(p.text)
                    .text_size(px(17.))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(initial),
            )
            .child(
                div()
                    .id("sidebar-user-nickname")
                    .debug_selector(|| "sidebar-user-nickname".into())
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .text_size(px(17.))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child(name),
            )
            .on_click(cx.listener(|this, _, window, cx| {
                this.close_drawer(false, window, cx);
                this.edit_user_nickname(cx);
            }))
            .into_any_element()
    }
    pub(super) fn edit_user_nickname(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || self.native_form_active
            || self.assistant.directory_ui.nickname_request.is_some()
        {
            return;
        }
        let Some(revision) = self.assistant.directory().map(|d| d.revision) else {
            self.initialize_assistant(cx);
            return;
        };
        let initial = self
            .assistant
            .directory_ui
            .nickname_draft
            .clone()
            .unwrap_or_else(|| self.sidebar_user_nickname());
        let command = assistant_copy::field_command(
            assistant_copy::copy(self.locale, "Your nickname", "你的昵称"),
            &initial,
            false,
            self.locale,
            cx,
        );
        let token = uuid::Uuid::new_v4().to_string();
        self.assistant.directory_ui.nickname_request = Some(token.clone());
        self.set_inline_native_form(true, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                this.set_inline_native_form(false, cx);
                if this.assistant.directory_ui.nickname_request.as_deref() != Some(&token) {
                    return;
                }
                this.assistant.directory_ui.nickname_request = None;
                match result {
                    Ok(Value::String(text)) => {
                        let nickname = text.trim().to_owned();
                        this.assistant.directory_ui.nickname_draft = Some(nickname.clone());
                        this.assistant_command(
                            RunnerCommand::SetUserNickname {
                                expected_revision: revision,
                                nickname,
                            },
                            cx,
                        );
                    }
                    Ok(Value::Null) => {}
                    _ => {
                        this.notice = Some(
                            assistant_copy::copy(
                                this.locale,
                                "Could not edit your nickname. Your saved name was kept.",
                                "昵称编辑失败，已保存的昵称未变。",
                            )
                            .into(),
                        )
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}
