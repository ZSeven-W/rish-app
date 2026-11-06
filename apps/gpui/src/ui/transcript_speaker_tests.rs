use super::*;
use gpui::{TestAppContext, VisualTestContext, size};

fn reply(speaker_id: &str, name: &str) -> DisplayMessage {
    DisplayMessage {
        id: "group-reply".into(),
        role: "assistant".into(),
        text: "This is the committed reply.".into(),
        reasoning: "Visible only when expanded.".into(),
        speaker: Some(DisplaySpeaker {
            id: speaker_id.into(),
            name: name.into(),
            avatar: None,
            directory: None,
        }),
    }
}

#[test]
fn speaker_labels_use_persisted_identity_and_keep_plain_message_labels() {
    let first = reply("bot-a", "规划助手");
    assert_eq!(first.speaker_name(Locale::Zh), "规划助手");
    assert_ne!(first, reply("bot-b", "规划助手"));
    assert_ne!(first, reply("bot-a", "代码助手"));
    let mut plain = first.clone();
    plain.speaker = None;
    assert_eq!(
        plain.speaker_name(Locale::Zh),
        Locale::Zh.text(Text::Assistant)
    );
    let mut user = first.clone();
    user.role = "user".into();
    assert_eq!(user.speaker_name(Locale::Zh), Locale::Zh.text(Text::You));
    assert_eq!(
        reply("bot-a", "  ").speaker_name(Locale::En),
        Locale::En.text(Text::Assistant)
    );
}

#[test]
fn replacing_display_identity_refreshes_same_row_without_losing_reasoning_state() {
    let mut app = TestAppContext::single();
    let window = app.open_window(size(px(390.), px(600.)), |_, _| Transcript::new(Locale::Zh));
    let mut cx = VisualTestContext::from_window(window.into(), &app);
    window
        .update(&mut cx, |transcript, _, cx| {
            transcript.sync(vec![reply("bot-a", "规划助手")], Locale::Zh, cx);
            let before = transcript.rows[0].entity_id();
            transcript.rows[0].update(cx, |row, _| row.show_reasoning = true);
            transcript.sync(vec![reply("bot-b", "代码助手")], Locale::Zh, cx);
            let row = transcript.rows[0].read(cx);
            assert_eq!(transcript.rows[0].entity_id(), before);
            assert!(row.show_reasoning);
            assert_eq!(row.message.speaker.as_ref().unwrap().id, "bot-b");
            assert_eq!(row.message.speaker_name(Locale::Zh), "代码助手");
        })
        .unwrap();
}

#[test]
fn long_group_speaker_name_and_avatar_stay_inside_phone_and_tablet_rows() {
    for width in [390., 1194.] {
        let mut app = TestAppContext::single();
        let window = app.open_window(size(px(width), px(700.)), |_, _| {
            Transcript::new(Locale::Zh)
        });
        let mut cx = VisualTestContext::from_window(window.into(), &app);
        window
            .update(&mut cx, |transcript, _, cx| {
                transcript.sync(
                    vec![reply("bot-a", &"陪你梳理生活与工作的个人助手".repeat(12))],
                    Locale::Zh,
                    cx,
                );
            })
            .unwrap();
        cx.run_until_parked();
        cx.update(|window, cx| window.draw(cx).clear(cx));
        let bounds = cx
            .debug_bounds("message-speaker-group-reply")
            .expect("speaker row is rendered");
        assert!(
            bounds.left() >= px(0.) && bounds.right() <= px(width),
            "speaker row overflow at {width}: {bounds:?}"
        );
        assert!(
            bounds.size.height >= px(24.),
            "avatar must retain visible size"
        );
    }
}
