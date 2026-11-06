//! Ordinary conversations remain independent of personal Bot identities.
use super::*;

#[test]
fn ordinary_conversation_menu_entry_returns_to_chat_without_opening_a_bot_form() {
    for locale in [Locale::Zh, Locale::En] {
        for (width, height) in [(390., 844.), (1194., 834.)] {
            let mut f = Fixture::new(width, height, locale);
            f.hub();
            let before = f
                .window
                .read_with(&f.cx, |s, _| s.assistant.directory().cloned())
                .unwrap();
            f.add_menu();
            f.inside("assistant-create-chat", width, height);
            f.click("assistant-create-chat");
            assert!(f.cx.debug_bounds("assistant-directory-add-menu").is_none());
            assert!(f.cx.debug_bounds("assistant-directory-editor").is_none());
            f.window
                .read_with(&f.cx, |s, _| {
                    assert!(s.page == Page::Chat);
                    assert!(!s.assistant_hub_visible());
                    assert!(s.assistant.directory_ui.editor.is_none());
                    assert!(s.notice.is_none());
                    assert_eq!(s.assistant.directory(), before.as_ref());
                })
                .unwrap();
        }
    }
}

#[test]
fn ordinary_conversation_starts_the_agent_controller_without_bot_memory_authority() {
    let mut state = test_fixture::loaded();
    let bot = directory();
    state.bind_assistant_snapshot(&bot);
    let private_chat = state.active_conversation_id().unwrap().to_owned();
    let ordinary = uuid::Uuid::new_v4().to_string();
    let create = state
        .create_conversation(&ordinary, test_fixture::NOW, "deepseek-v4-flash")
        .unwrap();
    assert!(test_fixture::persist(&mut state, create).is_none());
    assert_eq!(state.active_conversation_id(), Some(ordinary.as_str()));
    assert_ne!(state.active_conversation_id(), Some(private_chat.as_str()));
    assert!(state.assistant_profile_context().is_none());

    let send = state
        .prepare_agent_send(
            "请检查当前工作空间并制定计划",
            &TurnIds::new(),
            test_fixture::NOW,
        )
        .unwrap();
    let prepare =
        test_fixture::persist(&mut state, send).expect("committed ordinary Agent preparation");
    assert_eq!(prepare.method, "prepare_agent_attempt");
    assert_eq!(prepare.args[0]["conversation_id"], ordinary);
    assert_eq!(prepare.args[0]["registry_version"], 4);
    assert!(!state.raw_session().to_string().contains("PRIVATE-A"));
    assert!(!state.raw_session().to_string().contains("PRIVATE-B"));
    assert!(
        state.raw_session()["conversations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["id"] == private_chat)
    );
}
