//! The strict argument parser `DSHAgentParseArgumentsJSON` from
//! `AgentNativeWAL.mm`: a JSON text is accepted only when it is a single
//! object with no duplicate keys (including escaped-equivalent spellings),
//! no negative zero, no non-finite or unsafe-integer numbers, no fractional
//! lexeme with more than fifteen meaningful digits, at most 64 levels and
//! 30,000 nodes, and every string canonicalisable.

use crate::canonical::{canonical_json, MAX_SAFE_INTEGER};
use serde_json::Value;
use std::collections::HashSet;

/// Bytes the ObjC parser accepts before scanning (256 KiB envelope).
pub const MAX_ARGUMENTS_BYTES: usize = 256 * 1024;
const MAX_NODES: usize = 30_000;
const MAX_DEPTH: usize = 64;

/// Parses `text` as tool arguments; `None` means the ObjC parser would refuse.
pub fn parse_arguments(text: &str) -> Option<serde_json::Map<String, Value>> {
    parse_arguments_bounded(text, MAX_ARGUMENTS_BYTES)
}

/// Explicit opt-in for bounded non-tool payloads such as provider model lists.
/// Scanner depth, node, duplicate-key and numeric rules remain unchanged.
pub(crate) fn parse_arguments_bounded(
    text: &str,
    maximum_bytes: usize,
) -> Option<serde_json::Map<String, Value>> {
    if text.is_empty() || text.len() > maximum_bytes || text.contains('\0') {
        return None;
    }
    let mut scanner = Scanner {
        bytes: text.as_bytes(),
        position: 0,
        nodes: 0,
    };
    if !scanner.run() {
        return None;
    }
    let value: Value = serde_json::from_str(text).ok()?;
    let object = match value {
        Value::Object(map) => map,
        _ => return None,
    };
    canonical_json(&Value::Object(object.clone())).ok()?;
    Some(object)
}

struct Scanner<'a> {
    bytes: &'a [u8],
    position: usize,
    nodes: usize,
}

