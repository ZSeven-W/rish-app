//! Profile execution defaults are independent of model and account settings.
//! Editing and saving never evaluates user JavaScript.
use super::{
    assistant_copy::copy,
    assistant_forms::{AssistantUi, ProfileDraft},
    settings::{PreferenceGroup, group, section_title, separator},
    *,
};
use crate::icons::{Icon, icon};
use gpui::AnyElement;
use rish_shell_core::assistant_store::{AssistantProfile, RuntimeSpec};

const SCRIPT_EXAMPLE: &str = "({\n  beforeModel(ctx) { return { allow: true }; },\n  beforeTool(ctx) { return { allow: true }; }\n})";
const MAX_SOURCE_BYTES: usize = 32_768;

#[derive(Clone)]
pub(super) struct RuntimeEditor {
    id: String,
    baseline: AssistantProfile,
    custom: bool,
    name: String,
    source: String,
    error: Option<String>,
}

impl RuntimeEditor {
    fn new(baseline: &AssistantProfile, visible: &AssistantProfile, custom: bool) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            baseline: baseline.clone(),
            custom,
            name: visible
                .runtime
                .source()
                .map(|_| visible.runtime.name())
                .unwrap_or("My runtime")
                .into(),
            source: visible.runtime.source().unwrap_or(SCRIPT_EXAMPLE).into(),
            error: None,
        }
    }

    fn spec(&self, locale: Locale) -> Result<RuntimeSpec, String> {
        if !self.custom {
            return Ok(RuntimeSpec::pi());
        }
        RuntimeSpec::custom(self.name.clone(), self.source.clone()).map_err(|_| {
            copy(locale,
                "Enter a name up to 256 bytes and a nonempty script up to 32 KB. Remove control characters from the name.",
                "请输入不超过 256 字节的名称和不超过 32 KB 的非空脚本；名称不能含控制字符。",
            ).into()
        })
    }
}

#[derive(Clone, Copy)]
enum RuntimeAction {
    Pi,
    Custom,
    Name,
    Source,
    Save,
    Cancel,
    SaveProfile,
}

impl AssistantUi {
    /// The shared typed profile merge retains concurrent avatar/notes changes.
    /// A pre-existing draft or changed profile requires an explicit review save.
    fn stage_runtime(&mut self, baseline: &AssistantProfile, runtime: RuntimeSpec) -> bool {
        let Some(store) = self.snapshot.store.as_ref() else {
            return false;
        };
        let review = self.profile_draft.is_some() || store.profile != *baseline;
        let mut draft = self.profile_draft.take().unwrap_or_else(|| ProfileDraft {
            baseline: baseline.clone(),
            profile: baseline.clone(),
            expected_revision: store.revision,
            saving: false,
        });
        draft.profile.runtime = runtime;
        draft.rebase(&store.profile);
        self.profile_draft = Some(draft);
        !review
    }
}

impl Shell {
    fn runtime_edit_enabled(&self) -> bool {
        self.runtime.is_native()
            && self.assistant.snapshot.store.is_some()
            && !self.assistant.form_busy()
            && !self.native_form_active
    }

