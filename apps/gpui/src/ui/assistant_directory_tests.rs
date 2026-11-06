//! Rendered directory/group regression checks; fixtures never call a provider.
use super::assistant_avatar::AvatarUpdate;
use super::assistant_directory::GroupSubmission;
use super::assistant_forms::AssistantUi;
use super::*;
use crate::assistant_runtime::{RunnerCommand, RunnerHandle, RunnerSnapshot, test_fixture};
use gpui::{Bounds, Modifiers, Pixels, TestAppContext, VisualTestContext, WindowHandle, size};
use rish_shell_core::assistant_store::*;

const BOT: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const BOT_CHAT: &str = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const GROUP: &str = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const LANE_A: &str = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const LANE_B: &str = "ffffffff-ffff-4fff-8fff-ffffffffffff";

fn directory() -> AssistantSnapshot {
    AssistantSnapshot {
        conversation_id: Some(test_fixture::CHAT.into()),
        profile: AssistantProfile {
            name: "规划助手".into(),
            notes: "PRIVATE-A".into(),
            ..Default::default()
        },
        bots: vec![AssistantBot {
            id: BOT.into(),
            profile: AssistantProfile {
                name: "审查助手".into(),
                notes: "PRIVATE-B".into(),
                ..Default::default()
            },
            conversation_id: Some(BOT_CHAT.into()),
            tasks: Vec::new(),
            memories: Vec::new(),
        }],
        groups: vec![AssistantGroup {
            id: GROUP.into(),
            name: "一起讨论方案".into(),
            active_bot_ids: vec![DEFAULT_BOT_ID.into(), BOT.into()],
            members: vec![
                AssistantGroupMember {
                    bot_id: DEFAULT_BOT_ID.into(),
                    conversation_id: LANE_A.into(),
                },
                AssistantGroupMember {
                    bot_id: BOT.into(),
                    conversation_id: LANE_B.into(),
                },
            ],
            rounds: Vec::new(),
        }],
        ..Default::default()
    }
}
fn runner_snapshot(directory: AssistantSnapshot) -> RunnerSnapshot {
    RunnerSnapshot {
        store: directory.bot_snapshot(DEFAULT_BOT_ID),
        directory: Some(directory),
        selected_bot_id: DEFAULT_BOT_ID.into(),
        ..Default::default()
    }
}
struct Fixture {
    window: WindowHandle<Shell>,
    cx: VisualTestContext,
}
impl Fixture {
    fn new(width: f32, height: f32, locale: Locale) -> Self {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(height)), |_, cx| Shell::new(cx));
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        cx.run_until_parked();
        window
            .update(&mut cx, |shell, _, cx| {
                shell.page = Page::Assistant;
                shell.locale = locale;
                shell.loading = false;
                shell.notice = None;
                shell.state = test_fixture::loaded();
                for id in [BOT_CHAT, LANE_A, LANE_B] {
                    let command = shell
                        .state
                        .create_conversation(id, test_fixture::NOW, "deepseek-v4-flash")
                        .unwrap();
                    test_fixture::persist(&mut shell.state, command);
                }
                let command = shell.state.select_conversation(test_fixture::CHAT).unwrap();
                test_fixture::persist(&mut shell.state, command);
                shell.assistant = AssistantUi {
                    snapshot: runner_snapshot(directory()),
                    ..Default::default()
                };
                shell.bind_assistant_chat_snapshot();
                shell.update_placeholders(cx);
                shell.sync_transcript(cx);
                cx.notify();
            })
            .unwrap();
        let mut result = Self { window, cx };
        result.draw();
        result
    }
    fn draw(&mut self) {
        self.cx.run_until_parked();
        self.cx.update(|w, cx| w.draw(cx).clear(cx));
    }
    fn bounds(&mut self, id: impl Into<String>) -> Bounds<Pixels> {
        let id: &'static str = Box::leak(id.into().into_boxed_str());
        self.cx
            .debug_bounds(id)
            .unwrap_or_else(|| panic!("missing {id}"))
    }
    fn inside(&mut self, id: impl Into<String>, width: f32, height: f32) -> Bounds<Pixels> {
        let id = id.into();
        let b = self.bounds(id.clone());
        assert!(
            b.left() >= px(0.)
                && b.right() <= px(width)
                && b.top() >= px(0.)
                && b.bottom() <= px(height),
            "{id}: {b:?}"
        );
        b
    }
    fn click(&mut self, id: impl Into<String>) {
        let p = self.bounds(id).center();
        self.cx.simulate_click(p, Modifiers::none());
        self.draw();
    }
    fn hub(&mut self) {
        self.window
            .update(&mut self.cx, |s, _, cx| s.assistant_open_hub(cx))
            .unwrap();
        self.draw();
    }
    fn add_menu(&mut self) {
        self.click("assistant-directory-add");
        self.bounds("assistant-directory-add-menu");
    }
    fn group(&mut self) {
        self.window
            .update(&mut self.cx, |s, _, cx| {
                s.assistant_open_group(GROUP.into(), cx)
            })
            .unwrap();
        self.draw();
    }
}

