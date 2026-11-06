//! Compact conversation-side file browser. It shares browser state and scroll
//! handles with the focused workspace, and does not claim a recursive tree.
use super::{Page, Shell, i18n::Text, theme::Palette};
use crate::icons::{Icon, icon};
use gpui::{Context, IntoElement, div, prelude::*, px};

impl Shell {
    pub(super) fn workspace_inspector(
        &self,
        width: f32,
        available_height: f32,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        // A retained draft uses the same complete recovery banner as the focused
        // view. Reserve room for its controls before choosing two usable panes.
        let usable_height = available_height - if self.has_file_draft() { 160. } else { 0. };
        if self.page == Page::Git
            || self.browser.root.is_none()
            || usable_height < 420.
            || width >= 760.
        {
            return self.workspace_screen(width, cx).into_any_element();
        }
        let p = Palette::get(cx);
        let selected = self.browser.file.is_some();
        let directory_height = (usable_height * 0.40).clamp(168., 280.);
        let mut directory = div()
            .w_full()
            .min_h(px(0.))
            .flex()
            .flex_col()
            .when(selected, |s| s.h(px(directory_height)).flex_shrink_0())
            .when(!selected, |s| s.flex_1())
            .child(self.workspace_inspector_path(p, cx));
        let browsing_busy = self.aux_busy && !self.browser.edit.busy();
        let mut listing = div()
            .id("workspace-directory-pane")
            .debug_selector(|| "workspace-directory-pane".into())
            .w_full()
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll()
            .track_scroll(&self.browser.files_directory_scroll)
            .px_1()
            .pb_1();
        if browsing_busy {
            listing = listing.child(self.workspace_loading(p));
        }
        if self.browser.entries.is_empty() {
            if !browsing_busy {
                listing = listing.child(
                    div()
                        .p_4()
                        .text_size(px(13.))
                        .text_color(p.muted)
                        .whitespace_normal()
                        .child(self.locale.text(Text::NoFiles)),
                );
            }
        } else {
            listing = listing.child(self.workspace_files(true, p, cx));
        }
        directory = directory.child(listing);
        div()
            .id("workspace-content")
            .debug_selector(|| "workspace-content".into())
            .w_full()
            .flex_1()
            .min_h(px(0.))
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(p.composer)
            .child(
                div()
                    .id("workspace-inspector")
                    .debug_selector(|| "workspace-inspector".into())
                    .w_full()
                    .flex_1()
                    .min_h(px(0.))
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .when(self.has_file_draft(), |s| {
                        s.child(self.workspace_draft_banner(p, cx).m_3().flex_shrink_0())
                    })
                    .child(directory)
                    .when(selected, |s| {
                        s.child(self.workspace_document_pane(true, true, p, cx))
                    }),
            )
            .into_any_element()
    }

    fn workspace_inspector_path(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let can_back = !self.browser.path.is_empty() && !self.aux_busy;
        div()
            .min_h(px(super::theme::HIT_TARGET.max(44.)))
            .flex_shrink_0()
            .px_2()
            .flex()
            .items_center()
            .gap_1()
            .child(
                div()
                    .id("workspace-back")
                    .debug_selector(|| "workspace-back".into())
                    .min_h(px(super::theme::HIT_TARGET.max(44.)))
                    .flex_1()
                    .min_w(px(0.))
                    .px_1()
                    .flex()
                    .items_center()
                    .gap_2()
                    .when(can_back, |s| {
                        s.role(gpui::Role::Button)
                            .aria_label(self.locale.text(Text::Back))
                            .cursor_pointer()
                            .hover(|s| s.bg(p.surface))
                    })
                    .child(icon(
                        if self.browser.path.is_empty() {
                            Icon::Folder
                        } else {
                            Icon::ChevronLeft
                        },
                        16.,
                        p.muted,
                    ))
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.))
                            .text_color(p.muted)
                            .child(if self.browser.path.is_empty() {
                                "/".to_owned()
                            } else {
                                self.browser.path.clone()
                            }),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        if this.browser.path.is_empty() || this.aux_busy {
                            return;
                        }
                        let parent = this
                            .browser
                            .path
                            .rsplit_once('/')
                            .map(|(parent, _)| parent.to_owned())
                            .unwrap_or_default();
                        this.load_folder(parent, cx);
                    })),
            )
            .when(self.browser.capabilities["write"] == true, |s| {
                s.child(self.workspace_inspector_create(false, p, cx))
                    .child(self.workspace_inspector_create(true, p, cx))
            })
    }

    fn workspace_inspector_create(
        &self,
        folder: bool,
        p: Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let enabled = if folder {
            self.can_create_folder()
        } else {
            self.can_create_file()
        };
        let id = if folder {
            "workspace-new-folder"
        } else {
            "workspace-new-file"
        };
        let label = self.locale.text(if folder {
            Text::NewFolder
        } else {
            Text::NewFile
        });
        div()
            .id(id)
            .debug_selector(move || id.into())
            .role(gpui::Role::Button)
            .aria_label(label)
            .size(px(super::theme::HIT_TARGET.max(44.)))
            .flex_shrink_0()
            .rounded(px(8.))
            .flex()
            .items_center()
            .justify_center()
            .when(enabled, |s| s.cursor_pointer().hover(|s| s.bg(p.surface)))
            .when(!enabled, |s| s.opacity(0.40))
            .child(icon(
                if folder { Icon::FolderPlus } else { Icon::File },
                17.,
                p.muted,
            ))
            .on_click(cx.listener(move |this, _, _, cx| {
                if folder {
                    this.begin_new_folder(cx);
                } else {
                    this.begin_new_file(cx);
                }
            }))
    }
}
