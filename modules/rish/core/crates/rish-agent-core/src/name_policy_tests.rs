use super::*;

#[test]
fn completed_names_share_unicode_trim_and_nfc() {
    for kind in [NameKind::Workspace, NameKind::Conversation] {
        assert_eq!(
            normalize(kind, "\u{0085}\u{00a0} Cafe\u{0301}\u{3000}"),
            Ok("Café".into())
        );
        assert_eq!(normalize(kind, "项目"), Ok("项目".into()));
        assert_eq!(normalize(kind, " \t\n\u{3000}"), Err(NameIssue::Empty));
    }
    // These C0 separators are not Unicode White_Space and must not disappear.
    assert_eq!(
        normalize(NameKind::Conversation, "\u{001c}Title"),
        Err(NameIssue::Invalid)
    );
}

#[test]
fn both_name_kinds_use_the_persisted_utf8_byte_limit() {
    for kind in [NameKind::Workspace, NameKind::Conversation] {
        for (at_limit, beyond) in [
            ("a".repeat(120), "a".repeat(121)),
            ("中".repeat(40), "中".repeat(41)),
            ("é".repeat(60), "é".repeat(61)),
            ("🌏".repeat(30), "🌏".repeat(31)),
        ] {
            assert_eq!(normalize(kind, &at_limit), Ok(at_limit));
            assert_eq!(normalize(kind, &beyond), Err(NameIssue::TooLong));
        }
        // Limit checking must happen after canonical composition.
        assert_eq!(normalize(kind, &"e\u{301}".repeat(60)), Ok("é".repeat(60)));
    }
}

#[test]
fn completed_names_are_single_line_but_conversation_emoji_stays_intact() {
    for kind in [NameKind::Workspace, NameKind::Conversation] {
        for control in [
            '\0', '\n', '\r', '\t', '\u{007f}', '\u{0085}', '\u{2028}', '\u{2029}',
        ] {
            assert_eq!(
                normalize(kind, &format!("a{control}b")),
                Err(NameIssue::Invalid)
            );
        }
    }
    let title = "👩‍💻 与家人 👨‍👩‍👧‍👦";
    assert_eq!(normalize(NameKind::Conversation, title), Ok(title.into()));
    assert_eq!(
        normalize(NameKind::Workspace, title),
        Err(NameIssue::Invalid)
    );
}

#[test]
fn workspace_names_reuse_registry_restrictions_and_reserved_names() {
    for rejected in [
        ".",
        "..",
        ".hidden",
        "a/b",
        "a\\b",
        "a:b",
        "a\u{200b}b",
        "Rish Workspaces",
        "RISH WORKSPACES",
        "Rísh Wórkspaces",
        ".rish-owned",
    ] {
        assert_eq!(
            normalize(NameKind::Workspace, rejected),
            Err(NameIssue::Invalid),
            "{rejected}"
        );
    }
    for title in [".notes", "a/b", "Rish Workspaces"] {
        assert_eq!(normalize(NameKind::Conversation, title), Ok(title.into()));
    }
}

#[test]
fn json_bridge_returns_normalized_text_for_both_success_and_validation_failure() {
    for (raw, expected, issue) in [
        (" Cafe\u{301} ".to_owned(), "Café".to_owned(), Value::Null),
        ("\u{3000}".to_owned(), "".to_owned(), json!("empty")),
        (" a\nb ".to_owned(), "a\nb".to_owned(), json!("invalid")),
        ("中".repeat(41), "中".repeat(41), json!("too_long")),
    ] {
        let reply: Value = serde_json::from_str(&reduce_json(
            &json!({"kind":"conversation","text":raw}).to_string(),
        ))
        .unwrap();
        assert_eq!(
            reply,
            json!({"ok":true,"value":{"text":expected,"issue":issue}})
        );
    }
}

#[test]
fn json_bridge_refuses_unknown_missing_extra_duplicate_or_malformed_fields() {
    for input in [
        "null",
        "[]",
        "{}",
        "{",
        r#"{"kind":"file","text":"name"}"#,
        r#"{"kind":"workspace"}"#,
        r#"{"kind":"workspace","text":null}"#,
        r#"{"kind":"workspace","text":"name","other":true}"#,
        r#"{"kind":"workspace","text":"name","text":"override"}"#,
        r#"{"kind":"workspace","text":"name","\u0074ext":"override"}"#,
        r#"{"kind":"workspace","text":"\ud800"}"#,
    ] {
        let reply: Value = serde_json::from_str(&reduce_json(input)).unwrap();
        assert_eq!(
            reply,
            json!({"ok":false,"error":"E_NAME_POLICY_ARGUMENTS"}),
            "{input}"
        );
    }
}

#[test]
fn automatic_titles_fit_both_character_and_persisted_byte_budgets() {
    for (body, expected) in [
        ("a".repeat(80), "a".repeat(60)),
        ("中".repeat(60), "中".repeat(40)),
        ("🌏".repeat(60), "🌏".repeat(30)),
        (
            format!("a{}", "中".repeat(50)),
            format!("a{}", "中".repeat(39)),
        ),
        ("e\u{301}".repeat(80), "é".repeat(60)),
    ] {
        let title = automatic_title(&body);
        assert_eq!(title, expected);
        assert!(title.len() <= MAX_CONVERSATION_TITLE_BYTES);
        assert!(title.chars().count() <= 60);
        assert_eq!(normalize(NameKind::Conversation, &title), Ok(title));
    }
}

#[test]
fn automatic_titles_are_single_line_and_have_a_nonempty_fallback() {
    assert_eq!(
        automatic_title("  规划\n\n 项目\t下一步 \u{2028}继续  "),
        "规划 项目 下一步 继续"
    );
    assert_eq!(automatic_title("a\0b"), "ab");
    assert_eq!(automatic_title("e\0\u{301}"), "é");
    for body in ["", "  \n\t", "\0\u{0001}"] {
        assert_eq!(automatic_title(body), "New chat");
    }
}
