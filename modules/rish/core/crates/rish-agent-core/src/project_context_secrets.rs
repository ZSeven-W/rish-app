//! Whether a file's text looks like it carries a credential.
//!
//! Ported from `secretDecisionForData:` and the credential grammar around it
//! in `ProjectContextPolicy.mm`: the private-key and known-token shapes, a
//! JWT, an assignment of a credential-named key to something that is not an
//! approved placeholder, the same assignment spelled as XML, JSON or a
//! bracketed JavaScript property, and a long high-entropy value.
//!
//! **This walks UTF-16 code units**, because the original walks `unichar`s:
//! a line break is `\n`, `\r`, U+2028 or U+2029; horizontal whitespace is
//! space, tab and form feed; anything else Foundation's
//! `whitespaceAndNewlineCharacterSet` holds counts as the ambiguous
//! non-ASCII whitespace the grammar refuses to reason past. A lone surrogate
//! is none of these. Reproducing that is the point: the fixture in
//! `project-secret-decisions.json` was recorded from the shipped host.
//!
//! The four regular expressions of the original are matched by hand here,
//! with the same leftmost-first alternation ICU uses, so that "tokenizer"
//! matches "token" and is therefore *not* an approved placeholder for the
//! whole value -- exactly as before.

/// `DSHProjectContextMaxFileBytes`: the scan reads no further than this.
const MAX_SCAN_BYTES: usize = 64 * 1024;
/// A credential key, a quoted token or a placeholder value longer than this
/// is not reasoned about.
const MAX_KEY_UNITS: usize = 128;
const MAX_PLACEHOLDER_UNITS: usize = 512;

pub const REASON_SUSPECTED_SECRET: &str = "suspected_secret";

/// `secretDecisionForData:`. The bytes are cut at the file budget; text that
/// does not decode is not scanned, unless the cut fell inside a character,
/// in which case up to three trailing bytes are dropped first.
pub fn suspected_secret(data: &[u8]) -> bool {
    let length = data.len().min(MAX_SCAN_BYTES);
    let bounded = &data[..length];
    let mut text = std::str::from_utf8(bounded).ok();
    if text.is_none() && data.len() > length {
        let maximum_trim = 3.min(bounded.len());
        for trim in 1..=maximum_trim {
            if let Ok(decoded) = std::str::from_utf8(&bounded[..bounded.len() - trim]) {
                text = Some(decoded);
                break;
            }
        }
    }
    let Some(text) = text else {
        return false;
    };
    let units: Vec<u16> = text.encode_utf16().collect();
    has_private_key(&units)
        || has_known_token(&units)
        || has_jwt(&units)
        || has_unsafe_structured_credential(&units)
        || has_credential_assignment(&units)
        || has_high_entropy_credential_like_value(&units)
}

// MARK: - character classes

fn lower(unit: u16) -> u16 {
    if (b'A' as u16..=b'Z' as u16).contains(&unit) {
        unit - b'A' as u16 + b'a' as u16
    } else {
        unit
    }
}

fn is_ascii_alnum(unit: u16) -> bool {
    (b'a' as u16..=b'z' as u16).contains(&unit)
        || (b'A' as u16..=b'Z' as u16).contains(&unit)
        || (b'0' as u16..=b'9' as u16).contains(&unit)
}

fn is_line_break(unit: u16) -> bool {
    unit == b'\n' as u16 || unit == b'\r' as u16 || unit == 0x2028 || unit == 0x2029
}

fn is_horizontal_whitespace(unit: u16) -> bool {
    unit == b' ' as u16 || unit == b'\t' as u16 || unit == 0x0c
}

/// `whitespaceAndNewlineCharacterSet` minus the two classes above: Unicode
/// White_Space is the same set Foundation names, and a surrogate is in neither.
fn is_non_ascii_horizontal_whitespace(unit: u16) -> bool {
    !is_line_break(unit)
        && !is_horizontal_whitespace(unit)
        && char::from_u32(u32::from(unit)).is_some_and(char::is_whitespace)
}

fn is_xml_whitespace(unit: u16) -> bool {
    unit == b' ' as u16 || unit == b'\t' as u16 || unit == b'\r' as u16 || unit == b'\n' as u16
}

fn is_xml_name_character(unit: u16) -> bool {
    is_ascii_alnum(unit)
        || unit == b'_' as u16
        || unit == b'-' as u16
        || unit == b':' as u16
        || unit == b'.' as u16
        || unit > 0x7f
}

fn is_credential_token_character(unit: u16) -> bool {
    is_ascii_alnum(unit) || unit == b'_' as u16 || unit == b'-' as u16 || unit == b'.' as u16
}

fn hex_value(unit: u16) -> Option<u32> {
    match unit {
        u if (b'0' as u16..=b'9' as u16).contains(&u) => Some(u32::from(u - b'0' as u16)),
        u if (b'a' as u16..=b'f' as u16).contains(&u) => Some(u32::from(u - b'a' as u16) + 10),
        u if (b'A' as u16..=b'F' as u16).contains(&u) => Some(u32::from(u - b'A' as u16) + 10),
        _ => None,
    }
}

/// Whether `text[at..]` starts with `literal`, ASCII case-insensitively.
fn starts_with_ci(text: &[u16], at: usize, literal: &str) -> bool {
    let bytes = literal.as_bytes();
    at + bytes.len() <= text.len()
        && bytes
            .iter()
            .enumerate()
            .all(|(offset, byte)| lower(text[at + offset]) == lower(u16::from(*byte)))
}

fn starts_with(text: &[u16], at: usize, literal: &str) -> bool {
    let bytes = literal.as_bytes();
    at + bytes.len() <= text.len()
        && bytes
            .iter()
            .enumerate()
            .all(|(offset, byte)| text[at + offset] == u16::from(*byte))
}

fn run_length(text: &[u16], at: usize, class: impl Fn(u16) -> bool) -> usize {
    text[at.min(text.len())..]
        .iter()
        .take_while(|unit| class(**unit))
        .count()
}

// MARK: - the four expressions

