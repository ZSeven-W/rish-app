use super::*;

impl Shell {
    pub(in crate::ui) fn open_provider_settings(&mut self, cx: &mut Context<Self>) {
        self.navigate(Page::Settings, cx);
        self.settings_expanded = Some(settings::PreferenceGroup::Accounts);
        cx.notify();
    }
    pub(in crate::ui) fn open_provider_models(&mut self, harness: &str, cx: &mut Context<Self>) {
        if !HARNESSES.contains(&harness) || self.native_form_active {
            return;
        }
        if let Some(editor) = &mut self.provider_models.editor {
            if editor.harness == harness {
                return;
            }
            editor.notice = Some(
                copy(
                    self.locale,
                    "Save or close this provider before opening another.",
                    "请先保存或关闭当前服务商，再打开其他服务商。",
                )
                .into(),
            );
            cx.notify();
            return;
        }
        let models = self
            .provider_models
            .snapshot
            .as_ref()
            .map(|v| rows_for(v, harness))
            .unwrap_or_default();
        self.provider_models.editor = Some(ProviderModelEditor::new(
            harness,
            self.provider_models.revision(),
            models,
        ));
        self.settings_expanded = Some(settings::PreferenceGroup::Accounts);
        if self.provider_models.snapshot.is_none() && self.runtime.is_native() {
            self.start_provider_models_request(Operation::Reload, cx);
        }
        cx.notify();
    }
    pub(super) fn provider_models_idle(&self) -> bool {
        !self.loading
            && !self.aux_busy
            && !self.state.is_busy()
            && !self.assistant_writer_lease
            && !self.native_form_active
            && !self.custom_providers.request_pending()
            && !self.provider_models.request_pending()
    }
    pub(in crate::ui) fn provider_models_action(&mut self, action: Action, cx: &mut Context<Self>) {
        match action {
            Action::Close => {
                if self
                    .provider_models
                    .editor
                    .as_ref()
                    .is_some_and(|e| e.field_request.is_some())
                {
                    return;
                }
                if let Some(request) = &self.provider_models.request {
                    if matches!(request.operation, Operation::Discover { .. }) {
                        self.cancel_provider_models_discovery(cx);
                    } else if matches!(
                        request.operation,
                        Operation::Save { .. } | Operation::Credential
                    ) {
                        return;
                    }
                }
                self.provider_models.editor = None;
            }
            Action::CancelFetch => self.cancel_provider_models_discovery(cx),
            Action::Reload => {
                if self.provider_models_idle() {
                    self.start_provider_models_request(Operation::Reload, cx)
                }
            }
            Action::Credential => {
                if self.provider_models_idle() {
                    self.start_provider_models_request(Operation::Credential, cx)
                }
            }
            Action::Fetch => {
                if self.provider_models_idle() {
                    self.start_provider_models_request(Operation::ProfileForDiscovery, cx)
                }
            }
            Action::EditModels => {
                if self.provider_models_idle() {
                    self.edit_provider_models_field(false, cx)
                }
            }
            Action::EditFilter => {
                if self.provider_models_idle() {
                    self.edit_provider_models_field(true, cx)
                }
            }
            Action::ClearFilter => {
                if let Some(editor) = &mut self.provider_models.editor {
                    editor.query.clear();
                }
            }
            Action::ToggleCandidate(id) => {
                if self.provider_models_idle() {
                    if let Some(editor) = &mut self.provider_models.editor {
                        if editor.has_model(&id) || !editor.candidates.iter().any(|m| m.id == id) {
                            return;
                        }
                        if !editor.selected.remove(&id) {
                            if editor.models.len() + editor.selected.len() >= 32 {
                                editor.notice = Some(
                                    copy(
                                        self.locale,
                                        "A provider can have up to 32 selected models.",
                                        "每个服务商最多可配置 32 个模型。",
                                    )
                                    .into(),
                                );
                            } else {
                                editor.selected.insert(id);
                            }
                        }
                    }
                }
            }
            Action::Import => {
                if self.provider_models_idle() {
                    if let Some(editor) = &mut self.provider_models.editor {
                        editor.notice = Some(match editor.import_selected() {
                            Ok(n) => {
                                if self.locale == Locale::Zh {
                                    format!("已添加 {n} 个模型到草稿，保存后即可选择。")
                                } else {
                                    format!(
                                        "Added {n} models to the draft. Save to make them selectable."
                                    )
                                }
                            }
                            Err(()) => copy(
                                self.locale,
                                "A provider can have up to 32 selected models.",
                                "每个服务商最多可配置 32 个模型。",
                            )
                            .into(),
                        });
                    }
                }
            }
            Action::ToggleImages(id) => {
                if self.provider_models_idle() {
                    if let Some(model) = self
                        .provider_models
                        .editor
                        .as_mut()
                        .and_then(|e| e.models.iter_mut().find(|m| m.id == id))
                    {
                        model.images = !model.images;
                    }
                }
            }
            Action::Save => {
                if self.provider_models_idle() {
                    let Some(editor) = &self.provider_models.editor else {
                        return;
                    };
                    if editor.needs_reload {
                        return;
                    }
                    let models: Vec<_> = editor.models.iter().map(ModelRow::value).collect();
                    let payload = json!({"schema_version":1,"harness_id":editor.harness,
                        "expected_revision":editor.revision,"models":models});
                    let valid = self
                        .provider_models
                        .snapshot
                        .as_ref()
                        .is_some_and(|snapshot| {
                            rish_shell_core::provider_model_catalog::save_registry(
                                snapshot,
                                &payload,
                                &Value::Null,
                                &[],
                            )
                            .is_ok()
                        });
                    if !valid {
                        self.provider_models.editor.as_mut().unwrap().notice = Some(copy(self.locale,
                            "Check model IDs and labels. An ID already owned by another provider needs a separate custom provider configuration.",
                            "请检查模型 ID 和名称。已属于另一服务商的 ID，请通过独立的自定义服务商配置。").into());
                        cx.notify();
                        return;
                    }
                    let operation = Operation::Save {
                        models,
                        revision: editor.revision,
                    };
                    self.start_provider_models_request(operation, cx);
                }
            }
        }
        self.schedule_navigation_resume(cx);
        cx.notify();
    }
    fn edit_provider_models_field(&mut self, filter: bool, cx: &mut Context<Self>) {
        let Some(editor) = &mut self.provider_models.editor else {
            return;
        };
        let token = uuid::Uuid::new_v4().to_string();
        let editor_token = editor.token.clone();
        let initial = if filter {
            editor.query.clone()
        } else {
            editor.model_text()
        };
        editor.field_request = Some(token.clone());
        let title = if filter {
            copy(self.locale, "Search models", "搜索模型")
        } else {
            copy(
                self.locale,
                "Model IDs · one per line, optional | name",
                "模型 ID · 每行一个，可填写 | 名称",
            )
        };
        let command = assistant_copy::field_command(title, &initial, !filter, self.locale, cx);
        self.set_inline_native_form(true, cx);
        let runtime = self.runtime.clone();
        cx.spawn(async move|this,cx|{
            let result=runtime.call(&command.module,&command.method,Value::Array(command.args)).await;
            let _=this.update(cx,|this,cx|{
                this.set_inline_native_form(false,cx);
                this.schedule_navigation_resume(cx);
                let Some(editor)=this.provider_models.editor.as_mut().filter(|e|e.token==editor_token&&e.field_request.as_deref()==Some(&token))else{return;};
                editor.field_request=None;
                match result {
                    Ok(Value::String(text)) if filter=>editor.query=text,
                    Ok(Value::String(text))=>{
                        editor.notice=if editor.set_models(&text).is_err(){Some(copy(this.locale,
                            "Use distinct model IDs, one per line. Labels are optional; at most 32 models.",
                            "每行填写一个不重复的模型 ID，可附加名称；最多 32 个模型。").into())}else{None};
                    },
                    Ok(Value::Null)=>{},
                    _=>editor.notice=Some(copy(this.locale,"Could not edit the list. Your draft is kept.","编辑未完成，原草稿已保留。").into()),
                }
                this.schedule_navigation_resume(cx);cx.notify();
            });
        }).detach();
    }
    fn start_provider_models_request(&mut self, operation: Operation, cx: &mut Context<Self>) {
        if !self.runtime.is_native()
            || self.provider_models.request.is_some()
            || self.provider_models.cancel.is_some()
        {
            return;
        }
        let Some(editor) = &mut self.provider_models.editor else {
            return;
        };
        let request = Request {
            token: uuid::Uuid::new_v4().to_string(),
            editor: editor.token.clone(),
            harness: editor.harness.clone(),
            operation,
        };
        let (method, args) = match &request.operation {
            Operation::Reload => ("listProviderModels", json!([])),
            Operation::ProfileForDiscovery => ("providerConfiguration", json!([request.harness])),
            Operation::Discover { profile } => (
                "discoverProviderModels",
                json!([{"schema_version":1,"harness_id":request.harness,"operation_id":request.token,"expected_profile":profile}]),
            ),
            Operation::Save { models, revision } => (
                "saveProviderModels",
                json!([{"schema_version":1,"harness_id":request.harness,"expected_revision":revision,"models":models}]),
            ),
            Operation::Credential => (
                "presentCredentialPromptForSlot",
                json!([credential_slot(&request.harness), self.locale.code()]),
            ),
        };
        editor.notice = None;
        self.provider_models.request = Some(request.clone());
        if matches!(request.operation, Operation::Credential) {
            self.set_inline_native_form(true, cx);
        }
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime.call("LocalRuntime", method, args).await;
            let _ = this.update(cx, |this, cx| {
                this.complete_provider_models_request(request, result, cx)
            });
        })
        .detach();
        cx.notify();
    }
    pub(in crate::ui) fn accept_provider_models_snapshot(
        &mut self,
        value: Value,
    ) -> Result<(), ()> {
        let value = validated_registry(&value)?;
        if self
            .provider_models
            .snapshot
            .as_ref()
            .is_some_and(|old| old["revision"].as_u64() > value["revision"].as_u64())
        {
            return Err(());
        }
        let mut state = self.state.clone();
        state
            .apply_provider_catalog(value.clone())
            .map_err(|_| ())?;
        self.provider_models.install_snapshot(value)?;
        self.state = state;
        Ok(())
    }
    pub(in crate::ui) fn complete_provider_models_request(
        &mut self,
        request: Request,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.schedule_navigation_resume(cx);
        if self
            .provider_models
            .request
            .as_ref()
            .is_none_or(|pending| pending.token != request.token)
        {
            return;
        }
        self.provider_models.request = None;
        if matches!(request.operation, Operation::Credential) {
            self.set_inline_native_form(false, cx);
        }
        if self.provider_models.current_editor(&request).is_none() {
            cx.notify();
            return;
        }
        match request.operation.clone() {
            Operation::ProfileForDiscovery => match result {
                Ok(profile) if profile["harness_id"] == request.harness => {
                    self.start_provider_models_request(Operation::Discover { profile }, cx)
                }
                _ => {
                    self.provider_models
                        .current_editor(&request)
                        .unwrap()
                        .notice = Some(discovery_failure(
                        self.locale,
                        "E_PROVIDER_CONFIGURATION_CHANGED",
                    ))
                }
            },
            Operation::Discover { .. } => {
                let parsed = result.and_then(|value| {
                    parse_discovery(&request, &value)
                        .map_err(|_| "E_PROVIDER_MODEL_DISCOVERY_INVALID".into())
                });
                let editor = self.provider_models.current_editor(&request).unwrap();
                match parsed {
                    Ok((rows, truncated)) => {
                        editor.candidates = rows;
                        editor.truncated = truncated;
                        editor.discovered = true;
                        editor.selected.clear();
                        editor.scroll = Default::default();
                        if editor.candidates.is_empty() {
                            editor.notice = Some(
                                copy(
                                    self.locale,
                                    "No models were returned. You can add model IDs manually.",
                                    "服务商没有返回模型，可手动填写模型 ID。",
                                )
                                .into(),
                            );
                        }
                    }
                    Err(error) => editor.notice = Some(discovery_failure(self.locale, &error)),
                }
            }
            Operation::Reload => {
                match result.and_then(|v| {
                    self.accept_provider_models_snapshot(v)
                        .map_err(|_| "invalid registry".into())
                }) {
                    Ok(()) => {
                        let revision = self.provider_models.revision();
                        let models = rows_for(
                            self.provider_models.snapshot.as_ref().unwrap(),
                            &request.harness,
                        );
                        let editor = self.provider_models.current_editor(&request).unwrap();
                        let edited = editor.models != editor.baseline;
                        editor.revision = revision;
                        editor.baseline = models.clone();
                        if !edited {
                            editor.models = models;
                        }
                        editor.needs_reload = false;
                        editor.notice=edited.then(||copy(self.locale,"Catalog refreshed. Your edited list is kept; review before saving.","目录已刷新，编辑草稿已保留，请核对后保存。").into());
                    }
                    Err(_) => {
                        let editor = self.provider_models.current_editor(&request).unwrap();
                        editor.needs_reload = true;
                        editor.notice = Some(
                            copy(
                                self.locale,
                                "Could not load the catalog. Your saved models and draft are kept.",
                                "暂时无法读取模型目录，已保存模型和草稿均已保留。",
                            )
                            .into(),
                        );
                    }
                }
            }
            Operation::Save { models, .. } => {
                let accepted = result.and_then(|v| {
                    let rows = rows_for(&v, &request.harness)
                        .iter()
                        .map(ModelRow::value)
                        .collect::<Vec<_>>();
                    if rows != models {
                        return Err("unconfirmed save".into());
                    }
                    self.accept_provider_models_snapshot(v)
                        .map_err(|_| "unconfirmed save".into())
                });
                let revision = self.provider_models.revision();
                let editor = self.provider_models.current_editor(&request).unwrap();
                if accepted.is_ok() {
                    editor.revision = revision;
                    editor.baseline = editor.models.clone();
                    editor.needs_reload = false;
                    editor.notice = Some(
                        copy(
                            self.locale,
                            "Models saved. Choose a default model when you are ready.",
                            "模型已保存，可以选择默认模型了。",
                        )
                        .into(),
                    );
                } else {
                    editor.needs_reload = true;
                    editor.notice=Some(copy(self.locale,"The save could not be confirmed. Your draft is kept; reload and review before retrying.","尚未确认保存成功，草稿已保留；请刷新目录、核对后重试。").into());
                }
            }
            Operation::Credential => {
                let configured = result.is_ok_and(|v| v == true);
                let editor = self.provider_models.current_editor(&request).unwrap();
                editor.notice = Some(
                    if configured {
                        copy(
                            self.locale,
                            "Key saved. Fetch models to check this provider.",
                            "密钥已保存，可以拉取模型。",
                        )
                    } else {
                        copy(
                            self.locale,
                            "Key entry closed. Your model list is unchanged.",
                            "密钥设置已关闭，模型列表未变。",
                        )
                    }
                    .into(),
                );
                if configured {
                    self.refresh_subscription_after_credentials(cx);
                }
            }
        }
        cx.notify();
    }
    fn cancel_provider_models_discovery(&mut self, cx: &mut Context<Self>) {
        let Some(request) = self.provider_models.request.clone() else {
            return;
        };
        if matches!(request.operation, Operation::ProfileForDiscovery) {
            self.provider_models.request = None;
            return;
        }
        if !matches!(request.operation, Operation::Discover { .. })
            || self.provider_models.cancel.is_some()
        {
            return;
        }
        self.provider_models.request = None;
        let cancel = CancelRequest {
            token: uuid::Uuid::new_v4().to_string(),
            editor: request.editor,
            operation_id: request.token,
            harness: request.harness,
        };
        self.provider_models.cancel = Some(cancel.clone());
        if let Some(editor) = &mut self.provider_models.editor {
            editor.notice =
                Some(copy(self.locale, "Cancelling model fetch…", "正在取消模型拉取…").into());
        }
        let runtime = self.runtime.clone();
        cx.spawn(async move|this,cx|{
            let result=runtime.call("LocalRuntime","cancelProviderModelDiscovery",json!([{"schema_version":1,"harness_id":cancel.harness,"operation_id":cancel.operation_id}])).await;
            let _=this.update(cx,|this,cx|{
                this.schedule_navigation_resume(cx);
                if this.provider_models.cancel.as_ref().is_none_or(|current|current.token!=cancel.token){return;}
                this.provider_models.cancel=None;
                if let Some(editor)=this.provider_models.editor.as_mut().filter(|e|e.harness==cancel.harness&&e.token==cancel.editor){
                    let confirmed=result.is_ok_and(|v|v["schema_version"]==1&&v["harness_id"]==cancel.harness&&v["operation_id"]==cancel.operation_id&&matches!(v["status"].as_str(),Some("cancelled"|"idle")));
                    editor.notice=Some(copy(this.locale,if confirmed{"Fetch cancelled. Your models are unchanged."}else{"Cancellation could not be confirmed. Your models are kept; late results will be ignored."},if confirmed{"已取消拉取，模型未变。"}else{"尚未确认取消结果，模型已保留，旧回包不会覆盖草稿。"}).into());
                }
                this.schedule_navigation_resume(cx);cx.notify();
            });
        }).detach();
    }
}