#[test]
fn bot_hub_and_member_choices_fit_phone_and_landscape_tablet() {
    for locale in [Locale::Zh, Locale::En] {
        for (width, height) in [(390., 844.), (1194., 834.)] {
            let mut f = Fixture::new(width, height, locale);
            f.hub();
            let a = f.inside(
                format!("assistant-bot-card-{DEFAULT_BOT_ID}"),
                width,
                height,
            );
            let b = f.inside(format!("assistant-bot-card-{BOT}"), width, height);
            assert!(a.bottom() <= b.top(), "Bot rows must form a vertical list");
            f.inside(format!("assistant-group-card-{GROUP}"), width, height);
            assert!(f.cx.debug_bounds("assistant-create-bot").is_none());
            assert!(f.cx.debug_bounds("assistant-create-group").is_none());
            assert!(f.cx.debug_bounds("composer-card").is_none());
            f.add_menu();
            f.inside("assistant-create-bot", width, height);
            f.inside("assistant-create-group", width, height);
            f.click("assistant-create-group");
            assert!(f.cx.debug_bounds("assistant-directory-add-menu").is_none());
            f.inside("assistant-directory-editor", width, height);
            f.inside("assistant-directory-name", width, height);
            f.inside(
                format!("assistant-group-member-{DEFAULT_BOT_ID}"),
                width,
                height,
            );
            f.inside(format!("assistant-group-member-{BOT}"), width, height);
            f.inside("assistant-directory-save", width, height);
            f.click(format!("assistant-group-member-{DEFAULT_BOT_ID}"));
            f.click(format!("assistant-group-member-{BOT}"));
            f.window
                .read_with(&f.cx, |s, _| {
                    assert_eq!(
                        s.assistant
                            .directory_ui
                            .editor
                            .as_ref()
                            .unwrap()
                            .members
                            .as_ref()
                            .unwrap(),
                        &vec![DEFAULT_BOT_ID.to_owned(), BOT.to_owned()]
                    )
                })
                .unwrap();
            f.click("assistant-directory-cancel");
            f.inside("assistant-hub", width, height);
        }
    }
}

