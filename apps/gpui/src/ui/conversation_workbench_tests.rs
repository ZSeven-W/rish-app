//! Exercise the full shell: conversation tools share state with the chat and
//! consume the space left by global navigation, rather than the device width.
use super::*;
use gpui::{
    Bounds, Focusable, Modifiers, Pixels, ScrollDelta, ScrollWheelEvent, TestAppContext,
    TouchPhase, VisualTestContext, WindowHandle, point, size,
};
use workspace_edit::{EditTarget, FileDraft, FileSnapshot};
use workspace_git::GitState;

#[path = "conversation_workspace_selector_tests.rs"]
mod workspace_selector_tests;

const PANEL_CONTROLS: [&str; 4] = [
    "conversation-files",
    "conversation-git",
    "workspace-panel-close",
    "refresh-workspaces",
];
const GIT_ACTIONS: [&str; 8] = [
    "git-fetch",
    "git-pull",
    "git-push",
    "git-stage",
    "git-commit",
    "git-remote",
    "git-diff",
    "git-diff-staged",
];

struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
    width: f32,
    height: f32,
}

impl Fixture {
    fn new(width: f32, height: f32, page: Page, locale: Locale) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(height)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window.update(&mut cx, |shell, _, cx| {
            shell.state = ShellState::with_test_models();
            shell.state.load_snapshot(json!({"schema_version":1,"status":"missing"})).unwrap();
            shell.state.set_default_workspace(json!({
                "schema_version":2,"workspace_id":"845d980b-8acd-4710-a54c-7975b6839024",
                "binding_revision":1,"display_name":"Rish workspace with a descriptive name",
                "status":"ok","capabilities":{"read":true,"write":true,"git":true}
            })).unwrap();
            let command = shell.state.create_conversation(
                "aaaaaaaa-aaaa-4aaa-8aaa-000000000001", "2026-10-15T00:00:00.000Z",
                "deepseek-v4-flash",
            ).unwrap();
            commit_candidate(&mut shell.state, command);
            shell.locale = locale;
            shell.page = page;
            shell.loading = false;
            shell.aux_busy = false;
            shell.notice = None;
            shell.sync_conversation_workspace(cx);
            let mut root = shell.browser.root.clone().unwrap();
            if page == Page::Git {
                root["project_id"] = json!("85ac8af6-b884-4b55-b63a-b46cabf56296");
                shell.browser.root = Some(root.clone());
            }
            shell.browser.path = "src".into();
            shell.browser.entries = vec![
                json!({"path":"src/main.rs","name":"main.rs","kind":"file"}),
                json!({"path":"src/lib.rs","name":"lib.rs","kind":"file"}),
            ];
            shell.browser.file = Some(FileSnapshot {
                root: root.clone(), path: "src/main.rs".into(),
                content: "// 中文内容\nfn main() {}".into(),
                revision: "a".repeat(64), truncated: false,
            });
            shell.browser.git = GitState::Attached(json!({
                "schema_version":2,"root":root,"project_id":root["project_id"],
                "branch":"main","head_oid":"a".repeat(40),"clean":false,
                "has_conflicts":false,"ahead":1,"behind":0,
                "entries":[{"path":"src/main.rs","index_status":"modified",
                    "worktree_status":"modified","conflicted":false}]
            }));
            shell.browser.git_actions.metadata_root = Some(root.clone());
            shell.browser.git_actions.remote = Some(json!({
                "url":"https://example.test/rish/app.git","host":"example.test"
            }));
            shell.browser.git_actions.diff = Some(json!({
                "staged":false,"truncated":false,
                "patch":"diff --git a/src/main.rs b/src/main.rs\n@@ -1 +1 @@\n-旧内容\n+新内容\n"
            }));
            cx.notify();
        }).unwrap();
        let mut fixture = Self {
            window,
            cx,
            width,
            height,
        };
        fixture.draw();
        fixture
    }

    fn draw(&mut self) {
        self.cx.run_until_parked();
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
    }

    fn bounds(&mut self, selector: &'static str) -> Bounds<Pixels> {
        self.cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"))
    }

    fn read<R>(&self, f: impl FnOnce(&Shell, &App) -> R) -> R {
        self.window.read_with(&self.cx, f).unwrap()
    }

    fn update(&mut self, f: impl FnOnce(&mut Shell, &mut Window, &mut Context<Shell>)) {
        self.window.update(&mut self.cx, f).unwrap();
        self.draw();
    }

    fn click(&mut self, selector: &'static str) {
        let point = self.bounds(selector).center();
        self.cx.simulate_click(point, Modifiers::none());
        self.draw();
    }

    fn resize(&mut self, width: f32, height: f32) {
        self.width = width;
        self.height = height;
        self.cx.simulate_resize(size(px(width), px(height)));
        self.draw();
    }

    fn assert_controls(&mut self, selectors: &[&'static str], area: Bounds<Pixels>) {
        let controls: Vec<_> = selectors
            .iter()
            .map(|name| {
                let bounds = self.bounds(name);
                assert!(
                    bounds.size.width >= px(44.),
                    "{name} is too narrow: {bounds:?}"
                );
                assert!(
                    bounds.size.height >= px(44.),
                    "{name} is too short: {bounds:?}"
                );
                assert!(
                    bounds.left() >= area.left() - px(0.5)
                        && bounds.right() <= area.right() + px(0.5),
                    "{name} escaped horizontal bounds: {bounds:?}, area {area:?}"
                );
                assert!(
                    bounds.top() >= area.top() - px(0.5)
                        && bounds.bottom() <= area.bottom() + px(0.5),
                    "{name} is not reachable in the visible viewport: {bounds:?}, area {area:?}"
                );
                (*name, bounds)
            })
            .collect();
        for (index, (name, bounds)) in controls.iter().enumerate() {
            for (other_name, other) in &controls[index + 1..] {
                assert!(!overlap(*bounds, *other), "{name} overlaps {other_name}");
            }
        }
    }

    fn viewport(&self) -> Bounds<Pixels> {
        Bounds {
            origin: gpui::point(px(0.), px(0.)),
            size: size(px(self.width), px(self.height)),
        }
    }

    fn assert_panel_controls(&mut self, area: Bounds<Pixels>) {
        let mut controls = PANEL_CONTROLS.to_vec();
        if self.cx.debug_bounds("workspace-panel-workspace").is_some() {
            controls.push("workspace-panel-workspace");
        }
        if self.cx.debug_bounds("workbench-focus").is_some() {
            controls.push("workbench-focus");
        }
        self.assert_controls(&controls, area);
    }
}

