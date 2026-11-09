use super::*;
use crate::icons::{Icon, icon};

impl Shell {
    pub(super) fn composer_card(
        &self,
        width: f32,
        height_budget: f32,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let touch = HIT_TARGET.max(44.);
        let footer_width = (width - 26.).max(0.);
        let compact_controls = footer_width < 460.;
        let control_gap = if compact_controls { 4. } else { 8. };
        let workspace_width = if compact_controls {
            (footer_width - 92. - touch * 2. - control_gap * 3.).clamp(72., 120.)
        } else {
            170.
        };
        let actions_width = (footer_width - workspace_width - control_gap)
            .max(0.)
            .min(if compact_controls { 250. } else { 300. });
        let model_width = if compact_controls {
            (actions_width - touch * 2. - control_gap * 2.).max(touch)
        } else {
            (actions_width - 140.).max(touch)
        };
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        let _ = height_budget;
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        let editor = div()
            .px_4()
            .pt_4()
            .min_h(px(if compact_controls { 56. } else { 76. }))
            .w_full()
            .child(self.composer.clone());
        #[cfg(any(target_os = "ios", target_os = "android"))]
        let editor = self.inline_composer_element(
            (height_budget - touch - if compact_controls { 10. } else { 18. }).clamp(
                44.,
                if compact_controls && self.composer.read(cx).text().is_empty() {
                    56.
                } else {
                    168.
                },
            ),
            cx,
        );
        let group_model = self.assistant_group_model();
        let selected = if self.assistant_group_visible() {
            group_model.as_str()
        } else {
            self.state.selected_model()
        };
        let (name, unavailable) = self.model_display_parts(selected);
        let configure = self.locale.text(Text::Configure);
        let model_label = match unavailable {
            Some(status) => format!("{configure}: {name} · {status}"),
            None => format!("{configure}: {name}"),
        };
        let busy = (self.state.is_busy() && !self.composer_drafts.saving)
            || (self.assistant_group_visible() && self.assistant_group_busy());
        let answering = self
            .state
            .agent_view()
            .and_then(|view| view.question)
            .is_some_and(|question| question.input_mode == "free_text");
        div()
            .id("composer-card")
            .debug_selector(|| "composer-card".into())
            .w_full()
            .rounded(px(if compact_controls { 20. } else { 22. }))
            .bg(p.composer)
            .border_1()
            .border_color(p.line)
            .shadow_sm()
            .flex()
            .flex_col()
            .child(editor)
            .when_some(self.composer_draft_status(), |card, status| {
                card.child(
                    div()
                        .id("composer-draft-status")
                        .px_4()
                        .pb_1()
                        .flex()
                        .flex_wrap()
                        .items_center()
                        .gap_2()
                        .text_size(px(11.))
                        .text_color(p.muted)
                        .child(status)
                        .when(
                            self.composer_drafts.error.is_some()
                                && self.state.composer_draft_conflicts().is_empty(),
                            |row| {
                                row.child(
                                    div()
                                        .id("retry-composer-draft")
                                        .min_h(px(44.))
                                        .px_2()
                                        .flex()
                                        .items_center()
                                        .cursor_pointer()
                                        .text_color(p.text)
                                        .child(self.locale.text(Text::Retry))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.retry_composer_drafts(cx)
                                        })),
                                )
                            },
                        ),
                )
            })
            .when_some(
                self.state.composer_draft_conflicts().into_iter().next(),
                |card, key| card.child(self.composer_draft_conflict_view(key, cx)),
            )
            .child(
                div()
                    .w(px((width - 2.).max(0.)))
                    .px_3()
                    .pb(px(if compact_controls { 8. } else { 12. }))
                    .pt(px(if compact_controls { 0. } else { 4. }))
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap(px(control_gap))
                    .child(if self.assistant_group_visible() {
                        self.assistant_group_target(workspace_width, cx)
                    } else {
                        self.composer_workspace_picker(workspace_width, compact_controls, p, cx)
                            .into_any_element()
                    })
                    .child(
                        div()
                            .flex()
                            .w(px(actions_width))
                            .justify_end()
                            .items_center()
                            .gap(px(control_gap))
                            .min_w(px(0.))
                            .child(
                                div()
                                    .id("model")
                                    .debug_selector(|| "model-picker-open".into())
                                    .role(gpui::Role::Button)
                                    .aria_label(model_label)
                                    .aria_expanded(self.model_picker)
                                    .min_h(px(touch))
                                    .px(px(if compact_controls { 4. } else { 12. }))
                                    .min_w(px(touch))
                                    .max_w(px(model_width))
                                    .rounded(px(8.))
                                    .cursor_pointer()
                                    .hover(|s| s.bg(p.surface))
                                    .flex()
                                    .items_center()
                                    .gap(px(if compact_controls { 4. } else { 8. }))
                                    .text_size(px(12.))
                                    .text_color(p.text)
                                    .child(
                                        div()
                                            .min_w(px(0.))
                                            .flex()
                                            .flex_col()
                                            .child(div().truncate().child(name))
                                            .when_some(unavailable, |label, status| {
                                                label.child(
                                                    div()
                                                        .id("composer-model-unavailable")
                                                        .debug_selector(|| {
                                                            "composer-model-unavailable".into()
                                                        })
                                                        .text_size(px(10.))
                                                        .text_color(p.danger)
                                                        .truncate()
                                                        .child(status),
                                                )
                                            }),
                                    )
                                    .child(icon(
                                        Icon::ChevronDown,
                                        if compact_controls { 12. } else { 16. },
                                        p.muted,
                                    ))
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.open_model_picker(window, cx);
                                    })),
                            )
                            .when(!self.assistant_group_visible(), |bar| {
                                bar.child(
                                    div()
                                        .id("thinking")
                                        .debug_selector(|| "config-thinking-open".into())
                                        .role(gpui::Role::Button)
                                        .aria_label(self.locale.text(Text::Thinking))
                                        .aria_expanded(self.model_picker)
                                        .min_h(px(touch))
                                        .flex_shrink_0()
                                        .when(compact_controls, |s| {
                                            s.w(px(touch)).justify_center().rounded(px(8.))
                                        })
                                        .when(!compact_controls, |s| s.px_3().rounded(px(8.)))
                                        .cursor_pointer()
                                        .hover(|s| s.bg(p.surface))
                                        .flex()
                                        .items_center()
                                        .gap_1()
                                        .text_size(px(12.))
                                        .text_color(p.muted)
                                        .child(self.locale.text(
                                            match self.state.selected_thinking() {
                                                "off" => Text::Off,
                                                "max" => Text::Max,
                                                _ => Text::High,
                                            },
                                        ))
                                        .child(icon(
                                            Icon::ChevronDown,
                                            if compact_controls { 10. } else { 14. },
                                            p.muted,
                                        ))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.open_model_picker(window, cx);
                                        })),
                                )
                            })
                            .child(
                                div()
                                    .id("send")
                                    .debug_selector(|| "composer-send".into())
                                    .size(px(touch))
                                    .flex_shrink_0()
                                    .rounded_full()
                                    .text_color(p.on_accent)
                                    .cursor_pointer()
                                    .hover(|s| s.opacity(0.88))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .child(
                                        div()
                                            .size(px(if compact_controls { 36. } else { touch }))
                                            .rounded_full()
                                            .bg(p.accent)
                                            .flex()
                                            .items_center()
                                            .justify_center()
                                            .child(icon(
                                                if busy && !answering {
                                                    Icon::Square
                                                } else {
                                                    Icon::ArrowUp
                                                },
                                                if compact_controls { 18. } else { 20. },
                                                p.on_accent,
                                            )),
                                    )
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.stop_agent_or_completion(cx);
                                    })),
                            ),
                    ),
            )
    }
    fn composer_workspace_picker(
        &self,
        width: f32,
        compact: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id("conversation-workspace")
            .debug_selector(|| "conversation-workspace".into())
            .role(gpui::Role::Button)
            .aria_label(self.conversation_workspace_name())
            .aria_expanded(self.conversation_workspace.selector)
            .w(px(width))
            .min_w(px(0.))
            .min_h(px(HIT_TARGET.max(44.)))
            .flex_shrink_0()
            .px(px(if compact { 4. } else { 12. }))
            .rounded(px(8.))
            .cursor_pointer()
            .hover(|s| s.bg(p.surface))
            .flex()
            .items_center()
            .gap(px(if compact { 4. } else { 8. }))
            .text_size(px(12.))
            .text_color(p.muted)
            .child(icon(Icon::Folder, if compact { 14. } else { 17. }, p.muted))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .child(self.conversation_workspace_name()),
            )
            .when(!compact, |s| {
                s.child(icon(Icon::ChevronDown, 14., p.muted).when(
                    self.conversation_workspace.selector,
                    |glyph| {
                        glyph.with_transformation(gpui::Transformation::rotate(gpui::radians(
                            std::f32::consts::PI,
                        )))
                    },
                ))
            })
            .on_click(cx.listener(|this, _, _, cx| this.choose_conversation_workspace(cx)))
    }
    pub(super) fn unsaved_answer_panel(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let answer = self.state.pending_conflict().and_then(|c| c.answer);
        let has_answer = answer.is_some();
        let text = answer.map(|m| m.text).unwrap_or_default();
        let copied = text.clone();
        div()
            .id("unsaved-answer")
            .max_h(px(300.))
            .overflow_y_scroll()
            .p_4()
            .bg(p.surface)
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_sm()
                    .text_color(p.accent)
                    .child(self.locale.text(if has_answer {
                        Text::UnsavedAnswer
                    } else {
                        Text::UnsavedState
                    })),
            )
            .when(has_answer, |v| {
                v.child(div().whitespace_normal().child(text))
            })
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_3()
                    .child(
                        div()
                            .id("retry-conflict")
                            .min_h(px(HIT_TARGET))
                            .flex()
                            .items_center()
                            .gap_2()
                            .p_3()
                            .cursor_pointer()
                            .child(icon(Icon::RotateCcw, 16., p.text))
                            .child(self.locale.text(Text::Retry))
                            .on_click(cx.listener(|this, _, _, cx| this.bootstrap(cx))),
                    )
                    .when(has_answer, |row| {
                        row.child(
                            div()
                                .id("copy-unsaved")
                                .min_h(px(HIT_TARGET))
                                .flex()
                                .items_center()
                                .gap_2()
                                .p_3()
                                .cursor_pointer()
                                .child(icon(Icon::Copy, 16., p.text))
                                .child(self.locale.text(Text::Copy))
                                .on_click(move |_, _, cx| {
                                    cx.write_to_clipboard(gpui::ClipboardItem::new_string(
                                        copied.clone(),
                                    ))
                                }),
                        )
                    })
                    .child(
                        div()
                            .id("discard-unsaved")
                            .min_h(px(HIT_TARGET))
                            .flex()
                            .items_center()
                            .gap_2()
                            .p_3()
                            .cursor_pointer()
                            .text_color(p.danger)
                            .child(icon(Icon::Trash2, 16., p.danger))
                            .child(self.locale.text(if has_answer {
                                Text::DiscardAnswer
                            } else {
                                Text::DiscardState
                            }))
                            .on_click(cx.listener(|this, _, _, cx| {
                                match this.state.discard_pending_conflict() {
                                    Ok(()) => this.notice = None,
                                    Err(error) => this.notice = Some(error),
                                }
                                cx.notify();
                            })),
                    ),
            )
    }
}
