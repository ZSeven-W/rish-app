use super::{Page, Shell, i18n::Text, theme::Palette};
use crate::icons::{Icon, icon};
use gpui::{Context, Div, FontWeight, IntoElement, div, prelude::*, px, relative};

impl Shell {
    pub(super) fn workspace_screen(
        &self,
        content_width: f32,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let p = Palette::get(cx);
        let split = content_width >= 760. && self.browser.root.is_some();
        let browsing_busy = self.aux_busy && !self.browser.edit.busy();
        let mut content = div()
            .w_full()
            .mx_auto()
            .p(px(if split { 24. } else { 20. }))
            .flex()
            .flex_col()
            .when(split, |s| s.h_full().min_h(px(0.)))
            .when(!split, |s| s.max_w(px(760.)).min_h(relative(1.)));

        if self.has_file_draft() {
            content = content.child(self.workspace_draft_banner(p, cx).flex_shrink_0());
        }
        if self.browser.root.is_none() && self.browser.workspaces.is_empty() {
            content = content.justify_center().items_center().child(
                if self.aux_busy && !self.browser.workspaces_loaded {
                    self.workspace_loading(p)
                } else {
                    self.empty_workspaces(p, cx)
                },
            );
        } else if self.browser.root.is_none() {
            content = content.child(self.workspace_list(p, cx));
        } else {
            content = content.child(self.workspace_breadcrumb(p, cx).flex_shrink_0());
            if self.page == Page::Git {
                content = content.child(self.workspace_git(split, p, cx));
            } else if split {
                content = content.child(self.workspace_split(p, cx));
            } else {
                if browsing_busy {
                    content = content.child(self.workspace_loading(p));
                }
                if self.browser.file.is_some() {
                    content = content.child(self.workspace_file_preview(false, p, cx));
                } else if self.browser.entries.is_empty() {
                    if !browsing_busy {
                        content = content.child(self.workspace_empty_folder(p, cx));
                    }
                } else {
                    content = content
                        .when(self.browser.capabilities["write"] == true, |s| {
                            s.child(
                                div()
                                    .mb_4()
                                    .child(self.workspace_create_actions(false, p, cx)),
                            )
                        })
                        .child(self.workspace_files(false, p, cx));
                }
            }
        }
        if self.workspace_name_open {
            content = content.child(
                div()
                    .mt_4()
                    .p_3()
                    .rounded_xl()
                    .bg(p.composer)
                    .border_1()
                    .border_color(p.line)
                    .flex()
                    .gap_2()
                    .child(self.title_input.clone())
                    .child(
                        div()
                            .id("save-workspace")
                            .min_h(px(super::theme::HIT_TARGET.max(44.)))
                            .px_3()
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .child(self.locale.text(Text::Create))
                            .on_click(cx.listener(|this, _, _, cx| {
                                let name = this.title_input.read(cx).text();
                                this.create_workspace(name, cx);
                            })),
                    ),
            );
        }
        div()
            .id("workspace-content")
            .debug_selector(|| "workspace-content".into())
            .flex_1()
            .min_h(px(0.))
            .w_full()
            .when(split, |s| s.flex().flex_col().overflow_hidden())
            .when(!split, |s| {
                s.overflow_y_scroll()
                    .track_scroll(if self.conversation_workspace.selector {
                        &self.conversation_workspace.selector_scroll
                    } else if self.page == Page::Git {
                        &self.workspace_panel_git_scroll
                    } else {
                        &self.workspace_panel_files_scroll
                    })
            })
            .child(content)
    }

    fn empty_workspaces(&self, p: Palette, cx: &mut Context<Self>) -> Div {
        div()
            .w_full()
            .max_w(px(360.))
            .py_6()
            .flex()
            .flex_col()
            .items_center()
            .child(
                div()
                    .size(px(64.))
                    .rounded(px(20.))
                    .bg(p.surface)
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(icon(Icon::Folder, 28., p.text)),
            )
            .child(
                div()
                    .mt_6()
                    .text_size(px(22.))
                    .line_height(relative(1.35))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_center()
                    .child(self.locale.text(Text::FilesEmptyTitle)),
            )
            .child(
                div()
                    .mt_3()
                    .max_w(px(300.))
                    .text_size(px(14.))
                    .line_height(relative(1.6))
                    .text_color(p.muted)
                    .text_center()
                    .whitespace_normal()
                    .child(self.locale.text(Text::FilesEmptyHint)),
            )
            .child(
                div()
                    .id("create-workspace")
                    .debug_selector(|| "create-workspace".into())
                    .mt_6()
                    .min_h(px(48.))
                    .px_6()
                    .rounded(px(12.))
                    .bg(p.accent)
                    .text_color(p.on_accent)
                    .font_weight(FontWeight::MEDIUM)
                    .flex()
                    .items_center()
                    .justify_center()
                    .gap_2()
                    .when(self.runtime.is_native() && !self.aux_busy, |s| {
                        s.cursor_pointer().active(|s| s.opacity(0.8))
                    })
                    .when(!self.runtime.is_native() || self.aux_busy, |s| {
                        s.opacity(0.45)
                    })
                    .child(icon(Icon::FolderPlus, 18., p.on_accent))
                    .child(self.locale.text(Text::CreateWorkspace))
                    .on_click(cx.listener(|this, _, _, cx| this.begin_create_workspace(cx))),
            )
            .when(self.runtime.is_native(), |s| {
                s.child(
                    div()
                        .mt_4()
                        .text_size(px(12.))
                        .text_color(p.faint)
                        .child(self.locale.text(Text::LocalOnly)),
                )
            })
    }