#[test]
fn group_creation_requires_two_distinct_members_and_dispatches_stable_id() {
    let mut f = Fixture::new(390., 844., Locale::Zh);
    f.hub();
    f.add_menu();
    f.click("assistant-create-group");
    f.click(format!("assistant-group-member-{DEFAULT_BOT_ID}"));
    f.click("assistant-directory-save");
    f.window
        .read_with(&f.cx, |s, _| {
            assert!(s.assistant.error.is_some());
            assert!(!s.assistant.directory_ui.editor.as_ref().unwrap().saving);
        })
        .unwrap();
    f.click(format!("assistant-group-member-{BOT}"));
    f.click(format!("assistant-group-member-{BOT}"));
    f.window
        .read_with(&f.cx, |s, _| {
            assert_eq!(
                s.assistant
                    .directory_ui
                    .editor
                    .as_ref()
                    .unwrap()
                    .members
                    .as_ref()
                    .unwrap()
                    .len(),
                1
            )
        })
        .unwrap();
    f.click(format!("assistant-group-member-{BOT}"));
    let (handle, mut receiver) = RunnerHandle::test_client(runner_snapshot(directory()));
    let id = f
        .window
        .update(&mut f.cx, |s, _, _| {
            s.assistant_runner = Some(handle);
            s.assistant.directory_ui.editor.as_ref().unwrap().id.clone()
        })
        .unwrap();
    f.click("assistant-directory-save");
    match receiver.try_recv().unwrap() {
        RunnerCommand::CreateGroup {
            group_id, bot_ids, ..
        } => {
            assert_eq!(group_id, id);
            assert_eq!(bot_ids, vec![DEFAULT_BOT_ID.to_owned(), BOT.to_owned()]);
        }
        other => panic!("unexpected command: {other:?}"),
    }
    f.click("assistant-directory-save");
    assert!(receiver.try_recv().is_err(), "duplicate save dispatched");
}

#[test]
fn selected_group_model_does_not_reconfigure_private_chat_or_default_preference() {
    let mut f = Fixture::new(1194., 834., Locale::Zh);
    f.group();
    f.window
        .update(&mut f.cx, |s, window, cx| {
            let before = s.state.raw_session().clone();
            let private = s.state.selected_model().to_owned();
            let other = s
                .state
                .models()
                .into_iter()
                .find(|m| m.id != private)
                .unwrap()
                .id;
            s.open_model_picker(window, cx);
            s.choose_model(&other, window, cx);
            s.finish_configuration(window, cx);
            assert_eq!(s.assistant_group_model(), other);
            assert_eq!(s.state.selected_model(), private);
            assert_eq!(s.state.raw_session(), &before);
            assert!(!s.model_picker);
        })
        .unwrap();
}

#[test]
fn bot_creation_keeps_existing_profile_and_waits_for_its_own_conversation() {
    let mut f = Fixture::new(390., 844., Locale::Zh);
    f.hub();
    f.add_menu();
    f.click("assistant-create-bot");
    let (handle, mut receiver) = RunnerHandle::test_client(runner_snapshot(directory()));
    let original = f
        .window
        .update(&mut f.cx, |s, _, _| {
            s.assistant_runner = Some(handle);
            s.assistant.snapshot.directory.clone().unwrap()
        })
        .unwrap();
    f.click("assistant-directory-save");
    let (id, profile) = match receiver.try_recv().unwrap() {
        RunnerCommand::CreateBot {
            bot_id, profile, ..
        } => (bot_id, profile),
        command => panic!("unexpected command: {command:?}"),
    };
    f.window
        .update(&mut f.cx, |s, _, cx| {
            assert_eq!(s.assistant.snapshot.directory, Some(original.clone()));
            assert_eq!(
                s.assistant.snapshot.store.as_ref().unwrap().profile.name,
                "规划助手"
            );
            let mut saved = original.clone();
            saved.revision += 1;
            saved.bots.push(AssistantBot {
                id: id.clone(),
                profile,
                conversation_id: Some(uuid::Uuid::new_v4().to_string()),
                tasks: Vec::new(),
                memories: Vec::new(),
            });
            s.assistant.snapshot.directory = Some(saved.clone());
            s.assistant_directory_snapshot_changed(cx);
            assert!(s.assistant.directory_ui.editor.is_none());
            assert_eq!(
                s.assistant.directory_ui.pending_bot_id.as_deref(),
                Some(id.as_str())
            );
            assert!(!s.assistant_personal_chat_ready());
            s.assistant.snapshot.selected_bot_id = id.clone();
            s.assistant.snapshot.store = saved.bot_snapshot(&id);
            s.assistant_directory_snapshot_changed(cx);
            s.bind_assistant_chat_snapshot();
            assert!(s.assistant.directory_ui.pending_bot_id.is_none());
            assert_eq!(s.state.active_conversation_id(), Some(test_fixture::CHAT));
            assert!(
                !s.assistant_personal_chat_ready(),
                "The old private transcript must not appear under a new Bot"
            );
            assert_eq!(
                s.assistant.snapshot.directory.as_ref().unwrap().profile,
                original.profile
            );
        })
        .unwrap();
    assert!(
        matches!(receiver.try_recv().unwrap(), RunnerCommand::SelectBot { bot_id } if bot_id == id)
    );
}