impl Scanner<'_> {
    fn run(&mut self) -> bool {
        if !self.parse_value(0) {
            return false;
        }
        self.skip_whitespace();
        self.position == self.bytes.len()
    }

    fn skip_whitespace(&mut self) {
        while let Some(&c) = self.bytes.get(self.position) {
            if !matches!(c, b' ' | b'\n' | b'\r' | b'\t') {
                break;
            }
            self.position += 1;
        }
    }

    fn parse_value(&mut self, depth: usize) -> bool {
        if depth > MAX_DEPTH || self.nodes >= MAX_NODES {
            return false;
        }
        self.skip_whitespace();
        let Some(&c) = self.bytes.get(self.position) else {
            return false;
        };
        self.nodes += 1;
        match c {
            b'{' => self.parse_object(depth + 1),
            b'[' => self.parse_array(depth + 1),
            b'"' => self.parse_string().is_some(),
            b't' => self.parse_literal(b"true"),
            b'f' => self.parse_literal(b"false"),
            b'n' => self.parse_literal(b"null"),
            _ => self.parse_number(),
        }
    }

    fn parse_literal(&mut self, literal: &[u8]) -> bool {
        if self.bytes[self.position..].starts_with(literal) {
            self.position += literal.len();
            true
        } else {
            false
        }
    }

    /// Returns the byte range of the string token including quotes.
    fn parse_string(&mut self) -> Option<(usize, usize)> {
        if self.bytes.get(self.position) != Some(&b'"') {
            return None;
        }
        let begin = self.position;
        self.position += 1;
        while let Some(&c) = self.bytes.get(self.position) {
            self.position += 1;
            if c == b'"' {
                return Some((begin, self.position));
            }
            if c < 0x20 {
                return None;
            }
            if c != b'\\' {
                continue;
            }
            let escape = *self.bytes.get(self.position)?;
            self.position += 1;
            if escape == b'u' {
                let hex = self.bytes.get(self.position..self.position + 4)?;
                if !hex.iter().all(u8::is_ascii_hexdigit) {
                    return None;
                }
                self.position += 4;
            } else if !matches!(
                escape,
                b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't'
            ) {
                return None;
            }
        }
        None
    }

    fn parse_number(&mut self) -> bool {
        let begin = self.position;
        if self.bytes.get(self.position) == Some(&b'-') {
            self.position += 1;
        }
        match self.bytes.get(self.position) {
            Some(b'0') => {
                self.position += 1;
                if matches!(self.bytes.get(self.position), Some(b'0'..=b'9')) {
                    return false;
                }
            }
            Some(b'1'..=b'9') => {
                while matches!(self.bytes.get(self.position), Some(b'0'..=b'9')) {
                    self.position += 1;
                }
            }
            _ => return false,
        }
        let mut integer = true;
        if self.bytes.get(self.position) == Some(&b'.') {
            integer = false;
            self.position += 1;
            let fraction_start = self.position;
            while matches!(self.bytes.get(self.position), Some(b'0'..=b'9')) {
                self.position += 1;
            }
            if fraction_start == self.position {
                return false;
            }
        }
        if matches!(self.bytes.get(self.position), Some(b'e' | b'E')) {
            integer = false;
            self.position += 1;
            if matches!(self.bytes.get(self.position), Some(b'+' | b'-')) {
                self.position += 1;
            }
            let exponent_start = self.position;
            while matches!(self.bytes.get(self.position), Some(b'0'..=b'9')) {
                self.position += 1;
            }
            if exponent_start == self.position {
                return false;
            }
        }
        let token = std::str::from_utf8(&self.bytes[begin..self.position]).expect("ascii token");
        // The ObjC parser goes through strtold: an exponent that overflows or
        // underflows the double range is refused, as is negative zero.
        let Ok(value) = token.parse::<f64>() else {
            return false;
        };
        if !value.is_finite() || (value == 0.0 && token.starts_with('-')) {
            return false;
        }
        if underflowed_to_zero(token, value) {
            return false;
        }
        if !decimal_magnitude_within_safe_integer(token) {
            return false;
        }
        if integer && value.abs() > MAX_SAFE_INTEGER as f64 {
            return false;
        }
        true
    }

    fn parse_object(&mut self, depth: usize) -> bool {
        self.position += 1;
        self.skip_whitespace();
        let mut keys: HashSet<String> = HashSet::new();
        if self.bytes.get(self.position) == Some(&b'}') {
            self.position += 1;
            return true;
        }
        while self.position < self.bytes.len() {
            let Some((start, end)) = self.parse_string() else {
                return false;
            };
            let key_text = std::str::from_utf8(&self.bytes[start..end]).expect("utf8 slice");
            // Duplicate detection compares decoded keys, so "a" and "a"
            // collide exactly as they do through NSJSONSerialization.
            let Ok(Value::String(key)) = serde_json::from_str::<Value>(key_text) else {
                return false;
            };
            if !keys.insert(key) {
                return false;
            }
            self.skip_whitespace();
            if self.bytes.get(self.position) != Some(&b':') {
                return false;
            }
            self.position += 1;
            if !self.parse_value(depth) {
                return false;
            }
            self.skip_whitespace();
            match self.bytes.get(self.position) {
                Some(b'}') => {
                    self.position += 1;
                    return true;
                }
                Some(b',') => {
                    self.position += 1;
                    self.skip_whitespace();
                }
                _ => return false,
            }
        }
        false
    }

    fn parse_array(&mut self, depth: usize) -> bool {
        self.position += 1;
        self.skip_whitespace();
        if self.bytes.get(self.position) == Some(&b']') {
            self.position += 1;
            return true;
        }
        while self.position < self.bytes.len() {
            if !self.parse_value(depth) {
                return false;
            }
            self.skip_whitespace();
            match self.bytes.get(self.position) {
                Some(b']') => {
                    self.position += 1;
                    return true;
                }
                Some(b',') => {
                    self.position += 1;
                    self.skip_whitespace();
                }
                _ => return false,
            }
        }
        false
    }
}