    fn workspace_list(&self, p: Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let mut list = div()
            .id("workspace-choice-list")
            .role(gpui::Role::ListBox)
            .aria_label(self.locale.text(Text::Workspaces))
            .rounded(px(20.))
            .bg(p.composer)
            .border_1()
            .border_color(p.line)
            .overflow_hidden();
        for (index, workspace) in self.browser.workspaces.iter().cloned().enumerate() {
            let binding = rish_shell_core::workspace_binding(&workspace).ok();
            let unavailable = binding.is_none();
            let selected =
                binding.is_some() && binding.as_ref() == self.state.active_workspace_binding();
            list = list.child(
                div()
                    .id(workspace["workspace_id"].as_str().unwrap_or("").to_owned())
                    .debug_selector(move || format!("workspace-choice-{index}").into())
                    .role(gpui::Role::ListBoxOption)
                    .aria_label(workspace["display_name"].as_str().unwrap_or("").to_owned())
                    .aria_selected(selected)
                    .when(unavailable, |row| {
                        row.aria_description(self.locale.text(Text::WorkspaceUnavailable))
                            .opacity(0.65)
                    })
                    .min_h(px(76.))
                    .px_4()
                    .py_3()
                    .flex()
                    .items_center()
                    .gap_3()
                    .cursor_pointer()
                    .hover(|s| s.bg(p.surface))
                    .when(index > 0, |s| s.border_t_1().border_color(p.line))
                    .child(
                        div()
                            .size(px(40.))
                            .rounded_xl()
                            .bg(p.surface)
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon(Icon::Folder, 20., p.text)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div().text_size(px(15.)).truncate().child(
                                    workspace["display_name"].as_str().unwrap_or("").to_owned(),
                                ),
                            )
                            .when(unavailable, |s| {
                                s.child(
                                    div()
                                        .id(("workspace-choice-unavailable", index))
                                        .debug_selector(move || {
                                            format!("workspace-choice-unavailable-{index}").into()
                                        })
                                        .text_size(px(12.))
                                        .text_color(p.muted)
                                        .child(self.locale.text(Text::WorkspaceUnavailable)),
                                )
                            }),
                    )
                    .child(icon(
                        if selected {
                            Icon::Check
                        } else {
                            Icon::ChevronRight
                        },
                        17.,
                        p.faint,
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_workspace(workspace.clone(), cx)
                    })),
            );
        }
        div()
            .id("workspace-choices")
            .debug_selector(|| "workspace-choices".into())
            .child(
                div()
                    .mb_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.muted)
                            .child(self.locale.text(Text::Workspaces)),
                    )
                    .when(self.conversation_workspace.selector, |header| {
                        header.child(
                            div()
                                .id("cancel-workspace-selection")
                                .debug_selector(|| "cancel-workspace-selection".into())
                                .role(gpui::Role::Button)
                                .aria_label(self.locale.text(Text::Cancel))
                                .min_h(px(44.))
                                .px_3()
                                .rounded(px(12.))
                                .flex()
                                .items_center()
                                .cursor_pointer()
                                .hover(|s| s.bg(p.surface))
                                .child(self.locale.text(Text::Cancel))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.cancel_conversation_workspace_selection(cx)
                                })),
                        )
                    })
                    .child(
                        div()
                            .id("create-workspace")
                            .min_h(px(super::theme::HIT_TARGET.max(44.)))
                            .px_3()
                            .rounded(px(12.))
                            .flex()
                            .items_center()
                            .gap_2()
                            .when(self.runtime.is_native() && !self.aux_busy, |s| {
                                s.cursor_pointer().hover(|s| s.bg(p.surface))
                            })
                            .when(!self.runtime.is_native() || self.aux_busy, |s| {
                                s.opacity(0.45)
                            })
                            .child(icon(Icon::FolderPlus, 18., p.text))
                            .child(self.locale.text(Text::Create))
                            .on_click(
                                cx.listener(|this, _, _, cx| this.begin_create_workspace(cx)),
                            ),
                    ),
            )
            .when(self.aux_busy, |s| s.child(self.workspace_loading(p)))
            .child(list)
    }

    fn workspace_breadcrumb(&self, p: Palette, cx: &mut Context<Self>) -> Div {
        div()
            .mb_3()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .id("workspace-back")
                    .debug_selector(|| "workspace-back".into())
                    .min_h(px(super::theme::HIT_TARGET.max(44.)))
                    .flex()
                    .items_center()
                    .gap_2()
                    .cursor_pointer()
                    .child(icon(Icon::ChevronLeft, 20., p.text))
                    .child(
                        div()
                            .min_w(px(0.))
                            .flex_1()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(16.))
                                    .font_weight(FontWeight::MEDIUM)
                                    .child(self.browser.name.clone()),
                            )
                            .when(!self.browser.path.is_empty(), |s| {
                                s.child(
                                    div()
                                        .text_size(px(12.))
                                        .text_color(p.muted)
                                        .truncate()
                                        .child(self.browser.path.clone()),
                                )
                            }),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        if this.browser.file.take().is_some() {
                            this.browser.generation += 1;
                            cx.notify();
                            return;
                        }
                        if this.browser.path.is_empty() {
                            this.browser.root = None;
                            this.browser.generation += 1;
                            cx.notify();
                        } else {
                            let parent = this
                                .browser
                                .path
                                .rsplit_once('/')
                                .map(|(p, _)| p.to_owned())
                                .unwrap_or_default();
                            this.load_folder(parent, cx);
                        }
                    })),
            )
            .when(self.browser.capabilities["write"] != true, |s| {
                s.child(
                    div().flex().child(
                        div()
                            .px_2()
                            .py_1()
                            .rounded_md()
                            .bg(p.surface)
                            .text_size(px(11.))
                            .text_color(p.muted)
                            .child(self.locale.text(Text::ReadOnly)),
                    ),
                )
            })
    }

    pub(super) fn workspace_files(&self, compact: bool, p: Palette, cx: &mut Context<Self>) -> Div {
        let mut list = div()
            .rounded(px(14.))
            .bg(p.composer)
            .when(!compact, |s| s.border_1().border_color(p.line))
            .overflow_hidden();
        for (index, entry) in self.browser.entries.iter().cloned().enumerate() {
            let directory = entry["kind"] == "directory";
            let selected = self
                .browser
                .file
                .as_ref()
                .is_some_and(|file| entry["path"] == file.path);
            list = list.child(
                div()
                    .id(entry["path"].as_str().unwrap_or("").to_owned())
                    .min_h(px(if compact {
                        super::theme::HIT_TARGET.max(44.)
                    } else {
                        56.
                    }))
                    .px_3()
                    .py_2()
                    .when(selected, |s| {
                        s.bg(p.raised)
                            .debug_selector(|| "workspace-selected-entry".into())
                    })
                    .flex()
                    .items_center()
                    .gap(px(if compact { 8. } else { 12. }))
                    .cursor_pointer()
                    .hover(|s| s.bg(p.surface))
                    .when(index > 0 && !compact, |s| {
                        s.border_t_1().border_color(p.line)
                    })
                    .child(icon(
                        if directory { Icon::Folder } else { Icon::File },
                        if compact { 17. } else { 20. },
                        if directory { p.text } else { p.muted },
                    ))
                    .child(
                        div()
                            .min_w(px(0.))
                            .flex_1()
                            .truncate()
                            .text_size(px(if compact { 13. } else { 14. }))
                            .child(entry["name"].as_str().unwrap_or("").to_owned()),
                    )
                    .when(directory, |s| {
                        s.child(icon(Icon::ChevronRight, 16., p.faint))
                    })
                    .on_click(
                        cx.listener(move |this, _, _, cx| this.open_entry(entry.clone(), cx)),
                    ),
            );
        }
        list
    }

    pub(super) fn workspace_empty(&self, glyph: Icon, title: Text, p: Palette) -> Div {
        div()
            .py_6()
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap_4()
            .child(
                div()
                    .size(px(56.))
                    .rounded(px(18.))
                    .bg(p.surface)
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(icon(glyph, 24., p.muted)),
            )
            .child(
                div()
                    .max_w(px(300.))
                    .text_size(px(15.))
                    .text_center()
                    .text_color(p.muted)
                    .whitespace_normal()
                    .child(self.locale.text(title)),
            )
    }

    pub(super) fn workspace_loading(&self, p: Palette) -> Div {
        div()
            .py_4()
            .flex()
            .items_center()
            .justify_center()
            .gap_2()
            .text_size(px(13.))
            .text_color(p.muted)
            .child(icon(Icon::RefreshCw, 16., p.muted))
            .child(self.locale.text(Text::Loading))
    }
}