    fn runtime_action(&mut self, action: RuntimeAction, cx: &mut Context<Self>) {
        if matches!(action, RuntimeAction::Cancel) {
            if !self.assistant.form_busy() && !self.native_form_active {
                self.runtime_editor = None;
                cx.notify();
            }
            return;
        }
        if !self.runtime_edit_enabled() {
            return;
        }
        match action {
            RuntimeAction::Pi | RuntimeAction::Custom => {
                let custom = matches!(action, RuntimeAction::Custom);
                if let Some(editor) = &mut self.runtime_editor {
                    editor.custom = custom;
                    editor.error = None;
                } else if let Some(store) = self.assistant.snapshot.store.as_ref() {
                    let visible = self.assistant.visible_profile().unwrap_or(&store.profile);
                    self.runtime_editor = Some(RuntimeEditor::new(&store.profile, visible, custom));
                }
            }
            RuntimeAction::Name | RuntimeAction::Source => {
                self.edit_runtime_field(matches!(action, RuntimeAction::Source), cx);
            }
            RuntimeAction::Save => {
                let Some(editor) = self.runtime_editor.as_ref() else {
                    return;
                };
                let spec = match editor.spec(self.locale) {
                    Ok(spec) => spec,
                    Err(error) => {
                        self.runtime_editor.as_mut().unwrap().error = Some(error);
                        cx.notify();
                        return;
                    }
                };
                let baseline = editor.baseline.clone();
                let save = self.assistant.stage_runtime(&baseline, spec);
                self.runtime_editor = None;
                if save {
                    self.assistant.error = None;
                    self.assistant_save_profile(cx);
                } else {
                    self.assistant.error = Some(copy(self.locale,
                        "Your profile changed or has an unsaved draft. Review the profile below before saving.",
                        "资料已变更或存在未保存草稿，请核对下方资料后保存。",
                    ).into());
                }
            }
            RuntimeAction::SaveProfile => self.assistant_save_profile(cx),
            RuntimeAction::Cancel => {}
        }
        cx.notify();
    }

