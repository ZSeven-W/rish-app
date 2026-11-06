//! Exercise the real workspace component with the available content width,
//! independently of whether the parent is a phone screen or a conversation pane.
use super::*;
use gpui::{Bounds, Pixels, TestAppContext, VisualTestContext, WindowHandle, size};
use workspace_edit::{EditTarget, FileDraft, FileSnapshot};
use workspace_git::GitState;

struct WorkspaceHarness {
    shell: Entity<Shell>,
    inspector: bool,
}
impl Render for WorkspaceHarness {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.shell.update(cx, |shell, cx| {
            if self.inspector {
                shell
                    .workspace_inspector(
                        window.viewport_size().width.into(),
                        window.viewport_size().height.into(),
                        cx,
                    )
                    .into_any_element()
            } else {
                shell
                    .workspace_screen(window.viewport_size().width.into(), cx)
                    .into_any_element()
            }
        })
    }
}
struct Fixture {
    window: WindowHandle<WorkspaceHarness>,
    shell: Entity<Shell>,
    cx: VisualTestContext,
}
impl Fixture {
    fn new(page: Page) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(1060.), px(760.)), |_, cx| WorkspaceHarness {
            shell: cx.new(Shell::new),
            inspector: false,
        });
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        let shell = window.read_with(&cx, |view, _| view.shell.clone()).unwrap();
        shell.update(&mut cx, |shell, cx| {
            let root = json!({"schema_version":1,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024",
                "binding_revision":4,"project_id":"85ac8af6-b884-4b55-b63a-b46cabf56296"});
            shell.page = page;
            shell.loading = false;
            shell.aux_busy = false;
            shell.browser = Browser { root: Some(root.clone()), name: "Rish App".into(), path: "src".into(),
                generation: 19, capabilities: json!({"read":true,"write":true,"git":true}),
                entries: vec![json!({"path":"src/main.rs","name":"main.rs","kind":"file"}),
                    json!({"path":"src/lib.rs","name":"lib.rs","kind":"file"})],
                file: Some(FileSnapshot { root: root.clone(), path: "src/main.rs".into(), content: "// 中文内容\nfn main() {}".into(),
                    revision: "a".repeat(64), truncated: false }), ..Default::default() };
            shell.browser.git = GitState::Attached(json!({"schema_version":2,"root":root,
                "project_id":root["project_id"],"branch":"main","head_oid":"a".repeat(40),
                "clean":false,"has_conflicts":false,"ahead":1,"behind":0,
                "entries":[{"path":"src/main.rs","index_status":"modified","worktree_status":"modified","conflicted":false}]}));
            shell.browser.git_actions.metadata_root = Some(root.clone());
            shell.browser.git_actions.remote = Some(json!({"url":"https://example.test/rish/app.git"}));
            shell.browser.git_actions.diff = Some(json!({"staged":false,"truncated":false,
                "patch":"diff --git a/src/main.rs b/src/main.rs\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1 +1 @@\n-旧内容🙂\n+新内容🙂\n"}));
            cx.notify();
        });
        let mut fixture = Self { window, shell, cx };
        fixture.draw();
        fixture
    }
    fn draw(&mut self) {
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
    }
    fn inspector_size(&mut self, width: f32, height: f32) {
        self.window
            .update(&mut self.cx, |view, _, cx| {
                view.inspector = true;
                cx.notify();
            })
            .unwrap();
        self.cx.simulate_resize(size(px(width), px(height)));
        // Full refresh prevents test-only retained debug selectors from keeping
        // elements that were intentionally removed by the short-height fallback.
        self.cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear(cx);
        });
    }
    fn resize(&mut self, width: f32) {
        self.cx.simulate_resize(size(px(width), px(760.)));
        self.draw();
    }
    fn bounds(&mut self, selector: &'static str) -> Bounds<Pixels> {
        self.cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("Missing {selector}"))
    }
}

#[test]
fn tablet_files_show_directory_and_document_without_scaling_controls() {
    let mut fixture = Fixture::new(Page::Files);
    let directory = fixture.bounds("workspace-directory-pane");
    let document = fixture.bounds("workspace-document-pane");
    fixture.bounds("workspace-selected-entry");
    assert!(directory.size.width >= px(240.) && directory.size.width <= px(260.));
    assert!(document.origin.x > directory.right());
    assert!(document.size.width > directory.size.width);
    assert!(document.bottom() <= px(760.));
    let edit = fixture.bounds("workspace-edit-file");
    assert!(edit.size.height >= px(44.) && edit.size.height <= px(48.));
}

