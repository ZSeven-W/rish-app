//! Fetching is explicit and read-only. Import changes only the current draft.
use super::*;

#[derive(Clone)]
pub(super) struct DiscoveredModel {
    pub wire: String,
    pub name: String,
    pub images: bool,
}
#[derive(Clone, Default)]
pub(super) struct ModelDiscovery {
    pub generation: u64,
    pub rows: Vec<DiscoveredModel>,
    pub selected: BTreeSet<String>,
    pub query: String,
    pub loaded: bool,
    pub truncated: bool,
    pub error: Option<&'static str>,
    pub notice: Option<&'static str>,
    pub profile: Option<Value>,
}
#[derive(Clone)]
pub(super) enum DiscoveryAction {
    Fetch,
    CancelWait,
    Filter,
    ClearFilter,
    Toggle(String),
    SelectVisible,
    Import,
    Close,
}
impl ModelDiscovery {
    pub fn visible(&self) -> impl Iterator<Item = &DiscoveredModel> {
        let query = self.query.to_lowercase();
        self.rows.iter().filter(move |row| {
            query.is_empty()
                || row.wire.to_lowercase().contains(&query)
                || row.name.to_lowercase().contains(&query)
        })
    }
    pub(super) fn parse(
        id: &str,
        operation_id: &str,
        value: &Value,
    ) -> Result<(Vec<DiscoveredModel>, bool), ()> {
        let object = value.as_object().ok_or(())?;
        if object.len() != 5
            || value["schema_version"] != 1
            || value["id"] != id
            || value["operation_id"] != operation_id
        {
            return Err(());
        }
        let truncated = value["truncated"].as_bool().ok_or(())?;
        let models =
            rish_shell_core::provider_model_discovery::validate_candidates(&value["models"])
                .map_err(|_| ())?;
        let rows = models
            .as_array()
            .ok_or(())?
            .iter()
            .map(|model| DiscoveredModel {
                wire: model["wire_model"].as_str().unwrap().into(),
                name: model["name"].as_str().unwrap().into(),
                images: model["supports_images"].as_bool().unwrap(),
            })
            .collect();
        Ok((rows, truncated))
    }
}
impl ProviderEditor {
    pub(super) fn invalidate_discovery(&mut self) {
        let generation = self.discovery.generation.wrapping_add(1);
        self.discovery = ModelDiscovery {
            generation,
            ..Default::default()
        };
    }
    pub(super) fn discovery_profile_matches(&self, saved: &Value) -> bool {
        let Ok(mut payload) = self.payload() else {
            return false;
        };
        // A staged model list is not an endpoint/authentication change.
        payload["configuration"]["model_mappings"] = saved["model_mappings"].clone();
        payload["configuration"] == *saved
    }
    pub(super) fn has_wire(&self, wire: &str) -> bool {
        self.models.iter().any(|model| model["wire_model"] == wire)
    }
    pub(super) fn selected_new_count(&self) -> usize {
        self.discovery
            .selected
            .iter()
            .filter(|wire| !self.has_wire(wire))
            .count()
    }
    pub(super) fn select_discovered(&mut self, wire: &str, locale: Locale) {
        if self.has_wire(wire) || !self.discovery.rows.iter().any(|row| row.wire == wire) {
            return;
        }
        if self.discovery.selected.remove(wire) {
            self.discovery.error = None;
            return;
        }
        if self.models.len() + self.selected_new_count() >= registry::MAX_ACTIVE_MODELS_PER_PROVIDER
        {
            self.discovery.error = Some(copy(
                locale,
                "A provider can contain up to 32 models. Deselect a model first.",
                "每个服务商最多 32 个模型，请先取消部分选择。",
            ));
            return;
        }
        self.discovery.selected.insert(wire.into());
        self.discovery.error = None;
    }
    pub(super) fn select_visible_discovered(&mut self, locale: Locale) {
        let wires = self
            .discovery
            .visible()
            .map(|row| row.wire.clone())
            .collect::<Vec<_>>();
        for wire in wires {
            if !self.has_wire(&wire) && !self.discovery.selected.contains(&wire) {
                self.select_discovered(&wire, locale);
            }
        }
    }
    pub(super) fn import_discovered(&mut self, locale: Locale) {
        let rows = self
            .discovery
            .rows
            .iter()
            .filter(|row| self.discovery.selected.contains(&row.wire))
            .cloned()
            .collect::<Vec<_>>();
        for row in rows {
            if self.has_wire(&row.wire) {
                continue;
            }
            if self.models.len() >= registry::MAX_ACTIVE_MODELS_PER_PROVIDER {
                break;
            }
            let name = bounded_model_name(&row.name);
            self.models
                .push(json!({"id":uuid::Uuid::new_v4().to_string(),"name":name,
                "wire_model":row.wire,"supports_images":row.images,"active":true}));
        }
        self.discovery.selected.clear();
        self.discovery.error = None;
        self.discovery.notice = Some(copy(
            locale,
            "Added to your draft. Save the provider to use these models.",
            "已加入草稿，保存服务商后即可使用。",
        ));
    }
}
impl Shell {
    pub(super) fn custom_discovery_fetch_enabled(&self, editor: &ProviderEditor) -> bool {
        self.custom_provider_write_enabled()
            && self
                .custom_providers
                .provider(&editor.id)
                .is_some_and(|saved| editor.discovery_profile_matches(&saved["configuration"]))
    }
    pub(super) fn custom_discovery_action(
        &mut self,
        action: DiscoveryAction,
        cx: &mut Context<Self>,
    ) {
        if matches!(action, DiscoveryAction::CancelWait) {
            let Some(cancel) = self.prepare_custom_discovery_cancel() else {
                return;
            };
            self.start_custom_provider_request(cancel, cx);
            return;
        }
        if !self.custom_provider_idle() {
            return;
        }
        if matches!(action, DiscoveryAction::Fetch) {
            let Some(editor) = self.custom_providers.editor.as_ref() else {
                return;
            };
            if !self.custom_discovery_fetch_enabled(editor) {
                return;
            }
            let id = editor.id.clone();
            let profile = self.custom_providers.provider(&id).unwrap()["configuration"].clone();
            let editor = self.custom_providers.editor.as_mut().unwrap();
            editor.invalidate_discovery();
            editor.discovery.profile = Some(profile.clone());
            let operation = Operation::Discover {
                id,
                profile,
                editor: editor.token.clone(),
                generation: editor.discovery.generation,
            };
            self.start_custom_provider_request(operation, cx);
            return;
        }
        if matches!(action, DiscoveryAction::Filter) {
            if self.runtime.is_native() {
                self.custom_discovery_filter(cx);
            }
            return;
        }
        let current = self.custom_providers.editor.as_ref().is_some_and(|editor| {
            editor.discovery.profile.as_ref().is_some_and(|profile| {
                editor.discovery_profile_matches(profile)
                    && self
                        .custom_providers
                        .provider(&editor.id)
                        .is_some_and(|saved| saved["configuration"] == *profile)
            })
        });
        let Some(editor) = &mut self.custom_providers.editor else {
            return;
        };
        match action {
            DiscoveryAction::ClearFilter => editor.discovery.query.clear(),
            DiscoveryAction::Close => editor.invalidate_discovery(),
            DiscoveryAction::Toggle(wire) if current => {
                editor.select_discovered(&wire, self.locale)
            }
            DiscoveryAction::SelectVisible if current => {
                editor.select_visible_discovered(self.locale)
            }
            DiscoveryAction::Import if current => editor.import_discovered(self.locale),
            _ => {}
        }
        cx.notify();
    }
    pub(super) fn prepare_custom_discovery_cancel(&mut self) -> Option<Operation> {
        let pending = self.custom_providers.request.as_ref()?;
        let Operation::Discover { id, editor, .. } = &pending.operation else {
            return None;
        };
        let (id, operation_id, token) = (id.clone(), pending.token.clone(), editor.clone());
        let draft = self
            .custom_providers
            .editor
            .as_mut()
            .filter(|draft| draft.token == token)?;
        draft.invalidate_discovery();
        draft.discovery.notice = Some(copy(
            self.locale,
            "Cancelling model request…",
            "正在取消模型请求…",
        ));
        let generation = draft.discovery.generation;
        self.custom_providers.request = None;
        Some(Operation::CancelDiscovery {
            id,
            operation_id,
            editor: token,
            generation,
        })
    }
    pub(super) fn complete_custom_discovery_cancel(
        &mut self,
        request: ProviderRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.schedule_navigation_resume(cx);
        let Operation::CancelDiscovery {
            id,
            operation_id,
            editor,
            generation,
        } = &request.operation
        else {
            return;
        };
        if self
            .custom_providers
            .request
            .as_ref()
            .is_none_or(|pending| pending.token != request.token)
        {
            return;
        }
        self.custom_providers.request = None;
        let Some(draft) = self.custom_providers.editor.as_mut().filter(|draft| {
            draft.id == *id && draft.token == *editor && draft.discovery.generation == *generation
        }) else {
            cx.notify();
            return;
        };
        let status = result
            .as_ref()
            .ok()
            .filter(|value| {
                value.as_object().is_some_and(|object| object.len() == 4)
                    && value["schema_version"] == 1
                    && value["id"] == *id
                    && value["operation_id"] == *operation_id
            })
            .and_then(|value| value["status"].as_str());
        draft.discovery.notice = match status {
            Some("cancelled") => Some(copy(
                self.locale,
                "Model request cancelled. Your draft is unchanged.",
                "已取消模型请求，草稿未变更。",
            )),
            Some("idle") => Some(copy(
                self.locale,
                "The model request has ended. Your draft is unchanged.",
                "模型请求已结束，草稿未变更。",
            )),
            _ => None,
        };
        if draft.discovery.notice.is_none() {
            draft.discovery.error = Some(copy(
                self.locale,
                "Could not confirm cancellation. Your draft is unchanged; the old result will be ignored.",
                "无法确认取消结果，草稿未变更；旧请求结果将被忽略。",
            ));
        }
        cx.notify();
    }
    pub(super) fn complete_custom_discovery(
        &mut self,
        request: ProviderRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.schedule_navigation_resume(cx);
        let Operation::Discover {
            id,
            editor,
            generation,
            profile,
        } = &request.operation
        else {
            return;
        };
        if self
            .custom_providers
            .request
            .as_ref()
            .is_none_or(|pending| pending.token != request.token)
        {
            return;
        }
        self.custom_providers.request = None;
        let saved_matches = self.custom_providers.revision() == request.revision
            && self
                .custom_providers
                .provider(id)
                .is_some_and(|saved| saved["configuration"] == *profile);
        let Some(draft) = self.custom_providers.editor.as_mut().filter(|draft| {
            draft.id == *id && draft.token == *editor && draft.discovery.generation == *generation
        }) else {
            cx.notify();
            return;
        };
        if !saved_matches || !draft.discovery_profile_matches(profile) {
            draft.invalidate_discovery();
            draft.discovery.error = Some(copy(
                self.locale,
                "Provider settings changed. Save them and fetch again.",
                "服务商设置已变化，请保存后重新拉取。",
            ));
            cx.notify();
            return;
        }
        match result {
            Ok(value) => match ModelDiscovery::parse(id, &request.token, &value) {
                Ok((rows, truncated)) => {
                    draft.discovery.rows = rows;
                    draft.discovery.truncated = truncated;
                    draft.discovery.loaded = true;
                    draft.discovery.error = None;
                }
                Err(()) => draft.discovery.error = Some(discovery_failure(self.locale, "")),
            },
            Err(error) => draft.discovery.error = Some(discovery_failure(self.locale, &error)),
        }
        cx.notify();
    }
    fn custom_discovery_filter(&mut self, cx: &mut Context<Self>) {
        let Some(editor) = self.custom_providers.editor.as_ref() else {
            return;
        };
        let editor_id = editor.token.clone();
        let generation = editor.discovery.generation;
        let command = assistant_copy::field_command(
            copy(self.locale, "Search models", "搜索模型"),
            &editor.discovery.query,
            false,
            self.locale,
            cx,
        );
        let token = uuid::Uuid::new_v4().to_string();
        self.assistant.form_request = Some(token.clone());
        self.set_inline_native_form(true, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.assistant.form_request.as_deref() != Some(&token) {
                    return;
                }
                this.assistant.form_request = None;
                this.set_inline_native_form(false, cx);
                if let Some(editor) = this.custom_providers.editor.as_mut().filter(|editor| {
                    editor.token == editor_id && editor.discovery.generation == generation
                }) {
                    if let Ok(Value::String(text)) = result {
                        editor.discovery.query = text;
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}
fn discovery_failure(locale: Locale, error: &str) -> &'static str {
    if error.contains("E_PROVIDER_CONFIGURATION_CHANGED") || error.contains("CREDENTIAL_CHANGED") {
        copy(
            locale,
            "The provider settings or key changed. Reload the provider before fetching again.",
            "服务商设置或密钥已变化，请重新加载服务商后再拉取。",
        )
    } else if error.contains("DISCOVERY_CREDENTIAL")
        || error.contains("CREDENTIAL_UNAVAILABLE")
        || error.contains("KEY_REQUIRED")
        || error.contains("CREDENTIAL_MISSING")
    {
        copy(
            locale,
            "Set the provider’s key, then fetch models again. You can also enter model IDs manually.",
            "请先设置服务商密钥，再拉取模型；也可手动填写模型 ID。",
        )
    } else if error.contains("DISCOVERY_AUTH") {
        copy(
            locale,
            "The provider did not accept the key. Check its key and permissions, or enter model IDs manually.",
            "服务商未接受此密钥，请检查密钥和权限；也可手动填写模型 ID。",
        )
    } else if error.contains("DISCOVERY_UNSUPPORTED") {
        copy(
            locale,
            "This endpoint does not provide a supported model list. Enter model IDs manually.",
            "此地址不支持拉取模型列表，请手动填写模型 ID。",
        )
    } else if error.contains("DISCOVERY_LIMIT") {
        copy(
            locale,
            "The model list exceeds the supported limits. Enter the model IDs you need manually.",
            "模型列表超出支持的范围，请手动填写所需的模型 ID。",
        )
    } else if error.contains("DISCOVERY_TIMEOUT") {
        copy(
            locale,
            "Fetching models timed out. Your draft is unchanged; retry or enter model IDs manually.",
            "拉取模型超时，草稿未变更；请重试或手动填写模型 ID。",
        )
    } else if error.contains("DISCOVERY_CANCELLED") {
        copy(
            locale,
            "Model request cancelled. Your draft is unchanged.",
            "已取消模型请求，草稿未变更。",
        )
    } else if error.contains("DISCOVERY_REDIRECT") {
        copy(
            locale,
            "The provider requested a different URL. Check the saved API URL or enter model IDs manually.",
            "服务商要求跳转到其他地址，请核对已保存的 API URL；也可手动填写模型 ID。",
        )
    } else if error.contains("E_COMPLETION_BUSY") {
        copy(
            locale,
            "Another device request is running. Try again after it finishes.",
            "设备正在执行其他请求，请结束后重试。",
        )
    } else if error.contains("DISCOVERY_INVALID") {
        copy(
            locale,
            "The provider returned an unreadable model list. You can enter model IDs manually.",
            "无法读取服务商返回的模型列表，请手动填写模型 ID。",
        )
    } else if error.contains("DISCOVERY_HTTP") {
        copy(
            locale,
            "The provider could not return its model list. Retry later or enter model IDs manually.",
            "服务商暂未返回模型列表，请稍后重试或手动填写模型 ID。",
        )
    } else if error.contains("DISCOVERY_TRANSPORT") {
        copy(
            locale,
            "Could not reach the provider. Check the network and API URL, or enter model IDs manually.",
            "无法连接服务商，请检查网络和 API URL；也可手动填写模型 ID。",
        )
    } else {
        copy(
            locale,
            "Could not fetch models from this provider. Your draft is unchanged; you can enter model IDs manually.",
            "未能从此服务商拉取模型，草稿未变更；仍可手动填写模型 ID。",
        )
    }
}