fn commit_candidate(state: &mut ShellState, command: RuntimeCommand) {
    let raw = command.args[0]["candidate_json"].as_str().unwrap();
    let digest = rish_agent_core::session_schema::candidate_digest(raw.as_bytes()).unwrap();
    state
        .accept_persist(json!({"schema_version":1,"status":"committed",
        "snapshot":{"schema_version":1,"generation":1,"session_sha256":digest}}))
        .unwrap();
}

fn overlap(a: Bounds<Pixels>, b: Bounds<Pixels>) -> bool {
    a.left() < b.right() - px(0.5)
        && b.left() < a.right() - px(0.5)
        && a.top() < b.bottom() - px(0.5)
        && b.top() < a.bottom() - px(0.5)
}

#[test]
fn phone_keeps_chat_clear_and_opens_tools_in_a_modal_bottom_sheet() {
    for locale in [Locale::Zh, Locale::En] {
        let mut fixture = Fixture::new(393., 852., Page::Chat, locale);
        let entities =
            fixture.read(|shell, _| (shell.composer.entity_id(), shell.transcript.entity_id()));
        let session = fixture.read(|shell, _| shell.state.raw_session().clone());
        let chat = fixture.bounds("chat-page");
        let composer = fixture.bounds("composer-card");
        fixture.assert_controls(
            &["workspace-toggle", "conversation-workspace"],
            fixture.viewport(),
        );
        let workspace = fixture.bounds("conversation-workspace");
        assert!(composer.contains(&workspace.center()));
        assert!(workspace.left() >= composer.left() && workspace.right() <= composer.right());
        assert!(fixture.cx.debug_bounds("conversation-files").is_none());
        assert!(fixture.cx.debug_bounds("conversation-git").is_none());
        assert!(fixture.cx.debug_bounds("conversation-chat").is_none());
        fixture.click("workspace-toggle");
        let sheet = fixture.bounds("workspace-panel-sheet");
        assert!(sheet.size.height >= px(852. * 0.80) && sheet.size.height <= px(852. * 0.86));
        assert!(sheet.top() > px(100.) && sheet.bottom() <= px(852.));
        fixture.assert_panel_controls(sheet);
        fixture.bounds("workspace-document-pane");
        assert_eq!(fixture.bounds("chat-page"), chat);
        assert_eq!(fixture.bounds("composer-card"), composer);
        assert!(fixture.cx.debug_bounds("workbench-chat-pane").is_none());
        assert!(fixture.cx.debug_bounds("workbench-focus").is_none());
        fixture.click("workspace-panel-close");
        assert!(fixture.cx.debug_bounds("workspace-panel-sheet").is_none());
        assert_eq!(fixture.bounds("chat-page"), chat);
        fixture.read(|shell, _| {
            assert_eq!(
                (shell.composer.entity_id(), shell.transcript.entity_id()),
                entities
            );
            assert_eq!(shell.state.raw_session(), &session);
            assert!(shell.page == Page::Chat);
            assert!(shell.state.active_workspace_binding().is_some());
        });
    }
}