#[test]
fn narrowing_and_expanding_files_preserves_selection_and_unsaved_draft() {
    let mut fixture = Fixture::new(Page::Files);
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell.browser.edit.draft = Some(FileDraft {
            target: EditTarget {
                root: shell.browser.root.clone().unwrap(),
                path: "src/main.rs".into(),
                folder: "src".into(),
                generation: 19,
            },
            content: "// retained edit 🙂".into(),
            expected_revision: Some("a".repeat(64)),
            create_only: false,
            failed: true,
        });
        cx.notify();
    });
    for width in [600., 320., 760., 1060.] {
        fixture.resize(width);
        assert_eq!(
            fixture
                .cx
                .debug_bounds("workspace-directory-pane")
                .is_some(),
            width >= 760.
        );
        fixture.bounds("workspace-document-pane");
        fixture
            .window
            .read_with(&fixture.cx, |view, cx| {
                let shell = view.shell.read(cx);
                assert_eq!(shell.browser.file.as_ref().unwrap().path, "src/main.rs");
                assert_eq!(
                    shell.browser.file.as_ref().unwrap().content,
                    "// 中文内容\nfn main() {}"
                );
                assert_eq!(shell.browser.generation, 19);
                assert_eq!(
                    shell.browser.edit.draft.as_ref().unwrap().content,
                    "// retained edit 🙂"
                );
            })
            .unwrap();
    }
}

#[test]
fn tablet_git_keeps_actions_beside_full_diff_and_collapses_without_losing_it() {
    let mut fixture = Fixture::new(Page::Git);
    for width in [1060., 760., 600., 320., 1060.] {
        fixture.resize(width);
        let diff = fixture.bounds("git-diff-pane");
        if width >= 760. {
            let changes = fixture.bounds("git-changes-pane");
            assert_eq!(changes.size.width, px(320.));
            assert!(diff.origin.x > changes.right());
            assert!(diff.bottom() <= px(760.));
        } else {
            assert!(fixture.cx.debug_bounds("git-changes-pane").is_none());
        }
        for action in [
            "git-fetch",
            "git-pull",
            "git-push",
            "git-stage",
            "git-commit",
            "git-remote",
            "git-diff",
            "git-diff-staged",
        ] {
            let button = fixture.bounds(action);
            assert!(button.size.width >= px(44.) && button.size.height >= px(44.));
            assert!(button.origin.x >= px(19.5) && button.right() <= px(width - 19.5));
        }
        fixture
            .window
            .read_with(&fixture.cx, |view, cx| {
                assert!(
                    view.shell
                        .read(cx)
                        .browser
                        .git_actions
                        .diff
                        .as_ref()
                        .unwrap()["patch"]
                        .as_str()
                        .unwrap()
                        .contains("+新内容🙂")
                );
            })
            .unwrap();
    }
}

#[test]
fn tablet_pane_scroll_positions_survive_a_narrow_window_round_trip() {
    let mut fixture = Fixture::new(Page::Files);
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell.browser.entries = (0..60)
            .map(|n| {
                json!({"path":format!("src/file-{n}.rs"),
            "name":format!("file-{n}.rs"),"kind":"file"})
            })
            .collect();
        shell.browser.file.as_mut().unwrap().content = "// 中文内容\nfn main() {}\n".repeat(120);
        cx.notify();
    });
    fixture.draw();
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell
            .browser
            .files_directory_scroll
            .set_offset(gpui::point(px(0.), px(-120.)));
        shell
            .browser
            .files_document_scroll
            .set_offset(gpui::point(px(0.), px(-180.)));
        cx.notify();
    });
    fixture.draw();
    for width in [600., 1060.] {
        fixture.resize(width);
        fixture
            .window
            .read_with(&fixture.cx, |view, cx| {
                let browser = &view.shell.read(cx).browser;
                assert_eq!(browser.files_directory_scroll.offset().y, px(-120.));
                assert_eq!(browser.files_document_scroll.offset().y, px(-180.));
            })
            .unwrap();
    }
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell.page = Page::Git;
        shell.browser.git_actions.diff.as_mut().unwrap()["patch"] =
            json!("@@ -1 +1 @@\n-旧内容\n+新内容\n".repeat(120));
        cx.notify();
    });
    fixture.draw();
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell
            .browser
            .git_diff_scroll
            .set_offset(gpui::point(px(0.), px(-240.)));
        cx.notify();
    });
    fixture.draw();
    for width in [600., 1060.] {
        fixture.resize(width);
        fixture
            .window
            .read_with(&fixture.cx, |view, cx| {
                assert_eq!(
                    view.shell.read(cx).browser.git_diff_scroll.offset().y,
                    px(-240.)
                );
            })
            .unwrap();
    }
}

