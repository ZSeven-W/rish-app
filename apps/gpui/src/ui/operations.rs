//! Native reply routing for the GPUI shell.
use super::*;

impl Shell {
    pub(super) fn run(&mut self, reply: Reply, command: RuntimeCommand, cx: &mut Context<Self>) {
        if self.assistant_writer_lease
            && matches!(
                reply,
                Reply::Catalog
                    | Reply::CustomProviderCatalog
                    | Reply::Load
                    | Reply::Persist
                    | Reply::Completion
                    | Reply::Cancel
            )
        {
            self.restore_assistant_read_model(cx);
            return;
        }
        if inline_composer::native_form_reply(&reply) {
            self.set_inline_native_form(true, cx);
        }
        let primary = matches!(
            reply,
            Reply::Catalog
                | Reply::CustomProviderCatalog
                | Reply::Load
                | Reply::Persist
                | Reply::Completion
                | Reply::Cancel
        );
        if primary {
            self.loading = true;
        } else {
            self.aux_busy = true;
            self.browser_pending = browser_requests::BrowserReadRequest::from_reply(&reply);
            self.browser.git_actions.pending = match &reply {
                Reply::GitAction(request) => Some(request.clone()),
                _ => None,
            };
            self.git_pending = match &reply {
                Reply::Git(request) => Some(request.clone()),
                _ => None,
            };
        }
        self.notice = None;
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(&command.module, &command.method, Value::Array(command.args))
                .await;
            let _ = this.update(cx, |this, cx| this.accept(reply, result, cx));
        })
        .detach();
        cx.notify();
    }
    pub(super) fn accept(
        &mut self,
        reply: Reply,
        result: Result<Value, String>,
        cx: &mut Context<Self>,
    ) {
        self.schedule_navigation_resume(cx);
        if self.assistant_writer_lease
            && matches!(
                reply,
                Reply::Catalog
                    | Reply::CustomProviderCatalog
                    | Reply::Load
                    | Reply::Persist
                    | Reply::Completion
                    | Reply::Cancel
            )
        {
            return;
        }
        if let Reply::AgentPresentations(command) = reply {
            self.accept_agent_presentation_reply(command, result, cx);
            return;
        }
        if let Reply::Agent(command) = reply {
            self.accept_agent_reply(command, result, cx);
            return;
        }
        if inline_composer::native_form_reply(&reply) {
            self.set_inline_native_form(false, cx);
        }
        if matches!(reply, Reply::DefaultWorkspace) {
            self.accept_default_workspace(result, cx);
            return;
        }
        if let Reply::ConversationWorkspace(request) = reply {
            self.accept_conversation_workspace(request, result, cx);
            return;
        }
        if matches!(
            reply,
            Reply::EntryName(_)
                | Reply::FileEditor(_)
                | Reply::ResumeDraftFolder(_)
                | Reply::FileWritten(_)
                | Reply::DirectoryCreated(_)
        ) {
            self.accept_workspace_edit(reply, result, cx);
            return;
        }
        if let Reply::GitAction(request) = reply {
            self.accept_git_action(request, result, cx);
            return;
        }
        if let Reply::Git(request) = reply {
            self.accept_git_reply(request, result, cx);
            return;
        }
        if let Some(request) = browser_requests::BrowserReadRequest::from_reply(&reply) {
            if self.browser_pending.as_ref() != Some(&request) {
                return;
            }
            self.browser_pending = None;
            self.aux_busy = false;
            if request.generation != self.browser.generation {
                cx.notify();
                return;
            }
        }
        let primary = matches!(
            reply,
            Reply::Catalog
                | Reply::CustomProviderCatalog
                | Reply::Load
                | Reply::Persist
                | Reply::Completion
                | Reply::Cancel
        );
        if primary {
            self.loading = false;
        } else {
            self.aux_busy = false;
        }
        let value = match result {
            Ok(v) => v,
            Err(error) => {
                if matches!(reply, Reply::Completion) {
                    self.settle_failure(&error, cx);
                } else if primary {
                    self.state.record_error(error.clone());
                }
                self.notice = Some(error);
                cx.notify();
                return;
            }
        };
        let persisting = matches!(reply, Reply::Persist);
        let outcome: Result<(), String> = match reply {
            Reply::Catalog => {
                let mut state = self.state.clone();
                state.apply_provider_catalog(value.clone()).and_then(|()| {
                    self.provider_models
                        .install_snapshot(value)
                        .map_err(|_| "Invalid provider model registry".to_owned())?;
                    self.state = state;
                    self.run(
                        Reply::CustomProviderCatalog,
                        RuntimeCommand::new("LocalRuntime", "listCustomProviders", vec![]),
                        cx,
                    );
                    Ok(())
                })
            }
            Reply::CustomProviderCatalog => {
                // Install every known identity before validating old session
                // receipts, without letting an older UI reply regress routing.
                let mut state = self.state.clone();
                state.apply_custom_providers(value.clone()).and_then(|()| {
                    self.custom_providers.install_snapshot(value)?;
                    self.state = state;
                    self.run(Reply::Load, self.state.load_command(), cx);
                    Ok(())
                })
            }
            Reply::Load => self.state.load_snapshot(value).map(|_| {
                match self.state.preferences()["locale"].as_str() {
                    Some("zh-CN") => self.locale = Locale::Zh,
                    Some("en-US") => self.locale = Locale::En,
                    _ => {}
                }
                self.update_placeholders(cx);
                self.refresh_agent_presentations(cx);
                match self.state.recovery_command(&now()) {
                    Ok(Some(command)) => self.run(Reply::Persist, command, cx),
                    Ok(None) => self.resume_agent_or_workspace(cx),
                    Err(error) => {
                        self.state.record_error(error.clone());
                        self.notice = Some(error);
                    }
                }
            }),
            Reply::Persist => self.state.accept_persist(value).map(|next| {
                if let Some(next) = next {
                    if self.state.may_clear_sent_draft() {
                        self.clear_sent_inline_draft(cx);
                    }
                    self.dispatch_continuation(next, cx);
                } else {
                    self.continue_workspace_lifecycle(cx);
                    self.resume_agent_or_workspace(cx);
                    if self.send_after_create
                        && !self.loading
                        && !self.aux_busy
                        && !self.state.is_busy()
                    {
                        self.send_after_create = false;
                        self.send(cx);
                    }
                }
                self.update_placeholders(cx);
                self.refresh_agent_presentations(cx);
            }),
            Reply::Completion => match self.state.accept_completion(value, &now()) {
                Ok(next) => {
                    self.run(Reply::Persist, next, cx);
                    Ok(())
                }
                Err(error) => {
                    self.settle_failure(&error, cx);
                    Err(error)
                }
            },
            Reply::Cancel => {
                self.notice = Some(self.locale.text(Text::Cancelled).into());
                Ok(())
            }
            Reply::Agent(_) | Reply::AgentPresentations(_) => unreachable!(),
            Reply::Workspaces => self.browser.accept_workspaces(value),
            Reply::DefaultWorkspace | Reply::ConversationWorkspace(_) => unreachable!(),
            Reply::Files(_, path) => self.browser.accept_files(value, path),
            Reply::Read(_, path) => self.browser.accept_read(value, path),
            Reply::Git(_) | Reply::GitAction(_) => unreachable!(),
            #[cfg(any(target_os = "ios", target_os = "android"))]
            Reply::WorkspaceName => {
                if let Some(name) = value.as_str().filter(|s| !s.trim().is_empty()) {
                    self.create_workspace(name.to_owned(), cx);
                }
                Ok(())
            }
            Reply::CreatedWorkspace => self.accept_created_workspace(value, cx),
            Reply::EntryName(_)
            | Reply::FileEditor(_)
            | Reply::ResumeDraftFolder(_)
            | Reply::FileWritten(_)
            | Reply::DirectoryCreated(_) => unreachable!(),
            #[cfg(any(target_os = "ios", target_os = "android"))]
            Reply::Rename => {
                if let Some(text) = value.as_str() {
                    self.title_input
                        .update(cx, |input, cx| input.set_text(text.into(), cx));
                    self.save_title(cx);
                }
                Ok(())
            }
        };
        if let Err(error) = outcome {
            if persisting && !self.state.is_busy() {
                self.send_after_create = false;
                self.cancel_inline_send_intent();
                self.conversation_workspace.intent = None;
            }
            if primary {
                self.state.record_error(error.clone());
            }
            self.notice = Some(error);
        }
        self.sync_transcript(cx);
        self.enter_assistant_conversation(cx);
        self.try_assistant_handoff(cx);
        cx.notify();
    }
}
