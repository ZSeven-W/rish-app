//! Bounded, exact unsent text in the schema-10 session authority.

use super::{bounded_text, valid_identifier, MAX_ID_BYTES};
use serde_json::Value;

pub const MAX_COMPOSER_DRAFTS: usize = 256;
pub const MAX_COMPOSER_DRAFT_BYTES: usize = 1024 * 1024;
pub const MAX_COMPOSER_DRAFT_TOTAL_BYTES: usize = 4 * 1024 * 1024;

/// Keys are stable editor identities (conversation, new chat or assistant group).
/// Empty text is represented by removing its key; whitespace is preserved.
pub fn validate_composer_drafts(value: &Value) -> bool {
    let Some(drafts) = value.as_object() else {
        return false;
    };
    if drafts.len() > MAX_COMPOSER_DRAFTS {
        return false;
    }
    let mut total = 0usize;
    for (key, value) in drafts {
        if !valid_identifier(Some(&Value::String(key.clone())), MAX_ID_BYTES) {
            return false;
        }
        let Some(text) = bounded_text(Some(value), MAX_COMPOSER_DRAFT_BYTES, false) else {
            return false;
        };
        total += text.len();
        if total > MAX_COMPOSER_DRAFT_TOTAL_BYTES {
            return false;
        }
    }
    true
}
