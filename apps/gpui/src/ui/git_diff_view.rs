//! Diff text is the exact native patch. Highlighting adds no synthetic lines,
//! counters, file-selection controls or claims about a reviewed index snapshot.
use super::{Shell, i18n::Text, theme::Palette};
use crate::icons::{Icon, icon};
use gpui::{Div, FontWeight, HighlightStyle, StyledText, div, prelude::*, px, relative};
use std::ops::Range;

impl Shell {
    pub(super) fn git_diff_panel(&self, split: bool, p: Palette) -> Div {
        if !split && self.browser.git_actions.diff.is_none() {
            return div();
        }
        let diff = self.browser.git_actions.diff.as_ref();
        let title = if diff.is_some_and(|diff| diff["staged"] == true) {
            Text::GitDiffStaged
        } else {
            Text::GitDiff
        };
        let mut panel = div()
            .flex_1()
            .min_w(px(0.))
            .flex()
            .flex_col()
            .rounded(px(18.))
            .border_1()
            .border_color(p.line)
            .bg(p.composer)
            .when(split, |s| s.h_full().min_h(px(0.)).overflow_hidden())
            .when(!split, |s| s.mt_4());
        panel = panel.child(
            div()
                .p_4()
                .flex_shrink_0()
                .border_b_1()
                .border_color(p.line)
                .flex()
                .items_center()
                .gap_2()
                .child(icon(Icon::CodeXml, 18., p.muted))
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(self.locale.text(title)),
                ),
        );
        if let Some(diff) = diff {
            if diff["truncated"] == true {
                panel = panel.child(
                    div()
                        .px_4()
                        .py_2()
                        .bg(p.surface)
                        .flex_shrink_0()
                        .text_size(px(12.))
                        .text_color(p.muted)
                        .whitespace_normal()
                        .child(self.locale.text(Text::GitDiffTruncated)),
                );
            }
            let patch = diff["patch"].as_str().unwrap_or("");
            let text = if patch.is_empty() {
                self.locale.text(Text::GitDiffEmpty)
            } else {
                patch
            };
            panel = panel.child(
                div()
                    .id("git-diff-pane")
                    .debug_selector(|| "git-diff-pane".into())
                    .min_w(px(0.))
                    .w_full()
                    .p_4()
                    .when(split, |s| {
                        s.flex_1()
                            .min_h(px(0.))
                            .overflow_y_scroll()
                            .track_scroll(&self.browser.git_diff_scroll)
                    })
                    .font_family(super::theme::code_font_family())
                    .text_size(px(12.))
                    .line_height(relative(1.65))
                    .whitespace_normal()
                    .child(
                        StyledText::new(text.to_owned())
                            .with_highlights(patch_highlights(patch, p)),
                    ),
            );
        } else {
            panel = panel.child(
                div()
                    .id("git-diff-pane")
                    .debug_selector(|| "git-diff-pane".into())
                    .flex_1()
                    .min_h(px(0.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .p_5()
                    .child(self.workspace_empty(Icon::CodeXml, Text::GitSelectDiffHint, p)),
            );
        }
        panel
    }
}

fn patch_highlights(patch: &str, p: Palette) -> Vec<(Range<usize>, HighlightStyle)> {
    let mut offset = 0;
    let mut highlights = Vec::new();
    for line in patch.split_inclusive('\n') {
        let color =
            if line.starts_with("+++") || line.starts_with("---") || line.starts_with("diff ") {
                Some(p.muted)
            } else if line.starts_with('+') {
                Some(p.success)
            } else if line.starts_with('-') {
                Some(p.danger)
            } else if line.starts_with("@@") {
                Some(p.muted)
            } else {
                None
            };
        if let Some(color) = color {
            highlights.push((
                offset..offset + line.len(),
                HighlightStyle {
                    color: Some(color),
                    ..Default::default()
                },
            ));
        }
        offset += line.len();
    }
    highlights
}

#[cfg(all(test, not(any(target_os = "ios", target_os = "android"))))]
mod tests {
    use super::*;
    #[test]
    fn diff_highlights_preserve_unicode_boundaries_and_native_text() {
        let app = gpui::TestAppContext::single();
        app.update(|cx| {
            let patch = "diff --git a/中文.md b/中文.md\n--- a/中文.md\n+++ b/中文.md\n@@ -1 +1 @@\n-旧内容🙂\n+新内容🙂\n unchanged\n";
            let highlights = patch_highlights(patch, Palette::get(cx));
            assert_eq!(highlights.len(), 6);
            let mut end = 0;
            for (range, _) in highlights {
                assert!(range.start >= end);
                assert!(patch.is_char_boundary(range.start));
                assert!(patch.is_char_boundary(range.end));
                end = range.end;
            }
            assert_eq!(&patch[end..], " unchanged\n");
        });
    }
}
