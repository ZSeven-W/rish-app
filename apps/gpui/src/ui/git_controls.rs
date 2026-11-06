use super::{
    Shell,
    git_operations::{GitAction, GitFeedback},
    i18n::{Locale, Text},
    theme::Palette,
    workspace_git::GitState,
};
use crate::icons::{Icon, icon};
use gpui::{Context, Div, IntoElement, div, prelude::*, px};

impl Shell {
    fn git_action_button(
        &self,
        action: GitAction,
        label: Text,
        glyph: Icon,
        primary: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let enabled = self.git_action_available(action);
        let id = match action {
            GitAction::Stage => "git-stage",
            GitAction::Commit => "git-commit",
            GitAction::Fetch => "git-fetch",
            GitAction::Pull => "git-pull",
            GitAction::Push => "git-push",
            GitAction::Remote => "git-remote",
            GitAction::Credentials => "git-credentials",
            GitAction::CheckPush => "git-check-push",
            GitAction::Diff => "git-diff",
            GitAction::DiffStaged => "git-diff-staged",
            GitAction::Refresh => "git-refresh-metadata",
        };
        let selected = self
            .browser
            .git_actions
            .diff
            .as_ref()
            .is_some_and(|diff| match action {
                GitAction::Diff => diff["staged"] != true,
                GitAction::DiffStaged => diff["staged"] == true,
                _ => false,
            });
        let color = if primary { p.on_accent } else { p.text };
        div()
            .id(id)
            .debug_selector(move || id.into())
            .min_h(px(super::theme::HIT_TARGET.max(44.)))
            .min_w(px(76.))
            .px_3()
            .when(
                matches!(action, GitAction::Remote | GitAction::Credentials),
                |s| s.flex_shrink_0(),
            )
            .when(
                !matches!(action, GitAction::Remote | GitAction::Credentials),
                |s| s.flex_1(),
            )
            .rounded(px(12.))
            .border_1()
            .border_color(if primary { p.accent } else { p.line })
            .bg(if primary {
                p.accent
            } else if selected {
                p.raised
            } else {
                p.composer
            })
            .text_color(color)
            .flex()
            .items_center()
            .justify_center()
            .gap_2()
            .text_size(px(13.))
            .when(enabled, |s| s.cursor_pointer().active(|s| s.opacity(0.8)))
            .when(!enabled, |s| s.opacity(0.4))
            .child(icon(glyph, 16., color))
            .child(
                div()
                    .min_w(px(0.))
                    .whitespace_normal()
                    .child(self.locale.text(label)),
            )
            .on_click(cx.listener(move |this, _, _, cx| this.begin_git_action(action, cx)))
    }

