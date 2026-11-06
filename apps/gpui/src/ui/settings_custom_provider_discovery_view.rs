use super::*;
use gpui::AnyElement;

impl Shell {
    pub(super) fn custom_discovery_view(
        &self,
        editor: &ProviderEditor,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let pending = self.custom_providers.request.as_ref().is_some_and(|request|
            matches!(&request.operation,Operation::Discover { editor:token,.. } if token == &editor.token));
        let idle = self.custom_provider_idle();
        let saved_matches = self
            .custom_providers
            .provider(&editor.id)
            .is_some_and(|saved| editor.discovery_profile_matches(&saved["configuration"]));
        let mut section = div()
            .id("custom-model-discovery")
            .debug_selector(|| "custom-model-discovery".into())
            .w_full()
            .min_w(px(0.))
            .flex()
            .flex_col()
            .child(
                self.custom_control(
                    "custom-provider-fetch-models",
                    copy(self.locale, "Fetch models", "拉取模型"),
                    if saved_matches {
                        copy(
                            self.locale,
                            "Request this provider’s model list",
                            "向此服务商请求模型列表",
                        )
                    } else {
                        copy(
                            self.locale,
                            "Save the provider URL and authentication settings first",
                            "请先保存服务商 URL 和鉴权设置",
                        )
                    }
                    .into(),
                    false,
                    self.custom_discovery_fetch_enabled(editor),
                    Action::Discovery(DiscoveryAction::Fetch),
                    cx,
                ),
            );
        if pending {
            section = section
                .child(
                    div()
                        .px_4()
                        .py_2()
                        .text_size(px(12.))
                        .text_color(p.muted)
                        .child(copy(
                            self.locale,
                            "Fetching model list…",
                            "正在拉取模型列表…",
                        )),
                )
                .child(self.custom_control(
                    "custom-provider-cancel-fetch",
                    copy(self.locale, "Cancel model request", "取消拉取"),
                    String::new(),
                    false,
                    true,
                    Action::Discovery(DiscoveryAction::CancelWait),
                    cx,
                ));
        }
        if let Some(error) = editor.discovery.error {
            section = section
                .child(
                    div()
                        .px_4()
                        .py_2()
                        .text_size(px(12.))
                        .line_height(px(18.))
                        .text_color(p.danger)
                        .whitespace_normal()
                        .child(error),
                )
                .child(self.custom_control(
                    "custom-provider-discovery-reload",
                    copy(
                        self.locale,
                        "Reload provider settings",
                        "重新加载服务商设置",
                    ),
                    String::new(),
                    false,
                    idle && self.runtime.is_native(),
                    Action::Reload,
                    cx,
                ));
        }
        if let Some(notice) = editor.discovery.notice {
            section = section.child(
                div()
                    .px_4()
                    .py_2()
                    .text_size(px(12.))
                    .line_height(px(18.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(notice),
            );
        }
        if editor.discovery.loaded {
            let count = editor.discovery.rows.len();
            section = section
                .child(
                    div()
                        .px_4()
                        .py_2()
                        .text_size(px(12.))
                        .text_color(p.muted)
                        .child(if self.locale == Locale::Zh {
                            format!(
                                "已从服务商获取 {count} 个模型 · 已选 {} 个",
                                editor.selected_new_count()
                            )
                        } else {
                            format!(
                                "{count} models received · {} selected",
                                editor.selected_new_count()
                            )
                        }),
                )
                .child(self.custom_control(
                    "custom-provider-filter-models",
                    copy(self.locale, "Search models", "搜索模型"),
                    if editor.discovery.query.is_empty() {
                        copy(
                            self.locale,
                            "Filter by model ID or name",
                            "按模型 ID 或名称筛选",
                        )
                        .into()
                    } else {
                        editor.discovery.query.clone()
                    },
                    false,
                    idle && self.runtime.is_native(),
                    Action::Discovery(DiscoveryAction::Filter),
                    cx,
                ));
            if !editor.discovery.query.is_empty() {
                section = section.child(self.custom_control(
                    "custom-provider-clear-filter",
                    copy(self.locale, "Clear search", "清除搜索"),
                    String::new(),
                    false,
                    idle,
                    Action::Discovery(DiscoveryAction::ClearFilter),
                    cx,
                ));
            }
            let visible = editor.discovery.visible().collect::<Vec<_>>();
            if visible.is_empty() {
                section = section.child(div().px_4().py_3().text_size(px(12.)).text_color(p.muted).whitespace_normal()
                    .child(if editor.discovery.rows.is_empty(){copy(self.locale,"The provider returned no models. You can still enter IDs manually.","服务商未返回模型，仍可手动填写 ID。")}
                    else{copy(self.locale,"No matching models.","没有匹配的模型。") }));
            } else {
                let mut list = div()
                    .id("custom-discovered-models-list")
                    .debug_selector(|| "custom-discovered-models-list".into())
                    .h(px(260.))
                    .min_h(px(0.))
                    .w_full()
                    .overflow_y_scroll()
                    .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
                    .flex()
                    .flex_col()
                    .bg(p.surface);
                for row in visible {
                    let existing = editor.has_wire(&row.wire);
                    let selected = editor.discovery.selected.contains(&row.wire);
                    list = list.child(self.custom_control(
                        &format!("custom-discovered-model-{}", row.wire),
                        &row.name,
                        if existing {
                            format!(
                                "{} · {}",
                                row.wire,
                                copy(self.locale, "Already in draft", "已在草稿")
                            )
                        } else {
                            row.wire.clone()
                        },
                        existing || selected,
                        idle && !existing,
                        Action::Discovery(DiscoveryAction::Toggle(row.wire.clone())),
                        cx,
                    ));
                }
                section = section
                    .child(list)
                    .child(
                        self.custom_control(
                            "custom-provider-select-models",
                            copy(self.locale, "Select matching models", "选择筛选结果"),
                            copy(
                                self.locale,
                                "Up to 32 total models per provider",
                                "每个服务商合计最多 32 个模型",
                            )
                            .into(),
                            false,
                            idle,
                            Action::Discovery(DiscoveryAction::SelectVisible),
                            cx,
                        ),
                    )
                    .child(
                        self.custom_control(
                            "custom-provider-import-models",
                            copy(
                                self.locale,
                                "Add selected models to draft",
                                "将所选模型加入草稿",
                            ),
                            copy(
                                self.locale,
                                "Existing manual models are kept",
                                "保留已有手动模型",
                            )
                            .into(),
                            false,
                            idle && editor.selected_new_count() > 0,
                            Action::Discovery(DiscoveryAction::Import),
                            cx,
                        ),
                    );
            }
            if editor.discovery.truncated {
                section = section.child(
                    div()
                        .px_4()
                        .py_2()
                        .text_size(px(12.))
                        .line_height(px(18.))
                        .text_color(p.muted)
                        .whitespace_normal()
                        .child(copy(
                            self.locale,
                            "This list is partial. Other model IDs can be entered manually.",
                            "此列表未展示全部模型，其他模型 ID 可手动填写。",
                        )),
                );
            }
            section = section.child(self.custom_control(
                "custom-provider-close-discovery",
                copy(self.locale, "Close fetched list", "收起拉取结果"),
                String::new(),
                false,
                idle,
                Action::Discovery(DiscoveryAction::Close),
                cx,
            ));
        }
        section.into_any_element()
    }
}
