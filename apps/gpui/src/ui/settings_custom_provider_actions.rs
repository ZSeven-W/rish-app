use super::*;

impl Shell {
    pub(super) fn custom_provider_idle(&self) -> bool {
        if self.provider_models.request_pending() {
            return false;
        }
        self.custom_providers.request.is_none()
            && !self.native_form_active
            && !self.loading
            && !self.aux_busy
            && !self.state.is_busy()
            && !self.assistant_writer_lease
            && !self.assistant.form_busy()
    }
    pub(super) fn custom_provider_write_enabled(&self) -> bool {
        self.runtime.is_native()
            && self.custom_providers.loaded
            && !self.custom_providers.needs_reload
            && !self.custom_providers.editor.as_ref().is_some_and(|editor| {
                editor.baseline.is_some() && self.custom_providers.provider(&editor.id).is_none()
            })
            && self.custom_provider_idle()
    }
    pub(in crate::ui) fn reload_custom_providers(&mut self, cx: &mut Context<Self>) {
        if self.runtime.is_native() && self.custom_provider_idle() {
            self.start_custom_provider_request(Operation::Reload, cx);
        }
    }
    pub(in crate::ui) fn refresh_custom_provider_statuses(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || !self.custom_provider_idle()
            || self.custom_providers.needs_reload
        {
            return;
        }
        let next = self
            .custom_providers
            .providers()
            .find(|provider| {
                self.custom_providers
                    .phase(provider["id"].as_str().unwrap())
                    == CredentialPhase::Unknown
            })
            .map(|provider| Operation::Status {
                id: provider["id"].as_str().unwrap().into(),
                profile: provider["configuration"].clone(),
            });
        if let Some(next) = next {
            self.start_custom_provider_request(next, cx);
        }
    }
    pub(super) fn custom_provider_action(&mut self, action: Action, cx: &mut Context<Self>) {
        if let Action::Discovery(action) = action {
            self.custom_discovery_action(action, cx);
            return;
        }
        if !self.custom_provider_idle() {
            return;
        }
        match action {
            Action::Reload => self.reload_custom_providers(cx),
            Action::Cancel => {
                self.custom_providers.editor = None;
            }
            Action::Add => {
                self.custom_providers.editor =
                    Some(ProviderEditor::new(self.custom_providers.revision(), None));
            }
            Action::Edit(id) => {
                if let Some(provider) = self.custom_providers.provider(&id) {
                    let profile = provider["configuration"].clone();
                    self.custom_providers.editor = Some(ProviderEditor::new(
                        self.custom_providers.revision(),
                        Some(provider),
                    ));
                    if self.runtime.is_native() {
                        self.start_custom_provider_request(Operation::Status { id, profile }, cx);
                    }
                }
            }
            Action::Field(field) => {
                if self.runtime.is_native() {
                    self.edit_custom_provider_field(field, cx);
                }
            }
            Action::Protocol(value) | Action::Auth(value) => {
                if let Some(editor) = self.custom_providers.editor.as_mut() {
                    if matches!(action, Action::Protocol(_)) {
                        editor.protocol = value.into();
                    } else {
                        editor.auth = value.into();
                    }
                    editor.error = None;
                    editor.invalidate_discovery();
                }
            }
            Action::FullUrl | Action::Reasoning => {
                if let Some(editor) = self.custom_providers.editor.as_mut() {
                    if matches!(action, Action::FullUrl) {
                        editor.full_url = !editor.full_url;
                    } else {
                        editor.send_reasoning = !editor.send_reasoning;
                    }
                    editor.invalidate_discovery();
                }
            }
            Action::Images(id) => {
                if let Some(model) = self
                    .custom_providers
                    .editor
                    .as_mut()
                    .and_then(|editor| editor.models.iter_mut().find(|model| model["id"] == id))
                {
                    model["supports_images"] = json!(model["supports_images"] != true);
                }
            }
            Action::Save(key) if self.custom_provider_write_enabled() => {
                let Some(editor) = self.custom_providers.editor.as_ref() else {
                    return;
                };
                if editor.revision != self.custom_providers.revision() {
                    self.custom_providers.needs_reload = true;
                    self.custom_providers.error = Some(copy(
                        self.locale,
                        "Provider settings changed. Reload and review your draft before saving.",
                        "服务商设置已变化，请重新加载并核对草稿后保存。",
                    ));
                    cx.notify();
                    return;
                }
                match editor.payload() {
                    Ok(provider) => self.start_custom_provider_request(
                        Operation::Save {
                            editor: editor.token.clone(),
                            provider,
                            key,
                        },
                        cx,
                    ),
                    Err(()) => {
                        self.custom_providers.editor.as_mut().unwrap().error = Some(copy(
                            self.locale,
                            "Enter a name (up to 80 bytes) and API URL. Models can be added after saving.",
                            "请填写名称（最多 80 字节）和 API URL；保存后可添加模型。",
                        ))
                    }
                }
            }
            Action::Remove => {
                if let Some(editor) = self.custom_providers.editor.as_mut() {
                    editor.remove_confirm = true;
                }
            }
            Action::ConfirmRemove if self.custom_provider_write_enabled() => {
                if let Some(editor) = self
                    .custom_providers
                    .editor
                    .as_ref()
                    .filter(|e| e.baseline.is_some())
                {
                    self.start_custom_provider_request(Operation::Remove(editor.id.clone()), cx);
                }
            }
            Action::SetKey | Action::ClearKey if self.custom_provider_write_enabled() => {
                let Some(editor) = self.custom_providers.editor.as_ref() else {
                    return;
                };
                let Some(saved) = self.custom_providers.provider(&editor.id) else {
                    return;
                };
                if !editor
                    .payload()
                    .is_ok_and(|draft| active_payload(saved) == draft)
                {
                    self.custom_providers.editor.as_mut().unwrap().error = Some(copy(
                        self.locale,
                        "Save your provider changes before changing its key.",
                        "请先保存服务商修改，再设置密钥。",
                    ));
                } else {
                    self.start_custom_provider_request(
                        Operation::Key {
                            id: editor.id.clone(),
                            profile: saved["configuration"].clone(),
                            clear: matches!(action, Action::ClearKey),
                        },
                        cx,
                    );
                }
            }
            _ => {}
        }
        cx.notify();
    }
    fn edit_custom_provider_field(&mut self, field: Field, cx: &mut Context<Self>) {
        let Some(editor) = self.custom_providers.editor.as_ref() else {
            return;
        };
        let editor_id = editor.token.clone();
        let (title, initial) = match field {
            Field::Name => (
                copy(self.locale, "Provider name", "服务商名称"),
                editor.name.clone(),
            ),
            Field::Endpoint => ("API URL", editor.endpoint.clone()),
            Field::Models => (
                copy(
                    self.locale,
                    "Model IDs · one per line; optional: ID | name",
                    "模型 ID · 每行一个；可选：ID | 名称",
                ),
                editor.model_text(),
            ),
        };
        let mut command =
            assistant_copy::field_command(title, &initial, field != Field::Name, self.locale, cx);
        if field == Field::Endpoint {
            command.args[0]["max_bytes"] = json!(2048);
        }
        let token = uuid::Uuid::new_v4().to_string();
        self.assistant.form_request = Some(token.clone());
        self.set_inline_native_form(true, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime.call(&command.module,&command.method,Value::Array(command.args)).await;
            let _ = this.update(cx, |this,cx| {
                if this.assistant.form_request.as_deref() != Some(&token) { return; }
                this.assistant.form_request = None;
                this.set_inline_native_form(false,cx);
                let Some(editor) = this.custom_providers.editor.as_mut().filter(|e|e.token == editor_id) else { return; };
                match result {
                    Ok(Value::Null) => {}
                    Ok(Value::String(text)) => {
                        editor.error = None;
                        match field {
                            Field::Name => { editor.name = text; editor.invalidate_discovery(); },
                            Field::Endpoint => { editor.endpoint = text; editor.invalidate_discovery(); },
                            Field::Models => if editor.set_models(&text).is_err() {
                                editor.error = Some(copy(this.locale,
                                    "Use up to 32 unique model IDs, one per line. Optional name follows |.",
                                    "请输入最多 32 个不重复的模型 ID，每行一个；可在 | 后填写名称。"));
                            },
                        }
                    }
                    _ => editor.error = Some(copy(this.locale,"Could not read input. Your draft was kept.","无法读取输入，已保留草稿。")),
                }
                cx.notify();
            });
        }).detach();
    }
    pub(super) fn start_custom_provider_request(
        &mut self,
        operation: Operation,
        cx: &mut Context<Self>,
    ) {
        if self.custom_providers.request.is_some() {
            return;
        }
        let request = ProviderRequest {
            token: uuid::Uuid::new_v4().to_string(),
            revision: self.custom_providers.revision(),
            operation,
        };
        let (method, args) = match &request.operation {
            Operation::Reload => ("listCustomProviders", json!([])),
            Operation::Discover { id, profile, .. } => (
                "discoverCustomProviderModels",
                json!([{"schema_version":1,"id":id,"operation_id":request.token,"expected_profile":profile}]),
            ),
            Operation::CancelDiscovery {
                id, operation_id, ..
            } => (
                "cancelCustomProviderModelDiscovery",
                json!([{"schema_version":1,"id":id,"operation_id":operation_id}]),
            ),
            Operation::Save { provider, .. } => (
                "saveCustomProvider",
                json!([{"schema_version":1,
                "expected_revision":request.revision,"provider":provider}]),
            ),
            Operation::Remove(id) => (
                "removeCustomProvider",
                json!([{"schema_version":1,
                "expected_revision":request.revision,"id":id}]),
            ),
            Operation::Status { id, .. } => (
                "customProviderCredentialStatus",
                json!([{"schema_version":1,"id":id}]),
            ),
            Operation::Key { id, profile, clear } => {
                if *clear {
                    (
                        "clearCustomProviderCredential",
                        json!([{"schema_version":1,"id":id,"expected_profile":profile}]),
                    )
                } else {
                    (
                        "presentCustomProviderCredentialPrompt",
                        json!([{"schema_version":1,"id":id,
                "expected_profile":profile,"locale":self.locale.code()}]),
                    )
                }
            }
        };
        if !matches!(request.operation, Operation::Status { .. }) {
            self.custom_providers.error = None;
        }
        self.custom_providers.request = Some(request.clone());
        if matches!(request.operation, Operation::Key { clear: false, .. }) {
            self.set_inline_native_form(true, cx);
        }
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime.call("LocalRuntime", method, args).await;
            let _ = this.update(cx, |this, cx| {
                this.complete_custom_provider_request(request, result, cx)
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn complete_custom_provider_request(
        &mut self,
        request: ProviderRequest,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.schedule_navigation_resume(cx);
        if self
            .custom_providers
            .request
            .as_ref()
            .is_none_or(|pending| pending.token != request.token)
        {
            return;
        }
        if matches!(request.operation, Operation::Discover { .. }) {
            self.complete_custom_discovery(request, result, cx);
            return;
        }
        if matches!(request.operation, Operation::CancelDiscovery { .. }) {
            self.complete_custom_discovery_cancel(request, result, cx);
            return;
        }
        if !self.custom_providers.current(&request) {
            self.custom_providers.request = None;
            if matches!(request.operation, Operation::Key { clear: false, .. }) {
                self.set_inline_native_form(false, cx);
            }
            self.custom_providers.needs_reload = true;
            self.custom_providers.error = Some(copy(
                self.locale,
                "Provider settings changed. Reload and review your kept draft.",
                "服务商设置已变化，请重新加载并核对保留的草稿。",
            ));
            cx.notify();
            return;
        }
        self.custom_providers.request = None;
        if matches!(request.operation, Operation::Key { clear: false, .. }) {
            self.set_inline_native_form(false, cx);
        }
        let accepted = match (&request.operation, result) {
            (Operation::Reload, Ok(value)) => {
                self.accept_custom_provider_snapshot(value).map(|()| {
                    // Refresh is explicit. Keep all typed draft fields for review and
                    // bind the next save to the newly read registry revision.
                    let revision = self.custom_providers.revision();
                    let baseline = self
                        .custom_providers
                        .editor
                        .as_ref()
                        .and_then(|e| self.custom_providers.provider(&e.id))
                        .cloned();
                    if let Some(editor) = &mut self.custom_providers.editor {
                        let removed = editor.review_snapshot(revision, baseline);
                        editor.error = Some(if removed {
                            copy(self.locale, "This provider was removed elsewhere. Close this draft to add a new provider.",
                                "此服务商已在别处移除，请关闭草稿后添加新服务商。")
                        } else {
                            copy(self.locale, "Reloaded. Review your kept draft before saving.",
                                "已重新加载，请核对保留的草稿后保存。")
                        });
                    }
                })
            }
            (Operation::Save { provider, key, .. }, Ok(value)) => {
                let id = provider["id"].as_str().unwrap();
                if !save_receipt_matches(&value, provider, request.revision) {
                    Err(())
                } else {
                    self.accept_custom_provider_snapshot(value).map(|()| {
                        let saved = self.custom_providers.provider(id).unwrap().clone();
                        self.custom_providers.editor = Some(ProviderEditor::new(
                            self.custom_providers.revision(),
                            Some(&saved),
                        ));
                        if *key && saved["configuration"]["auth_type"] != "none" {
                            self.start_custom_provider_request(
                                Operation::Key {
                                    id: id.into(),
                                    profile: saved["configuration"].clone(),
                                    clear: false,
                                },
                                cx,
                            );
                        } else if self.runtime.is_native() {
                            self.start_custom_provider_request(
                                Operation::Status {
                                    id: id.into(),
                                    profile: saved["configuration"].clone(),
                                },
                                cx,
                            );
                        }
                    })
                }
            }
            (Operation::Remove(id), Ok(value)) => {
                let removed = value["providers"]
                    .as_array()
                    .is_some_and(|ps| ps.iter().any(|p| p["id"] == *id && p["active"] == false));
                if !removed || value["revision"].as_u64() != request.revision.checked_add(1) {
                    Err(())
                } else {
                    self.accept_custom_provider_snapshot(value)
                        .map(|()| self.custom_providers.editor = None)
                }
            }
            (Operation::Status { id, .. }, Ok(value)) => {
                self.accept_custom_provider_status(id, &value, false)
            }
            (Operation::Key { id, profile, clear }, Ok(value)) => {
                let accepted = self.accept_custom_provider_status(id, &value, true);
                if accepted.is_ok() {
                    if value["status"] == "cancelled" {
                        self.custom_providers.error = Some(copy(
                            self.locale,
                            "Key entry cancelled. Saved provider settings were kept.",
                            "已取消密钥输入，服务商设置已保存。",
                        ));
                    }
                    if !*clear {
                        self.start_custom_provider_request(
                            Operation::Status {
                                id: id.clone(),
                                profile: profile.clone(),
                            },
                            cx,
                        );
                    }
                }
                accepted
            }
            _ => Err(()),
        };
        if accepted.is_ok()
            && matches!(
                request.operation,
                Operation::Status { .. } | Operation::Reload
            )
        {
            self.refresh_custom_provider_statuses(cx);
        }
        if accepted.is_err() {
            self.custom_providers.needs_reload = true;
            self.custom_providers.error = Some(copy(
                self.locale,
                "Could not confirm this change. Your draft is kept. Reload before retrying.",
                "无法确认变更结果，已保留草稿。请重新加载后重试。",
            ));
        }
        cx.notify();
    }
    pub(super) fn accept_custom_provider_snapshot(&mut self, value: Value) -> Result<(), ()> {
        // Validate before updating either view. Core retains retired identities.
        if value["schema_version"] != 1 {
            return Err(());
        }
        registry::read_registry(&value).map_err(|_| ())?;
        let mut state = self.state.clone();
        state
            .apply_custom_providers(value.clone())
            .map_err(|_| ())?;
        self.custom_providers
            .install_snapshot(value)
            .map_err(|_| ())?;
        self.state = state;
        Ok(())
    }
    fn accept_custom_provider_status(
        &mut self,
        id: &str,
        value: &Value,
        action: bool,
    ) -> Result<(), ()> {
        if value["schema_version"] != 1 || value["id"] != id {
            return Err(());
        }
        let phase = match value["status"].as_str() {
            Some("configured") => CredentialPhase::Configured,
            Some("missing") if !action => CredentialPhase::Missing,
            Some("not_required") => CredentialPhase::NotRequired,
            Some("cleared") if action => CredentialPhase::Missing,
            Some("cancelled") if action => return Ok(()),
            _ => return Err(()),
        };
        self.custom_providers.status.insert(id.into(), phase);
        Ok(())
    }
}
fn active_payload(provider: &Value) -> Value {
    let mut payload = provider.clone();
    payload["models"] = json!(
        provider["models"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|model| model["active"] == true)
            .cloned()
            .collect::<Vec<_>>()
    );
    payload
}
pub(super) fn save_receipt_matches(value: &Value, expected: &Value, revision: u64) -> bool {
    let Ok(value) = registry::read_registry(value) else {
        return false;
    };
    if value["revision"].as_u64() != revision.checked_add(1) {
        return false;
    }
    let Some(saved) = value["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == expected["id"] && p["active"] == true)
    else {
        return false;
    };
    let mut actual = active_payload(saved);
    let mut expected = expected.clone();
    // Native URL codecs may normalize base URLs to protocol endpoints.
    actual["configuration"]["endpoint_url"] = Value::Null;
    expected["configuration"]["endpoint_url"] = Value::Null;
    // Canonical native records mark the normalized endpoint as a complete URL.
    if actual["configuration"]["full_url"] == true {
        expected["configuration"]["full_url"] = json!(true);
    }
    for payload in [&mut actual, &mut expected] {
        payload["models"]
            .as_array_mut()
            .unwrap()
            .sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    }
    actual == expected
}