/// strtold reports ERANGE when a non-zero lexeme underflows to zero; Rust's
/// parser silently returns 0.0, so detect the case from the digits.
fn underflowed_to_zero(token: &str, value: f64) -> bool {
    if value != 0.0 {
        return false;
    }
    let significand = token.split(['e', 'E']).next().unwrap_or("");
    significand.bytes().any(|b| (b'1'..=b'9').contains(&b))
}

/// Port of `DSHAgentDecimalMagnitudeWithinSafeInteger`.
fn decimal_magnitude_within_safe_integer(token: &str) -> bool {
    let bytes = token.as_bytes();
    let cursor = usize::from(bytes.first() == Some(&b'-'));
    let dot = token[cursor..].find('.').map(|i| i + cursor);
    let exponent_mark = token[cursor..].find(['e', 'E']).map(|i| i + cursor);
    let significand_end = exponent_mark.unwrap_or(bytes.len());
    let mut fraction_digits = 0usize;
    let mut digits: Vec<u8> = Vec::with_capacity(significand_end - cursor);
    for (index, &byte) in bytes.iter().enumerate().take(significand_end).skip(cursor) {
        if byte == b'.' {
            continue;
        }
        if let Some(dot) = dot {
            if index > dot {
                fraction_digits += 1;
            }
        }
        digits.push(byte);
    }
    let Some(first_significant) = digits.iter().position(|d| *d != b'0') else {
        return true;
    };
    digits.drain(..first_significant);
    let mut exponent: i64 = 0;
    if let Some(mark) = exponent_mark {
        let mut index = mark + 1;
        let mut negative = false;
        if let Some(&sign) = bytes.get(index) {
            if sign == b'+' || sign == b'-' {
                negative = sign == b'-';
                index += 1;
            }
        }
        let mut magnitude: i64 = 0;
        while index < bytes.len() {
            let digit = i64::from(bytes[index] - b'0');
            if magnitude < 100_000 {
                magnitude = magnitude * 10 + digit;
            }
            if magnitude > 100_000 {
                magnitude = 100_000;
            }
            index += 1;
        }
        exponent = if negative { -magnitude } else { magnitude };
    }
    let decimal_shift = exponent - fraction_digits as i64;
    let integer_digits: i64 = if decimal_shift >= 0 {
        digits.len() as i64 + decimal_shift
    } else {
        (digits.len() as i64 + decimal_shift).max(0)
    };
    let mut fractional = false;
    if decimal_shift < 0 && digits.len() as i64 > integer_digits {
        fractional = digits[integer_digits as usize..].iter().any(|d| *d != b'0');
    }
    if fractional && (dot.is_some() || exponent_mark.is_some()) {
        let mut meaningful = digits.clone();
        while meaningful.last() == Some(&b'0') {
            meaningful.pop();
        }
        if meaningful.len() > 15 {
            return false;
        }
    }
    if integer_digits < 16 {
        return true;
    }
    if integer_digits > 16 {
        return false;
    }
    let mut integer_part: Vec<u8> = if decimal_shift >= 0 {
        let mut part = digits.clone();
        part.extend(std::iter::repeat_n(b'0', decimal_shift as usize));
        part
    } else {
        digits[..digits.len().min(16)].to_vec()
    };
    if integer_part.len() > 16 {
        return false;
    }
    while integer_part.len() < 16 {
        integer_part.push(b'0');
    }
    const SAFE: &[u8] = b"9007199254740991";
    match integer_part.as_slice().cmp(SAFE) {
        std::cmp::Ordering::Greater => false,
        std::cmp::Ordering::Less => true,
        std::cmp::Ordering::Equal => {
            if decimal_shift < 0 && digits.len() > 16 {
                digits[16..].iter().all(|d| *d == b'0')
            } else {
                true
            }
        }
    }
}
