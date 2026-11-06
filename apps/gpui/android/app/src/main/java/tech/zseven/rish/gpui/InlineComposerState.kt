package tech.zseven.rish.gpui

import org.json.JSONObject

internal fun interface InlineComposerCancellation { fun cancel() }

internal fun interface InlineComposerScheduler {
    fun schedule(delayMs: Long, task: () -> Unit): InlineComposerCancellation
}

/** Main-thread confined. The scheduler must deliver its callback on the same thread. */
internal class InlineComposerState(
    val sessionId: String,
    private val scheduler: InlineComposerScheduler,
) {
    private var revision = 1L
    private var appliedTextRevision = 0L
    private var text = ""
    private var composing = false
    private var focused = false
    private var keyboardBottom = 0.0
    private var contentHeight = 80.0
    private var closed = false
    private var waiter: Waiter? = null

    /** True means native text replacement is explicit, including the first sync. */
    fun sync(request: InlineSyncRequest): Boolean {
        if (closed || request.sessionId != sessionId || request.textRevision < appliedTextRevision) {
            throw BridgeFailure("E_INLINE_COMPOSER_STALE")
        }
        if (request.textRevision == appliedTextRevision) return false
        val initial = appliedTextRevision == 0L
        text = request.text
        appliedTextRevision = request.textRevision
        composing = false
        if (!initial) changed()
        return true
    }

    /** Clear only the exact draft that was persisted; a failed compare is never a replacement. */
    fun clearIfUnchanged(expectedRevision: Long, textRevision: Long): Boolean {
        if (expectedRevision < 0 || textRevision <= 0) invalidInline()
        if (closed || appliedTextRevision == 0L || revision != expectedRevision || composing ||
            textRevision <= appliedTextRevision) return false
        text = ""
        appliedTextRevision = textRevision
        changed()
        return true
    }

    /** Preserve the native buffer and IME state; the view's input filter owns size enforcement. */
    fun observe(text: String, composing: Boolean, focused: Boolean,
                keyboardBottom: Double, contentHeight: Double) {
        if (closed) return
        if (!keyboardBottom.isFinite() || !contentHeight.isFinite() || keyboardBottom < 0) invalidInline()
        val occlusion = if (focused) keyboardBottom else 0.0
        val height = contentHeight.coerceIn(80.0, 168.0)
        if (this.text == text && this.composing == composing && this.focused == focused &&
            this.keyboardBottom == occlusion && this.contentHeight == height) return
        this.text = text
        this.composing = composing
        this.focused = focused
        this.keyboardBottom = occlusion
        this.contentHeight = height
        changed()
    }

    fun snapshot(): JSONObject = JSONObject()
        .put("session_id", sessionId)
        .put("status", if (closed) "closed" else "ready")
        .put("revision", revision)
        .put("applied_text_revision", appliedTextRevision)
        .put("text", text)
        .put("composing", composing)
        .put("focused", focused)
        .put("keyboard_bottom", keyboardBottom)
        .put("content_height", contentHeight)

    fun close(): JSONObject {
        if (!closed) {
            closed = true
            focused = false
            composing = false
            keyboardBottom = 0.0
            changed()
        }
        return snapshot()
    }

    /** A replacement settles the old request once, without leaving its timer attached. */
    fun wait(afterRevision: Long, completion: (JSONObject) -> Unit) {
        if (afterRevision < 0) invalidInline()
        val next = Waiter(completion)
        val previous = waiter
        waiter = next
        previous?.let(::finish)
        // A callback can synchronously close the state or install another waiter.
        if (waiter !== next || next.settled) return
        if (closed || revision > afterRevision) {
            finish(next)
            return
        }
        val cancellation = scheduler.schedule(HEARTBEAT_MS) {
            if (waiter === next && !next.settled) finish(next)
        }
        next.cancellation = cancellation
        if (next.settled) cancellation.cancel()
    }

    private fun changed() {
        check(revision < Long.MAX_VALUE) { "Inline revision exhausted" }
        revision += 1
        waiter?.let(::finish)
    }

    private fun finish(target: Waiter) {
        if (target.settled) return
        target.settled = true
        if (waiter === target) waiter = null
        target.cancellation?.cancel()
        target.cancellation = null
        target.completion(snapshot())
    }

    private class Waiter(val completion: (JSONObject) -> Unit) {
        var cancellation: InlineComposerCancellation? = null
        var settled = false
    }

    companion object { const val HEARTBEAT_MS = 10_000L }
}
