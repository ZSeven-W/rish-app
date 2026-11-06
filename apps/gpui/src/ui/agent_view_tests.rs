use super::*;
use gpui::{Bounds, Modifiers, Pixels, TestAppContext, VisualTestContext, WindowHandle, size};
use rish_shell_core::{AgentApprovalView, AgentQuestionView, AgentView};

struct Panel {
    shell: Entity<Shell>,
    view: AgentView,
}
impl Render for Panel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let height = window.viewport_size().height.into();
        let view = self.view.clone();
        let panel = self
            .shell
            .update(cx, |shell, cx| shell.agent_panel(view, height, cx));
        div()
            .size_full()
            .flex()
            .flex_col()
            .justify_end()
            .child(panel)
    }
}
struct Fixture {
    window: WindowHandle<Panel>,
    cx: VisualTestContext,
}
impl Fixture {
    fn new(width: f32, height: f32, view: AgentView) -> Self {
        let mut cx = TestAppContext::single();
        let window = cx.open_window(size(px(width), px(height)), |_, cx| {
            let shell = cx.new(Shell::new);
            Panel { shell, view }
        });
        let mut cx = VisualTestContext::from_window(window.into(), &cx);
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        Self { window, cx }
    }
    fn bounds(&mut self, selector: &'static str) -> Bounds<Pixels> {
        self.cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"))
    }
}

fn view() -> AgentView {
    AgentView {
        phase: "awaiting_approval".into(),
        round: 0,
        tools: Vec::new(),
        approval: None,
        question: None,
        preview_text: String::new(),
        preview_reasoning: String::new(),
        preview_incomplete: false,
        failure_code: None,
        recoverable: false,
    }
}

#[test]
fn long_approval_diff_keeps_decisions_reachable_at_phone_and_ipad_widths() {
    for (width, height) in [(320., 480.), (390., 844.), (1024., 768.)] {
        let mut model = view();
        model.approval = Some(AgentApprovalView {
            approval_id: "token-1".into(),
            call_id: "call-1".into(),
            name: "write_file".into(),
            preview: json!({"paths":["src/中文文件.rs"],"content_bytes":128,"diff_preview":"+ a changed line\n".repeat(150),"diff_truncated":true}),
            allowed_decisions: vec!["allow_once".into(), "denied".into(), "cancelled".into()],
        });
        let mut fixture = Fixture::new(width, height, model);
        let panel = fixture.bounds("agent-panel");
        let scroll = fixture.bounds("agent-progress-scroll");
        assert!(panel.size.width <= px(width));
        assert!(scroll.size.height <= px((height * 0.38).clamp(96., 300.) + 1.));
        for selector in ["agent-allow-once", "agent-deny", "agent-decision-cancel"] {
            let button = fixture.bounds(selector);
            assert!(button.origin.y >= px(0.), "{selector} above viewport");
            assert!(button.bottom() <= px(height), "{selector} below viewport");
            assert!(button.right() <= px(width), "{selector} outside viewport");
            assert!(button.size.height >= px(44.));
        }
    }
}

#[test]
fn a_token_that_only_offers_denial_never_renders_an_allow_action() {
    let mut model = view();
    model.approval = Some(AgentApprovalView {
        approval_id: "token-1".into(),
        call_id: "call-1".into(),
        name: "write_file".into(),
        preview: json!({"paths":["file.txt"]}),
        allowed_decisions: vec!["denied".into(), "unexpected".into()],
    });
    let mut fixture = Fixture::new(390., 844., model);
    fixture.bounds("agent-deny");
    assert!(fixture.cx.debug_bounds("agent-allow-once").is_none());
    assert!(fixture.cx.debug_bounds("agent-decision-cancel").is_none());
}

#[test]
fn eight_question_options_scroll_without_hiding_the_skip_action() {
    let mut model = view();
    model.question = Some(AgentQuestionView {
        call_id: "question-1".into(),
        id: "question-1".into(),
        question: "请选择需要修改的部分。".repeat(20),
        input_mode: "options".into(),
        options: (0..8)
            .map(|i| {
                (
                    format!("o{i}"),
                    "一个很长的选项名称，需要换行显示完整内容".repeat(2),
                )
            })
            .collect(),
    });
    let mut fixture = Fixture::new(320., 480., model);
    let button = fixture.bounds("agent-question-skip");
    assert!(button.bottom() <= px(480.));
    assert!(button.origin.y >= px(0.));
    assert!(fixture.bounds("agent-progress-scroll").size.height <= px(183.));
}

#[test]
fn a_stale_agent_reply_cannot_overwrite_current_notice_or_draft() {
    let mut fixture = Fixture::new(390., 844., view());
    fixture
        .window
        .update(&mut fixture.cx, |panel, _, cx| {
            panel.shell.update(cx, |shell, cx| {
                shell.notice = Some("current notice".into());
                shell
                    .composer
                    .update(cx, |input, cx| input.set_text("保留草稿".into(), cx));
                shell.agent_requests.push(RuntimeCommand::new(
                    "AgentRuntime",
                    "complete_agent_round_v2",
                    vec![json!({"operation_id":"old"})],
                ));
                assert!(
                    !shell.agent_request_in_flight(),
                    "a retired promise must not block the current task's controls"
                );
                shell.accept_agent_reply(
                    RuntimeCommand::new(
                        "AgentRuntime",
                        "complete_agent_round_v2",
                        vec![json!({"operation_id":"old"})],
                    ),
                    Err("old request failed".into()),
                    cx,
                );
                assert_eq!(shell.notice.as_deref(), Some("current notice"));
                assert_eq!(shell.composer.read(cx).text(), "保留草稿");
                assert!(shell.agent_requests.is_empty());
            });
        })
        .unwrap();
}

#[test]
fn missing_credentials_offer_settings_without_an_approval_or_retry_side_effect() {
    let mut model = view();
    model.phase = "failed".into();
    model.failure_code = Some("E_AGENT_PROVIDER_CREDENTIAL".into());
    let mut fixture = Fixture::new(320., 480., model);
    let settings = fixture.bounds("agent-open-settings");
    assert!(settings.bottom() <= px(480.));
    assert!(fixture.cx.debug_bounds("agent-allow-once").is_none());
    assert!(fixture.cx.debug_bounds("agent-recover").is_none());
    fixture
        .cx
        .simulate_click(settings.center(), Modifiers::none());
    fixture.cx.run_until_parked();
    fixture
        .window
        .read_with(&fixture.cx, |panel, cx| {
            assert!(panel.shell.read(cx).page == Page::Settings);
            assert!(panel.shell.read(cx).agent_requests.is_empty());
        })
        .unwrap();
}

#[test]
fn long_native_diagnostics_keep_the_notice_inside_a_phone_width() {
    let mut cx = TestAppContext::single();
    let window = cx.open_window(size(px(320.), px(568.)), |_, cx| Shell::new(cx));
    window.update(&mut cx, |shell, _, cx| {
        shell.notice = Some("E_AGENT_PERSISTENCE: agent_runtime/v1 operation=complete_agent_round_v2 kind=unavailable".into());
        cx.notify();
    }).unwrap();
    let mut cx = VisualTestContext::from_window(window.into(), &cx);
    cx.run_until_parked();
    cx.update(|window, cx| window.draw(cx).clear(cx));
    let label = cx.debug_bounds("notice-text").unwrap();
    assert!(
        label.right() < px(280.),
        "the retry action must retain its own width"
    );
    assert!(label.size.width > px(100.));
}