    pub(super) fn git_operation_controls(&self, p: Palette, cx: &mut Context<Self>) -> Div {
        let metadata =
            self.browser.git_actions.metadata_root.as_ref() == self.browser.root.as_ref();
        let remote = self
            .browser
            .git_actions
            .remote
            .as_ref()
            .filter(|_| metadata);
        let url = remote.and_then(|v| v["url"].as_str());
        let credential = self
            .browser
            .git_actions
            .credential
            .as_ref()
            .filter(|_| metadata);
        let configured = credential.is_some_and(|v| v["configured"] == true);
        let mut panel = div()
            .flex()
            .flex_col()
            .gap_2()
            .mb_3()
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(self.git_action_button(
                        GitAction::Fetch,
                        Text::GitFetch,
                        Icon::RefreshCw,
                        false,
                        p,
                        cx,
                    ))
                    .child(self.git_action_button(
                        GitAction::Pull,
                        Text::GitPull,
                        Icon::ArrowDown,
                        false,
                        p,
                        cx,
                    ))
                    .child(self.git_action_button(
                        GitAction::Push,
                        Text::GitPush,
                        Icon::ArrowUp,
                        false,
                        p,
                        cx,
                    )),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(self.git_action_button(
                        GitAction::Stage,
                        Text::GitStageAll,
                        Icon::CheckCheck,
                        false,
                        p,
                        cx,
                    ))
                    .child(self.git_action_button(
                        GitAction::Commit,
                        Text::GitCommit,
                        Icon::SquarePen,
                        true,
                        p,
                        cx,
                    )),
            )
            .child(
                div()
                    .p_3()
                    .rounded(px(14.))
                    .border_1()
                    .border_color(p.line)
                    .bg(p.composer)
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
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
                                            .text_size(px(12.))
                                            .text_color(p.muted)
                                            .child(self.locale.text(Text::GitRemote)),
                                    )
                                    .child(
                                        div().truncate().text_size(px(13.)).child(
                                            url.unwrap_or(self.locale.text(Text::GitRemoteNotSet))
                                                .to_owned(),
                                        ),
                                    ),
                            )
                            .child(self.git_action_button(
                                GitAction::Remote,
                                Text::Configure,
                                Icon::Settings2,
                                false,
                                p,
                                cx,
                            )),
                    )
                    .when(url.is_some(), |s| {
                        s.child(
                            div()
                                .border_t_1()
                                .border_color(p.line)
                                .pt_3()
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
                                                .text_size(px(12.))
                                                .text_color(p.muted)
                                                .child(self.locale.text(Text::GitCredentials)),
                                        )
                                        .child(div().text_size(px(13.)).whitespace_normal().child(
                                            self.locale.text(if configured {
                                                Text::GitCredentialsReady
                                            } else {
                                                Text::GitCredentialsMissing
                                            }),
                                        )),
                                )
                                .child(self.git_action_button(
                                    GitAction::Credentials,
                                    Text::Configure,
                                    Icon::Settings2,
                                    false,
                                    p,
                                    cx,
                                )),
                        )
                    }),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(self.git_action_button(
                        GitAction::Diff,
                        Text::GitDiff,
                        Icon::CodeXml,
                        false,
                        p,
                        cx,
                    ))
                    .child(self.git_action_button(
                        GitAction::DiffStaged,
                        Text::GitDiffStaged,
                        Icon::CodeXml,
                        false,
                        p,
                        cx,
                    )),
            );
        if let GitState::Attached(git) = &self.browser.git {
            let hint = if git["has_conflicts"] == true {
                Text::GitConflictHint
            } else if git["head_oid"].is_null() {
                Text::GitFirstCommitHint
            } else if url.is_none() {
                Text::GitNoRemoteHint
            } else if git["clean"] != true {
                Text::GitDirtyPullHint
            } else {
                Text::GitSyncHint
            };
            panel = panel.child(
                div()
                    .text_size(px(12.))
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(self.locale.text(hint)),
            );
        }
        if let Some(pending) = &self.browser.git_actions.pending {
            panel = panel.child(
                div()
                    .px_3()
                    .py_2()
                    .rounded_lg()
                    .bg(p.surface)
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .text_size(px(13.))
                            .whitespace_normal()
                            .child(self.locale.text(
                                if self.browser.git_actions.cancel_requested {
                                    Text::GitCancelling
                                } else {
                                    Text::GitRunning
                                },
                            )),
                    )
                    .when(pending.cancellable(), |s| {
                        s.child(
                            div()
                                .id("git-cancel")
                                .min_h(px(super::theme::HIT_TARGET.max(44.)))
                                .min_w(px(44.))
                                .flex_shrink_0()
                                .px_3()
                                .flex()
                                .items_center()
                                .text_size(px(13.))
                                .when(!self.browser.git_actions.cancel_requested, |s| {
                                    s.cursor_pointer()
                                })
                                .when(self.browser.git_actions.cancel_requested, |s| {
                                    s.opacity(0.45)
                                })
                                .child(self.locale.text(Text::Cancel))
                                .on_click(cx.listener(|this, _, _, cx| this.cancel_git_action(cx))),
                        )
                    }),
            );
        }
        if let Some(feedback) = &self.browser.git_actions.feedback {
            let message = git_feedback_message(feedback, self.locale);
            if !message.is_empty() {
                panel = panel.child(
                    div()
                        .p_3()
                        .rounded_lg()
                        .bg(p.surface)
                        .text_size(px(13.))
                        .whitespace_normal()
                        .text_color(if matches!(feedback, GitFeedback::Error(_)) {
                            p.danger
                        } else {
                            p.text
                        })
                        .child(message),
                );
            }
        }
        if self
            .browser
            .git_actions
            .has_uncertain_push(self.browser.root.as_ref())
        {
            panel = panel.child(self.git_action_button(
                GitAction::CheckPush,
                Text::GitCheckPush,
                Icon::RotateCcw,
                false,
                p,
                cx,
            ));
        }
        panel
    }
}

fn git_feedback_message(feedback: &GitFeedback, locale: Locale) -> String {
    let text = match feedback {
        GitFeedback::Done(action) => match action {
            GitAction::Stage => Text::GitStageDone,
            GitAction::Commit => Text::GitCommitDone,
            GitAction::Fetch => Text::GitFetchDone,
            GitAction::Pull => Text::GitPullDone,
            GitAction::Push => Text::GitPushDone,
            GitAction::Remote => Text::GitRemoteDone,
            GitAction::Credentials => Text::GitCredentialDone,
            _ => return String::new(),
        },
        GitFeedback::Cancelled => Text::GitCancelled,
        GitFeedback::PushUncertain => Text::GitPushUncertain,
        GitFeedback::PushConfirmed => Text::GitPushConfirmed,
        GitFeedback::PushNotConfirmed => Text::GitPushNotConfirmed,
        GitFeedback::PushAcknowledged => Text::GitPushAcknowledged,
        GitFeedback::Error(error) => {
            let code = error.split(':').next().unwrap_or("").trim();
            let key = match code {
                "E_PROJECT_CONFLICT" => Text::GitStateChanged,
                "E_PROJECT_NON_FAST_FORWARD" => Text::GitNonFastForward,
                "E_PROJECT_CREDENTIAL" => Text::GitCredentialError,
                "E_WORKSPACE_CONFIRMATION" => Text::GitRemoteMissingError,
                "E_PROJECT_TIMEOUT" => Text::GitTimeout,
                "E_PROJECT_CANCELLED" => Text::GitCancelled,
                "E_PROJECT_RECOVERY_REQUIRED" => Text::GitRecoveryRequired,
                _ => Text::GitOperationFailed,
            };
            return if code.starts_with("E_")
                && code
                    .bytes()
                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
            {
                format!("{} ({code})", locale.text(key))
            } else {
                locale.text(key).to_owned()
            };
        }
    };
    locale.text(text).to_owned()
}
