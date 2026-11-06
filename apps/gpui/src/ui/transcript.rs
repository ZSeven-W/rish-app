use super::{
    i18n::{Locale, Text},
    theme::{HIT_TARGET, Palette},
};
use crate::icons::{Icon, icon};
use gpui::{
    AppContext, ClipboardItem, Context, Entity, IntoElement, ListAlignment, ListState, Render,
    Window, div, list, prelude::*, px,
};
use rish_shell_core::assistant_store::AssistantAvatar;
use std::{collections::HashMap, path::PathBuf};

/// Display identity comes from the persisted Bot/room mapping, never from
/// model-produced text. It does not grant an execution or storage scope.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DisplaySpeaker {
    pub id: String,
    pub name: String,
    pub avatar: Option<AssistantAvatar>,
    pub directory: Option<PathBuf>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DisplayMessage {
    pub id: String,
    pub role: String,
    pub text: String,
    pub reasoning: String,
    pub speaker: Option<DisplaySpeaker>,
}

impl DisplayMessage {
    fn speaker_name(&self, locale: Locale) -> String {
        if self.role == "user" {
            return locale.text(Text::You).to_owned();
        }
        self.speaker
            .as_ref()
            .map(|speaker| speaker.name.as_str())
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| locale.text(Text::Assistant))
            .to_owned()
    }
}

pub struct Transcript {
    rows: Vec<Entity<MessageRow>>,
    state: ListState,
    locale: Locale,
}
impl Transcript {
    #[cfg(test)]
    pub(super) fn test_messages(&self, cx: &gpui::App) -> Vec<DisplayMessage> {
        self.rows
            .iter()
            .map(|row| row.read(cx).message.clone())
            .collect()
    }

    pub fn new(locale: Locale) -> Self {
        let state = ListState::new(0, ListAlignment::Bottom, px(500.));
        #[cfg(any(target_os = "ios", target_os = "android"))]
        state.set_follow_mode(gpui::FollowMode::Tail);
        Self {
            rows: Vec::new(),
            state,
            locale,
        }
    }
    fn follows_tail(&self) -> bool {
        #[cfg(any(target_os = "ios", target_os = "android"))]
        {
            self.state.is_following_tail()
        }
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        {
            self.state.is_scrolled_to_end().unwrap_or(true)
        }
    }
    fn scroll_to_end(&self) {
        #[cfg(any(target_os = "ios", target_os = "android"))]
        self.state.set_follow_mode(gpui::FollowMode::Tail);
        self.state.scroll_to_end();
    }
    pub fn sync(&mut self, messages: Vec<DisplayMessage>, locale: Locale, cx: &mut Context<Self>) {
        let follow = self.rows.is_empty() || self.follows_tail();
        let old_ids: Vec<String> = self
            .rows
            .iter()
            .map(|r| r.read(cx).message.id.clone())
            .collect();
        let next_ids: Vec<String> = messages.iter().map(|m| m.id.clone()).collect();
        let mut existing: HashMap<String, Entity<MessageRow>> = self
            .rows
            .iter()
            .map(|r| (r.read(cx).message.id.clone(), r.clone()))
            .collect();
        let mut changed = false;
        let mut updated = Vec::new();
        let rows = messages
            .into_iter()
            .enumerate()
            .map(|(index, message)| {
                if let Some(row) = existing.remove(&message.id) {
                    if row.read(cx).message != message
                        || row.read(cx).locale != locale
                        || row.read(cx).index != index
                    {
                        row.update(cx, |r, cx| {
                            r.message = message;
                            r.locale = locale;
                            r.index = index;
                            cx.notify();
                        });
                        updated.push(index);
                        changed = true;
                    }
                    row
                } else {
                    changed = true;
                    let state = self.state.clone();
                    cx.new(|_| MessageRow {
                        message,
                        locale,
                        show_reasoning: false,
                        state,
                        index,
                    })
                }
            })
            .collect();
        self.rows = rows;
        self.locale = locale;
        if old_ids != next_ids {
            // Preserve existing measured rows when appending streaming history.
            if next_ids.starts_with(&old_ids) {
                self.state
                    .splice(old_ids.len()..old_ids.len(), next_ids.len() - old_ids.len());
            } else {
                self.state.reset(next_ids.len());
            }
            changed = true;
        }
        for index in updated {
            self.state.splice(index..index + 1, 1);
        }
        if changed {
            if follow {
                self.scroll_to_end();
            }
            cx.notify();
        }
    }
}
impl Render for Transcript {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                list(
                    self.state.clone(),
                    cx.processor(|this, index: usize, _, _| {
                        this.rows[index].clone().into_any_element()
                    }),
                )
                .flex_1()
                .w_full(),
            )
            .when(!self.follows_tail(), |view| {
                view.child(
                    div()
                        .id("latest")
                        .mx_auto()
                        .mb_2()
                        .px_4()
                        .py_2()
                        .min_h(px(HIT_TARGET))
                        .rounded_full()
                        .bg(p.composer)
                        .border_1()
                        .border_color(p.line)
                        .shadow_sm()
                        .flex()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .text_size(px(12.))
                        .text_color(p.accent)
                        .cursor_pointer()
                        .child(icon(Icon::ArrowDown, 16., p.accent))
                        .child(self.locale.text(Text::JumpToBottom))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.scroll_to_end();
                            cx.notify();
                        })),
                )
            })
    }
}