#[test]
fn identically_named_members_are_targeted_by_identity_and_tablet_has_member_sidebar() {
    for (width, height) in [(390., 844.), (1194., 834.)] {
        let mut f = Fixture::new(width, height, Locale::Zh);
        f.window
            .update(&mut f.cx, |s, _, _| {
                let directory = s.assistant.snapshot.directory.as_mut().unwrap();
                directory.bots[0].profile.name = directory.profile.name.clone();
            })
            .unwrap();
        f.group();
        if width > 1000. {
            let sidebar = f.inside("group-members-sidebar", width, height);
            let chat = f.inside("assistant-group-page", width, height);
            assert!(sidebar.left() >= chat.right());
        } else {
            assert!(f.cx.debug_bounds("group-members-sidebar").is_none());
        }
        f.click("group-target-toggle");
        f.click(format!("group-target-{BOT}"));
        f.window
            .read_with(&f.cx, |s, _| {
                assert_eq!(s.assistant.directory_ui.target_bot_id.as_deref(), Some(BOT));
            })
            .unwrap();
    }
}

fn completed_reply(bot_id: &str, lane: &str, name: &str, text: &str) -> AssistantGroupReply {
    let ids = rish_shell_core::TurnIds::new();
    AssistantGroupReply {
        id: uuid::Uuid::new_v4().to_string(),
        bot_id: bot_id.into(),
        conversation_id: lane.into(),
        text: Some(text.into()),
        run: Some(AssistantRun {
            run_id: uuid::Uuid::new_v4().to_string(),
            ids: AssistantTurnIds {
                turn_id: ids.turn_id,
                attempt_id: ids.attempt_id,
                round_id: ids.round_id,
                user_message_id: ids.user_message_id,
                assistant_message_id: ids.assistant_message_id,
            },
            started_at_ms: 1,
            status: AssistantRunStatus::Completed,
            finished_at_ms: Some(2),
            result_summary: Some("Done".into()),
            failure_code: None,
            snapshot: AssistantRunSnapshot {
                name: name.into(),
                soul: String::new(),
                notes: String::new(),
                instructions: "Question".into(),
                model_id: "deepseek-v4-flash".into(),
                workspace_binding: json!({}),
                workspace_descriptor: json!({}),
                runtime: None,
            },
        }),
    }
}
#[test]
fn group_transcript_has_one_user_message_and_distinct_persisted_speakers() {
    for (width, height) in [(390., 844.), (1194., 834.)] {
        let mut f = Fixture::new(width, height, Locale::Zh);
        let ids = f
            .window
            .update(&mut f.cx, |s, _, cx| {
                let a = completed_reply(DEFAULT_BOT_ID, LANE_A, "发言时的规划助手", "先明确目标。");
                let b = completed_reply(BOT, LANE_B, "发言时的审查助手", "再检查边界情况。");
                let ids = vec![
                    a.run.as_ref().unwrap().ids.assistant_message_id.clone(),
                    b.run.as_ref().unwrap().ids.assistant_message_id.clone(),
                ];
                let group = &mut s.assistant.snapshot.directory.as_mut().unwrap().groups[0];
                group.rounds.push(AssistantGroupRound {
                    id: uuid::Uuid::new_v4().to_string(),
                    user_message_id: uuid::Uuid::new_v4().to_string(),
                    text: "讨论方案".into(),
                    created_at_ms: 1,
                    model_id: "deepseek-v4-flash".into(),
                    workspace_binding: json!({}),
                    workspace_descriptor: json!({"display_name":"Default"}),
                    runtime: None,
                    replies: vec![a, b],
                    stopped: false,
                });
                s.assistant_open_group(GROUP.into(), cx);
                let messages = s.transcript.read(cx).test_messages(cx);
                assert_eq!(messages.len(), 3);
                assert!(messages[0].speaker.is_none());
                assert_eq!(messages[0].text, "讨论方案");
                assert_eq!(messages[1].speaker.as_ref().unwrap().id, DEFAULT_BOT_ID);
                assert_eq!(messages[2].speaker.as_ref().unwrap().id, BOT);
                assert_eq!(
                    messages[1].speaker.as_ref().unwrap().name,
                    "发言时的规划助手"
                );
                assert_eq!(
                    messages[2].speaker.as_ref().unwrap().name,
                    "发言时的审查助手"
                );
                assert!(messages.iter().all(|m| !m.text.contains("PRIVATE-")));
                ids
            })
            .unwrap();
        f.draw();
        for id in ids {
            f.inside(format!("message-speaker-{id}"), width, height);
        }
    }
}

