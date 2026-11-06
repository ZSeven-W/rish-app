use super::{
    Shell,
    i18n::Text,
    theme::Palette,
    workspace_git::{GitState, git_error_message},
};
use crate::icons::{Icon, icon};
use gpui::{Context, Div, FontWeight, div, prelude::*, px};
use serde_json::Value;

impl Shell {
    pub(super) fn workspace_git(&self, split: bool, p: Palette, cx: &mut Context<Self>) -> Div {
        let mut content = div()
            .flex()
            .flex_col()
            .gap_3()
            .when(split, |s| s.flex_1().min_h(px(0.)));
        match &self.browser.git {
            GitState::Loading => content.child(self.workspace_loading(p)),
            GitState::Idle if self.aux_busy => content.child(self.workspace_loading(p)),
            GitState::Idle => content
                .child(self.workspace_empty(Icon::GitBranch, Text::GitNotLoaded, p))
                .child(
                    div()
                        .id("load-git")
                        .debug_selector(|| "load-git".into())
                        .min_h(px(48.))
                        .px_5()
                        .rounded(px(12.))
                        .bg(p.surface)
                        .cursor_pointer()
                        .flex()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .child(icon(Icon::RefreshCw, 18., p.text))
                        .child(self.locale.text(Text::Retry))
                        .on_click(cx.listener(|this, _, _, cx| this.load_git(cx))),
                ),
            GitState::Failed(error) => content
                .child(self.workspace_empty(Icon::GitBranch, Text::GitLoadFailed, p))
                .child(
                    div()
                        .text_size(px(13.))
                        .text_center()
                        .text_color(p.muted)
                        .whitespace_normal()
                        .child(git_error_message(error, self.locale)),
                )
                .child(
                    div()
                        .id("retry-git")
                        .debug_selector(|| "retry-git".into())
                        .min_h(px(48.))
                        .px_5()
                        .rounded(px(12.))
                        .bg(p.surface)
                        .cursor_pointer()
                        .flex()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .child(icon(Icon::RefreshCw, 18., p.text))
                        .child(self.locale.text(Text::Retry))
                        .on_click(cx.listener(|this, _, _, cx| this.load_git(cx))),
                ),
            GitState::Missing => {
                content = content.child(self.workspace_empty(Icon::GitBranch, Text::NoGit, p));
                if self.browser.can_initialize_git() {
                    content = content
                        .child(
                            div()
                                .max_w(px(340.))
                                .mx_auto()
                                .text_size(px(13.))
                                .text_center()
                                .text_color(p.muted)
                                .whitespace_normal()
                                .child(self.locale.text(Text::InitializeGitHint)),
                        )
                        .child(
                            div()
                                .id("initialize-repository")
                                .debug_selector(|| "initialize-repository".into())
                                .min_h(px(48.))
                                .px_5()
                                .rounded(px(12.))
                                .bg(p.accent)
                                .text_color(p.on_accent)
                                .flex()
                                .items_center()
                                .justify_center()
                                .gap_2()
                                .when(self.runtime.is_native() && !self.aux_busy, |s| {
                                    s.cursor_pointer()
                                })
                                .when(!self.runtime.is_native() || self.aux_busy, |s| {
                                    s.opacity(0.45)
                                })
                                .child(icon(Icon::GitBranch, 18., p.on_accent))
                                .child(self.locale.text(Text::InitializeGit))
                                .on_click(cx.listener(|this, _, _, cx| this.initialize_git(cx))),
                        );
                } else {
                    content = content.child(
                        div()
                            .text_size(px(13.))
                            .text_center()
                            .text_color(p.muted)
                            .whitespace_normal()
                            .child(self.locale.text(Text::GitInitializationUnavailable)),
                    );
                }
                content
            }
            GitState::Attached(git) => {
                if split {
                    div()
                        .flex_1()
                        .min_h(px(0.))
                        .flex()
                        .gap_4()
                        .child(
                            div()
                                .id("git-changes-pane")
                                .debug_selector(|| "git-changes-pane".into())
                                .w(px(320.))
                                .flex_shrink_0()
                                .h_full()
                                .overflow_y_scroll()
                                .child(self.git_branch_summary(git, p))
                                .child(self.git_operation_controls(p, cx))
                                .child(self.git_changed_files(git, p)),
                        )
                        .child(self.git_diff_panel(true, p))
                } else {
                    content
                        .child(self.git_branch_summary(git, p))
                        .child(self.git_operation_controls(p, cx))
                        .child(self.git_changed_files(git, p))
                        .child(self.git_diff_panel(false, p))
                }
            }
        }
    }
}