pub(super) fn parse_discovery(
    request: &Request,
    value: &Value,
) -> Result<(Vec<ModelRow>, bool), ()> {
    if value.as_object().is_none_or(|o| o.len() != 5)
        || value["schema_version"] != 1
        || value["harness_id"] != request.harness
        || value["operation_id"] != request.token
    {
        return Err(());
    }
    let truncated = value["truncated"].as_bool().ok_or(())?;
    let candidates =
        rish_shell_core::provider_model_discovery::validate_candidates(&value["models"])
            .map_err(|_| ())?;
    let rows = candidates
        .as_array()
        .ok_or(())?
        .iter()
        .map(|m| ModelRow {
            id: m["wire_model"].as_str().unwrap().into(),
            name: m["name"].as_str().unwrap().into(),
            images: m["supports_images"].as_bool().unwrap(),
        })
        .collect();
    Ok((rows, truncated))
}
fn discovery_failure(locale: Locale, error: &str) -> String {
    let (en, zh) = if error.contains("CREDENTIAL") || error.contains("AUTH") {
        (
            "Set a valid API key, then fetch again. You can also add models manually.",
            "请先配置有效的 API 密钥再拉取，也可以手动添加模型。",
        )
    } else if error.contains("UNSUPPORTED") || error.contains("HTTP") {
        (
            "This provider did not return a model list. Add the model IDs you use manually.",
            "服务商暂未返回模型列表，可以手动添加你要使用的模型 ID。",
        )
    } else if error.contains("CONFIGURATION_CHANGED") {
        (
            "Provider settings changed. Fetch again after saving them; your models are kept.",
            "服务商配置已变化，请保存后重新拉取；现有模型已保留。",
        )
    } else if error.contains("BUSY") {
        (
            "A request is still running. Fetch after it finishes; your models are kept.",
            "当前请求仍在执行，完成后可拉取；现有模型已保留。",
        )
    } else {
        (
            "Could not fetch models right now. Your list is kept; retry later or add a model manually.",
            "暂时无法拉取模型，现有列表已保留；稍后重试或手动添加即可。",
        )
    };
    copy(locale, en, zh).into()
}