/// `-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOCK-----`, case-insensitive.
fn has_private_key(text: &[u16]) -> bool {
    (0..text.len()).any(|start| {
        if !starts_with_ci(text, start, "-----BEGIN") {
            return false;
        }
        if starts_with_ci(text, start, "-----BEGIN PGP PRIVATE KEY BLOCK-----") {
            return true;
        }
        let mut cursor = start + "-----BEGIN".len();
        loop {
            if starts_with_ci(text, cursor, " PRIVATE KEY-----") {
                return true;
            }
            if cursor < text.len() && text[cursor] == b' ' as u16 {
                let word = run_length(text, cursor + 1, is_ascii_alnum);
                if word == 0 {
                    return false;
                }
                cursor += 1 + word;
                continue;
            }
            return false;
        }
    })
}

/// The known token prefixes, case-insensitive as the original's flag made
/// the whole expression.
fn has_known_token(text: &[u16]) -> bool {
    const ALNUM: fn(u16) -> bool = is_ascii_alnum;
    fn alnum_underscore(unit: u16) -> bool {
        is_ascii_alnum(unit) || unit == b'_' as u16
    }
    fn alnum_underscore_dash(unit: u16) -> bool {
        is_ascii_alnum(unit) || unit == b'_' as u16 || unit == b'-' as u16
    }
    fn alnum_dash(unit: u16) -> bool {
        is_ascii_alnum(unit) || unit == b'-' as u16
    }
    (0..text.len()).any(|start| {
        let unit = lower(text[start]);
        let tail = |prefix: &str, minimum: usize, class: fn(u16) -> bool| {
            starts_with_ci(text, start, prefix)
                && run_length(text, start + prefix.len(), class) >= minimum
        };
        match unit {
            u if u == b'a' as u16 => {
                (tail("AKIA", 16, ALNUM) || tail("ASIA", 16, ALNUM))
                    || tail("AIza", 20, alnum_underscore_dash)
            }
            u if u == b'g' as u16 => {
                (starts_with_ci(text, start, "gh")
                    && start + 3 < text.len()
                    && "pousr"
                        .bytes()
                        .any(|c| lower(text[start + 2]) == u16::from(c))
                    && text[start + 3] == b'_' as u16
                    && run_length(text, start + 4, ALNUM) >= 20)
                    || tail("github_pat_", 22, alnum_underscore)
                    || tail("glpat-", 20, alnum_underscore_dash)
            }
            u if u == b'h' as u16 => tail("hf_", 20, ALNUM),
            u if u == b'n' as u16 => tail("npm_", 20, ALNUM),
            u if u == b's' as u16 => tail("sk-", 16, alnum_underscore_dash),
            u if u == b'x' as u16 => {
                starts_with_ci(text, start, "xox")
                    && start + 4 < text.len()
                    && "baprs"
                        .bytes()
                        .any(|c| lower(text[start + 3]) == u16::from(c))
                    && text[start + 4] == b'-' as u16
                    && run_length(text, start + 5, alnum_dash) >= 10
            }
            _ => false,
        }
    })
}

/// `(?:^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}(?:$|[^A-Za-z0-9_-])`.
fn has_jwt(text: &[u16]) -> bool {
    fn segment(unit: u16) -> bool {
        is_ascii_alnum(unit) || unit == b'_' as u16 || unit == b'-' as u16
    }
    (0..text.len()).any(|start| {
        if !starts_with(text, start, "eyJ") || (start > 0 && segment(text[start - 1])) {
            return false;
        }
        let first = run_length(text, start, segment);
        if first < 3 + 5 {
            return false;
        }
        let mut cursor = start + first;
        for _ in 0..2 {
            if cursor >= text.len() || text[cursor] != b'.' as u16 {
                return false;
            }
            let run = run_length(text, cursor + 1, segment);
            if run < 5 {
                return false;
            }
            cursor += 1 + run;
        }
        true
    })
}

/// The placeholder expression, anchored at `at`, with ICU's leftmost-first
/// alternation: the length of the first alternative that matches, if any,
/// within `limit` units.
fn placeholder_match(text: &[u16], at: usize, limit: usize) -> Option<usize> {
    const WORDS: &[&str] = &[
        "change_me",
        "changeme",
        "dummy",
        "example",
        "nil",
        "none",
        "null",
        "password",
        "placeholder",
        "redacted",
        "secret",
        "todo",
        "token",
        "test",
        "undefined",
        "xxxxx",
        "<password>",
        "<secret>",
        "<token>",
        "<api-key>",
        "<api_key>",
        "<your-password>",
        "<your_password>",
    ];
    let end = at.saturating_add(limit).min(text.len());
    let within = |length: usize| at + length <= end;
    for word in WORDS {
        if starts_with_ci(text, at, word) && within(word.len()) {
            return Some(word.len());
        }
    }
    let identifier = |from: usize| -> Option<usize> {
        // [a-z_][a-z0-9_]*, case-insensitively
        let first = text.get(from)?;
        let lowered = lower(*first);
        if !((b'a' as u16..=b'z' as u16).contains(&lowered) || lowered == b'_' as u16) {
            return None;
        }
        Some(
            1 + run_length(text, from + 1, |unit| {
                let l = lower(unit);
                (b'a' as u16..=b'z' as u16).contains(&l)
                    || (b'0' as u16..=b'9' as u16).contains(&l)
                    || l == b'_' as u16
            }),
        )
    };
    // ${name}
    if starts_with(text, at, "${") {
        if let Some(name) = identifier(at + 2) {
            let close = at + 2 + name;
            if close < text.len() && text[close] == b'}' as u16 && within(name + 3) {
                return Some(name + 3);
            }
        }
    }
    // {{name}}
    if starts_with(text, at, "{{") {
        if let Some(name) = identifier(at + 2) {
            if starts_with(text, at + 2 + name, "}}") && within(name + 4) {
                return Some(name + 4);
            }
        }
    }
    // process.env.name
    if starts_with_ci(text, at, "process.env.") {
        if let Some(name) = identifier(at + 12) {
            if within(12 + name) {
                return Some(12 + name);
            }
        }
    }
    // (os.environ|env)["name"] / getenv("name")
    let quoted_name = |from: usize, close: u8| -> Option<usize> {
        let quote = *text.get(from)?;
        if quote != b'"' as u16 && quote != b'\'' as u16 {
            return None;
        }
        let name = identifier(from + 1)?;
        let closing = from + 1 + name;
        if text.get(closing) != Some(&quote) || text.get(closing + 1) != Some(&u16::from(close)) {
            return None;
        }
        Some(name + 3)
    };
    for prefix in ["os.environ[", "env["] {
        if starts_with_ci(text, at, prefix) {
            if let Some(inner) = quoted_name(at + prefix.len(), b']') {
                if within(prefix.len() + inner) {
                    return Some(prefix.len() + inner);
                }
            }
        }
    }
    if starts_with_ci(text, at, "getenv(") {
        if let Some(inner) = quoted_name(at + 7, b')') {
            if within(7 + inner) {
                return Some(7 + inner);
            }
        }
    }
    None
}