impl Shell {
    fn git_branch_summary(&self, git: &Value, p: Palette) -> Div {
        div()
            .mb_3()
            .p_4()
            .rounded(px(14.))
            .bg(p.composer)
            .border_1()
            .border_color(p.line)
            .flex()
            .items_center()
            .gap_3()
            .child(icon(Icon::GitBranch, 20., p.text))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .truncate()
                            .child(git["branch"].as_str().unwrap_or("HEAD").to_owned()),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .child(icon(Icon::ArrowUp, 13., p.muted))
                            .child(git["ahead"].to_string())
                            .child(icon(Icon::ArrowDown, 13., p.muted))
                            .child(git["behind"].to_string()),
                    ),
            )
    }

    fn git_changed_files(&self, git: &Value, p: Palette) -> Div {
        let entries: Vec<_> = git["entries"].as_array().into_iter().flatten().collect();
        if entries.is_empty() {
            return self.workspace_empty(Icon::Check, Text::NoGitChanges, p);
        }
        let mut content = div().mt_3().flex().flex_col().gap_3().child(
            div()
                .text_size(px(14.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(self.locale.text(Text::GitChanges)),
        );
        for (key, title) in [
            ("index_status", Text::GitStaged),
            ("worktree_status", Text::GitUnstaged),
        ] {
            let changed: Vec<_> = entries
                .iter()
                .filter(|entry| {
                    entry[key].as_str().is_some_and(|value| {
                        value != "unmodified" && value != "none" && !value.is_empty()
                    })
                })
                .collect();
            if changed.is_empty() {
                continue;
            }
            let mut group = div()
                .rounded(px(12.))
                .bg(p.composer)
                .border_1()
                .border_color(p.line)
                .overflow_hidden()
                .child(
                    div()
                        .px_3()
                        .py_2()
                        .text_size(px(12.))
                        .text_color(p.muted)
                        .child(format!("{} · {}", self.locale.text(title), changed.len())),
                );
            for entry in changed {
                let status = entry[key].as_str().unwrap_or("");
                let conflicted = entry["conflicted"] == true;
                let status_text = if conflicted {
                    Text::GitStatusConflict
                } else {
                    git_status_text(status)
                };
                let positive = status == "added" && key == "index_status" && !conflicted;
                let color = if conflicted {
                    p.danger
                } else if positive {
                    p.success
                } else {
                    p.muted
                };
                group = group.child(
                    div()
                        .min_h(px(48.))
                        .px_3()
                        .py_2()
                        .border_t_1()
                        .border_color(p.line)
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(icon(Icon::File, 16., color))
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .truncate()
                                .text_size(px(13.))
                                .child(entry["path"].as_str().unwrap_or("").to_owned()),
                        )
                        .child(
                            div()
                                .flex_shrink_0()
                                .px_2()
                                .py_1()
                                .rounded(px(6.))
                                .bg(if positive { p.success_soft } else { p.surface })
                                .text_color(color)
                                .text_size(px(11.))
                                .child(self.locale.text(status_text)),
                        ),
                );
            }
            content = content.child(group);
        }
        content
    }
}

fn git_status_text(status: &str) -> Text {
    match status {
        "added" | "untracked" | "new" => Text::GitStatusAdded,
        "modified" => Text::GitStatusModified,
        "deleted" => Text::GitStatusDeleted,
        "renamed" => Text::GitStatusRenamed,
        "copied" => Text::GitStatusCopied,
        "conflicted" | "conflict" => Text::GitStatusConflict,
        "typechange" | "typechanged" => Text::GitStatusTypeChanged,
        _ => Text::GitStatusUnknown,
    }
}