#[test]
fn group_draft_uses_room_identity_across_participant_lane_switches() {
    let mut f = Fixture::new(390., 844., Locale::Zh);
    f.window
        .update(&mut f.cx, |s, _, cx| {
            s.composer
                .update(cx, |i, cx| i.set_text("私人草稿".into(), cx));
            s.test_align_inline_session(true, cx);
            s.assistant_open_group(GROUP.into(), cx);
            s.test_align_inline_session(true, cx);
            assert!(s.composer.read(cx).text().is_empty());
            s.composer
                .update(cx, |i, cx| i.set_text("群聊草稿\n还没有发出".into(), cx));
            s.test_align_inline_session(true, cx);
            let session = s.test_inline_identity().0.unwrap();
            for lane in [LANE_A, LANE_B] {
                let command = s.state.select_conversation(lane).unwrap();
                test_fixture::persist(&mut s.state, command);
                s.test_align_inline_session(true, cx);
                assert_eq!(
                    s.test_inline_identity().0.as_deref(),
                    Some(session.as_str())
                );
                assert_eq!(
                    s.test_inline_identity().1.as_deref(),
                    Some(format!("assistant-group-{GROUP}").as_str())
                );
                assert_eq!(s.composer.read(cx).text(), "群聊草稿\n还没有发出");
            }
            s.assistant_open_bot(DEFAULT_BOT_ID.into(), cx);
            let command = s.state.select_conversation(test_fixture::CHAT).unwrap();
            test_fixture::persist(&mut s.state, command);
            s.test_align_inline_session(true, cx);
            assert_eq!(s.composer.read(cx).text(), "私人草稿");
            s.assistant_open_group(GROUP.into(), cx);
            s.test_align_inline_session(true, cx);
            assert_eq!(s.composer.read(cx).text(), "群聊草稿\n还没有发出");
        })
        .unwrap();
}

#[test]
fn group_members_and_targets_cannot_change_during_send_or_active_reply() {
    let mut f = Fixture::new(390., 844., Locale::Zh);
    f.group();
    for active in [false, true] {
        f.window
            .update(&mut f.cx, |s, _, cx| {
                s.assistant.directory_ui.submit = if active {
                    None
                } else {
                    Some(GroupSubmission {
                        group_id: GROUP.into(),
                        turn_id: uuid::Uuid::new_v4().to_string(),
                        text: "Pending".into(),
                        sending: true,
                    })
                };
                s.assistant.snapshot.active_group_id = active.then(|| GROUP.into());
                cx.notify();
            })
            .unwrap();
        f.draw();
        f.click("group-edit");
        f.window
            .read_with(&f.cx, |s, _| {
                assert!(s.assistant.directory_ui.editor.is_none())
            })
            .unwrap();
        f.click("group-target-toggle");
        f.window
            .read_with(&f.cx, |s, _| {
                assert!(!s.assistant.directory_ui.target_picker)
            })
            .unwrap();
    }
}