/// `DSHCredentialValueRangeIsApproved`: empty, or exactly one placeholder.
fn value_range_is_approved(text: &[u16], start: usize, length: usize) -> bool {
    if length == 0 {
        return true;
    }
    if length > MAX_PLACEHOLDER_UNITS || start + length > text.len() {
        return false;
    }
    placeholder_match(text, start, length) == Some(length)
}

/// `[A-Za-z0-9+/_=-]{32,512}`, every match, greedy: a run past 512 is cut
/// into 512-unit matches and the remainder, as the engine would cut it.
fn has_high_entropy_credential_like_value(text: &[u16]) -> bool {
    fn class(unit: u16) -> bool {
        is_ascii_alnum(unit)
            || unit == b'+' as u16
            || unit == b'/' as u16
            || unit == b'_' as u16
            || unit == b'=' as u16
            || unit == b'-' as u16
    }
    let mut index = 0;
    while index < text.len() {
        let run = run_length(text, index, class);
        if run == 0 {
            index += 1;
            continue;
        }
        let mut cursor = index;
        let end = index + run;
        while end - cursor >= 32 {
            let take = (end - cursor).min(512);
            if credential_like(&text[cursor..cursor + take]) {
                return true;
            }
            cursor += take;
        }
        index = end;
    }
    false
}

fn credential_like(value: &[u16]) -> bool {
    let (mut lower_seen, mut upper_seen, mut digit, mut symbol) = (false, false, false, false);
    let mut counts = [0usize; 256];
    for unit in value {
        let byte = *unit as u8;
        lower_seen |= byte.is_ascii_lowercase();
        upper_seen |= byte.is_ascii_uppercase();
        digit |= byte.is_ascii_digit();
        symbol |= !byte.is_ascii_alphanumeric();
        counts[usize::from(byte)] += 1;
    }
    let categories = usize::from(lower_seen)
        + usize::from(upper_seen)
        + usize::from(digit)
        + usize::from(symbol);
    if categories < 3 {
        return false;
    }
    let total = value.len() as f64;
    let entropy: f64 = counts
        .iter()
        .filter(|count| **count > 0)
        .map(|count| {
            let probability = *count as f64 / total;
            -probability * probability.log2()
        })
        .sum();
    entropy >= 4.0
}

// MARK: - the credential grammar

fn skip_horizontal_whitespace(text: &[u16], mut index: usize) -> usize {
    while index < text.len() && is_horizontal_whitespace(text[index]) {
        index += 1;
    }
    index
}

fn starts_next_json_property(text: &[u16], mut index: usize) -> bool {
    if index >= text.len() || text[index] != b'"' as u16 {
        return false;
    }
    index += 1;
    let mut key_characters = 0;
    while index < text.len() && key_characters <= MAX_KEY_UNITS {
        let character = text[index];
        index += 1;
        if character == b'"' as u16 {
            index = skip_horizontal_whitespace(text, index);
            return index < text.len() && text[index] == b':' as u16;
        }
        if character == b'\\' as u16 && index < text.len() {
            index += 1;
        }
        if is_line_break(character) {
            return false;
        }
        key_characters += 1;
    }
    false
}

fn line_break_starts_credential_continuation(
    text: &[u16],
    mut index: usize,
    json_shaped: bool,
    after_json_comma: bool,
) -> bool {
    let mut next = 0u16;
    let mut found_next = false;
    let mut saw_line_break = false;
    let mut horizontal_after_last_break = false;
    while index < text.len() {
        let character = text[index];
        if is_line_break(character) {
            saw_line_break = true;
            horizontal_after_last_break = false;
            index += 1;
            continue;
        }
        if is_horizontal_whitespace(character) {
            horizontal_after_last_break = saw_line_break;
            index += 1;
            continue;
        }
        if is_non_ascii_horizontal_whitespace(character) {
            return true;
        }
        next = character;
        found_next = true;
        break;
    }
    if !found_next {
        return false;
    }
    if json_shaped {
        if next == b'}' as u16 || next == b']' as u16 {
            return after_json_comma;
        }
        if next == b'"' as u16 {
            return !after_json_comma || !starts_next_json_property(text, index);
        }
        if next == b',' as u16 {
            if after_json_comma {
                return true;
            }
            let mut after_comma = index + 1;
            while after_comma < text.len() {
                let character = text[after_comma];
                if is_horizontal_whitespace(character) || is_line_break(character) {
                    after_comma += 1;
                    continue;
                }
                if is_non_ascii_horizontal_whitespace(character) {
                    return true;
                }
                return character != b'"' as u16 || !starts_next_json_property(text, after_comma);
            }
            return true;
        }
        return true;
    }
    if horizontal_after_last_break && next != b'#' as u16 {
        return true;
    }
    if next == b'"' as u16 || next == b'\'' as u16 || next == b'`' as u16 {
        return true;
    }
    matches!(
        next as u8,
        b'+' | b'?' | b'|' | b'&' | b'\\' | b'/' | b'.' | b':' | b';' | b',' | b'}' | b']'
    ) && next < 0x80
}

fn json_closing_delimiters_exhaust_assignment(text: &[u16], mut index: usize) -> bool {
    while index < text.len() {
        let closing = text[index];
        if closing != b'}' as u16 && closing != b']' as u16 {
            break;
        }
        index += 1;
    }
    index = skip_horizontal_whitespace(text, index);
    if index >= text.len() {
        return true;
    }
    let delimiter = text[index];
    if is_non_ascii_horizontal_whitespace(delimiter) {
        return false;
    }
    if is_line_break(delimiter) {
        return !line_break_starts_credential_continuation(text, index, true, false);
    }
    if delimiter != b',' as u16 {
        return false;
    }
    index = skip_horizontal_whitespace(text, index + 1);
    if index >= text.len() {
        return true;
    }
    let next = text[index];
    if is_non_ascii_horizontal_whitespace(next) {
        return false;
    }
    if is_line_break(next) {
        !line_break_starts_credential_continuation(text, index, true, true)
    } else {
        starts_next_json_property(text, index)
    }
}

