use super::{Shell, i18n::Text, theme::Palette};
use crate::icons::{Icon, icon};
use gpui::{Context, Div, FontWeight, IntoElement, div, prelude::*, px};

impl Shell {
    pub(super) fn workspace_create_actions(
        &self,
        prominent: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> Div {
        let file_enabled = self.can_create_file();
        let folder_enabled = self.can_create_folder();
        div()
            .flex()
            .flex_wrap()
            .gap_2()
            .when(prominent, |s| s.justify_center())
            .child(
                div()
                    .id("workspace-new-file")
                    .debug_selector(|| "workspace-new-file".into())
                    .min_h(px(super::theme::HIT_TARGET.max(44.)))
                    .px_3()
                    .rounded(px(12.))
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_size(px(13.))
                    .font_weight(FontWeight::MEDIUM)
                    .bg(p.accent)
                    .text_color(p.on_accent)
                    .when(file_enabled, |s| {
                        s.cursor_pointer().active(|s| s.opacity(0.8))
                    })
                    .when(!file_enabled, |s| s.opacity(0.45))
                    .child(icon(Icon::File, 16., p.on_accent))
                    .child(self.locale.text(Text::NewFile))
                    .on_click(cx.listener(|this, _, _, cx| this.begin_new_file(cx))),
            )
            .child(
                div()
                    .id("workspace-new-folder")
                    .debug_selector(|| "workspace-new-folder".into())
                    .min_h(px(super::theme::HIT_TARGET.max(44.)))
                    .px_3()
                    .rounded(px(12.))
                    .border_1()
                    .border_color(p.line)
                    .bg(p.composer)
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_size(px(13.))
                    .when(folder_enabled, |s| {
                        s.cursor_pointer().hover(|s| s.bg(p.surface))
                    })
                    .when(!folder_enabled, |s| s.opacity(0.45))
                    .child(icon(Icon::FolderPlus, 17., p.text))
                    .child(self.locale.text(Text::NewFolder))
                    .on_click(cx.listener(|this, _, _, cx| this.begin_new_folder(cx))),
            )
    }

    pub(super) fn workspace_edit_control(
        &self,
        compact: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let enabled = self.can_edit_file();
        div()
            .id("workspace-edit-file")
            .role(gpui::Role::Button)
            .aria_label(self.locale.text(Text::EditFile))
            .debug_selector(|| "workspace-edit-file".into())
            .min_h(px(super::theme::HIT_TARGET.max(44.)))
            .px_3()
            .rounded(px(if compact { 8. } else { 12. }))
            .bg(if compact { p.composer } else { p.accent })
            .text_color(if compact { p.text } else { p.on_accent })
            .flex()
            .items_center()
            .gap_2()
            .text_size(px(13.))
            .when(enabled, |s| s.cursor_pointer().active(|s| s.opacity(0.8)))
            .when(!enabled, |s| s.opacity(0.45))
            .child(icon(
                Icon::SquarePen,
                16.,
                if compact { p.text } else { p.on_accent },
            ))
            .child(self.locale.text(Text::EditFile))
            .on_click(cx.listener(|this, _, _, cx| this.begin_edit_file(cx)))
    }

    pub(super) fn workspace_draft_banner(&self, p: Palette, cx: &mut Context<Self>) -> Div {
        div()
            .mb_4()
            .p_4()
            .rounded_xl()
            .border_1()
            .border_color(p.line)
            .bg(p.surface)
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .text_size(px(13.))
                    .font_weight(FontWeight::MEDIUM)
                    .child(self.locale.text(Text::DraftRetained)),
            )
            .when_some(self.browser.edit.draft.as_ref(), |banner, draft| {
                banner.child(
                    div()
                        .text_size(px(12.))
                        .text_color(p.muted)
                        .whitespace_normal()
                        .child(draft.target.path.clone()),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        div()
                            .id("workspace-resume-draft")
                            .min_h(px(super::theme::HIT_TARGET.max(44.)))
                            .px_3()
                            .rounded_lg()
                            .bg(p.composer)
                            .flex()
                            .items_center()
                            .text_size(px(13.))
                            .when(!self.aux_busy, |s| s.cursor_pointer())
                            .when(self.aux_busy, |s| s.opacity(0.45))
                            .child(self.locale.text(Text::ResumeDraft))
                            .on_click(cx.listener(|this, _, _, cx| this.reopen_file_draft(cx))),
                    )
                    .child(
                        div()
                            .id("workspace-discard-draft")
                            .min_h(px(super::theme::HIT_TARGET.max(44.)))
                            .px_3()
                            .flex()
                            .items_center()
                            .text_size(px(13.))
                            .text_color(p.muted)
                            .when(!self.aux_busy, |s| s.cursor_pointer())
                            .when(self.aux_busy, |s| s.opacity(0.45))
                            .child(self.locale.text(Text::DiscardDraft))
                            .on_click(cx.listener(|this, _, _, cx| this.discard_file_draft(cx))),
                    ),
            )
    }
}