#[test]
fn tablet_workspace_is_a_trailing_sidebar_that_leaves_the_conversation_primary() {
    for locale in [Locale::Zh, Locale::En] {
        for (width, height) in [(1194., 834.), (1366., 1024.)] {
            for page in [Page::Files, Page::Git] {
                let mut fixture = Fixture::new(width, height, page, locale);
                let workbench = fixture.bounds("conversation-workbench");
                let chat = fixture.bounds("workbench-chat-pane");
                let tools = fixture.bounds("workbench-tools-pane");
                assert!(tools.size.width >= px(340.) && tools.size.width <= px(380.));
                assert!(chat.size.width > tools.size.width);
                assert!(chat.right() <= tools.left() + px(0.5));
                assert!(
                    (chat.size.width + tools.size.width - workbench.size.width).abs() <= px(1.)
                );
                assert!(chat.left() >= workbench.left() && tools.right() <= workbench.right());
                assert!((tools.right() - px(width)).abs() <= px(1.));
                assert!(workbench.bottom() <= px(height));
                fixture.assert_panel_controls(tools);
                assert!(
                    fixture
                        .cx
                        .debug_bounds("workspace-panel-workspace")
                        .is_none()
                );
                let header = fixture.bounds("workspace-panel-header");
                let tabs = fixture.bounds("workspace-panel-tabs");
                let body = fixture.bounds("workspace-panel-body");
                assert_eq!(header.size.height, px(44.));
                assert_eq!(tabs.size.height, px(44.));
                assert!(body.top() - tools.top() <= px(89.));
                let composer = fixture.bounds("composer-card");
                assert!(composer.contains(&fixture.bounds("conversation-workspace").center()));
                fixture.assert_controls(&["composer-send"], chat);
                assert!(fixture.cx.debug_bounds("workspace-panel-sheet").is_none());
                assert!(fixture.cx.debug_bounds("git-changes-pane").is_none());
                if page == Page::Git {
                    assert!(
                        fixture
                            .cx
                            .debug_bounds("workspace-directory-pane")
                            .is_none()
                    );
                    fixture.assert_controls(&GIT_ACTIONS, tools);
                } else {
                    fixture.assert_controls(&["workspace-edit-file"], tools);
                    let directory = fixture.bounds("workspace-directory-pane");
                    let document = fixture.bounds("workspace-document-pane");
                    assert!(directory.bottom() < document.top());
                    assert!(directory.left() >= tools.left() && document.right() <= tools.right());
                }
            }
        }
    }
}

