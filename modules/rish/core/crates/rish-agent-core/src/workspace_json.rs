//! Whether stored workspace bytes are JSON this engine will look at.
//!
//! Ported from `DSHJSONHasBoundedExactStructure` and its scanner in
//! `LocalWorkspaceAccess.mm`. It runs before the parse, on the raw bytes of a
//! file that may be corrupt or hand-edited, and it is the reason a bad
//! registry costs a refusal rather than an unbounded walk.
//!
//! **The core already has two scanners of this shape, and this is a third.**
//! `strict_json` (tool arguments) and `session_schema::scanner` (the session
//! snapshot) look almost identical, and they are not interchangeable:
//!
//! | | top level | nodes | `0x7f` in a string |
//! | --- | --- | --- | --- |
//! | `strict_json` | object | 30,000 | refused |
//! | `session_schema::scanner` | object | 250,000 | refused |
//! | here | any value | 100,000 | **accepted** |
//!
//! The third column is the one that matters. Reusing either of the others
//! would refuse a stored registry the current engine accepts — unlikely to
//! exist, because Foundation escapes control characters when it writes and
//! every string position is refused downstream anyway, but *unlikely* is not
//! *verified*, and this is the acceptance rule for data already on people's
//! devices. So the rule is ported as it is. Unifying the three is a decision
//! someone should take knowingly, not one that arrives by reuse.

/// `depth > 64` is refused, matching the ObjC scanner and `canonical::MAX_DEPTH`.
pub const MAX_DEPTH: usize = 64;

/// At most this many values, so a corrupt file cannot make a launch walk an
/// unbounded structure.
pub const MAX_NODES: usize = 100_000;

struct Scanner<'a> {
    bytes: &'a [u8],
    index: usize,
    nodes: usize,
}

impl Scanner<'_> {
    fn skip_whitespace(&mut self) {
        while let Some(&byte) = self.bytes.get(self.index) {
            if !matches!(byte, b' ' | b'\t' | b'\r' | b'\n') {
                break;
            }
            self.index += 1;
        }
    }

    /// Returns the decoded key, so an object can refuse two spellings of one
    /// key — `"a"` and `"a"` are the same key and the second is not a
    /// second field.
    fn scan_string(&mut self) -> Option<String> {
        if self.bytes.get(self.index) != Some(&b'"') {
            return None;
        }
        let start = self.index;
        self.index += 1;
        let mut escaped = false;
        while let Some(&byte) = self.bytes.get(self.index) {
            if !escaped && byte == b'"' {
                self.index += 1;
                let token = std::str::from_utf8(&self.bytes[start..self.index]).ok()?;
                return serde_json::from_str::<String>(token).ok();
            }
            // Raw control bytes below 0x20 are not legal in a JSON string.
            // 0x7f is, and is accepted here; see the module note.
            if !escaped && byte < 0x20 {
                return None;
            }
            escaped = !escaped && byte == b'\\';
            self.index += 1;
        }
        None
    }

    fn scan_object(&mut self, depth: usize) -> bool {
        self.index += 1;
        self.skip_whitespace();
        if self.bytes.get(self.index) == Some(&b'}') {
            self.index += 1;
            return true;
        }
        let mut keys = std::collections::HashSet::new();
        while self.index < self.bytes.len() {
            let Some(key) = self.scan_string() else {
                return false;
            };
            if !keys.insert(key) {
                return false;
            }
            self.skip_whitespace();
            if self.bytes.get(self.index) != Some(&b':') {
                return false;
            }
            self.index += 1;
            if !self.scan_value(depth + 1) {
                return false;
            }
            self.skip_whitespace();
            if self.bytes.get(self.index) == Some(&b'}') {
                self.index += 1;
                return true;
            }
            if self.bytes.get(self.index) != Some(&b',') {
                return false;
            }
            self.index += 1;
            self.skip_whitespace();
        }
        false
    }

    fn scan_array(&mut self, depth: usize) -> bool {
        self.index += 1;
        self.skip_whitespace();
        if self.bytes.get(self.index) == Some(&b']') {
            self.index += 1;
            return true;
        }
        while self.index < self.bytes.len() {
            if !self.scan_value(depth + 1) {
                return false;
            }
            self.skip_whitespace();
            if self.bytes.get(self.index) == Some(&b']') {
                self.index += 1;
                return true;
            }
            if self.bytes.get(self.index) != Some(&b',') {
                return false;
            }
            self.index += 1;
            self.skip_whitespace();
        }
        false
    }

    fn scan_scalar(&mut self) -> bool {
        let start = self.index;
        while let Some(&byte) = self.bytes.get(self.index) {
            if matches!(byte, b',' | b']' | b'}' | b' ' | b'\t' | b'\r' | b'\n') {
                break;
            }
            self.index += 1;
        }
        if self.index == start {
            return false;
        }
        let token = &self.bytes[start..self.index];
        let Ok(text) = std::str::from_utf8(token) else {
            return false;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
            return false;
        };
        // Negative zero is refused: Foundation folds it into +0, so the bytes
        // and the value they decode to would disagree, and a digest taken over
        // one would not describe the other.
        if token[0] == b'-' && value.as_f64() == Some(0.0) {
            return false;
        }
        matches!(
            value,
            serde_json::Value::Number(_) | serde_json::Value::Null | serde_json::Value::Bool(_)
        )
    }

    fn scan_value(&mut self, depth: usize) -> bool {
        if depth > MAX_DEPTH || self.nodes >= MAX_NODES {
            return false;
        }
        self.nodes += 1;
        self.skip_whitespace();
        let Some(&byte) = self.bytes.get(self.index) else {
            return false;
        };
        match byte {
            b'{' => self.scan_object(depth),
            b'[' => self.scan_array(depth),
            b'"' => self.scan_string().is_some(),
            _ => self.scan_scalar(),
        }
    }
}

/// `DSHJSONHasBoundedExactStructure`: one complete value, within the bounds,
/// with no duplicate keys, no negative zero, and nothing after it.
pub fn bounded_exact_structure(bytes: &[u8]) -> bool {
    if bytes.is_empty() {
        return false;
    }
    let mut scanner = Scanner {
        bytes,
        index: 0,
        nodes: 0,
    };
    if !scanner.scan_value(1) {
        return false;
    }
    scanner.skip_whitespace();
    // Trailing bytes mean the file is two things, and the second was never
    // asked about.
    scanner.index == bytes.len()
}

#[cfg(test)]
#[path = "workspace_json_tests.rs"]
mod tests;
