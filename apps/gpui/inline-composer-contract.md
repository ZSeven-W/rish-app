# Inline composer native contract

The native host embeds a UITextView/EditText only over the GPUI composer text
rectangle. It never presents a controller/dialog. UIKit/Android own selection,
multiline editing and IME marked text. GPUI owns the surrounding card and footer.

All methods are in `ShellInput`, with one JSON object argument.

## inlineSync

Exact keys: `session_id` (UUID), `text_revision` (positive integer), `text`
(UTF-8 string, at most 1 MiB), `rect` ([x,y,width,height] logical window pixels),
`viewport` ([width,height] logical window pixels), `scale` (positive number),
`visible` (bool), `focus` (null or bool: null leaves focus alone),
`appearance` (light/dark), `placeholder` (string).

Create/replace the one inline editor for a new session. Set its text only for a
new session or a strictly newer text_revision; layout-only syncs must not reset
text, selection or composition. An equal text revision with different text is
not a replacement. Explicit newer replacements may replace the draft, but only
when requested by Rust (preset, send-clear, or a deliberate conversation change).
Geometry is already safe-area adjusted; never add safe insets again. iOS uses
points; Android maps logical coordinates to its actual SurfaceView origin and
scale, keeping touches outside the text rect in GPUI.

Return the snapshot below after applying the request. Hiding resigns and
preserves the current text; do not erase the editor's draft. The view must be
hidden while a GPUI drawer/model sheet/workspace modal, Settings, focused full
workspace, or other native form covers the composer.

## inlineWait / inlineSnapshot / inlineClose

- inlineWait: `{session_id, after_revision}`. Return immediately for a newer
  snapshot, otherwise keep exactly one waiter until change/close, with a 10 s
  heartbeat returning the unchanged snapshot. Settle replaced waiters once.
- inlineSnapshot: `{session_id}`. Return current text and marked state without
  forcing unmark/commit. Send and conversation switches must flush through this.
- inlineClose: `{session_id}`. Resign/remove only that matching editor, settle
  its waiter, and return its final closed snapshot. A stale close must never
  remove or reveal a newer session's editor.

## inlineClearIfUnchanged

Argument: `{session_id, expected_revision, text_revision}`. Return
`{cleared: bool, snapshot: Snapshot}`. On the native UI thread atomically compare
the current native revision to expected_revision and require !composing. Only
on a match replace text with the empty string, apply the strictly newer external
text_revision, increment native revision and settle the waiter. Otherwise leave
all text/composition/selection and applied_text_revision intact. This method is
used only after a successfully persisted send; a concurrent keystroke must never
be erased by a later Rust clear. Do not turn a failed compare into a retry.

Snapshot exact fields: `session_id`, `status` (ready/closed), `revision`
(monotonic native change counter), `applied_text_revision`, `text`, `composing`
(bool), `focused` (bool), `keyboard_bottom` (nonnegative logical pixels),
`content_height` (logical pixels, clamped 80..168).

Boolean fields must serialize as JSON `true`/`false`, never numeric `0`/`1`.
On iOS, box logical expressions explicitly as `@YES`/`@NO`; C expression
boxing can otherwise produce integers that the Rust parser correctly rejects.

Text, marked state, focus, keyboard occlusion and preferred height changes bump
native revision and settle the waiter. Geometry-only changes do not create an
endless callback/render loop. Observe keyboard frame changes, not just show/hide;
report bottom occlusion in the GPUI viewport only while this editor is focused.
Floating keyboards must not subtract their full height. On Android account for
an already resized SurfaceView; do not avoid the IME twice. Rust takes max of the
existing safe bottom and reported keyboard_bottom, not their sum.

Errors: E_INLINE_COMPOSER_INVALID, E_INLINE_COMPOSER_STALE,
E_INLINE_COMPOSER_UNAVAILABLE. Never log complete text payloads. Background,
detach, disposal and session replacement must settle outstanding waiters.

Rust keeps one outstanding sync and one wait, coalesces geometry changes, and
checks session_id, native revision and applied_text_revision before applying
snapshots. Old snapshots cannot overwrite an explicit newer Rust replacement or
another conversation. Before send/create/select/bind, read a fresh snapshot;
marked text blocks sending until the user confirms the input method candidate.
Return inserts a newline, never sends. Preserve existing draft-switch guards.