struct MessageRow {
    message: DisplayMessage,
    locale: Locale,
    show_reasoning: bool,
    state: ListState,
    index: usize,
}
impl Render for MessageRow {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = Palette::get(cx);
        let user = self.message.role == "user";
        let speaker_name = self.message.speaker_name(self.locale);
        let speaker_selector = format!("message-speaker-{}", self.message.id);
        let copy = self.message.text.clone();
        let mut body = div().flex().flex_col().gap_4().w_full().min_w(px(0.));
        // Keep model text literal. Code has a separate copy action; rendering never
        // discards message content just because the Markdown is incomplete.
        for (index, chunk) in self.message.text.split("```").enumerate() {
            if chunk.is_empty() {
                continue;
            }
            if index % 2 == 1 {
                let (language, code) = chunk
                    .split_once('\n')
                    .map(|(language, code)| (language.trim(), code))
                    .unwrap_or(("", chunk));
                let copied_code = code.to_string();
                body = body.child(
                    div()
                        .rounded(px(14.))
                        .overflow_hidden()
                        .bg(p.composer)
                        .border_1()
                        .border_color(p.line)
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .px_3()
                                .min_h(px(HIT_TARGET))
                                .bg(p.surface)
                                .border_b_1()
                                .border_color(p.line)
                                .flex()
                                .items_center()
                                .gap_2()
                                .text_size(px(12.))
                                .text_color(p.muted)
                                .child(icon(Icon::CodeXml, 15., p.muted))
                                .child(div().flex_1().min_w(px(0.)).child(language.to_string()))
                                .child(
                                    div()
                                        .id(("copy-code", index))
                                        .min_h(px(HIT_TARGET))
                                        .px_2()
                                        .flex()
                                        .items_center()
                                        .gap_2()
                                        .cursor_pointer()
                                        .hover(|button| button.text_color(p.text))
                                        .child(icon(Icon::Copy, 15., p.muted))
                                        .child(self.locale.text(Text::Copy))
                                        .on_click(move |_, _, cx| {
                                            cx.write_to_clipboard(ClipboardItem::new_string(
                                                copied_code.clone(),
                                            ));
                                        }),
                                ),
                        )
                        .child(
                            div()
                                .p_4()
                                .font_family(super::theme::code_font_family())
                                .text_size(px(13.))
                                .line_height(px(21.))
                                .whitespace_normal()
                                .child(code.to_string()),
                        ),
                );
            } else {
                body = body.child(div().whitespace_normal().child(chunk.to_string()));
            }
        }
        let message = div()
            .max_w(px(if user { 610. } else { 720. }))
            .min_w(px(0.))
            .rounded(px(18.))
            .when(user, |message| message.bg(p.surface).px_4().pt_3().pb_1())
            .when(!user, |message| message.w_full().py_2())
            .flex()
            .flex_col()
            .gap_3()
            .text_color(p.text)
            .text_size(px(15.))
            .line_height(px(24.))
            .when(!user, |message| {
                message.child(
                    div()
                        .id(speaker_selector.clone())
                        .debug_selector(move || speaker_selector.clone())
                        .aria_label(speaker_name.clone())
                        .min_w(px(0.))
                        .flex()
                        .items_center()
                        .gap_2()
                        .text_size(px(12.))
                        .line_height(px(18.))
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(p.muted)
                        .when_some(self.message.speaker.as_ref(), |header, speaker| {
                            header.child(super::assistant_avatar::profile_avatar(
                                speaker.directory.as_ref(),
                                speaker.avatar.as_ref(),
                                24.,
                                cx,
                            ))
                        })
                        .child(div().min_w(px(0.)).truncate().child(speaker_name.clone())),
                )
            })
            .when(!self.message.reasoning.is_empty(), |message| {
                message.child(
                    div()
                        .id("reasoning")
                        .min_h(px(HIT_TARGET))
                        .px_3()
                        .rounded(px(12.))
                        .bg(p.surface)
                        .flex()
                        .items_center()
                        .gap_2()
                        .text_size(px(13.))
                        .text_color(p.muted)
                        .cursor_pointer()
                        .child(icon(
                            if self.show_reasoning {
                                Icon::ChevronDown
                            } else {
                                Icon::ChevronRight
                            },
                            16.,
                            p.muted,
                        ))
                        .child(self.locale.text(Text::Reasoning))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.show_reasoning = !this.show_reasoning;
                            this.state.splice(this.index..this.index + 1, 1);
                            cx.notify();
                        })),
                )
            })
            .when(
                self.show_reasoning && !self.message.reasoning.is_empty(),
                |message| {
                    message.child(
                        div()
                            .border_l_2()
                            .border_color(p.line)
                            .pl_4()
                            .text_size(px(14.))
                            .line_height(px(23.))
                            .text_color(p.muted)
                            .whitespace_normal()
                            .child(self.message.reasoning.clone()),
                    )
                },
            )
            .child(body)
            .child(
                div()
                    .flex()
                    .when(user, |footer| footer.justify_end())
                    .child(
                        div()
                            .id("copy")
                            .min_h(px(HIT_TARGET))
                            .min_w(px(HIT_TARGET))
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_size(px(12.))
                            .line_height(px(18.))
                            .text_color(p.muted)
                            .cursor_pointer()
                            .hover(|button| button.text_color(p.text))
                            .child(icon(Icon::Copy, 15., p.muted))
                            .child(self.locale.text(Text::Copy))
                            .on_click(move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()))
                            }),
                    ),
            );
        div()
            .id(self.message.id.clone())
            .aria_label(speaker_name)
            .w_full()
            .px_5()
            .py_3()
            .child(
                div()
                    .max_w(px(720.))
                    .mx_auto()
                    .w_full()
                    .flex()
                    .when(user, |column| column.justify_end())
                    .child(message),
            )
    }
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
#[path = "transcript_speaker_tests.rs"]
mod speaker_tests;
