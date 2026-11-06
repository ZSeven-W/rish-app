//! Platform facts and explicit opt-ins; eligibility never means an OS grant.
use super::*;
use crate::icons::{Icon, icon};
use serde_json::json;

pub(super) type VisibilitySignature = (Option<String>, &'static str);

// This describes display state only. It does not select a conversation or
// acquire the session writer. Record attempts before dispatch, including failures,
// so a missing native service cannot trigger a request on every rendered frame.
fn next_visibility(
    previous: &mut Option<VisibilitySignature>,
    page: Page,
    chat: Option<&str>,
    selected_task: Option<&str>,
    active_panel: Option<&str>,
    locale: Locale,
) -> Option<Value> {
    let conversation = match page {
        Page::Chat => chat,
        Page::Assistant => active_panel.or(selected_task).or(chat),
        Page::Settings | Page::Files | Page::Git => None,
    };
    let signature = (conversation.map(str::to_owned), locale.code());
    if previous.as_ref() == Some(&signature) {
        return None;
    }
    let request = json!([{"schema_version":1,"op":"visible",
        "conversationId":signature.0,"locale":signature.1}]);
    *previous = Some(signature);
    Some(request)
}

impl Shell {
    pub(super) fn sync_assistant_visibility(&mut self, content_width: f32, cx: &mut Context<Self>) {
        if !self.runtime.is_native() {
            return;
        }
        let task_panel_visible = self.assistant.panel
            == assistant_memory_state::AssistantPanel::Tasks
            && (content_width >= assistant_chat_view::TASK_PANEL_BREAKPOINT
                || self.assistant.tasks_open);
        let chat_visible =
            self.page != Page::Assistant || self.assistant_chat_visible(content_width);
        let selected = self
            .assistant
            .selected_task()
            .filter(|_| task_panel_visible && self.assistant.editor.is_none());
        let active = self.assistant.snapshot.state.as_ref().filter(|state| {
            self.assistant_writer_lease
                && state.agent_view().is_some()
                && (content_width >= assistant_chat_view::TASK_PANEL_BREAKPOINT
                    || !self.assistant.tasks_open)
        });
        let Some(request) = next_visibility(
            &mut self.assistant_visible_signature,
            self.page,
            self.state.active_conversation_id().filter(|_| chat_visible),
            selected.map(|task| task.conversation_id.as_str()),
            active.and_then(|state| state.active_conversation_id()),
            self.locale,
        ) else {
            return;
        };
        let runtime = self.runtime.clone();
        cx.spawn(async move |_, _| {
            if runtime
                .call("TaskExperience", "handle", request)
                .await
                .is_err()
            {
                // Notification display failure must never change a task result.
                log::warn!("Could not update native task visibility");
            }
        })
        .detach();
    }

    pub(super) fn load_assistant_platform(&mut self, cx: &mut Context<Self>) {
        if !self.runtime.is_native() || self.assistant_platform_pending {
            return;
        }
        self.assistant_platform_pending = true;
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = runtime
                .call(
                    "TaskExperience",
                    "handle",
                    json!([{"schema_version":1,"op":"settings"}]),
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                this.assistant_platform_pending = false;
                match result {
                    Ok(value) => this.assistant_platform = Some(value),
                    Err(error) => this.assistant.accept_error(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn set_assistant_platform_option(
        &mut self,
        background: bool,
        enabled: bool,
        cx: &mut Context<Self>,
    ) {
        if !self.runtime.is_native() || self.assistant_platform_pending {
            return;
        }
        self.assistant_platform_pending = true;
        let runtime = self.runtime.clone();
        cx.spawn(async move |this,cx| {
            let result=async {
                let current=runtime.call("TaskExperience","handle",json!([{"schema_version":1,"op":"settings"}])).await?;
                let mut prefs=current["preferences"].clone();
                if !prefs.is_object(){return Err("Invalid task preferences".to_owned());}
                if background {
                    if enabled && current["backgroundAvailable"]!=true {return Err("Background processing is unavailable on this device".into());}
                    prefs["background"]=json!(enabled);
                } else {
                    for key in ["completed","failed","attention"] {prefs[key]=json!(enabled);}
                    if enabled {
                        // Only this actual click asks the OS for permission.
                        runtime.call("TaskExperience","handle",json!([{"schema_version":1,"op":"permission","userInitiated":true}])).await?;
                    }
                }
                runtime.call("TaskExperience","handle",json!([{"schema_version":1,"op":"preferences","preferences":prefs}])).await
            }.await;
            let _=this.update(cx,|this,cx| {
                this.assistant_platform_pending=false;
                match result {
                    Ok(settings)=>this.assistant_platform=Some(settings),
                    Err(error)=>this.assistant.accept_error(&error),
                }
                cx.notify();
            });
        }).detach();
    }

    pub(super) fn assistant_platform_bar(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let p = Palette::get(cx);
        let settings = self.assistant_platform.as_ref();
        let background = settings.is_some_and(|v| v["preferences"]["background"] == true);
        let alerts = settings.is_some_and(|v| v["preferences"]["completed"] == true);
        let available = self.runtime.is_native() && !self.assistant_platform_pending;
        let can_background =
            available && settings.is_some_and(|v| v["backgroundAvailable"] == true);
        let denied = alerts
            && settings.is_some_and(|v| {
                !matches!(
                    v["notifications"].as_str(),
                    Some("authorized" | "provisional" | "ephemeral")
                )
            });
        let mut card = div()
            .id("assistant-platform-controls")
            .debug_selector(|| "assistant-platform-controls".into())
            .w_full()
            .flex_shrink_0()
            .rounded(px(22.))
            .border_1()
            .border_color(p.line.opacity(0.6))
            .bg(p.composer)
            .overflow_hidden();
        for (index, (id, is_background, checked, enabled, glyph, label)) in [
            (
                "assistant-notifications",
                false,
                alerts,
                available && settings.is_some(),
                Icon::Bell,
                assistant_copy::copy(self.locale, "Notifications", "通知"),
            ),
            (
                "assistant-background",
                true,
                background,
                can_background,
                Icon::Monitor,
                assistant_copy::copy(self.locale, "Continue in background", "后台继续当前任务"),
            ),
        ]
        .into_iter()
        .enumerate()
        {
            if index > 0 {
                card = card.child(div().h(px(1.)).ml(px(48.)).mr_4().bg(p.line.opacity(0.6)));
            }
            let switch_selector = if is_background {
                "assistant-background-switch"
            } else {
                "assistant-notifications-switch"
            };
            card = card.child(
                div()
                    .id(id)
                    .debug_selector(move || id.into())
                    .role(gpui::Role::Switch)
                    .aria_label(label)
                    .aria_toggled(if checked {
                        gpui::Toggled::True
                    } else {
                        gpui::Toggled::False
                    })
                    .min_h(px(58.))
                    .px_4()
                    .py_3()
                    .flex()
                    .items_center()
                    .gap_3()
                    .when(enabled, |row| {
                        row.cursor_pointer().hover(|s| s.bg(p.surface))
                    })
                    .child(icon(glyph, 18., if enabled { p.text } else { p.muted }))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .text_size(px(14.))
                            .line_height(px(20.))
                            .text_color(if enabled { p.text } else { p.muted })
                            .whitespace_normal()
                            .child(label),
                    )
                    .child(
                        div()
                            .debug_selector(move || switch_selector.into())
                            .w(px(44.))
                            .h(px(27.))
                            .flex_shrink_0()
                            .p(px(3.))
                            .rounded_full()
                            .bg(if checked { p.accent } else { p.raised })
                            .flex()
                            .items_center()
                            .when(checked, |track| track.justify_end())
                            .when(!enabled, |track| track.opacity(0.5))
                            .child(div().size(px(21.)).rounded_full().bg(if checked {
                                p.on_accent
                            } else {
                                p.composer
                            })),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if enabled {
                            this.set_assistant_platform_option(is_background, !checked, cx);
                        }
                    })),
            );
        }
        let hint = if denied {
            assistant_copy::copy(
                self.locale,
                "Allow notifications in system settings to receive task updates.",
                "在系统设置中允许通知，即可接收任务进展。",
            )
        } else if !self.runtime.is_native() {
            assistant_copy::copy(
                self.locale,
                "Manage these options in the mobile app.",
                "请在手机 App 中管理这些设置。",
            )
        } else if settings.is_none() && self.assistant_platform_pending {
            assistant_copy::copy(self.locale, "Loading device settings…", "正在读取设备设置…")
        } else if settings.is_none() {
            assistant_copy::copy(
                self.locale,
                "Device settings are unavailable right now.",
                "设备设置暂时不可用。",
            )
        } else if settings.is_some_and(|v| v["backgroundAvailable"] != true) {
            assistant_copy::copy(
                self.locale,
                "Background execution is unavailable on this device.",
                "此设备暂不支持后台继续任务。",
            )
        } else {
            assistant_copy::copy(
                self.locale,
                "Continue an active task when the system allows.",
                "系统允许时，继续已开始的任务。",
            )
        };
        card.child(
            div()
                .debug_selector(move || {
                    if denied {
                        "assistant-notifications-denied"
                    } else {
                        "assistant-platform-hint"
                    }
                    .into()
                })
                .px_4()
                .pt_1()
                .pb_3()
                .text_size(px(12.))
                .line_height(px(18.))
                .text_color(p.muted)
                .whitespace_normal()
                .child(hint),
        )
        .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_visibility_uses_the_open_conversation_only() {
        let request = next_visibility(
            &mut None,
            Page::Chat,
            Some("chat"),
            Some("selected"),
            Some("running"),
            Locale::Zh,
        )
        .unwrap();
        assert_eq!(
            request,
            json!([{"schema_version":1,"op":"visible","conversationId":"chat","locale":"zh-CN"}])
        );
    }

    #[test]
    fn assistant_visibility_prefers_the_visible_active_panel() {
        let request = next_visibility(
            &mut None,
            Page::Assistant,
            Some("chat"),
            Some("selected"),
            Some("running"),
            Locale::En,
        )
        .unwrap();
        assert_eq!(request[0]["conversationId"], "running");
        let request = next_visibility(
            &mut None,
            Page::Assistant,
            Some("chat"),
            Some("selected"),
            None,
            Locale::En,
        )
        .unwrap();
        assert_eq!(request[0]["conversationId"], "selected");
        let request = next_visibility(
            &mut None,
            Page::Assistant,
            Some("chat"),
            None,
            None,
            Locale::En,
        )
        .unwrap();
        assert_eq!(request[0]["conversationId"], "chat");
    }

    #[test]
    fn other_pages_clear_stale_notification_visibility() {
        for page in [Page::Settings, Page::Files, Page::Git] {
            let request = next_visibility(
                &mut None,
                page,
                Some("chat"),
                Some("selected"),
                Some("running"),
                Locale::En,
            )
            .unwrap();
            assert_eq!(request[0]["conversationId"], Value::Null);
        }
    }

    #[test]
    fn repeated_frames_do_not_repeat_even_unacknowledged_display_requests() {
        let mut previous = None;
        assert!(
            next_visibility(
                &mut previous,
                Page::Chat,
                Some("chat"),
                None,
                None,
                Locale::Zh
            )
            .is_some()
        );
        // No acknowledgement arrives. Render still must not flood the bridge.
        assert!(
            next_visibility(
                &mut previous,
                Page::Chat,
                Some("chat"),
                None,
                None,
                Locale::Zh
            )
            .is_none()
        );
        assert!(
            next_visibility(
                &mut previous,
                Page::Chat,
                Some("other"),
                None,
                None,
                Locale::Zh
            )
            .is_some()
        );
        assert!(
            next_visibility(
                &mut previous,
                Page::Settings,
                Some("other"),
                None,
                None,
                Locale::Zh
            )
            .is_some()
        );
        assert!(
            next_visibility(
                &mut previous,
                Page::Settings,
                Some("other"),
                None,
                None,
                Locale::Zh
            )
            .is_none()
        );
    }

    #[test]
    fn locale_change_updates_notification_copy_without_switching_conversation() {
        let mut previous = None;
        next_visibility(
            &mut previous,
            Page::Chat,
            Some("chat"),
            None,
            None,
            Locale::Zh,
        );
        let request = next_visibility(
            &mut previous,
            Page::Chat,
            Some("chat"),
            None,
            None,
            Locale::En,
        )
        .unwrap();
        assert_eq!(request[0]["locale"], "en-US");
        assert_eq!(request[0]["conversationId"], "chat");
    }

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    #[test]
    fn grouped_platform_switches_fit_narrow_cards_in_both_languages_and_themes() {
        use gpui::{Modifiers, TestAppContext, VisualTestContext, size};
        struct Panel {
            shell: Entity<Shell>,
        }
        impl Render for Panel {
            fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
                self.shell
                    .update(cx, |shell, cx| shell.assistant_platform_bar(cx))
            }
        }
        for width in [270., 296., 350.] {
            for locale in [Locale::Zh, Locale::En] {
                for mode in [theme::ThemeMode::Light, theme::ThemeMode::Dark] {
                    let mut app = TestAppContext::single();
                    let window = app.open_window(size(px(width), px(400.)), |_, cx| {
                        let shell = cx.new(|cx| {
                            let mut shell = Shell::new(cx);
                            shell.locale = locale;
                            shell.assistant_platform = Some(json!({"preferences":{"completed":true,"failed":true,"attention":true,"background":true},"backgroundAvailable":true,"notifications":"denied"}));
                            theme::set_mode(mode, cx);
                            shell
                        });
                        Panel { shell }
                    });
                    let mut cx = VisualTestContext::from_window(window.into(), &app);
                    cx.run_until_parked();
                    cx.update(|window, cx| window.draw(cx).clear(cx));
                    let card = cx.debug_bounds("assistant-platform-controls").unwrap();
                    assert!(card.left() >= px(0.) && card.right() <= px(width));
                    for (row, switch) in [
                        ("assistant-notifications", "assistant-notifications-switch"),
                        ("assistant-background", "assistant-background-switch"),
                    ] {
                        let bounds = cx.debug_bounds(row).unwrap();
                        let track = cx.debug_bounds(switch).unwrap();
                        assert!(bounds.size.height >= px(44.));
                        assert!(bounds.left() >= card.left() && bounds.right() <= card.right());
                        assert_eq!(track.size.width, px(44.));
                        assert_eq!(track.size.height, px(27.));
                        assert!(track.left() >= bounds.left() && track.right() <= bounds.right());
                        // Desktop preview must never request native permission.
                        cx.simulate_click(bounds.center(), Modifiers::none());
                        cx.run_until_parked();
                    }
                    let hint = cx.debug_bounds("assistant-notifications-denied").unwrap();
                    assert!(hint.left() >= card.left() && hint.right() <= card.right());
                    window.read_with(&cx, |panel, cx| {
                        let shell = panel.shell.read(cx);
                        assert!(!shell.assistant_platform_pending);
                        assert_eq!(shell.assistant_platform.as_ref().unwrap()["preferences"]["background"], true);
                    }).unwrap();
                }
            }
        }
    }
}