    fn edit_runtime_field(&mut self, source: bool, cx: &mut Context<Self>) {
        let Some(editor) = self.runtime_editor.as_ref() else {
            return;
        };
        let editor_id = editor.id.clone();
        let initial = if source { &editor.source } else { &editor.name };
        let title = if source {
            copy(self.locale, "Runtime script", "运行时脚本")
        } else {
            copy(self.locale, "Runtime name", "运行时名称")
        };
        let mut command = assistant_copy::field_command(title, initial, source, self.locale, cx);
        if source {
            command.args[0]["max_bytes"] = serde_json::json!(MAX_SOURCE_BYTES);
        }
        let token = uuid::Uuid::new_v4().to_string();
        self.assistant.form_request = Some(token.clone());
        self.set_inline_native_form(true, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                this.complete_runtime_field(&token, &editor_id, source, result, cx);
            });
        })
        .detach();
    }

    fn complete_runtime_field(
        &mut self,
        token: &str,
        editor_id: &str,
        source: bool,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        if self.assistant.form_request.as_deref() != Some(token) {
            return;
        }
        self.assistant.form_request = None;
        self.set_inline_native_form(false, cx);
        let Some(editor) = self
            .runtime_editor
            .as_mut()
            .filter(|editor| editor.id == editor_id)
        else {
            cx.notify();
            return;
        };
        let text = match result {
            Ok(Value::Null) => {
                cx.notify();
                return;
            }
            Ok(Value::String(text)) => text,
            _ => {
                editor.error = Some(
                    copy(
                        self.locale,
                        "Could not read that input. Your draft was kept.",
                        "无法读取输入内容，已保留草稿。",
                    )
                    .into(),
                );
                cx.notify();
                return;
            }
        };
        let max = if source { MAX_SOURCE_BYTES } else { 256 };
        if text.len() > max
            || text.contains('\0')
            || (!source && text.chars().any(char::is_control))
        {
            editor.error = Some(
                copy(
                    self.locale,
                    "The input is too long or contains an invalid character.",
                    "输入过长或包含无效字符。",
                )
                .into(),
            );
        } else {
            if source {
                editor.source = text;
            } else {
                editor.name = text.trim().into();
            }
            editor.error = None;
        }
        cx.notify();
    }

    pub(super) fn settings_runtime_section(
        &self,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let expanded = self.settings_expanded == Some(PreferenceGroup::Runtime);
        let saved = self
            .assistant
            .snapshot
            .store
            .as_ref()
            .map(|s| &s.profile.runtime);
        let value = saved
            .map(|runtime| runtime.name())
            .unwrap_or(copy(self.locale, "Preparing", "正在准备"))
            .to_owned();
        let custom = self
            .runtime_editor
            .as_ref()
            .map(|editor| editor.custom)
            .unwrap_or_else(|| {
                self.assistant
                    .visible_profile()
                    .is_some_and(|profile| profile.runtime.source().is_some())
            });
        let mut card = group(p)
            .id("settings-runtime-card")
            .debug_selector(|| "settings-runtime-card".into())
            .child(self.preference_row(
                "settings-runtime",
                PreferenceGroup::Runtime,
                Icon::CodeXml,
                copy(self.locale, "Default engine", "默认引擎"),
                value,
                cx,
            ));
        if expanded {
            for (id, label, selected, action) in [
                ("settings-runtime-pi", "Pi", !custom, RuntimeAction::Pi),
                (
                    "settings-runtime-custom",
                    copy(self.locale, "Custom JavaScript", "自定义 JavaScript"),
                    custom,
                    RuntimeAction::Custom,
                ),
            ] {
                card = card.child(separator(p)).child(self.runtime_row(
                    id,
                    label,
                    if selected {
                        "✓".into()
                    } else {
                        String::new()
                    },
                    action,
                    true,
                    cx,
                ));
                if matches!(action, RuntimeAction::Pi) {
                    for entry in &self.runtime_engines.entries {
                        card = card
                            .child(separator(p))
                            .child(self.settings_runtime_product_row(entry, cx));
                    }
                }
            }
            if let Some(editor) = &self.runtime_editor {
                if editor.custom {
                    card = card
                        .child(separator(p))
                        .child(self.runtime_row(
                            "settings-runtime-name",
                            copy(self.locale, "Name", "名称"),
                            editor.name.clone(),
                            RuntimeAction::Name,
                            false,
                            cx,
                        ))
                        .child(separator(p))
                        .child(self.runtime_row(
                            "settings-runtime-source",
                            copy(self.locale, "Script", "脚本"),
                            format!("{} B", editor.source.len()),
                            RuntimeAction::Source,
                            false,
                            cx,
                        ));
                }
                if let Some(error) = &editor.error {
                    card = card.child(self.runtime_hint(error.clone(), true, p));
                }
                card = card
                    .child(separator(p))
                    .child(self.runtime_row(
                        "settings-runtime-save",
                        copy(self.locale, "Save runtime", "保存运行时"),
                        String::new(),
                        RuntimeAction::Save,
                        false,
                        cx,
                    ))
                    .child(separator(p))
                    .child(self.runtime_row(
                        "settings-runtime-cancel",
                        copy(self.locale, "Cancel editing", "取消编辑"),
                        String::new(),
                        RuntimeAction::Cancel,
                        false,
                        cx,
                    ));
            }
        }
        let mut section = div()
            .id("settings-runtime-section")
            .debug_selector(|| "settings-runtime-section".into())
            .w_full()
            .flex()
            .flex_col()
            .gap_3()
            .child(section_title(
                copy(self.locale, "Runtime Engine", "运行时引擎"),
                p,
            ))
            .child(card);
        if expanded {
            section = section.child(self.runtime_engines_status(cx));
            section = section.child(self.runtime_hint(copy(self.locale,
                "Tasks using the default engine inherit it on their next run. Started runs keep their engine.",
                "使用默认引擎的任务会在下次运行时继承此设置，已开始的运行保持原引擎。",
            ).into(), false, p));
            if self.runtime_editor.as_ref().is_some_and(|e| e.custom) {
                section = section.child(self.runtime_hint(copy(self.locale,
                    "Custom scripts use synchronous beforeModel / beforeTool hooks. Return { allow: true } or { stop: 'reason' }. No direct file, network or shell access.",
                    "自定义脚本使用同步 beforeModel / beforeTool 钩子，返回 { allow: true } 或 { stop: '原因' }。脚本不直接访问文件、网络或 Shell。",
                ).into(), false, p));
                section = section.child(self.runtime_hint(SCRIPT_EXAMPLE.into(), false, p));
            }
            if let Some(draft) = &self.assistant.profile_draft {
                let profile = &draft.profile;
                section = section.child(self.runtime_hint(
                    format!(
                        "{}: {}\n{}: {}\n{}: {}",
                        copy(self.locale, "Profile", "资料"),
                        profile.name,
                        copy(self.locale, "Notes", "备注"),
                        assistant_view::preview(&profile.notes, 80),
                        copy(self.locale, "Runtime", "运行时"),
                        profile.runtime.name()
                    ),
                    false,
                    p,
                ));
                if let Some(error) = &self.assistant.error {
                    let message = if error.starts_with("Assistant state changed") {
                        copy(self.locale, "Your profile changed. Your runtime draft was kept; review before saving again.", "资料已变更，运行时草稿已保留，请核对后重新保存。").into()
                    } else if error.starts_with("Assistant storage failed") {
                        copy(self.locale, "The save could not be confirmed. Your draft is kept; check the saved profile before retrying.", "尚未确认资料已保存，草稿已保留，请核对保存结果后重试。").into()
                    } else {
                        assistant_copy::message(self.locale, error)
                    };
                    section = section.child(self.runtime_hint(message, true, p));
                }
                section = section.child(group(p).child(self.runtime_row(
                    "settings-runtime-save-profile",
                    copy(self.locale, "Save reviewed profile", "保存已核对的资料"),
                    String::new(),
                    RuntimeAction::SaveProfile,
                    false,
                    cx,
                )));
            }
        }
        section.into_any_element()
    }

    fn runtime_hint(&self, text: String, error: bool, p: Palette) -> AnyElement {
        div()
            .px_3()
            .py_2()
            .text_size(px(12.))
            .line_height(px(19.))
            .text_color(if error { p.danger } else { p.muted })
            .whitespace_normal()
            .child(text)
            .into_any_element()
    }

    fn runtime_row(
        &self,
        id: &'static str,
        label: &'static str,
        value: String,
        action: RuntimeAction,
        radio: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let enabled = if matches!(action, RuntimeAction::Cancel) {
            !self.assistant.form_busy() && !self.native_form_active
        } else {
            self.runtime_edit_enabled()
        };
        let selected = value == "✓";
        let theme = cx
            .try_global::<theme::ThemeState>()
            .copied()
            .unwrap_or_default();
        let dark = theme.mode == theme::ThemeMode::Dark
            || (theme.mode == theme::ThemeMode::System && theme.system_dark);
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(if radio {
                gpui::Role::RadioButton
            } else {
                gpui::Role::Button
            })
            .aria_label(format!("{label}: {value}"))
            .when(radio, |row| {
                row.aria_toggled(if selected {
                    gpui::Toggled::True
                } else {
                    gpui::Toggled::False
                })
            })
            .min_h(px(48.))
            .when(radio, |row| row.min_h(px(64.)))
            .px_4()
            .py_3()
            .flex()
            .items_center()
            .gap_3()
            .when(enabled, |row| {
                row.cursor_pointer().hover(|style| style.bg(p.surface))
            })
            .when(matches!(action, RuntimeAction::Pi), |row| {
                row.child(crate::providers::pi_logo(30., dark))
            })
            .when(matches!(action, RuntimeAction::Custom), |row| {
                row.child(
                    div()
                        .size(px(30.))
                        .flex_shrink_0()
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(icon(Icon::CodeXml, 24., p.muted)),
                )
            })
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .text_size(px(14.))
                    .text_color(p.text)
                    .whitespace_normal()
                    .child(label),
            )
            .child(
                div()
                    .max_w(px(125.))
                    .truncate()
                    .text_size(px(13.))
                    .text_color(p.muted)
                    .child(value),
            )
            .when(!radio, |row| {
                row.child(icon(Icon::ChevronRight, 16., p.faint))
            })
            .on_click(cx.listener(move |this, _, _, cx| this.runtime_action(action, cx)))
            .into_any_element()
    }
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "settings_runtime_tests.rs"]
mod tests;
