//! Shared rules for names entered by a person and titles derived from messages.
//!
//! Native controls retain their uncommitted IME buffers. Once composition ends,
//! each host asks this policy for the normalized value and its validation issue.
//! Directory allocation and filesystem-specific collision folding stay native.

use crate::{project_module::clip_utf8, strict_json, workspace_record};
use serde_json::{json, Value};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

/// The stored session schema measures a conversation title in UTF-8 bytes.
pub const MAX_CONVERSATION_TITLE_BYTES: usize = 120;
const MAX_AUTOMATIC_TITLE_CHARACTERS: usize = 60;
const DEFAULT_CONVERSATION_TITLE: &str = "New chat";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NameKind {
    Workspace,
    Conversation,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NameIssue {
    Empty,
    Invalid,
    TooLong,
}

impl NameIssue {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Empty => "empty",
            Self::Invalid => "invalid",
            Self::TooLong => "too_long",
        }
    }
}

fn normalized_text(raw: &str) -> String {
    raw.trim().nfc().collect()
}

fn single_line_control(character: char) -> bool {
    character.is_control() || matches!(character, '\u{2028}' | '\u{2029}')
}

fn validate(kind: NameKind, name: &str) -> Result<(), NameIssue> {
    if name.is_empty() {
        return Err(NameIssue::Empty);
    }
    if name.chars().any(single_line_control) {
        return Err(NameIssue::Invalid);
    }
    let maximum_bytes = match kind {
        NameKind::Workspace => workspace_record::MAX_DISPLAY_NAME_BYTES,
        NameKind::Conversation => MAX_CONVERSATION_TITLE_BYTES,
    };
    if name.len() > maximum_bytes {
        return Err(NameIssue::TooLong);
    }
    if kind == NameKind::Workspace {
        // The reserved ASCII container name ignores case and diacritics. This
        // projection is only for the shared naming policy, never for deciding
        // whether two on-disk directory names identify the same directory.
        let folded: String = name
            .nfd()
            .filter(|character| !is_combining_mark(*character))
            .flat_map(char::to_lowercase)
            .collect();
        if !workspace_record::display_name(Some(&Value::String(name.into())), Some(&folded)) {
            return Err(NameIssue::Invalid);
        }
    }
    Ok(())
}

/// Normalize a completed input and apply the same limits as persistence.
pub fn normalize(kind: NameKind, raw: &str) -> Result<String, NameIssue> {
    let name = normalized_text(raw);
    validate(kind, &name)?;
    Ok(name)
}

/// Produce a single-line title without changing or truncating the message body.
pub fn automatic_title(raw: &str) -> String {
    let mut single_line = String::new();
    let mut space_pending = false;
    for character in raw.chars() {
        if character.is_whitespace() {
            space_pending = !single_line.is_empty();
        } else if !single_line_control(character) {
            if space_pending {
                single_line.push(' ');
                space_pending = false;
            }
            single_line.push(character);
        }
    }
    let prefix: String = single_line
        .nfc()
        .take(MAX_AUTOMATIC_TITLE_CHARACTERS)
        .collect();
    let (bounded, _) = clip_utf8(&prefix, MAX_CONVERSATION_TITLE_BYTES);
    let title = bounded.trim_end();
    if title.is_empty() {
        DEFAULT_CONVERSATION_TITLE.into()
    } else {
        title.into()
    }
}

/// Exact input: `{"kind":"workspace"|"conversation","text":"..."}`.
/// A validation issue still returns the normalized text; malformed envelopes
/// return a static failure and never echo input into an error message.
pub fn reduce_json(input: &str) -> String {
    let invalid = || json!({"ok": false, "error": "E_NAME_POLICY_ARGUMENTS"}).to_string();
    let Some(envelope) = strict_json::parse_arguments(input) else {
        return invalid();
    };
    if envelope.len() != 2 {
        return invalid();
    }
    let kind = match envelope.get("kind").and_then(Value::as_str) {
        Some("workspace") => NameKind::Workspace,
        Some("conversation") => NameKind::Conversation,
        _ => return invalid(),
    };
    let Some(raw) = envelope.get("text").and_then(Value::as_str) else {
        return invalid();
    };
    let text = normalized_text(raw);
    let issue = validate(kind, &text).err().map(NameIssue::as_str);
    json!({"ok": true, "value": {"text": text, "issue": issue}}).to_string()
}

#[cfg(test)]
#[path = "name_policy_tests.rs"]
mod tests;
