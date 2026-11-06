use super::*;
use crate::icons::{Icon, icon};
use gpui::{AnyElement, FontWeight};

impl Shell {
    pub(in crate::ui) fn provider_models_editor(
        &self,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let editor = self.provider_models.editor.as_ref()?;
        let p = Palette::get(cx);
        let idle = self.provider_models_idle();
        let editing = idle && self.runtime.is_native();
        let fetching = self.provider_models.request.as_ref().is_some_and(|r| {
            matches!(
                r.operation,
                Operation::ProfileForDiscovery | Operation::Discover { .. }
            )
        });
        let saving = self
            .provider_models
            .request
            .as_ref()
            .is_some_and(|r| matches!(r.operation, Operation::Save { .. }));
        let mut form=div().id("provider-models-editor").debug_selector(||"provider-models-editor".into())
            .m_3().min_w(px(0.)).rounded(px(18.)).border_1().border_color(p.line).overflow_hidden()
            .flex().flex_col()
            .child(div().px_4().pt_4().pb_2().flex().items_center().gap_2()
                .child(div().flex_1().min_w(px(0.)).text_size(px(15.)).font_weight(FontWeight::SEMIBOLD)
                    .child(format!("{} · {}",provider_label(&editor.harness),copy(self.locale,"Models","模型"))))
                .child(self.provider_models_small_button("provider-models-close",copy(self.locale,"Close","关闭"),Icon::X,
                    !saving&&editor.field_request.is_none(),Action::Close,cx)))
            .child(div().px_4().pb_3().text_size(px(12.)).line_height(px(20.)).text_color(p.muted).whitespace_normal()
                .child(copy(self.locale,"Fetch this provider’s model list, or enter model IDs manually. Saved entries become available in the model picker.",
                    "从服务商拉取模型，也可以手动填写模型 ID。保存后即可在模型选择器中使用。")))
            .child(self.provider_models_control("provider-models-key",copy(self.locale,"API key","API 密钥"),
                copy(self.locale,"Configure in secure storage","在安全存储中配置").into(),Icon::Settings2,editing,Action::Credential,cx))
            .child(self.provider_models_control("provider-models-fetch",copy(self.locale,if fetching{"Fetching models…"}else{"Fetch models"},if fetching{"正在拉取模型…"}else{"拉取模型"}),
                String::new(),Icon::RefreshCw,editing,Action::Fetch,cx))
            .when(fetching,|form|form.child(self.provider_models_control("provider-models-cancel-fetch",copy(self.locale,"Cancel fetch","取消拉取"),
                String::new(),Icon::X,true,Action::CancelFetch,cx)))
            .child(self.provider_models_control("provider-models-manual",copy(self.locale,"Add / edit model IDs","手动添加／编辑模型"),
                if self.locale==Locale::Zh{format!("已配置 {} 个",editor.models.len())}else{format!("{} configured",editor.models.len())},
                Icon::SquarePen,editing,Action::EditModels,cx));
        if editor.discovered {
            form = form.child(self.provider_models_discovery(editor, editing, cx));
        }
        if editor.models.is_empty() {
            form = form.child(
                div()
                    .px_4()
                    .py_4()
                    .text_size(px(12.))
                    .line_height(px(20.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(copy(
                        self.locale,
                        "No models configured. Fetch the catalog or add a model manually.",
                        "尚未配置模型，请拉取目录或手动添加。",
                    )),
            );
        } else {
            form = form.child(
                div()
                    .px_4()
                    .pt_4()
                    .pb_2()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .child(copy(
                        self.locale,
                        "Saved-list draft · image support is explicit",
                        "模型列表草稿 · 图片能力需明确设置",
                    )),
            );
            for model in &editor.models {
                let id = model.id.clone();
                let selector = format!("provider-model-images-{id}");
                form = form.child(
                    div()
                        .id(selector.clone())
                        .debug_selector(move || selector.clone())
                        .role(gpui::Role::Switch)
                        .aria_label(format!(
                            "{} · {}",
                            model.name,
                            copy(self.locale, "Image input", "图片输入")
                        ))
                        .aria_toggled(if model.images {
                            gpui::Toggled::True
                        } else {
                            gpui::Toggled::False
                        })
                        .min_h(px(60.))
                        .px_4()
                        .py_2()
                        .flex()
                        .items_center()
                        .gap_3()
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .flex()
                                .flex_col()
                                .gap_1()
                                .child(
                                    div()
                                        .text_size(px(13.))
                                        .truncate()
                                        .child(model.name.clone()),
                                )
                                .child(
                                    div()
                                        .text_size(px(10.))
                                        .text_color(p.muted)
                                        .truncate()
                                        .child(model.id.clone()),
                                ),
                        )
                        .child(div().text_size(px(11.)).text_color(p.muted).child(copy(
                            self.locale,
                            if model.images {
                                "Images on"
                            } else {
                                "Text only"
                            },
                            if model.images {
                                "支持图片"
                            } else {
                                "仅文本"
                            },
                        )))
                        .when(editing, |row| {
                            row.cursor_pointer().hover(|v| v.bg(p.surface))
                        })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if editing {
                                this.provider_models_action(Action::ToggleImages(id.clone()), cx)
                            }
                        })),
                );
            }
        }
        if let Some(notice) = &editor.notice {
            form = form.child(
                div()
                    .id("provider-models-notice")
                    .debug_selector(|| "provider-models-notice".into())
                    .px_4()
                    .py_3()
                    .text_size(px(12.))
                    .line_height(px(20.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(notice.clone()),
            );
        }
        form = form.child(self.provider_models_control(
            "provider-models-reload",
            copy(self.locale, "Refresh saved catalog", "刷新已保存目录"),
            String::new(),
            Icon::RotateCcw,
            editing,
            Action::Reload,
            cx,
        ));
        form = form.child(
            div().px_4().py_3().child(
                div()
                    .id("provider-models-save")
                    .debug_selector(|| "provider-models-save".into())
                    .role(gpui::Role::Button)
                    .aria_label(copy(self.locale, "Save models", "保存模型"))
                    .min_h(px(48.))
                    .w_full()
                    .rounded_full()
                    .bg(p.accent)
                    .text_color(p.on_accent)
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(14.))
                    .child(copy(
                        self.locale,
                        if saving { "Saving…" } else { "Save models" },
                        if saving {
                            "保存中…"
                        } else {
                            "保存模型"
                        },
                    ))
                    .when(editing && !editor.needs_reload, |v| v.cursor_pointer())
                    .when(!editing || editor.needs_reload, |v| v.opacity(0.5))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if editing {
                            this.provider_models_action(Action::Save, cx)
                        }
                    })),
            ),
        );
        Some(form.into_any_element())
    }
    fn provider_models_discovery(
        &self,
        editor: &ProviderModelEditor,
        enabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        let mut rows = div()
            .id("provider-model-candidates")
            .debug_selector(|| "provider-model-candidates".into())
            .max_h(px(280.))
            .min_h(px(0.))
            .overflow_y_scroll()
            .track_scroll(&editor.scroll)
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .flex()
            .flex_col();
        for candidate in editor.visible_candidates() {
            let id = candidate.id.clone();
            let selected = editor.selected.contains(&id);
            let existing = editor.has_model(&id);
            let selector = format!("provider-model-candidate-{id}");
            rows = rows.child(
                div()
                    .id(selector.clone())
                    .debug_selector(move || selector.clone())
                    .role(gpui::Role::CheckBox)
                    .aria_label(candidate.name.clone())
                    .aria_toggled(if selected || existing {
                        gpui::Toggled::True
                    } else {
                        gpui::Toggled::False
                    })
                    .min_h(px(56.))
                    .flex_shrink_0()
                    .px_3()
                    .py_2()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(icon(
                        if selected || existing {
                            Icon::Check
                        } else {
                            Icon::Plus
                        },
                        16.,
                        if existing { p.faint } else { p.text },
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div()
                                    .text_size(px(13.))
                                    .truncate()
                                    .child(candidate.name.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(10.))
                                    .text_color(p.muted)
                                    .truncate()
                                    .child(candidate.id.clone()),
                            ),
                    )
                    .when(existing, |row| {
                        row.child(div().text_size(px(10.)).text_color(p.muted).child(copy(
                            self.locale,
                            "Added",
                            "已添加",
                        )))
                    })
                    .when(enabled && !existing, |row| {
                        row.cursor_pointer().hover(|v| v.bg(p.surface))
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if enabled {
                            this.provider_models_action(Action::ToggleCandidate(id.clone()), cx)
                        }
                    })),
            );
        }
        div().id("provider-model-discovery").debug_selector(||"provider-model-discovery".into()).m_3().rounded(px(14.))
            .border_1().border_color(p.line).overflow_hidden().flex().flex_col()
            .child(self.provider_models_control("provider-model-filter",copy(self.locale,"Search returned models","搜索返回的模型"),editor.query.clone(),Icon::Search,enabled,Action::EditFilter,cx))
            .when(!editor.query.is_empty(),|v|v.child(self.provider_models_control("provider-model-clear-filter",copy(self.locale,"Clear filter","清除筛选"),String::new(),Icon::X,enabled,Action::ClearFilter,cx)))
            .child(rows)
            .when(editor.truncated,|v|v.child(div().px_3().py_2().text_size(px(11.)).text_color(p.muted).whitespace_normal()
                .child(copy(self.locale,"The returned list was truncated. Missing models can be added manually.","返回列表已截断，未列出的模型可手动添加。"))))
            .child(self.provider_models_control("provider-model-import",copy(self.locale,"Add selected to draft","添加所选到草稿"),
                editor.selected.len().to_string(),Icon::Plus,enabled&&!editor.selected.is_empty(),Action::Import,cx))
            .into_any_element()
    }
    fn provider_models_small_button(
        &self,
        id: &'static str,
        label: &'static str,
        glyph: Icon,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .size(px(44.))
            .flex_shrink_0()
            .rounded_full()
            .flex()
            .items_center()
            .justify_center()
            .child(icon(glyph, 18., p.muted))
            .when(enabled, |v| v.cursor_pointer().hover(|v| v.bg(p.surface)))
            .when(!enabled, |v| v.opacity(0.5))
            .on_click(cx.listener(move |this, _, _, cx| {
                if enabled {
                    this.provider_models_action(action.clone(), cx)
                }
            }))
            .into_any_element()
    }
    fn provider_models_control(
        &self,
        id: &'static str,
        label: &'static str,
        detail: String,
        glyph: Icon,
        enabled: bool,
        action: Action,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = Palette::get(cx);
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .min_h(px(48.))
            .w_full()
            .px_4()
            .py_2()
            .flex()
            .items_center()
            .gap_3()
            .text_size(px(13.))
            .child(icon(glyph, 17., p.muted))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .whitespace_normal()
                    .child(label),
            )
            .when(!detail.is_empty(), |row| {
                row.child(
                    div()
                        .max_w(px(140.))
                        .truncate()
                        .text_size(px(11.))
                        .text_color(p.muted)
                        .child(detail),
                )
            })
            .when(enabled, |v| v.cursor_pointer().hover(|v| v.bg(p.surface)))
            .when(!enabled, |v| v.opacity(0.5))
            .on_click(cx.listener(move |this, _, _, cx| {
                if enabled {
                    this.provider_models_action(action.clone(), cx)
                }
            }))
            .into_any_element()
    }
}