fn credential_tail_is_safe(text: &[u16], tail_start: usize, json_shaped: bool) -> bool {
    let mut index = skip_horizontal_whitespace(text, tail_start);
    let had_comment_boundary_whitespace = index > tail_start;
    if index >= text.len() {
        return true;
    }
    let delimiter = text[index];
    if is_non_ascii_horizontal_whitespace(delimiter) {
        return false;
    }
    if is_line_break(delimiter) {
        return !line_break_starts_credential_continuation(text, index, json_shaped, false);
    }
    if delimiter == b'#' as u16 {
        return had_comment_boundary_whitespace;
    }
    if !json_shaped {
        return false;
    }
    if delimiter == b'}' as u16 || delimiter == b']' as u16 {
        return json_closing_delimiters_exhaust_assignment(text, index);
    }
    if delimiter != b',' as u16 {
        return false;
    }
    index = skip_horizontal_whitespace(text, index + 1);
    if index >= text.len() {
        return true;
    }
    let next = text[index];
    if is_non_ascii_horizontal_whitespace(next) {
        return false;
    }
    if is_line_break(next) {
        return !line_break_starts_credential_continuation(text, index, true, true);
    }
    if next == b'}' as u16 || next == b']' as u16 {
        return json_closing_delimiters_exhaust_assignment(text, index);
    }
    starts_next_json_property(text, index)
}

fn credential_rhs_is_approved_placeholder(
    text: &[u16],
    rhs_start: usize,
    json_shaped: bool,
) -> bool {
    if rhs_start >= text.len() {
        return false;
    }
    let first = text[rhs_start];
    if is_line_break(first) || is_non_ascii_horizontal_whitespace(first) {
        return false;
    }
    let tail_start;
    if first == b'"' as u16 || first == b'\'' as u16 {
        let quote = first;
        let value_start = rhs_start + 1;
        let mut index = value_start;
        let mut closed = None;
        while index < text.len() && index - value_start <= MAX_PLACEHOLDER_UNITS {
            let character = text[index];
            index += 1;
            if is_line_break(character) {
                return false;
            }
            if character == b'\\' as u16 && index < text.len() {
                index += 1;
                continue;
            }
            if character == quote {
                closed = Some(index);
                break;
            }
        }
        let Some(after_quote) = closed else {
            return false;
        };
        tail_start = after_quote;
        if !value_range_is_approved(text, value_start, tail_start - value_start - 1) {
            return false;
        }
    } else {
        let limit = MAX_PLACEHOLDER_UNITS.min(text.len() - rhs_start);
        let Some(length) = placeholder_match(text, rhs_start, limit) else {
            return false;
        };
        tail_start = rhs_start + length;
    }
    credential_tail_is_safe(text, tail_start, json_shaped)
}

/// `DSHCredentialKeyBufferMatches`: the key itself, or a `_`/`.`-scoped suffix.
fn credential_key_matches(key: &[u8]) -> bool {
    const VALUES: &[&str] = &[
        "password",
        "passwd",
        "pwd",
        "secret",
        "token",
        "api_key",
        "access_key",
        "client_secret",
        "private_key",
        "credential",
        "apikey",
        "accesskey",
        "clientsecret",
        "privatekey",
    ];
    VALUES.iter().any(|value| {
        let value = value.as_bytes();
        key == value
            || (key.len() > value.len() + 1
                && matches!(key[key.len() - value.len() - 1], b'_' | b'.')
                && &key[key.len() - value.len()..] == value)
    })
}

fn decode_xml_character_reference(text: &[u16], index: &mut usize, end: usize) -> Option<u16> {
    let mut cursor = *index;
    if cursor >= end {
        return None;
    }
    let mut entity: Vec<u8> = Vec::new();
    while cursor < end && entity.len() + 1 < 9 {
        let character = text[cursor];
        cursor += 1;
        if character == b';' as u16 {
            let value: u32 = if entity.len() >= 2 && entity[0] == b'#' {
                let mut digit_index = 1;
                let mut radix = 10u32;
                if digit_index < entity.len()
                    && (entity[digit_index] == b'x' || entity[digit_index] == b'X')
                {
                    radix = 16;
                    digit_index += 1;
                }
                if digit_index >= entity.len() {
                    return None;
                }
                let mut value = 0u32;
                for byte in &entity[digit_index..] {
                    let digit = if radix == 16 {
                        hex_value(u16::from(*byte))
                    } else if byte.is_ascii_digit() {
                        Some(u32::from(byte - b'0'))
                    } else {
                        None
                    };
                    let Some(digit) = digit else {
                        return None;
                    };
                    if value > 0x7f / radix {
                        return None;
                    }
                    value = value * radix + digit;
                }
                value
            } else {
                match entity.as_slice() {
                    b"amp" => u32::from(b'&'),
                    b"quot" => u32::from(b'"'),
                    b"apos" => u32::from(b'\''),
                    b"lt" => u32::from(b'<'),
                    b"gt" => u32::from(b'>'),
                    _ => return None,
                }
            };
            if value > 0x7f {
                return None;
            }
            *index = cursor;
            return Some(value as u16);
        }
        if character > 0x7f {
            return None;
        }
        entity.push(character as u8);
    }
    None
}