#[test]
fn already_open_target_choices_cannot_change_after_group_execution_starts() {
    for select_all in [false, true] {
        let mut f = Fixture::new(390., 844., Locale::Zh);
        f.group();
        f.window
            .update(&mut f.cx, |s, _, cx| {
                s.assistant.directory_ui.target_bot_id = select_all.then(|| BOT.into());
                cx.notify();
            })
            .unwrap();
        f.draw();
        f.click("group-target-toggle");
        f.inside("group-target-options", 390., 844.);
        f.window
            .update(&mut f.cx, |s, _, cx| {
                s.assistant.snapshot.active_group_id = Some(GROUP.into());
                cx.notify();
            })
            .unwrap();
        f.draw();
        f.click(if select_all {
            "group-target-all".into()
        } else {
            format!("group-target-{BOT}")
        });
        f.window.read_with(&f.cx, |s, _| {
            assert_eq!(s.assistant.directory_ui.target_bot_id, select_all.then(|| BOT.into()),
                "A late selection from the already-open picker changed the running group's target");
        }).unwrap();
    }
}

#[test]
fn late_avatar_result_cannot_write_the_currently_selected_other_bot() {
    let full = directory();
    let mut ui = AssistantUi {
        snapshot: runner_snapshot(full.clone()),
        ..Default::default()
    };
    let request = ui.begin_avatar_request().unwrap();
    ui.snapshot.selected_bot_id = BOT.into();
    ui.snapshot.store = full.bot_snapshot(BOT);
    let before = ui.snapshot.store.clone();
    let avatar = AssistantAvatar {
        id: uuid::Uuid::new_v4().to_string(),
        sha256: "a".repeat(64),
        mime_type: "image/png".into(),
        width: 64,
        height: 64,
        byte_length: 1024,
    };
    assert_eq!(
        ui.accept_avatar_result(
            &request,
            Ok(json!({"schema_version":1,"avatar":avatar})),
            Locale::Zh
        ),
        AvatarUpdate::Ignored
    );
    assert_eq!(ui.snapshot.store, before);
    assert!(ui.profile_draft.is_none());
    assert_eq!(ui.snapshot.directory, Some(full));
}

#[test]
fn header_add_menu_has_three_touchable_actions_and_outside_dismissal() {
    for (width, height) in [(390., 844.), (1194., 834.)] {
        let mut f = Fixture::new(width, height, Locale::Zh);
        f.hub();
        let add = f.inside("assistant-directory-add", width, height);
        assert!(add.size.width >= px(44.) && add.size.height >= px(44.));
        assert!(f.cx.debug_bounds("assistant-directory-add-menu").is_none());
        f.add_menu();
        let menu = f.inside("assistant-directory-add-menu", width, height);
        let chat = f.inside("assistant-create-chat", width, height);
        let bot = f.inside("assistant-create-bot", width, height);
        let group = f.inside("assistant-create-group", width, height);
        assert!(chat.bottom() <= bot.top() && bot.bottom() <= group.top());
        for action in [chat, bot, group] {
            assert!(action.size.height >= px(44.));
            assert!(action.left() >= menu.left() && action.right() <= menu.right());
            assert!(action.top() >= menu.top() && action.bottom() <= menu.bottom());
        }
        let scrim = f.bounds("assistant-directory-add-scrim");
        let outside = gpui::point(scrim.left() + px(8.), scrim.bottom() - px(8.));
        assert!(!menu.contains(&outside));
        f.cx.simulate_click(outside, Modifiers::none());
        f.draw();
        assert!(f.cx.debug_bounds("assistant-directory-add-menu").is_none());
        f.window
            .read_with(&f.cx, |s, _| {
                assert!(s.assistant.directory_ui.editor.is_none());
                assert!(s.assistant.directory_ui.hub_open);
            })
            .unwrap();
        f.add_menu();
        f.cx.simulate_keystrokes("escape");
        f.draw();
        assert!(f.cx.debug_bounds("assistant-directory-add-menu").is_none());
        for create_group in [false, true] {
            f.add_menu();
            f.click(if create_group {
                "assistant-create-group"
            } else {
                "assistant-create-bot"
            });
            assert!(f.cx.debug_bounds("assistant-directory-add-menu").is_none());
            f.window
                .read_with(&f.cx, |s, _| {
                    assert_eq!(
                        s.assistant
                            .directory_ui
                            .editor
                            .as_ref()
                            .unwrap()
                            .members
                            .is_some(),
                        create_group
                    );
                })
                .unwrap();
            f.click("assistant-directory-cancel");
            assert!(f.cx.debug_bounds("assistant-create-bot").is_none());
            assert!(f.cx.debug_bounds("assistant-create-group").is_none());
        }
    }
}

