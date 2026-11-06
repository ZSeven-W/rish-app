//! A real directory/document split. Resizing changes only the arrangement;
//! the browser remains the single owner of the selected file and draft.
use super::{Shell, i18n::Text, theme::Palette};
use crate::icons::{Icon, icon};
use gpui::{Context, Div, FontWeight, div, prelude::*, px, relative};

impl Shell {
    pub(super) fn workspace_split(&self, p: Palette, cx: &mut Context<Self>) -> Div {
        let browsing_busy = self.aux_busy && !self.browser.edit.busy();
        let mut directory = div()
            .w(px(260.))
            .h_full()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .rounded(px(18.))
            .border_1()
            .border_color(p.line)
            .bg(p.composer)
            .overflow_hidden()
            .when(self.browser.capabilities["write"] == true, |pane| {
                pane.child(
                    div()
                        .p_3()
                        .border_b_1()
                        .border_color(p.line)
                        .child(self.workspace_create_actions(false, p, cx)),
                )
            });
        let mut listing = div()
            .id("workspace-directory-pane")
            .debug_selector(|| "workspace-directory-pane".into())
            .flex_1()
            .min_h(px(0.))
            .w_full()
            .overflow_y_scroll()
            .track_scroll(&self.browser.files_directory_scroll)
            .p_2();
        if browsing_busy {
            listing = listing.child(self.workspace_loading(p));
        }
        if self.browser.entries.is_empty() {
            if !browsing_busy {
                listing = listing.child(self.workspace_empty(Icon::Folder, Text::NoFiles, p));
            }
        } else {
            listing = listing.child(self.workspace_files(true, p, cx));
        }
        directory = directory.child(listing);
        div()
            .flex_1()
            .min_h(px(0.))
            .w_full()
            .flex()
            .gap_4()
            .child(directory)
            .child(self.workspace_file_preview(true, p, cx))
    }

    pub(super) fn workspace_file_preview(
        &self,
        split: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> Div {
        self.workspace_document_pane(split, false, p, cx)
    }

    pub(super) fn workspace_document_pane(
        &self,
        split: bool,
        compact: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> Div {
        let mut panel = div()
            .flex_1()
            .min_w(px(0.))
            .flex()
            .flex_col()
            .when(!compact, |s| {
                s.rounded(px(18.)).border_1().border_color(p.line)
            })
            .when(compact, |s| s.border_t_1().border_color(p.line))
            .bg(p.composer)
            .when(split, |s| s.h_full().min_h(px(0.)).overflow_hidden());
        if let Some(file) = &self.browser.file {
            panel = panel
                .child(
                    div()
                        .px(px(if compact { 12. } else { 16. }))
                        .py(px(if compact { 4. } else { 16. }))
                        .flex_shrink_0()
                        .border_b_1()
                        .border_color(p.line)
                        .flex()
                        .items_center()
                        .gap(px(if compact { 8. } else { 12. }))
                        .child(icon(Icon::File, if compact { 16. } else { 19. }, p.muted))
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .flex()
                                .flex_col()
                                .gap_1()
                                .child(
                                    div()
                                        .text_size(px(if compact { 13. } else { 15. }))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .truncate()
                                        .child(
                                            file.path
                                                .rsplit('/')
                                                .next()
                                                .unwrap_or(&file.path)
                                                .to_owned(),
                                        ),
                                )
                                .when(split && !compact && file.path.contains('/'), |s| {
                                    s.child(
                                        div()
                                            .text_size(px(12.))
                                            .text_color(p.muted)
                                            .truncate()
                                            .child(file.path.clone()),
                                    )
                                }),
                        )
                        .when(self.browser.capabilities["write"] == true, |s| {
                            s.child(self.workspace_edit_control(compact, p, cx))
                        })
                        .when(compact, |s| {
                            s.child(
                                div()
                                    .id("workspace-close-preview")
                                    .debug_selector(|| "workspace-close-preview".into())
                                    .role(gpui::Role::Button)
                                    .aria_label(self.locale.text(Text::CloseFilePreview))
                                    .size(px(super::theme::HIT_TARGET.max(44.)))
                                    .flex_shrink_0()
                                    .rounded(px(8.))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .cursor_pointer()
                                    .hover(|s| s.bg(p.surface))
                                    .child(icon(Icon::X, 16., p.muted))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.browser.file = None;
                                        this.browser.generation += 1;
                                        cx.notify();
                                    })),
                            )
                        }),
                )
                .child(
                    div()
                        .id("workspace-document-pane")
                        .debug_selector(|| "workspace-document-pane".into())
                        .min_w(px(0.))
                        .w_full()
                        .p(px(if compact { 12. } else { 16. }))
                        .when(split, |s| {
                            s.flex_1()
                                .min_h(px(0.))
                                .overflow_y_scroll()
                                .track_scroll(&self.browser.files_document_scroll)
                        })
                        .font_family(super::theme::code_font_family())
                        .text_size(px(if compact { 12. } else { 13. }))
                        .line_height(relative(if compact { 1.55 } else { 1.65 }))
                        .whitespace_normal()
                        .child(file.content.clone()),
                );
        } else {
            panel = panel.child(
                div()
                    .id("workspace-document-pane")
                    .debug_selector(|| "workspace-document-pane".into())
                    .flex_1()
                    .min_h(px(0.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .p_5()
                    .child(self.workspace_empty(Icon::File, Text::FileSelectHint, p)),
            );
        }
        panel
    }

    pub(super) fn workspace_empty_folder(&self, p: Palette, cx: &mut Context<Self>) -> Div {
        self.workspace_empty(Icon::Folder, Text::NoFiles, p)
            .flex_1()
            .when(self.browser.capabilities["write"] == true, |empty| {
                empty
                    .child(
                        div()
                            .max_w(px(300.))
                            .text_size(px(13.))
                            .text_color(p.muted)
                            .text_center()
                            .whitespace_normal()
                            .child(self.locale.text(Text::FolderEmptyHint)),
                    )
                    .child(self.workspace_create_actions(true, p, cx))
            })
    }
}