/// `DSHCanonicalCredentialKeyMatches`: the key spelled canonically -- JSON
/// escapes and XML entities decoded when asked, upper folded to lower, `-` to
/// `_` -- and then looked up.
fn canonical_credential_key_matches(
    text: &[u16],
    start: usize,
    length: usize,
    decode_json_escapes: bool,
    decode_xml_entities: bool,
) -> bool {
    if start + length > text.len() || length > MAX_KEY_UNITS {
        return false;
    }
    let mut canonical: Vec<u8> = Vec::with_capacity(length);
    let mut index = start;
    let end = start + length;
    while index < end {
        let mut character = text[index];
        index += 1;
        if decode_json_escapes && character == b'\\' as u16 {
            if index >= end {
                return false;
            }
            let escaped = text[index];
            index += 1;
            if escaped == b'u' as u16 {
                if end - index < 4 {
                    return false;
                }
                let mut value = 0u32;
                for _ in 0..4 {
                    let Some(digit) = hex_value(text[index]) else {
                        return false;
                    };
                    index += 1;
                    value = (value << 4) | digit;
                }
                if value > 0x7f {
                    return false;
                }
                character = value as u16;
            } else if escaped == b'x' as u16 {
                if end - index < 2 {
                    return false;
                }
                let (Some(high), Some(low)) = (hex_value(text[index]), hex_value(text[index + 1]))
                else {
                    return false;
                };
                index += 2;
                character = ((high << 4) | low) as u16;
            } else if matches!(escaped as u8, b'"' | b'\'' | b'`' | b'\\' | b'/') && escaped < 0x80
            {
                character = escaped;
            } else {
                return false;
            }
        }
        if decode_xml_entities && character == b'&' as u16 {
            let Some(decoded) = decode_xml_character_reference(text, &mut index, end) else {
                return false;
            };
            character = decoded;
        }
        let mut folded = lower(character);
        if folded == b'-' as u16 {
            folded = b'_' as u16;
        }
        if folded > 0x7f || canonical.len() + 1 >= MAX_KEY_UNITS + 1 {
            return false;
        }
        canonical.push(folded as u8);
    }
    credential_key_matches(&canonical)
}

fn range_equals_ascii(text: &[u16], start: usize, length: usize, literal: &str) -> bool {
    let bytes = literal.as_bytes();
    length == bytes.len()
        && start + length <= text.len()
        && bytes
            .iter()
            .enumerate()
            .all(|(offset, byte)| lower(text[start + offset]) == u16::from(*byte))
}

fn ranges_equal_ascii(text: &[u16], left: (usize, usize), right: (usize, usize)) -> bool {
    left.1 == right.1
        && left.0 + left.1 <= text.len()
        && right.0 + right.1 <= text.len()
        && (0..left.1).all(|offset| lower(text[left.0 + offset]) == lower(text[right.0 + offset]))
}

#[derive(Clone, Copy, Default)]
struct XmlTag {
    valid: bool,
    closing: bool,
    self_closing: bool,
    qualified_name: (usize, usize),
    local_name: (usize, usize),
    attributes: Option<(usize, usize)>,
    next_index: usize,
}

fn parse_xml_tag(text: &[u16], start: usize) -> XmlTag {
    let mut tag = XmlTag {
        next_index: text.len().min(start + 1),
        ..XmlTag::default()
    };
    if start >= text.len() || text[start] != b'<' as u16 {
        return tag;
    }
    let mut index = start + 1;
    while index < text.len() && is_horizontal_whitespace(text[index]) {
        index += 1;
    }
    if index < text.len() && text[index] == b'/' as u16 {
        tag.closing = true;
        index += 1;
    }
    if index >= text.len() {
        tag.next_index = text.len();
        return tag;
    }
    let first = text[index];
    if first == b'!' as u16 || first == b'?' as u16 || !is_xml_name_character(first) {
        return tag;
    }
    let name_start = index;
    let mut local_start = index;
    while index < text.len() {
        let character = text[index];
        if !is_xml_name_character(character) {
            break;
        }
        if character == b':' as u16 {
            local_start = index + 1;
        }
        index += 1;
        if index - name_start > MAX_KEY_UNITS {
            tag.next_index = index;
            return tag;
        }
    }
    if index == name_start || local_start >= index {
        tag.next_index = tag.next_index.max(index);
        return tag;
    }
    tag.qualified_name = (name_start, index - name_start);
    tag.local_name = (local_start, index - local_start);
    let attributes_start = index;
    let mut quote = 0u16;
    let mut last_non_whitespace = 0u16;
    while index < text.len() {
        let character = text[index];
        if quote != 0 {
            if character == quote {
                quote = 0;
            }
            index += 1;
            continue;
        }
        if character == b'"' as u16 || character == b'\'' as u16 {
            quote = character;
            index += 1;
            continue;
        }
        if character == b'<' as u16 {
            tag.next_index = index;
            return tag;
        }
        if character == b'>' as u16 {
            tag.self_closing = !tag.closing && last_non_whitespace == b'/' as u16;
            tag.attributes = Some((attributes_start, index - attributes_start));
            tag.next_index = index + 1;
            tag.valid = true;
            return tag;
        }
        if !is_xml_whitespace(character) {
            last_non_whitespace = character;
        }
        index += 1;
    }
    tag.next_index = text.len();
    tag
}

enum XmlAttribute {
    NotFound,
    Found(usize, usize),
    Malformed,
}

fn find_xml_attribute(text: &[u16], tag: &XmlTag, attribute_name: &str) -> XmlAttribute {
    let Some((attributes_start, attributes_length)) = tag.attributes else {
        return XmlAttribute::Malformed;
    };
    if !tag.valid || attributes_start + attributes_length > text.len() {
        return XmlAttribute::Malformed;
    }
    let mut cursor = attributes_start;
    let end = attributes_start + attributes_length;
    let mut found: Option<(usize, usize)> = None;
    while cursor < end {
        while cursor < end && is_xml_whitespace(text[cursor]) {
            cursor += 1;
        }
        if cursor >= end {
            break;
        }
        if text[cursor] == b'/' as u16 {
            break;
        }
        let name_start = cursor;
        let mut local_start = cursor;
        while cursor < end {
            let character = text[cursor];
            if !is_xml_name_character(character) {
                break;
            }
            if character == b':' as u16 {
                local_start = cursor + 1;
            }
            cursor += 1;
            if cursor - name_start > MAX_KEY_UNITS {
                return XmlAttribute::Malformed;
            }
        }
        if cursor == name_start || local_start >= cursor {
            return XmlAttribute::Malformed;
        }
        let local_name = (local_start, cursor - local_start);
        while cursor < end && is_xml_whitespace(text[cursor]) {
            cursor += 1;
        }
        if cursor >= end || text[cursor] != b'=' as u16 {
            return XmlAttribute::Malformed;
        }
        cursor += 1;
        while cursor < end && is_xml_whitespace(text[cursor]) {
            cursor += 1;
        }
        if cursor >= end {
            return XmlAttribute::Malformed;
        }
        let quote = text[cursor];
        cursor += 1;
        if quote != b'"' as u16 && quote != b'\'' as u16 {
            return XmlAttribute::Malformed;
        }
        let value_start = cursor;
        while cursor < end && text[cursor] != quote {
            cursor += 1;
        }
        if cursor >= end {
            return XmlAttribute::Malformed;
        }
        let parsed_value = (value_start, cursor - value_start);
        cursor += 1;
        if range_equals_ascii(text, local_name.0, local_name.1, attribute_name) {
            if found.is_some() {
                return XmlAttribute::Malformed;
            }
            found = Some(parsed_value);
        }
    }
    match found {
        Some((start, length)) => XmlAttribute::Found(start, length),
        None => XmlAttribute::NotFound,
    }
}