#[test]
fn expanding_the_sidebar_uses_tablet_space_for_directory_or_changes_and_preview() {
    for page in [Page::Files, Page::Git] {
        let mut fixture = Fixture::new(1194., 834., page, Locale::Zh);
        let entities =
            fixture.read(|shell, _| (shell.composer.entity_id(), shell.transcript.entity_id()));
        fixture.click("workbench-focus");
        fixture.assert_panel_controls(fixture.viewport());
        assert!(fixture.read(|shell, _| shell.workspace_focus));
        assert!(fixture.cx.debug_bounds("chat-page").is_none());
        assert!(fixture.cx.debug_bounds("workbench-chat-pane").is_none());
        assert!(fixture.cx.debug_bounds("composer-card").is_none());
        let (leading, detail) = if page == Page::Files {
            (
                fixture.bounds("workspace-directory-pane"),
                fixture.bounds("workspace-document-pane"),
            )
        } else {
            (
                fixture.bounds("git-changes-pane"),
                fixture.bounds("git-diff-pane"),
            )
        };
        assert!(leading.right() < detail.left());
        assert!(detail.right() <= px(1194.) && detail.bottom() <= px(834.));
        if page == Page::Files {
            fixture.assert_controls(
                &[
                    "workspace-new-file",
                    "workspace-new-folder",
                    "workspace-edit-file",
                ],
                fixture.viewport(),
            );
        } else {
            fixture.assert_controls(&GIT_ACTIONS, fixture.viewport());
        }
        fixture.click("workbench-focus");
        fixture.bounds("workbench-chat-pane");
        fixture.bounds("composer-card");
        fixture.read(|shell, _| {
            assert!(!shell.workspace_focus);
            assert_eq!(
                (shell.composer.entity_id(), shell.transcript.entity_id()),
                entities
            );
        });
    }
}

#[test]
fn modal_sheet_captures_focus_and_dismisses_without_activating_the_chat_behind_it() {
    let mut fixture = Fixture::new(393., 852., Page::Chat, Locale::En);
    fixture.update(|shell, window, cx| {
        shell
            .composer
            .update(cx, |input, cx| input.set_text("Keep chat draft".into(), cx));
        window.focus(&shell.composer.read(cx).focus_handle(cx), cx);
    });
    let session = fixture.read(|shell, _| shell.state.raw_session().clone());
    let drawer = fixture.bounds("drawer-open").center();
    for close_with_escape in [false, true] {
        fixture.click("workspace-toggle");
        fixture
            .window
            .update(&mut fixture.cx, |shell, window, _| {
                assert!(shell.workspace_panel_focus.is_focused(window));
            })
            .unwrap();
        fixture.cx.simulate_keystrokes("x");
        fixture.draw();
        assert_eq!(
            fixture.read(|shell, cx| shell.composer.read(cx).text()),
            "Keep chat draft"
        );
        if close_with_escape {
            fixture.cx.simulate_keystrokes("escape");
        } else {
            assert!(!fixture.bounds("workspace-panel-sheet").contains(&drawer));
            fixture.cx.simulate_click(drawer, Modifiers::none());
        }
        fixture.draw();
        assert!(fixture.cx.debug_bounds("workspace-panel-sheet").is_none());
        fixture
            .window
            .update(&mut fixture.cx, |shell, window, cx| {
                assert!(shell.composer.read(cx).focus_handle(cx).is_focused(window));
                assert!(!shell.drawer_open);
                assert_eq!(shell.state.raw_session(), &session);
            })
            .unwrap();
    }
}

