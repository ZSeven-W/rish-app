//! Session and revision fencing for the native inline text view.
//!
//! Rust advances `text_revision` only for deliberate draft replacements. Native
//! edits advance their independent `revision`; layout and acknowledgements must
//! never turn an IME update into another Rust text replacement.

use serde_json::{Value, json};
use std::collections::BTreeMap;
use uuid::Uuid;

const MAX_TEXT_BYTES: usize = 1024 * 1024;
pub(super) const MIN_CONTENT_HEIGHT: f32 = 80.;
pub(super) const MAX_CONTENT_HEIGHT: f32 = 168.;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct InputGeometry {
    pub rect: [f32; 4],
    pub viewport: [f32; 2],
    pub scale: f32,
}

impl InputGeometry {
    pub fn new(rect: [f32; 4], viewport: [f32; 2], scale: f32) -> Self {
        let viewport = viewport.map(nonnegative);
        let [x, y, width, height] = rect;
        let x = finite(x);
        let y = finite(y);
        let left = x.clamp(0., viewport[0]);
        let top = y.clamp(0., viewport[1]);
        let right = (f64::from(x) + f64::from(nonnegative(width)))
            .clamp(f64::from(left), f64::from(viewport[0])) as f32;
        let bottom = (f64::from(y) + f64::from(nonnegative(height)))
            .clamp(f64::from(top), f64::from(viewport[1])) as f32;
        Self {
            rect: [left, top, right - left, bottom - top],
            viewport,
            scale: if scale.is_finite() && scale > 0. {
                scale
            } else {
                1.
            },
        }
    }