fn skip_xml_whitespace(text: &[u16], mut index: usize) -> usize {
    while index < text.len() && is_xml_whitespace(text[index]) {
        index += 1;
    }
    index
}

fn trim_xml_whitespace(text: &[u16], start: usize, length: usize) -> (usize, usize) {
    let mut start = start;
    let mut end = start + length;
    while start < end && is_xml_whitespace(text[start]) {
        start += 1;
    }
    while end > start && is_xml_whitespace(text[end - 1]) {
        end -= 1;
    }
    (start, end - start)
}

/// `DSHParseSimpleXMLElement`: the element's text (or CDATA) and the index
/// after its closing tag, when the opening tag is followed by exactly that.
fn parse_simple_xml_element(text: &[u16], opening: &XmlTag) -> Option<((usize, usize), usize)> {
    if !opening.valid || opening.closing {
        return None;
    }
    if opening.self_closing {
        return Some(((opening.next_index, 0), opening.next_index));
    }
    let content_start = opening.next_index;
    let mut cursor = skip_xml_whitespace(text, content_start);
    let parsed_value;
    if starts_with(text, cursor, "<![CDATA[") {
        let cdata_start = cursor + "<![CDATA[".len();
        let mut cdata_cursor = cdata_start;
        let mut cdata_end = None;
        while cdata_cursor < text.len() {
            if text[cdata_cursor] == b']' as u16
                && cdata_cursor + 2 < text.len()
                && text[cdata_cursor + 1] == b']' as u16
                && text[cdata_cursor + 2] == b'>' as u16
            {
                cdata_end = Some(cdata_cursor);
                cdata_cursor += 3;
                break;
            }
            cdata_cursor += 1;
        }
        let cdata_end = cdata_end?;
        parsed_value = (cdata_start, cdata_end - cdata_start);
        cursor = skip_xml_whitespace(text, cdata_cursor);
    } else {
        cursor = content_start;
        while cursor < text.len() && text[cursor] != b'<' as u16 {
            cursor += 1;
        }
        if cursor >= text.len() {
            return None;
        }
        parsed_value = (content_start, cursor - content_start);
    }
    let closing = parse_xml_tag(text, cursor);
    if !closing.valid
        || !closing.closing
        || closing.self_closing
        || !ranges_equal_ascii(text, opening.qualified_name, closing.qualified_name)
    {
        return None;
    }
    Some((
        trim_xml_whitespace(text, parsed_value.0, parsed_value.1),
        closing.next_index,
    ))
}

#[derive(Clone, Copy)]
struct QuotedToken {
    valid: bool,
    content: Option<(usize, usize)>,
    next_index: usize,
}

fn parse_quoted_token(text: &[u16], start: usize) -> QuotedToken {
    let mut token = QuotedToken {
        valid: false,
        content: None,
        next_index: text.len().min(start + 1),
    };
    if start >= text.len() {
        return token;
    }
    let quote = text[start];
    if quote != b'"' as u16 && quote != b'\'' as u16 && quote != b'`' as u16 {
        return token;
    }
    let mut index = start + 1;
    let content_start = index;
    let mut overlong = false;
    while index < text.len() {
        let character = text[index];
        index += 1;
        if is_line_break(character) {
            token.next_index = index;
            return token;
        }
        if character == b'\\' as u16 && index < text.len() {
            index += 1;
            overlong |= index - content_start > MAX_KEY_UNITS;
            continue;
        }
        if character == quote {
            let length = index - content_start - 1;
            token.content = Some((content_start, length));
            token.next_index = index;
            token.valid = !overlong && length <= MAX_KEY_UNITS;
            return token;
        }
        overlong |= index - content_start > MAX_KEY_UNITS;
    }
    token.next_index = text.len();
    token
}

fn quoted_token_has_json_boundary(text: &[u16], quote_index: usize) -> bool {
    let mut index = quote_index;
    let mut scanned = 0;
    while index > 0 {
        if scanned >= 256 {
            return false;
        }
        scanned += 1;
        let previous = text[index - 1];
        if is_horizontal_whitespace(previous) || is_line_break(previous) {
            index -= 1;
            continue;
        }
        return previous == b'{' as u16 || previous == b',' as u16;
    }
    true
}

fn skip_assignment_whitespace(text: &[u16], mut index: usize, ambiguous: &mut bool) -> usize {
    while index < text.len() {
        let character = text[index];
        if is_horizontal_whitespace(character) {
            index += 1;
            continue;
        }
        if is_line_break(character) || is_non_ascii_horizontal_whitespace(character) {
            *ambiguous = true;
            index += 1;
            continue;
        }
        break;
    }
    index
}

fn range_visibly_contains_credential_key(text: &[u16], start: usize, length: usize) -> bool {
    let mut index = start;
    let end = start + length;
    while index < end {
        if !is_credential_token_character(text[index]) {
            index += 1;
            continue;
        }
        let token_start = index;
        index += 1;
        while index < end && is_credential_token_character(text[index]) {
            index += 1;
        }
        let mut candidate_end = index;
        while candidate_end > token_start {
            let trailing = text[candidate_end - 1];
            if trailing != b'_' as u16 && trailing != b'-' as u16 && trailing != b'.' as u16 {
                break;
            }
            candidate_end -= 1;
        }
        let (mut candidate_start, mut candidate_length) =
            (token_start, candidate_end - token_start);
        if candidate_length > MAX_KEY_UNITS {
            candidate_start = candidate_end - MAX_KEY_UNITS;
            candidate_length = MAX_KEY_UNITS;
        }
        if canonical_credential_key_matches(text, candidate_start, candidate_length, false, false) {
            return true;
        }
    }
    false
}