#[test]
fn resizing_the_workspace_between_sheet_sidebar_and_focused_view_keeps_drafts_and_scrolls() {
    let mut fixture = Fixture::new(1194., 834., Page::Files, Locale::En);
    fixture.click("workbench-focus");
    fixture.update(|shell, _, cx| {
        shell.composer.update(cx, |input, cx| {
            input.set_text("Retain chat draft".into(), cx)
        });
        shell.browser.entries = (0..60)
            .map(|n| {
                json!({
                    "path":format!("src/file-{n}.rs"),"name":format!("file-{n}.rs"),"kind":"file"
                })
            })
            .collect();
        shell.browser.file.as_mut().unwrap().content = "// 中文内容\nfn main() {}\n".repeat(120);
        shell.browser.edit.draft = Some(FileDraft {
            target: EditTarget {
                root: shell.browser.root.clone().unwrap(),
                path: "src/main.rs".into(),
                folder: "src".into(),
                generation: shell.browser.generation,
            },
            content: "Retain unsaved file text 🙂".into(),
            expected_revision: Some("a".repeat(64)),
            create_only: false,
            failed: true,
        });
        cx.notify();
    });
    fixture.update(|shell, _, cx| {
        shell
            .browser
            .files_directory_scroll
            .set_offset(point(px(0.), px(-120.)));
        shell
            .browser
            .files_document_scroll
            .set_offset(point(px(0.), px(-180.)));
        cx.notify();
    });
    let entities =
        fixture.read(|shell, _| (shell.composer.entity_id(), shell.transcript.entity_id()));
    let session = fixture.read(|shell, _| shell.state.raw_session().clone());
    for (width, height) in [(393., 852.), (834., 1194.), (1366., 1024.), (1194., 834.)] {
        fixture.resize(width, height);
        fixture.bounds("workspace-document-pane");
        let narrow = width < 1194.;
        assert_eq!(
            fixture.cx.debug_bounds("workspace-panel-sheet").is_some(),
            narrow
        );
        assert_eq!(fixture.cx.debug_bounds("chat-page").is_some(), narrow);
        assert_eq!(
            fixture
                .cx
                .debug_bounds("workspace-directory-pane")
                .is_some(),
            !narrow
        );
        fixture.read(|shell, cx| {
            assert_eq!(
                (shell.composer.entity_id(), shell.transcript.entity_id()),
                entities
            );
            assert_eq!(shell.composer.read(cx).text(), "Retain chat draft");
            assert_eq!(shell.browser.file.as_ref().unwrap().path, "src/main.rs");
            assert_eq!(
                shell.browser.edit.draft.as_ref().unwrap().content,
                "Retain unsaved file text 🙂"
            );
            assert_eq!(shell.browser.files_directory_scroll.offset().y, px(-120.));
            assert_eq!(shell.browser.files_document_scroll.offset().y, px(-180.));
            assert_eq!(shell.state.raw_session(), &session);
        });
    }
}

#[test]
fn small_landscape_sheet_keeps_navigation_fixed_and_retains_scroll_after_close() {
    let mut fixture = Fixture::new(740., 360., Page::Files, Locale::Zh);
    fixture.update(|shell, _, cx| {
        shell.browser.file.as_mut().unwrap().content = "// A scrollable document\n".repeat(180);
        cx.notify();
    });
    let sheet = fixture.bounds("workspace-panel-sheet");
    let content = fixture.bounds("workspace-content");
    fixture.assert_panel_controls(sheet);
    assert!(sheet.top() >= px(0.) && sheet.bottom() <= px(360.));
    assert!(content.size.height >= px(80.));
    assert!(content.bottom() <= sheet.bottom());
    let close = fixture.bounds("workspace-panel-close");
    fixture.cx.simulate_event(ScrollWheelEvent {
        position: content.center(),
        delta: ScrollDelta::Pixels(point(px(0.), px(-200.))),
        modifiers: Modifiers::none(),
        touch_phase: TouchPhase::Moved,
    });
    fixture.draw();
    let offset = fixture.read(|shell, _| shell.workspace_panel_files_scroll.offset());
    assert!(offset.y < px(0.), "the body must really scroll");
    assert_eq!(fixture.bounds("workspace-panel-close"), close);
    fixture.click("workspace-panel-close");
    fixture.click("workspace-toggle");
    assert_eq!(
        fixture.read(|shell, _| shell.workspace_panel_files_scroll.offset()),
        offset
    );
    assert_eq!(fixture.bounds("workspace-panel-close"), close);
}

#[test]
fn workspace_selector_and_file_git_tabs_remain_real_click_targets_inside_the_panel() {
    for width in [393., 1194.] {
        let mut fixture = Fixture::new(width, 852., Page::Chat, Locale::Zh);
        fixture.click("workspace-toggle");
        let area = if width < 1194. {
            fixture.bounds("workspace-panel-sheet")
        } else {
            fixture.bounds("workbench-tools-pane")
        };
        fixture.assert_panel_controls(area);
        fixture.click(if width < 1194. {
            "workspace-panel-workspace"
        } else {
            "conversation-workspace"
        });
        assert!(fixture.read(|shell, _| shell.conversation_workspace.selector));
        assert!(fixture.read(|shell, _| shell.page == Page::Files));
        assert!(fixture.read(|shell, _| shell.browser.root.is_none()));
        fixture.click("conversation-files");
        assert!(!fixture.read(|shell, _| shell.conversation_workspace.selector));
        assert!(fixture.read(|shell, _| shell.browser.root.is_some()));
        fixture.click("conversation-git");
        assert!(fixture.read(|shell, _| shell.page == Page::Git));
        fixture.click("workspace-panel-close");
        assert!(fixture.read(|shell, _| shell.page == Page::Chat));
        fixture.bounds("composer-card");
    }
}