#[path = "ordinary_chat_menu_tests.rs"]
mod ordinary_chat;

#[test]
fn tablet_preview_opens_selected_bot_without_reusing_previous_private_chat() {
    let mut f = Fixture::new(1194., 834., Locale::Zh);
    f.hub();
    let before = f
        .window
        .read_with(&f.cx, |s, _| s.state.raw_session().clone())
        .unwrap();
    f.click(format!("assistant-bot-card-{BOT}"));
    f.inside("assistant-directory-preview", 1194., 834.);
    f.inside("assistant-directory-chat", 1194., 834.);
    f.window
        .read_with(&f.cx, |s, _| {
            assert_eq!(
                s.state.raw_session(),
                &before,
                "Selecting a preview must not write the previous chat"
            );
            assert!(s.assistant.directory_ui.hub_open);
        })
        .unwrap();
    f.click("assistant-directory-chat");
    f.window
        .read_with(&f.cx, |s, _| {
            assert_eq!(s.assistant.snapshot.selected_bot_id, BOT);
            assert!(!s.assistant.directory_ui.hub_open);
            assert_eq!(s.state.active_conversation_id(), Some(test_fixture::CHAT));
            assert!(
                !s.assistant_personal_chat_ready(),
                "The prior chat must not render below the new Bot identity"
            );
        })
        .unwrap();
}

#[test]
fn completed_group_with_failed_native_end_keeps_explicit_recovery_controls() {
    let mut f = Fixture::new(390., 844., Locale::Zh);
    f.group();
    let (handle, mut receiver) = RunnerHandle::test_client(runner_snapshot(directory()));
    f.window
        .update(&mut f.cx, |s, _, cx| {
            let group = &mut s.assistant.snapshot.directory.as_mut().unwrap().groups[0];
            group.rounds.push(AssistantGroupRound {
                id: uuid::Uuid::new_v4().to_string(),
                user_message_id: uuid::Uuid::new_v4().to_string(),
                text: "讨论方案".into(),
                created_at_ms: 1,
                model_id: "deepseek-v4-flash".into(),
                workspace_binding: json!({}),
                workspace_descriptor: json!({"display_name":"Default"}),
                runtime: None,
                replies: vec![
                    completed_reply(DEFAULT_BOT_ID, LANE_A, "规划助手", "完成"),
                    completed_reply(BOT, LANE_B, "审查助手", "完成"),
                ],
                stopped: false,
            });
            assert!(!group.rounds[0].is_pending());
            s.assistant.snapshot.active_group_id = Some(GROUP.into());
            s.assistant.snapshot.status = crate::assistant_runtime::RunnerStatus::NeedsAttention;
            s.assistant_writer_lease = true;
            s.assistant_runner = Some(handle);
            s.sync_transcript(cx);
            cx.notify();
        })
        .unwrap();
    f.draw();
    f.inside("group-recovery", 390., 844.);
    f.inside("group-recover", 390., 844.);
    f.click("group-recover");
    assert!(
        matches!(receiver.try_recv().unwrap(), RunnerCommand::RecoverGroup{group_id} if group_id == GROUP)
    );
    f.click("group-stop");
    assert!(
        matches!(receiver.try_recv().unwrap(), RunnerCommand::StopGroup{group_id} if group_id == GROUP)
    );
}

#[test]
fn pending_bot_selection_blocks_profile_forms_before_the_projection_acknowledges() {
    let mut ui = AssistantUi {
        snapshot: runner_snapshot(directory()),
        ..Default::default()
    };
    assert!(!ui.form_busy());
    ui.directory_ui.pending_bot_id = Some(BOT.into());
    assert!(ui.form_busy());
    assert!(ui.begin_avatar_request().is_none());
    assert!(ui.form_request.is_none());
    assert!(ui.profile_draft.is_none());
}