fn range_contains_template_interpolation(text: &[u16], start: usize, length: usize) -> bool {
    let end = start + length;
    (start..end.saturating_sub(1))
        .any(|index| text[index] == b'$' as u16 && text[index + 1] == b'{' as u16)
}

/// Skips JavaScript comments and whitespace; a line comment or a line break
/// makes what follows ambiguous, an unclosed block comment makes it invalid.
fn skip_js_bracket_trivia_forward(
    text: &[u16],
    mut index: usize,
    ambiguous: &mut bool,
    valid: &mut bool,
) -> usize {
    while index < text.len() {
        let character = text[index];
        if is_horizontal_whitespace(character) {
            index += 1;
            continue;
        }
        if is_line_break(character) || is_non_ascii_horizontal_whitespace(character) {
            *ambiguous = true;
            index += 1;
            continue;
        }
        if character == b'/' as u16 && index + 1 < text.len() {
            let following = text[index + 1];
            if following == b'*' as u16 {
                let mut cursor = index + 2;
                let mut scanned = 0;
                let mut overlong = false;
                let mut closed = false;
                while cursor + 1 < text.len() {
                    scanned += 1;
                    overlong |= scanned > 256;
                    if text[cursor] == b'*' as u16 && text[cursor + 1] == b'/' as u16 {
                        index = cursor + 2;
                        closed = true;
                        break;
                    }
                    cursor += 1;
                }
                if !closed {
                    *valid = false;
                    return text.len();
                }
                if overlong {
                    *ambiguous = true;
                }
                continue;
            }
            if following == b'/' as u16 {
                let mut cursor = index + 2;
                while cursor < text.len() && !is_line_break(text[cursor]) {
                    cursor += 1;
                }
                *ambiguous = true;
                index = cursor;
                continue;
            }
        }
        break;
    }
    index
}

fn js_assignment_operator_length(text: &[u16], index: usize) -> usize {
    if index >= text.len() {
        return 0;
    }
    let first = text[index];
    if first == b'=' as u16 {
        if index + 1 < text.len() {
            let following = text[index + 1];
            if following == b'=' as u16 || following == b'>' as u16 {
                return 0;
            }
        }
        return 1;
    }
    if index + 2 < text.len()
        && ((first == b'|' as u16 && text[index + 1] == b'|' as u16)
            || (first == b'&' as u16 && text[index + 1] == b'&' as u16)
            || (first == b'?' as u16 && text[index + 1] == b'?' as u16))
        && text[index + 2] == b'=' as u16
    {
        return 3;
    }
    if index + 1 < text.len()
        && first < 0x80
        && matches!(
            first as u8,
            b'+' | b'-' | b'*' | b'/' | b'%' | b'|' | b'&' | b'^'
        )
        && text[index + 1] == b'=' as u16
    {
        return 2;
    }
    0
}

/// `DSHBracketExpressionIsUnsafe`: `x[...] = value` where the bracket names
/// a credential and the value is not a placeholder. Answers the verdict and
/// where scanning resumes.
fn bracket_expression_is_unsafe(text: &[u16], opening_bracket: usize) -> (bool, usize) {
    let mut ambiguous = false;
    let mut valid_trivia = true;
    let mut cursor = skip_js_bracket_trivia_forward(
        text,
        opening_bracket + 1,
        &mut ambiguous,
        &mut valid_trivia,
    );
    if !valid_trivia {
        return (false, text.len());
    }
    let mut visible_credential = false;
    let mut constant_credential = false;
    let mut significant_components = 0usize;
    while cursor < text.len() {
        cursor = skip_js_bracket_trivia_forward(text, cursor, &mut ambiguous, &mut valid_trivia);
        if !valid_trivia {
            return (false, text.len());
        }
        if cursor >= text.len() {
            return (visible_credential, text.len());
        }
        let character = text[cursor];
        if character == b']' as u16 {
            break;
        }
        if character == b'"' as u16 || character == b'\'' as u16 || character == b'`' as u16 {
            let token = parse_quoted_token(text, cursor);
            let Some((content_start, content_length)) = token.content else {
                return (visible_credential, (cursor + 1).max(token.next_index));
            };
            if !token.valid {
                visible_credential |=
                    range_visibly_contains_credential_key(text, content_start, content_length);
                significant_components += 1;
                constant_credential = false;
                cursor = token.next_index;
                continue;
            }
            let constant_token =
                canonical_credential_key_matches(text, content_start, content_length, true, false);
            let dynamic_token = character == b'`' as u16
                && range_contains_template_interpolation(text, content_start, content_length)
                && range_visibly_contains_credential_key(text, content_start, content_length);
            visible_credential |= constant_token || dynamic_token;
            significant_components += 1;
            constant_credential = significant_components == 1 && constant_token && !dynamic_token;
            cursor = token.next_index;
            continue;
        }
        if is_credential_token_character(character) {
            let token_start = cursor;
            cursor += 1;
            while cursor < text.len() && is_credential_token_character(text[cursor]) {
                cursor += 1;
            }
            let length = cursor - token_start;
            visible_credential |=
                canonical_credential_key_matches(text, token_start, length, false, false)
                    || range_visibly_contains_credential_key(text, token_start, length);
            significant_components += 1;
            constant_credential = false;
            continue;
        }
        significant_components += 1;
        constant_credential = false;
        cursor += 1;
    }
    if cursor >= text.len() || text[cursor] != b']' as u16 {
        return (visible_credential, (opening_bracket + 1).max(cursor));
    }
    let next_index = cursor + 1;
    let assignment =
        skip_js_bracket_trivia_forward(text, cursor + 1, &mut ambiguous, &mut valid_trivia);
    if !valid_trivia {
        return (false, next_index);
    }
    let operator_length = js_assignment_operator_length(text, assignment);
    if operator_length == 0 || !visible_credential {
        return (false, next_index);
    }
    if ambiguous || !constant_credential {
        return (true, next_index);
    }
    let rhs_start = skip_assignment_whitespace(text, assignment + operator_length, &mut ambiguous);
    (
        ambiguous || !credential_rhs_is_approved_placeholder(text, rhs_start, false),
        next_index,
    )
}

