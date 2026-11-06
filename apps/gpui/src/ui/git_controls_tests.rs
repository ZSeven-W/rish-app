//! Render the actual Git page so narrow-screen regressions cannot hide actions.
use super::*;
use gpui::{Bounds, Pixels, TestAppContext, VisualTestContext, WindowHandle, size};
use workspace_git::GitState;

const COMMON_ACTIONS: [&str; 8] = [
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
}

impl Fixture {
    fn new(width: f32, locale: Locale, configured_remote: bool) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(844.)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                let root = json!({"schema_version":1,
                    "workspace_id":"845d980b-8acd-4710-a54c-7975b6839024",
                    "binding_revision":4,"project_id":"85ac8af6-b884-4b55-b63a-b46cabf56296"});
                shell.state = ShellState::with_test_models();
                shell.state.load_snapshot(json!({"schema_version":1,"status":"missing"})).unwrap();
                shell.page = Page::Git;
                shell.locale = locale;
                shell.loading = false;
                shell.aux_busy = false;
                shell.notice = None;
                shell.browser = Browser {
                    root: Some(root.clone()),
                    name: "A long workspace name for narrow-screen layout".into(),
                    generation: 7,
                    capabilities: json!({"read":true,"write":true,"git":true}),
                    ..Default::default()
                };
                shell.browser.git = GitState::Attached(json!({
                    "schema_version":2,"root":root,"project_id":root["project_id"],
                    "branch":"feature/a-long-branch-name-for-narrow-screen-layout",
                    "head_oid":"a".repeat(40),"clean":false,"has_conflicts":false,
                    "ahead":1,"behind":0,
                    "entries":[{"path":"docs/notes.md","index_status":"modified",
                        "worktree_status":"modified","conflicted":false}]
                }));
                shell.browser.git_actions.metadata_root = Some(root.clone());
                shell.browser.git_actions.remote = Some(json!({
                    "schema_version":2,"root":root,"project_id":root["project_id"],
                    "remote":"origin",
                    "url":if configured_remote {
                        json!("https://example.test/a-very-long-organization-name/a-very-long-repository-name.git")
                    } else { Value::Null },
                    "host":if configured_remote { json!("example.test") } else { Value::Null }
                }));
                shell.browser.git_actions.credential = configured_remote.then(|| json!({
                    "schema_version":2,"root":root,"project_id":root["project_id"],
                    "host":"example.test","configured":true
                }));
                cx.notify();
            })
            .unwrap();
        let mut fixture = Self { window, cx };
        fixture.draw();
        fixture
    }

    fn draw(&mut self) {
        self.cx.update(|window, cx| window.draw(cx).clear(cx));
    }

    fn resize(&mut self, width: f32) {
        self.cx.simulate_resize(size(px(width), px(844.)));
        self.draw();
    }

    fn assert_controls(&mut self, width: f32, remote: bool) {
        let mut selectors = COMMON_ACTIONS.to_vec();
        if remote {
            selectors.push("git-credentials");
        } else {
            assert!(self.cx.debug_bounds("git-credentials").is_none());
        }
        let bounds: Vec<_> = selectors
            .iter()
            .map(|selector| {
                let bounds = self
                    .cx
                    .debug_bounds(selector)
                    .unwrap_or_else(|| panic!("Missing {selector} at viewport width {width}"));
                assert!(
                    bounds.size.width >= px(44.),
                    "{selector} is too narrow: {bounds:?}"
                );
                assert!(
                    bounds.size.height >= px(44.),
                    "{selector} is too short: {bounds:?}"
                );
                assert!(
                    bounds.origin.x >= px(19.5),
                    "{selector} escaped the left inset: {bounds:?}"
                );
                assert!(
                    bounds.right() <= px(width - 19.5),
                    "{selector} escaped the right inset: {bounds:?}"
                );
                assert!(
                    bounds.origin.y >= px(0.),
                    "{selector} is above the viewport: {bounds:?}"
                );
                assert!(
                    bounds.bottom() <= px(844.),
                    "{selector} is below the initial viewport: {bounds:?}"
                );
                (*selector, bounds)
            })
            .collect();
        for (index, (a_name, a)) in bounds.iter().enumerate() {
            for (b_name, b) in &bounds[index + 1..] {
                assert!(
                    !overlap(*a, *b),
                    "{a_name} overlaps {b_name} at width {width}: {a:?} / {b:?}"
                );
            }
        }
        // Native actions remain visible in the desktop fixture; their native
        // execution guard is tested separately by the controller tests.
        self.window
            .read_with(&self.cx, |shell, _| {
                assert!(shell.page == Page::Git);
            })
            .unwrap();
    }
}

fn overlap(a: Bounds<Pixels>, b: Bounds<Pixels>) -> bool {
    a.origin.x < b.right() - px(0.5)
        && b.origin.x < a.right() - px(0.5)
        && a.origin.y < b.bottom() - px(0.5)
        && b.origin.y < a.bottom() - px(0.5)
}

#[test]
fn git_actions_without_a_remote_remain_visible_and_touchable_at_phone_and_wide_sizes() {
    for locale in [Locale::Zh, Locale::En] {
        for width in [320., 393., 780.] {
            Fixture::new(width, locale, false).assert_controls(width, false);
        }
    }
}

#[test]
fn git_actions_with_a_long_remote_url_fit_phone_and_wide_sizes() {
    for locale in [Locale::Zh, Locale::En] {
        for width in [320., 393., 780.] {
            Fixture::new(width, locale, true).assert_controls(width, true);
        }
    }
}

#[test]
fn resizing_between_sidebar_and_phone_layout_keeps_all_git_actions_reachable() {
    let mut fixture = Fixture::new(780., Locale::Zh, true);
    for width in [780., 320., 393., 780.] {
        fixture.resize(width);
        fixture.assert_controls(width, true);
    }
}