#[test]
fn sidebar_inspector_keeps_directory_above_selected_document_with_touchable_controls() {
    let mut fixture = Fixture::new(Page::Files);
    for width in [320., 340., 380.] {
        for height in [420., 600., 900.] {
            fixture.inspector_size(width, height);
            fixture.bounds("workspace-inspector");
            let directory = fixture.bounds("workspace-directory-pane");
            let document = fixture.bounds("workspace-document-pane");
            let selected = fixture.bounds("workspace-selected-entry");
            assert!(directory.size.height >= px(110.));
            assert!(document.origin.y > directory.bottom());
            assert!(document.size.height >= px(150.));
            assert!(document.bottom() <= px(height));
            assert!(document.right() <= px(width));
            assert!(selected.size.height >= px(44.) && selected.size.height <= px(48.));
            for selector in [
                "workspace-back",
                "workspace-new-file",
                "workspace-new-folder",
                "workspace-edit-file",
                "workspace-close-preview",
            ] {
                let control = fixture.bounds(selector);
                assert!(control.size.height >= px(44.) && control.size.width >= px(44.));
                assert!(control.origin.x >= px(0.) && control.right() <= px(width));
                assert!(control.bottom() <= px(height));
            }
        }
    }
}

#[test]
fn short_inspector_falls_back_without_losing_file_draft_or_independent_scroll_positions() {
    let mut fixture = Fixture::new(Page::Files);
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell.browser.entries = (0..60)
            .map(|n| json!({"path":format!("src/{n}.rs"), "name":format!("{n}.rs"), "kind":"file"}))
            .collect();
        shell.browser.file.as_mut().unwrap().content = "// retained 中文🙂\n".repeat(100);
        shell.browser.edit.draft = Some(FileDraft {
            target: EditTarget {
                root: shell.browser.root.clone().unwrap(),
                path: "src/main.rs".into(),
                folder: "src".into(),
                generation: 19,
            },
            content: "draft survives inspector".into(),
            expected_revision: Some("a".repeat(64)),
            create_only: false,
            failed: true,
        });
        cx.notify();
    });
    fixture.inspector_size(340., 900.);
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell
            .browser
            .files_directory_scroll
            .set_offset(gpui::point(px(0.), px(-120.)));
        shell
            .browser
            .files_document_scroll
            .set_offset(gpui::point(px(0.), px(-180.)));
        cx.notify();
    });
    fixture.draw();
    for height in [390., 900.] {
        fixture.inspector_size(340., height);
        assert_eq!(
            fixture.cx.debug_bounds("workspace-inspector").is_some(),
            height >= 580.
        );
        if height < 420. {
            fixture.bounds("workspace-back");
        }
        fixture
            .window
            .read_with(&fixture.cx, |view, cx| {
                let browser = &view.shell.read(cx).browser;
                assert_eq!(browser.file.as_ref().unwrap().path, "src/main.rs");
                assert_eq!(
                    browser.file.as_ref().unwrap().content,
                    "// retained 中文🙂\n".repeat(100)
                );
                assert_eq!(
                    browser.edit.draft.as_ref().unwrap().content,
                    "draft survives inspector"
                );
                assert_eq!(browser.files_directory_scroll.offset().y, px(-120.));
                assert_eq!(browser.files_document_scroll.offset().y, px(-180.));
                assert_eq!(browser.generation, 19);
            })
            .unwrap();
    }
}

#[test]
fn closing_sidebar_preview_reveals_full_directory_without_discarding_retained_draft() {
    let mut fixture = Fixture::new(Page::Files);
    fixture.shell.update(&mut fixture.cx, |shell, cx| {
        shell.browser.edit.draft = Some(FileDraft {
            target: EditTarget {
                root: shell.browser.root.clone().unwrap(),
                path: "src/main.rs".into(),
                folder: "src".into(),
                generation: 19,
            },
            content: "retained draft".into(),
            expected_revision: Some("a".repeat(64)),
            create_only: false,
            failed: true,
        });
        cx.notify();
    });
    fixture.inspector_size(340., 900.);
    let before = fixture.bounds("workspace-directory-pane").size.height;
    let close = fixture.bounds("workspace-close-preview").center();
    fixture.cx.simulate_click(close, gpui::Modifiers::none());
    fixture.inspector_size(340., 900.);
    assert!(fixture.bounds("workspace-directory-pane").size.height > before);
    assert!(fixture.cx.debug_bounds("workspace-document-pane").is_none());
    fixture
        .window
        .read_with(&fixture.cx, |view, cx| {
            let browser = &view.shell.read(cx).browser;
            assert!(browser.file.is_none());
            assert_eq!(
                browser.edit.draft.as_ref().unwrap().content,
                "retained draft"
            );
            assert_eq!(browser.path, "src");
        })
        .unwrap();
}
