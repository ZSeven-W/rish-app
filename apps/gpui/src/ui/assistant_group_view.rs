use super::{assistant_avatar::profile_avatar, assistant_copy::copy, *};
use crate::{
    assistant_runtime::RunnerCommand,
    icons::{Icon, icon},
};
use gpui::{AnyElement, FontWeight};

impl Shell {
    pub(super) fn assistant_group_target(&self, width: f32, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let name = self
            .assistant
            .directory_ui
            .target_bot_id
            .as_deref()
            .and_then(|id| self.assistant.directory()?.bot_profile(id))
            .map(|p| p.name.as_str())
            .unwrap_or(copy(self.locale, "Everyone", "所有成员"));
        div()
            .id("group-target-toggle")
            .debug_selector(|| "group-target-toggle".into())
            .role(gpui::Role::Button)
            .aria_label(format!(
                "{} {name}",
                copy(self.locale, "Reply from", "回复成员")
            ))
            .aria_expanded(self.assistant.directory_ui.target_picker)
            .w(px(width))
            .min_w(px(0.))
            .min_h(px(44.))
            .flex()
            .items_center()
            .gap_1()
            .text_size(px(12.))
            .text_color(p.muted)
            .cursor_pointer()
            .child(icon(Icon::MessagesSquare, 16., p.muted))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .child(name.to_owned()),
            )
            .child(icon(Icon::ChevronDown, 12., p.muted))
            .on_click(cx.listener(|this, _, _, cx| {
                if !this.assistant_group_busy() {
                    this.assistant.directory_ui.target_picker =
                        !this.assistant.directory_ui.target_picker;
                    cx.notify();
                }
            }))
            .into_any_element()
    }
    pub(super) fn assistant_group_page(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if width >= 900. && self.assistant.directory_ui.editor.is_none() {
            let p = Palette::get(cx);
            return div()
                .id("assistant-group-workbench")
                .debug_selector(|| "assistant-group-workbench".into())
                .size_full()
                .min_h(px(0.))
                .min_w(px(0.))
                .flex()
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .h_full()
                        .child(self.assistant_group_content(width - 248., height, cx)),
                )
                .child(
                    div()
                        .id("group-members-sidebar")
                        .debug_selector(|| "group-members-sidebar".into())
                        .w(px(248.))
                        .h_full()
                        .flex_shrink_0()
                        .border_l_1()
                        .border_color(p.line)
                        .p_3()
                        .flex()
                        .flex_col()
                        .gap_3()
                        .child(
                            div()
                                .px_2()
                                .py_3()
                                .text_size(px(15.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(copy(self.locale, "Group members", "群成员")),
                        )
                        .child(self.assistant_group_member_sidebar(cx)),
                )
                .into_any_element();
        }
        self.assistant_group_content(width, height, cx)
    }
    fn assistant_group_member_sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let mut members = div()
            .id("group-members-list")
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        if let (Some(group), Some(directory)) =
            (self.assistant_current_group(), self.assistant.directory())
        {
            for id in &group.active_bot_ids {
                let Some(profile) = directory.bot_profile(id) else {
                    continue;
                };
                let id = id.clone();
                let selector = format!("group-sidebar-member-{id}");
                let selected = self.assistant.directory_ui.target_bot_id.as_deref() == Some(&id);
                members = members.child(
                    div()
                        .id(selector.clone())
                        .debug_selector(move || selector.clone())
                        .role(gpui::Role::Button)
                        .aria_label(profile.name.clone())
                        .min_h(px(72.))
                        .p_3()
                        .rounded(px(18.))
                        .bg(if selected { p.surface } else { p.composer })
                        .flex()
                        .items_center()
                        .gap_3()
                        .child(profile_avatar(
                            self.assistant_storage_directory.as_ref(),
                            profile.avatar.as_ref(),
                            36.,
                            cx,
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
                                        .text_size(px(14.))
                                        .truncate()
                                        .child(profile.name.clone()),
                                )
                                .child(div().text_size(px(11.)).text_color(p.muted).child(copy(
                                    self.locale,
                                    "Tap to direct a message",
                                    "点击指定回复",
                                ))),
                        )
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if !this.assistant_group_busy() {
                                this.assistant.directory_ui.target_bot_id = Some(id.clone());
                                cx.notify();
                            }
                        })),
                );
            }
        }
        members.into_any_element()
    }
    fn assistant_group_content(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if self.assistant.directory_ui.editor.is_some() {
            return self.assistant_directory_editor(cx);
        }
        let p = Palette::get(cx);
        let Some(group) = self.assistant_current_group() else {
            return div()
                .p_5()
                .child(copy(self.locale, "Group unavailable", "群聊暂不可用"))
                .into_any_element();
        };
        let workspace = self.assistant_group_workspace();
        let name = workspace
            .as_ref()
            .and_then(|w| w["display_name"].as_str())
            .unwrap_or(self.locale.text(Text::DefaultWorkspace));
        let fixed = !group.rounds.is_empty();
        let mut page = div()
            .id("assistant-group-page")
            .debug_selector(|| "assistant-group-page".into())
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .flex_col()
            .overflow_hidden()
            .child(
                div()
                    .flex_shrink_0()
                    .px_4()
                    .pb_2()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .id("group-workspace-toggle")
                            .debug_selector(|| "group-workspace-toggle".into())
                            .role(gpui::Role::Button)
                            .aria_label(name.to_owned())
                            .aria_expanded(self.assistant.directory_ui.workspace_picker)
                            .min_h(px(44.))
                            .flex_1()
                            .min_w(px(0.))
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_color(p.muted)
                            .text_size(px(12.))
                            .child(icon(Icon::Folder, 16., p.muted))
                            .child(div().min_w(px(0.)).truncate().child(name.to_owned()))
                            .when(!fixed, |v| {
                                v.child(icon(Icon::ChevronDown, 12., p.muted))
                                    .cursor_pointer()
                            })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if !fixed && !this.assistant_group_busy() {
                                    this.assistant.directory_ui.workspace_picker =
                                        !this.assistant.directory_ui.workspace_picker;
                                    cx.notify();
                                }
                            })),
                    )
                    .child(
                        div()
                            .id("group-edit")
                            .debug_selector(|| "group-edit".into())
                            .role(gpui::Role::Button)
                            .aria_label(copy(self.locale, "Group members", "群成员"))
                            .min_h(px(44.))
                            .px_2()
                            .flex()
                            .items_center()
                            .gap_1()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .cursor_pointer()
                            .child(icon(Icon::Settings2, 16., p.muted))
                            .child(copy(self.locale, "Members", "群成员"))
                            .on_click(cx.listener(|this, _, _, cx| this.assistant_edit_group(cx))),
                    ),
            );
        if self.assistant.directory_ui.workspace_picker && !fixed {
            let mut choices = div()
                .id("group-workspace-options")
                .max_h(px(180.))
                .overflow_y_scroll()
                .mx_4()
                .bg(p.composer)
                .rounded(px(16.))
                .p_2()
                .flex_shrink_0()
                .flex()
                .flex_col();
            let mut workspaces = self.browser.workspaces.clone();
            if let Some(default) = self.state.default_workspace()
                && !workspaces
                    .iter()
                    .any(|w| w["workspace_id"] == default["workspace_id"])
            {
                workspaces.insert(0, default.clone());
            }
            for workspace in workspaces {
                let label = workspace["display_name"]
                    .as_str()
                    .unwrap_or("Workspace")
                    .to_owned();
                let key = format!(
                    "group-workspace-{}",
                    workspace["workspace_id"].as_str().unwrap_or("")
                );
                choices = choices.child(
                    div()
                        .id(key)
                        .min_h(px(44.))
                        .px_3()
                        .flex()
                        .items_center()
                        .text_size(px(13.))
                        .cursor_pointer()
                        .child(label)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if this.assistant_group_busy()
                                || this
                                    .assistant_current_group()
                                    .is_none_or(|g| !g.rounds.is_empty())
                            {
                                return;
                            }
                            if let Some(id) = this.assistant.directory_ui.group_id.clone() {
                                this.assistant
                                    .directory_ui
                                    .workspaces
                                    .insert(id, workspace.clone());
                                this.assistant.directory_ui.workspace_picker = false;
                                cx.notify();
                            }
                        })),
                );
            }
            page = page.child(choices);
        }
        if let Some(error) = self.assistant.error.as_ref().or(self
            .assistant
            .snapshot
            .message
            .as_ref())
        {
            page = page.child(
                div()
                    .px_4()
                    .pb_2()
                    .text_size(px(12.))
                    .text_color(p.danger)
                    .whitespace_normal()
                    .child(error.clone()),
            );
        }
        if group.rounds.is_empty() {
            page=page.child(div().id("group-welcome").debug_selector(||"group-welcome".into()).flex_1().min_h(px(0.)).overflow_y_scroll()
                .p_5().flex().flex_col().items_center().justify_center().gap_3()
                .child(icon(Icon::MessagesSquare,40.,p.muted))
                .child(div().text_size(px(23.)).font_weight(FontWeight::SEMIBOLD).text_center().child(group.name.clone()))
                .child(div().max_w(px(400.)).text_size(px(14.)).line_height(px(23.)).text_color(p.muted).text_center().whitespace_normal()
                    .child(copy(self.locale,"Ask everyone, or choose one assistant. Each member replies in their own voice.","可以问所有成员，也可以指定一位助手。每位成员会以自己的身份回复。"))));
        } else {
            page = page.child(
                div()
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_hidden()
                    .child(self.transcript.clone()),
            );
        }
        if self.assistant.snapshot.active_group_id.as_deref() == Some(&group.id) {
            if let Some(view) = self.state.agent_view() {
                page = page.child(self.agent_panel(view, height, cx));
            }
        }
        let needs_end_retry = self.assistant.snapshot.active_group_id.as_deref() == Some(&group.id)
            && self.assistant.snapshot.status
                == crate::assistant_runtime::RunnerStatus::NeedsAttention
            && self
                .state
                .agent_view()
                .is_none_or(|v| v.approval.is_none() && v.question.is_none());
        if needs_end_retry
            || (self.assistant.snapshot.active_group_id.as_deref() != Some(&group.id)
                && group.rounds.iter().any(|r| r.is_pending()))
        {
            let id = group.id.clone();
            let stop = id.clone();
            page = page.child(
                div()
                    .id("group-recovery")
                    .debug_selector(|| "group-recovery".into())
                    .px_4()
                    .py_2()
                    .flex_shrink_0()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .text_size(px(12.))
                    .child(
                        div()
                            .id("group-recover")
                            .debug_selector(|| "group-recover".into())
                            .min_h(px(44.))
                            .px_3()
                            .rounded_full()
                            .bg(p.surface)
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .child(copy(
                                self.locale,
                                "Continue / check reply",
                                "继续／核对回复",
                            ))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.assistant_command(
                                    RunnerCommand::RecoverGroup {
                                        group_id: id.clone(),
                                    },
                                    cx,
                                )
                            })),
                    )
                    .child(
                        div()
                            .id("group-stop")
                            .debug_selector(|| "group-stop".into())
                            .min_h(px(44.))
                            .px_3()
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .child(copy(self.locale, "Stop remaining replies", "停止后续回复"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.assistant_command(
                                    RunnerCommand::StopGroup {
                                        group_id: stop.clone(),
                                    },
                                    cx,
                                )
                            })),
                    ),
            );
        }
        if self.assistant.directory_ui.target_picker {
            page = page.child(self.assistant_group_target_options(cx));
        }
        let compact = width < 600. || height < 600.;
        page.child(
            div()
                .w_full()
                .flex_shrink_0()
                .px(px(if compact { 16. } else { 20. }))
                .pt_2()
                .pb_3()
                .child(
                    div()
                        .w_full()
                        .max_w(px(720.))
                        .mx_auto()
                        .child(self.composer_card(
                            (width - if compact { 32. } else { 40. }).clamp(0., 720.),
                            height.min(if self.state.agent_view().is_some() {
                                120.
                            } else {
                                190.
                            }),
                            cx,
                        )),
                ),
        )
        .into_any_element()
    }
    fn assistant_group_target_options(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = Palette::get(cx);
        let mut rows = div()
            .id("group-target-options")
            .debug_selector(|| "group-target-options".into())
            .max_h(px(200.))
            .overflow_y_scroll()
            .mx_4()
            .rounded(px(16.))
            .bg(p.composer)
            .p_2()
            .flex_shrink_0()
            .flex()
            .flex_col();
        rows = rows.child(
            div()
                .id("group-target-all")
                .debug_selector(|| "group-target-all".into())
                .min_h(px(44.))
                .px_3()
                .flex()
                .items_center()
                .text_size(px(13.))
                .cursor_pointer()
                .child(copy(
                    self.locale,
                    "Everyone · one reply each",
                    "所有成员 · 每人回复一次",
                ))
                .on_click(cx.listener(|this, _, _, cx| {
                    if this.assistant_group_busy() {
                        return;
                    }
                    this.assistant.directory_ui.target_bot_id = None;
                    this.assistant.directory_ui.target_picker = false;
                    cx.notify();
                })),
        );
        if let (Some(group), Some(directory)) =
            (self.assistant_current_group(), self.assistant.directory())
        {
            for id in &group.active_bot_ids {
                let Some(profile) = directory.bot_profile(id) else {
                    continue;
                };
                let id = id.clone();
                let selector = format!("group-target-{id}");
                rows = rows.child(
                    div()
                        .id(selector.clone())
                        .debug_selector(move || selector.clone())
                        .min_h(px(48.))
                        .px_3()
                        .flex()
                        .items_center()
                        .gap_2()
                        .text_size(px(13.))
                        .cursor_pointer()
                        .child(profile_avatar(
                            self.assistant_storage_directory.as_ref(),
                            profile.avatar.as_ref(),
                            28.,
                            cx,
                        ))
                        .child(div().min_w(px(0.)).truncate().child(profile.name.clone()))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if this.assistant_group_busy() {
                                return;
                            }
                            this.assistant.directory_ui.target_bot_id = Some(id.clone());
                            this.assistant.directory_ui.target_picker = false;
                            cx.notify();
                        })),
                );
            }
        }
        rows.into_any_element()
    }
}