fn quoted_json_credential_key_is_unsafe(
    text: &[u16],
    quote_index: usize,
    token: &QuotedToken,
) -> bool {
    let Some((content_start, content_length)) = token.content else {
        return false;
    };
    if !token.valid
        || text[quote_index] != b'"' as u16
        || !canonical_credential_key_matches(text, content_start, content_length, true, false)
    {
        return false;
    }
    let mut ambiguous = false;
    let separator_index = skip_assignment_whitespace(text, token.next_index, &mut ambiguous);
    if separator_index >= text.len()
        || text[separator_index] != b':' as u16
        || !quoted_token_has_json_boundary(text, quote_index)
    {
        return false;
    }
    let rhs_start = skip_assignment_whitespace(text, separator_index + 1, &mut ambiguous);
    ambiguous || !credential_rhs_is_approved_placeholder(text, rhs_start, true)
}

/// `DSHHasCredentialAssignment`: `key = value` / `key: value` where the key
/// is credential-named and the value is not an approved placeholder.
fn has_credential_assignment(text: &[u16]) -> bool {
    let mut index = 0;
    while index < text.len() {
        let character = text[index];
        if !is_credential_token_character(character) {
            index += 1;
            continue;
        }
        let token_start = index;
        index += 1;
        while index < text.len() && is_credential_token_character(text[index]) {
            index += 1;
        }
        let (mut bounded_start, mut bounded_length) = (token_start, index - token_start);
        if bounded_length > MAX_KEY_UNITS {
            bounded_start = index - MAX_KEY_UNITS;
            bounded_length = MAX_KEY_UNITS;
        }
        if !canonical_credential_key_matches(text, bounded_start, bounded_length, false, false) {
            continue;
        }
        let mut quote = 0u16;
        let mut separator_start = index;
        if token_start > 0 && index < text.len() {
            let opening = text[token_start - 1];
            let closing = text[index];
            if (opening == b'"' as u16 || opening == b'\'' as u16) && closing == opening {
                quote = opening;
                separator_start += 1;
            }
        }
        let mut ambiguous = false;
        let separator = skip_assignment_whitespace(text, separator_start, &mut ambiguous);
        if separator >= text.len() {
            continue;
        }
        let separator_character = text[separator];
        if separator_character != b':' as u16 && separator_character != b'=' as u16 {
            continue;
        }
        let json_shaped = quote == b'"' as u16
            && separator_character == b':' as u16
            && quoted_token_has_json_boundary(text, token_start - 1);
        let rhs_start = skip_assignment_whitespace(text, separator + 1, &mut ambiguous);
        if ambiguous || !credential_rhs_is_approved_placeholder(text, rhs_start, json_shaped) {
            return true;
        }
    }
    false
}

/// `DSHHasUnsafeStructuredCredential`: the same question over XML elements
/// and attributes, plist `<key>`/`<string>` pairs, JSON-quoted keys and
/// JavaScript bracket properties.
fn has_unsafe_structured_credential(text: &[u16]) -> bool {
    let mut index = 0;
    while index < text.len() {
        let character = text[index];
        if character == b'<' as u16 {
            let tag = parse_xml_tag(text, index);
            if !tag.valid {
                index = (index + 1).max(tag.next_index);
                continue;
            }
            let local = tag.local_name;
            if !tag.closing
                && canonical_credential_key_matches(text, local.0, local.1, false, false)
            {
                match find_xml_attribute(text, &tag, "value") {
                    XmlAttribute::Malformed => return true,
                    XmlAttribute::Found(start, length) => {
                        let (trimmed_start, trimmed_length) =
                            trim_xml_whitespace(text, start, length);
                        if !value_range_is_approved(text, trimmed_start, trimmed_length) {
                            return true;
                        }
                    }
                    XmlAttribute::NotFound => {}
                }
                let Some(((value_start, value_length), next_index)) =
                    parse_simple_xml_element(text, &tag)
                else {
                    return true;
                };
                if !value_range_is_approved(text, value_start, value_length) {
                    return true;
                }
                index = next_index;
                continue;
            }
            if !tag.closing && range_equals_ascii(text, local.0, local.1, "property") {
                match find_xml_attribute(text, &tag, "name") {
                    XmlAttribute::Malformed => return true,
                    XmlAttribute::Found(key_start, key_length)
                        if canonical_credential_key_matches(
                            text, key_start, key_length, false, true,
                        ) =>
                    {
                        match find_xml_attribute(text, &tag, "value") {
                            XmlAttribute::Found(value_start, value_length) => {
                                let (trimmed_start, trimmed_length) =
                                    trim_xml_whitespace(text, value_start, value_length);
                                if !value_range_is_approved(text, trimmed_start, trimmed_length) {
                                    return true;
                                }
                            }
                            _ => return true,
                        }
                        index = tag.next_index;
                        continue;
                    }
                    _ => {}
                }
            }
            if !tag.closing && range_equals_ascii(text, local.0, local.1, "key") {
                if let Some(((key_start, key_length), after_key)) =
                    parse_simple_xml_element(text, &tag)
                {
                    let (key_start, key_length) = trim_xml_whitespace(text, key_start, key_length);
                    if canonical_credential_key_matches(text, key_start, key_length, false, true) {
                        let string_start = skip_xml_whitespace(text, after_key);
                        let string_tag = parse_xml_tag(text, string_start);
                        let string_local = string_tag.local_name;
                        let parsed = if !string_tag.valid
                            || string_tag.closing
                            || !range_equals_ascii(text, string_local.0, string_local.1, "string")
                        {
                            None
                        } else {
                            parse_simple_xml_element(text, &string_tag)
                        };
                        let Some(((value_start, value_length), after_string)) = parsed else {
                            return true;
                        };
                        if !value_range_is_approved(text, value_start, value_length) {
                            return true;
                        }
                        index = after_string;
                        continue;
                    }
                    index = after_key;
                    continue;
                }
            }
            index = (index + 1).max(tag.next_index);
            continue;
        }
        if character == b'[' as u16 {
            let (unsafe_expression, next_index) = bracket_expression_is_unsafe(text, index);
            if unsafe_expression {
                return true;
            }
            index = (index + 1).max(next_index);
            continue;
        }
        if character == b'"' as u16 || character == b'\'' as u16 || character == b'`' as u16 {
            let token = parse_quoted_token(text, index);
            if quoted_json_credential_key_is_unsafe(text, index, &token) {
                return true;
            }
            index = (index + 1).max(token.next_index);
            continue;
        }
        index += 1;
    }
    false
}

#[cfg(test)]
#[path = "project_context_secrets_tests.rs"]
mod tests;