    pub fn is_empty(&self) -> bool {
        self.rect[2] <= 0. || self.rect[3] <= 0.
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SnapshotStatus {
    Ready,
    Closed,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Snapshot {
    pub session_id: String,
    pub status: SnapshotStatus,
    pub revision: u64,
    pub applied_text_revision: u64,
    pub text: String,
    pub composing: bool,
    pub focused: bool,
    pub keyboard_bottom: f32,
    pub content_height: f32,
}

impl Snapshot {
    /// The error is deliberately static: a failed bridge response must not leak
    /// the user's draft into diagnostics.
    pub fn parse(value: &Value) -> Result<Self, &'static str> {
        const INVALID: &str = "E_INLINE_COMPOSER_INVALID";
        let object = value.as_object().ok_or(INVALID)?;
        let keys = [
            "session_id",
            "status",
            "revision",
            "applied_text_revision",
            "text",
            "composing",
            "focused",
            "keyboard_bottom",
            "content_height",
        ];
        if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
            return Err(INVALID);
        }
        let session_id = value["session_id"].as_str().ok_or(INVALID)?;
        Uuid::parse_str(session_id).map_err(|_| INVALID)?;
        let status = match value["status"].as_str() {
            Some("ready") => SnapshotStatus::Ready,
            Some("closed") => SnapshotStatus::Closed,
            _ => return Err(INVALID),
        };
        let revision = value["revision"].as_u64().ok_or(INVALID)?;
        let applied_text_revision = value["applied_text_revision"].as_u64().ok_or(INVALID)?;
        if applied_text_revision == 0 {
            return Err(INVALID);
        }
        let text = value["text"].as_str().ok_or(INVALID)?;
        if text.len() > MAX_TEXT_BYTES {
            return Err(INVALID);
        }
        let number = |key| -> Result<f32, &'static str> {
            let number = value[key].as_f64().ok_or(INVALID)?;
            if !number.is_finite() || number < 0. || number > f64::from(f32::MAX) {
                return Err(INVALID);
            }
            Ok(number as f32)
        };
        Ok(Self {
            session_id: session_id.to_owned(),
            status,
            revision,
            applied_text_revision,
            text: text.to_owned(),
            composing: value["composing"].as_bool().ok_or(INVALID)?,
            focused: value["focused"].as_bool().ok_or(INVALID)?,
            keyboard_bottom: number("keyboard_bottom")?,
            content_height: number("content_height")?.clamp(MIN_CONTENT_HEIGHT, MAX_CONTENT_HEIGHT),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SnapshotAcceptance {
    Applied,
    Unchanged,
    Closed,
    StaleSession,
    StaleRevision,
    StaleTextRevision,
    SessionClosed,
    InvalidSnapshot,
}

impl SnapshotAcceptance {
    pub fn is_accepted(self) -> bool {
        matches!(self, Self::Applied | Self::Unchanged | Self::Closed)
    }
}

#[derive(Debug)]
pub(super) struct InlineComposerState {
    conversation_key: Option<String>,
    session_id: Option<String>,
    text_revision: u64,
    allocated_text_revision: u64,
    reserved_text_revisions: BTreeMap<u64, u64>,
    native_revision: u64,
    received_snapshot: bool,
    text: String,
    composing: bool,
    focused: bool,
    keyboard_bottom: f32,
    reported_keyboard_bottom: f32,
    content_height: f32,
    viewport_height: f32,
    closed: bool,
}

impl Default for InlineComposerState {
    fn default() -> Self {
        Self {
            conversation_key: None,
            session_id: None,
            text_revision: 0,
            allocated_text_revision: 0,
            reserved_text_revisions: BTreeMap::new(),
            native_revision: 0,
            received_snapshot: false,
            text: String::new(),
            composing: false,
            focused: false,
            keyboard_bottom: 0.,
            reported_keyboard_bottom: 0.,
            content_height: MIN_CONTENT_HEIGHT,
            viewport_height: 0.,
            closed: false,
        }
    }
}

impl InlineComposerState {
    /// A key identifies an active conversation (or the unsaved new-chat draft).
    /// Calling this during another render of that conversation is a no-op.
    pub fn begin_session(&mut self, conversation_key: &str, text: &str) -> bool {
        if self.conversation_key.as_deref() == Some(conversation_key) && !self.closed {
            return false;
        }
        let viewport_height = self.viewport_height;
        *self = Self {
            conversation_key: Some(conversation_key.to_owned()),
            session_id: Some(Uuid::new_v4().to_string()),
            text_revision: 1,
            allocated_text_revision: 1,
            text: text.to_owned(),
            viewport_height,
            ..Self::default()
        };
        true
    }

    /// Persisting the first conversation gives the existing unsaved draft its
    /// identity; it does not replace its native editor or in-flight IME input.
    pub fn adopt_initial_conversation(&mut self, new_key: &str) -> bool {
        if self.current_conversation_key() != Some("new-draft")
            || self.session_id.is_none()
            || self.closed
            || new_key == "new-draft"
        {
            return false;
        }
        self.conversation_key = Some(new_key.to_owned());
        true
    }

    /// Use after reading the Rust composer entity, including presets/send-clear.
    /// First apply accepted native text to this state, then to the entity: the
    /// next observation will consequently leave `text_revision` unchanged.
    pub fn observe_external_text(&mut self, text: &str) -> bool {
        if self.session_id.is_none() || self.closed || self.text == text {
            return false;
        }
        // At u64::MAX fail closed instead of wrapping and accepting an old ACK.
        let Some(next_revision) = self.allocated_text_revision.checked_add(1) else {
            self.closed = true;
            self.focused = false;
            self.keyboard_bottom = 0.;
            self.reported_keyboard_bottom = 0.;
            return false;
        };
        self.text = text.to_owned();
        self.text_revision = next_revision;
        self.allocated_text_revision = next_revision;
        self.reserved_text_revisions.clear();
        self.composing = false;
        if text.is_empty() {
            self.content_height = MIN_CONTENT_HEIGHT;
        }
        true
    }

    /// Allocate a revision for a native conditional clear without authorizing
    /// its text yet. A subsequent Rust preset must receive a greater revision,
    /// even when the compare-and-clear ultimately refuses to clear native text.
    pub fn reserve_text_revision(&mut self) -> Option<u64> {
        if self.session_id.is_none() || self.closed {
            return None;
        }
        let reserved = self.allocated_text_revision.checked_add(1)?;
        self.allocated_text_revision = reserved;
        self.reserved_text_revisions
            .insert(reserved, self.text_revision);
        Some(reserved)
    }

    pub fn accept_reserved_clear(
        &mut self,
        snapshot: Snapshot,
        reserved: u64,
        previous: u64,
        cleared: bool,
    ) -> SnapshotAcceptance {
        if self.session_id.as_deref() != Some(&snapshot.session_id) {
            return SnapshotAcceptance::StaleSession;
        }
        if !cleared {
            self.reserved_text_revisions.remove(&reserved);
            return self.accept(snapshot);
        }
        if self.closed {
            return SnapshotAcceptance::SessionClosed;
        }
        if self.text_revision != previous
            || reserved <= previous
            || self.reserved_text_revisions.get(&reserved) != Some(&previous)
            || snapshot.applied_text_revision != reserved
        {
            return SnapshotAcceptance::StaleTextRevision;
        }
        // A successful native clear increments its revision even for an empty
        // draft. Validate before changing active text_revision so a bad ACK
        // cannot disable the fence protecting a newer Rust replacement.
        if snapshot.revision <= self.native_revision {
            return SnapshotAcceptance::StaleRevision;
        }
        if !snapshot.text.is_empty()
            || snapshot.composing
            || snapshot.status != SnapshotStatus::Ready
            || !snapshot.keyboard_bottom.is_finite()
            || snapshot.keyboard_bottom < 0.
            || !snapshot.content_height.is_finite()
            || snapshot.content_height < 0.
        {
            return SnapshotAcceptance::InvalidSnapshot;
        }
        self.text_revision = reserved;
        self.reserved_text_revisions.clear();
        self.accept(snapshot)
    }

    pub fn accept(&mut self, snapshot: Snapshot) -> SnapshotAcceptance {
        if self.session_id.as_deref() != Some(&snapshot.session_id) {
            return SnapshotAcceptance::StaleSession;
        }
        if snapshot.applied_text_revision != self.text_revision {
            return SnapshotAcceptance::StaleTextRevision;
        }
        if snapshot.revision < self.native_revision {
            return SnapshotAcceptance::StaleRevision;
        }
        if self.closed {
            return if snapshot.status == SnapshotStatus::Closed
                && snapshot.revision == self.native_revision
            {
                SnapshotAcceptance::Unchanged
            } else {
                SnapshotAcceptance::SessionClosed
            };
        }
        if self.received_snapshot && snapshot.revision == self.native_revision {
            // Closing an already hidden/unfocused editor may leave its text
            // revision unchanged. Still install the terminal session fence.
            if snapshot.status == SnapshotStatus::Closed {
                self.closed = true;
                self.composing = false;
                self.focused = false;
                self.keyboard_bottom = 0.;
                self.reported_keyboard_bottom = 0.;
                return SnapshotAcceptance::Closed;
            }
            // Heartbeats acknowledge liveness, but cannot rewrite the draft.
            return SnapshotAcceptance::Unchanged;
        }
        self.native_revision = snapshot.revision;
        self.received_snapshot = true;
        self.text = snapshot.text;
        self.closed = snapshot.status == SnapshotStatus::Closed;
        self.composing = snapshot.composing && !self.closed;
        self.focused = snapshot.focused && !self.closed;
        self.reported_keyboard_bottom = if self.focused {
            nonnegative(snapshot.keyboard_bottom)
        } else {
            0.
        };
        self.keyboard_bottom = self.reported_keyboard_bottom.min(self.viewport_height);
        self.content_height =
            nonnegative(snapshot.content_height).clamp(MIN_CONTENT_HEIGHT, MAX_CONTENT_HEIGHT);
        if self.closed {
            SnapshotAcceptance::Closed
        } else {
            SnapshotAcceptance::Applied
        }
    }

    pub fn set_viewport_height(&mut self, height: f32) {
        self.viewport_height = nonnegative(height);
        self.keyboard_bottom = self.reported_keyboard_bottom.min(self.viewport_height);
    }

    /// A native detach may close the matching session before a queued Rust
    /// replacement reaches it. Honor that terminal control signal separately
    /// from accepting its now-stale text snapshot.
    pub fn mark_closed(&mut self, session_id: &str) -> bool {
        if self.session_id.as_deref() != Some(session_id) {
            return false;
        }
        self.closed = true;
        self.composing = false;
        self.focused = false;
        self.keyboard_bottom = 0.;
        self.reported_keyboard_bottom = 0.;
        true
    }

    /// The native keyboard occlusion already includes the device bottom inset.
    pub fn bottom_inset(&self, safe_bottom: f32) -> f32 {
        nonnegative(safe_bottom)
            .min(self.viewport_height)
            .max(self.keyboard_bottom())
    }

    pub fn sync_payload(
        &self,
        geometry: InputGeometry,
        visible: bool,
        focus: Option<bool>,
        appearance: &str,
        placeholder: &str,
    ) -> Option<Value> {
        let session_id = self.session_id.as_ref()?;
        if self.closed || self.text.len() > MAX_TEXT_BYTES {
            return None;
        }
        // Re-normalize public geometry fields so every native request is valid.
        let geometry = InputGeometry::new(geometry.rect, geometry.viewport, geometry.scale);
        let visible = visible && !geometry.is_empty();
        Some(json!({
            "session_id": session_id,
            "text_revision": self.text_revision,
            "text": self.text,
            "rect": geometry.rect,
            "viewport": geometry.viewport,
            "scale": geometry.scale,
            "visible": visible,
            "focus": if visible { focus } else { Some(false) },
            "appearance": if appearance == "dark" { "dark" } else { "light" },
            "placeholder": placeholder,
        }))
    }

    pub fn current_conversation_key(&self) -> Option<&str> {
        self.conversation_key.as_deref()
    }
    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn text_revision(&self) -> u64 {
        self.text_revision
    }
    pub fn native_revision(&self) -> u64 {
        self.native_revision
    }
    pub fn composing(&self) -> bool {
        self.composing
    }
    pub fn focused(&self) -> bool {
        self.focused
    }
    pub fn keyboard_bottom(&self) -> f32 {
        self.keyboard_bottom
    }
    pub fn content_height(&self) -> f32 {
        self.content_height
    }
    pub fn is_closed(&self) -> bool {
        self.closed
    }
}

fn finite(value: f32) -> f32 {
    if value.is_finite() { value } else { 0. }
}
fn nonnegative(value: f32) -> f32 {
    finite(value).max(0.)
}

#[cfg(test)]
#[path = "inline_composer_state_tests.rs"]
mod tests;