#[test]
fn phone_workspace_notice_stays_visible_inside_the_sheet_and_can_be_dismissed() {
    let mut fixture = Fixture::new(393., 852., Page::Files, Locale::Zh);
    fixture.update(|shell, _, cx| {
        shell.notice = Some("工作空间正在使用中，请稍后重试。".into());
        cx.notify();
    });
    let sheet = fixture.bounds("workspace-panel-sheet");
    let notice = fixture.bounds("workspace-panel-notice");
    let body = fixture.bounds("workspace-panel-body");
    assert!(sheet.contains(&notice.center()));
    assert!(notice.bottom() <= body.top());
    fixture.assert_controls(&["dismiss-notice"], sheet);
    fixture.click("dismiss-notice");
    assert!(fixture.read(|shell, _| shell.notice.is_none()));
    assert!(fixture.cx.debug_bounds("workspace-panel-notice").is_none());
    fixture.bounds("workspace-panel-sheet");
    fixture.bounds("workspace-document-pane");
}

#[test]
fn resizing_a_sidebar_into_a_sheet_captures_then_restores_the_chat_focus() {
    let mut fixture = Fixture::new(1194., 834., Page::Files, Locale::En);
    fixture.update(|shell, window, cx| {
        window.focus(&shell.composer.read(cx).focus_handle(cx), cx);
    });
    fixture.resize(393., 852.);
    fixture
        .window
        .update(&mut fixture.cx, |shell, window, _| {
            assert!(shell.workspace_panel_modal);
            assert!(shell.workspace_panel_focus.is_focused(window));
            assert!(shell.workspace_panel_previous_focus.is_some());
        })
        .unwrap();
    fixture.resize(1194., 834.);
    fixture
        .window
        .update(&mut fixture.cx, |shell, window, cx| {
            assert!(!shell.workspace_panel_modal);
            assert!(shell.workspace_panel_previous_focus.is_none());
            assert!(shell.composer.read(cx).focus_handle(cx).is_focused(window));
            assert!(shell.page == Page::Files);
        })
        .unwrap();
    fixture.bounds("workbench-tools-pane");
    assert!(fixture.cx.debug_bounds("workspace-panel-sheet").is_none());
}

#[test]
fn short_desktop_sidebar_falls_back_to_a_scrollable_document_without_squeezing_navigation() {
    let mut fixture = Fixture::new(1194., 480., Page::Files, Locale::En);
    fixture.update(|shell, _, cx| {
        shell.browser.file.as_mut().unwrap().content =
            "// Keep this document scrollable\n".repeat(160);
        cx.notify();
    });
    let tools = fixture.bounds("workbench-tools-pane");
    fixture.assert_panel_controls(tools);
    let header = fixture.bounds("workspace-panel-header");
    let tabs = fixture.bounds("workspace-panel-tabs");
    let body = fixture.bounds("workspace-panel-body");
    assert_eq!(header.size.height + tabs.size.height, px(88.));
    assert!(body.size.height >= px(200.));
    assert!(
        fixture
            .cx
            .debug_bounds("workspace-directory-pane")
            .is_none()
    );
    fixture.bounds("workspace-document-pane");
    assert!(
        fixture
            .cx
            .debug_bounds("workspace-panel-workspace")
            .is_none()
    );
    fixture.read(|shell, _| assert_eq!(shell.browser.file.as_ref().unwrap().path, "src/main.rs"));
    fixture.cx.simulate_event(ScrollWheelEvent {
        position: body.center(),
        delta: ScrollDelta::Pixels(point(px(0.), px(-160.))),
        modifiers: Modifiers::none(),
        touch_phase: TouchPhase::Moved,
    });
    fixture.draw();
    assert!(fixture.read(|shell, _| shell.workspace_panel_files_scroll.offset().y) < px(0.));
    assert_eq!(fixture.bounds("workspace-panel-header"), header);
    assert_eq!(fixture.bounds("workspace-panel-tabs"), tabs);
}
