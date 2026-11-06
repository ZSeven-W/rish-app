package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class InlineComposerTest {
    private val session = "bca2a36a-1314-4c1f-838a-eb73636c620a"
    private val otherSession = "d5bf81d8-2295-4c7e-af86-ef449516340c"

    private fun request(revision: Long = 1, text: String = "你好\nDraft 🚀"): JSONObject = JSONObject()
        .put("session_id", session).put("text_revision", revision).put("text", text)
        .put("rect", JSONArray(listOf(24, 140, 352, 120)))
        .put("viewport", JSONArray(listOf(400, 860))).put("scale", 3)
        .put("visible", true).put("focus", JSONObject.NULL).put("appearance", "light")
        .put("placeholder", "向 Rish 发送消息")

    private fun args(value: JSONObject): JSONArray = JSONArray().put(value)
    private fun parsed(revision: Long = 1, text: String = "你好\nDraft 🚀") =
        InlineSyncRequest.parse(args(request(revision, text)))

    private fun invalid(block: () -> Unit) {
        val failure = assertThrows(BridgeFailure::class.java, block)
        assertEquals("E_INLINE_COMPOSER_INVALID", failure.code)
    }

    private fun state(clock: Clock = Clock()): InlineComposerState = InlineComposerState(session, clock).also {
        assertTrue(it.sync(parsed()))
    }

    @Test fun allFourMethodsRequireOneObjectWithExactKeys() {
        val sync = request()
        for (candidate in listOf(JSONArray(), JSONArray().put(sync).put(sync), JSONArray().put("string"))) {
            invalid { InlineSyncRequest.parse(candidate) }
        }
        invalid { InlineSyncRequest.parse(args(request().put("unexpected", 1))) }
        invalid { InlineSyncRequest.parse(args(request().also { it.remove("focus") })) }
        val wait = JSONObject().put("session_id", session).put("after_revision", 0)
        assertEquals(0L, InlineWaitRequest.parse(args(wait)).afterRevision)
        invalid { InlineWaitRequest.parse(args(JSONObject(wait.toString()).put("text", "private"))) }
        invalid { InlineWaitRequest.parse(JSONArray().put(wait).put(wait)) }
        val sessionRequest = JSONObject().put("session_id", session)
        assertEquals(session, InlineSessionRequest.parse(args(sessionRequest)).sessionId)
        invalid { InlineSessionRequest.parse(args(JSONObject(sessionRequest.toString()).put("after_revision", 0))) }
        invalid { InlineSessionRequest.parse(JSONArray()) }
    }

    @Test fun parserDoesNotCoerceBooleansNumbersOrStrings() {
        for ((key, values) in listOf(
            "visible" to listOf<Any>("true", 1, JSONObject.NULL),
            "focus" to listOf<Any>("false", 0),
            "text_revision" to listOf<Any>("1", 1.0, 0, -1, true, JSONObject.NULL),
            "text" to listOf<Any>(0, false, JSONObject.NULL),
            "appearance" to listOf<Any>("system", "Light", false),
            "scale" to listOf<Any>("3", 0, -1, 17),
            "placeholder" to listOf<Any>(false, JSONObject.NULL),
        )) {
            values.forEach { invalid { InlineSyncRequest.parse(args(request().put(key, it))) } }
        }
        for (value in listOf<Any>(-1, 0.0, "0", true)) {
            invalid { InlineWaitRequest.parse(args(JSONObject().put("session_id", session).put("after_revision", value))) }
        }
        for (value in listOf("1-1-1-1-1", "", "bca2a36a-1314-4c1f-838a-eb73636c620z")) {
            invalid { InlineSyncRequest.parse(args(request().put("session_id", value))) }
        }
    }

    @Test fun coordinatesAndScaleMustBeFiniteAndBounded() {
        for (value in listOf(
            JSONArray(listOf(0, 0, -1, 80)), JSONArray(listOf(0, 0, 10)),
            JSONArray(listOf(0, 0, "20", 80)), JSONArray(listOf(70_000, 0, 20, 80)),
        )) invalid { InlineSyncRequest.parse(args(request().put("rect", value))) }
        for (value in listOf(JSONArray(listOf(0, 100)), JSONArray(listOf(100, 20_000)), JSONArray(listOf(100)))) {
            invalid { InlineSyncRequest.parse(args(request().put("viewport", value))) }
        }
        invalid { InlineComposerProtocol.number(Double.NaN) }
        invalid { InlineComposerProtocol.number(Double.POSITIVE_INFINITY) }
        invalid { InlineComposerProtocol.number(Double.NEGATIVE_INFINITY) }
        val hidden = InlineSyncRequest.parse(args(request().put("visible", false)
            .put("rect", JSONArray(listOf(-30, -10, 0, 0)))))
        assertFalse(hidden.visible)
        assertEquals(0.0, hidden.rect[2], 0.0)
    }

    @Test fun byteLimitSupportsMultilineUnicodeWithoutNormalization() {
        val composed = "汉".repeat(349_525) + "a"
        assertEquals(InlineComposerProtocol.MAX_TEXT_BYTES, composed.toByteArray(Charsets.UTF_8).size)
        assertEquals(composed, InlineSyncRequest.parse(args(request(text = composed))).text)
        invalid { InlineSyncRequest.parse(args(request(text = composed + "a"))) }
        val plain = "a".repeat(InlineComposerProtocol.MAX_TEXT_BYTES)
        assertEquals(plain, InlineSyncRequest.parse(args(request(text = plain))).text)
        invalid { InlineSyncRequest.parse(args(request(text = plain + "a"))) }
        invalid { InlineSyncRequest.parse(args(request(text = "\uD83D"))) }
        invalid { InlineSyncRequest.parse(args(request(text = "\uDE80"))) }
        assertEquals("e\u0301\n🚀", InlineSyncRequest.parse(args(request(text = "e\u0301\n🚀"))).text)
    }

    @Test fun snapshotContainsOnlyContractFieldsAndNativeValues() {
        val snapshot = state().snapshot()
        assertEquals(setOf("session_id", "status", "revision", "applied_text_revision", "text",
            "composing", "focused", "keyboard_bottom", "content_height"), snapshot.keys().asSequence().toSet())
        assertEquals(session, snapshot.getString("session_id"))
        assertEquals("ready", snapshot.getString("status"))
        assertEquals(1L, snapshot.getLong("revision"))
        assertEquals(1L, snapshot.getLong("applied_text_revision"))
        assertEquals("你好\nDraft 🚀", snapshot.getString("text"))
        assertFalse(snapshot.getBoolean("composing"))
        assertFalse(snapshot.getBoolean("focused"))
        assertEquals(0.0, snapshot.getDouble("keyboard_bottom"), 0.0)
        assertEquals(80.0, snapshot.getDouble("content_height"), 0.0)
    }

    @Test fun equalRevisionGeometryAndStaleRustTextPreserveNativeComposition() {
        val state = state()
        state.observe("正在输入拼音", true, true, 280.0, 116.0)
        val before = state.snapshot().toString()
        assertFalse(state.sync(InlineSyncRequest.parse(args(request(text = "old Rust draft")
            .put("rect", JSONArray(listOf(30, 330, 700, 160))).put("focus", false).put("visible", false)))))
        assertEquals(before, state.snapshot().toString())
    }

    @Test fun explicitReplacementBumpsEvenWithSameTextAndOldRevisionCannotMutateState() {
        val state = state()
        assertTrue(state.sync(parsed(2)))
        assertEquals(2L, state.snapshot().getLong("revision"))
        assertEquals(2L, state.snapshot().getLong("applied_text_revision"))
        val before = state.snapshot().toString()
        val failure = assertThrows(BridgeFailure::class.java) { state.sync(parsed(1, "stale")) }
        assertEquals("E_INLINE_COMPOSER_STALE", failure.code)
        assertEquals(before, state.snapshot().toString())
        assertTrue(state.sync(parsed(3, "clear then preset")))
        assertEquals("clear then preset", state.snapshot().getString("text"))
    }

    @Test fun markedFocusKeyboardAndHeightChangesEachWakeOnlyForChangedSnapshot() {
        val clock = Clock()
        val state = state(clock)
        var replies = 0
        fun await() { state.wait(state.snapshot().getLong("revision")) { replies++ } }
        await()
        state.observe("你好\nDraft 🚀", false, false, 100.0, 10.0)
        assertEquals(0, replies) // Unfocused occlusion is zero, height clamps to 80.
        state.observe("你好\nDraft 🚀", true, true, 240.0, 110.0)
        assertEquals(1, replies)
        assertEquals(2L, state.snapshot().getLong("revision")) // One atomic native observation.
        await()
        state.observe("你好\nDraft 🚀", true, true, 240.0, 110.0)
        assertEquals(1, replies)
        state.observe("你好\nDraft 🚀", false, true, 240.0, 110.0)
        assertEquals(2, replies)
        await()
        state.observe("你好\nDraft 🚀", false, true, 280.0, 110.0)
        assertEquals(3, replies)
        await()
        state.observe("你好\nDraft 🚀", false, true, 280.0, 999.0)
        assertEquals(4, replies)
        assertEquals(168.0, state.snapshot().getDouble("content_height"), 0.0)
        await()
        state.observe("你好\nDraft 🚀", false, false, 280.0, 168.0)
        assertEquals(5, replies)
        assertEquals(0.0, state.snapshot().getDouble("keyboard_bottom"), 0.0)
    }

    @Test fun nativeMarkedBufferIsNeverTrimmedOrSilentlyReplaced() {
        val state = state()
        val nativeMarked = "汉".repeat(349_526)
        state.observe(nativeMarked, true, true, 0.0, 168.0)
        assertEquals(nativeMarked, state.snapshot().getString("text"))
        assertTrue(state.snapshot().getBoolean("composing"))
        invalid { state.observe("replace", false, true, Double.NaN, 100.0) }
        assertEquals(nativeMarked, state.snapshot().getString("text"))
    }

    @Test fun newerSnapshotReturnsImmediatelyWithoutSchedulingHeartbeat() {
        val clock = Clock()
        val state = state(clock)
        var response: JSONObject? = null
        state.wait(0) { response = it }
        assertEquals(1L, response!!.getLong("revision"))
        assertTrue(clock.jobs.isEmpty())
    }

    @Test fun unchangedWaitHeartbeatSettlesExactlyOnceAtTenSeconds() {
        val clock = Clock()
        val state = state(clock)
        val replies = mutableListOf<JSONObject>()
        state.wait(1) { replies.add(it) }
        clock.advance(9_999)
        assertTrue(replies.isEmpty())
        clock.advance(1)
        assertEquals(1, replies.size)
        assertEquals(1L, replies.single().getLong("revision"))
        clock.force(0) // Simulate an already queued callback after cancellation.
        assertEquals(1, replies.size)
    }

    @Test fun replacedWaiterAndExpiredOldHeartbeatCannotSettleNewWaiter() {
        val clock = Clock()
        val state = state(clock)
        var first = 0
        var second = 0
        state.wait(1) { first++ }
        clock.advance(2_000)
        state.wait(1) { second++ }
        assertEquals(1, first)
        assertEquals(0, second)
        assertTrue(clock.jobs[0].cancelled)
        clock.force(0)
        assertEquals(0, second)
        clock.advance(9_999)
        assertEquals(0, second)
        clock.advance(1)
        assertEquals(1, second)
        clock.force(0)
        clock.force(1)
        assertEquals(1, first)
        assertEquals(1, second)
    }

    @Test fun changeSettlesPendingWaitAndExplicitSameTextReplacementIsObservable() {
        val clock = Clock()
        val state = state(clock)
        val replies = mutableListOf<JSONObject>()
        state.wait(1) { replies.add(it) }
        state.sync(parsed(2))
        assertEquals(1, replies.size)
        assertEquals(2L, replies.single().getLong("applied_text_revision"))
        assertTrue(clock.jobs.single().cancelled)
        clock.force(0)
        assertEquals(1, replies.size)
    }

    @Test fun closingPreservesDraftSettlesPendingWaitAndDoesNotResurrect() {
        val clock = Clock()
        val state = state(clock)
        state.observe("未发送的中文", true, true, 300.0, 100.0)
        val replies = mutableListOf<JSONObject>()
        state.wait(2) { replies.add(it) }
        val closed = state.close()
        assertEquals("closed", closed.getString("status"))
        assertEquals("未发送的中文", closed.getString("text"))
        assertFalse(closed.getBoolean("focused"))
        assertFalse(closed.getBoolean("composing"))
        assertEquals(0.0, closed.getDouble("keyboard_bottom"), 0.0)
        assertEquals(1, replies.size)
        state.observe("late text", false, true, 100.0, 120.0)
        state.close()
        clock.force(0)
        assertEquals(closed.toString(), state.snapshot().toString())
        assertEquals(1, replies.size)
        state.wait(100) { replies.add(it) }
        assertEquals(2, replies.size)
        assertEquals("closed", replies.last().getString("status"))
    }

    @Test fun sessionReplacementAndOldCloseCannotAffectNewStateOrWaiter() {
        val clock = Clock()
        val old = state(clock)
        var oldClosed = false
        old.wait(1) { oldClosed = it.getString("status") == "closed" }
        old.close()
        val fresh = InlineComposerState(otherSession, clock)
        assertTrue(fresh.sync(InlineSyncRequest.parse(args(request(text = "另一会话").put("session_id", otherSession)))))
        var newReplies = 0
        fresh.wait(1) { newReplies++ }
        old.close()
        clock.force(0)
        assertTrue(oldClosed)
        assertEquals(0, newReplies)
        assertEquals("ready", fresh.snapshot().getString("status"))
        assertEquals("另一会话", fresh.snapshot().getString("text"))
        val failure = assertThrows(BridgeFailure::class.java) { fresh.sync(parsed(2)) }
        assertEquals("E_INLINE_COMPOSER_STALE", failure.code)
        assertEquals("另一会话", fresh.snapshot().getString("text"))
    }

    @Test fun reentrantReplacementDoesNotLeakAnIntermediateWaiter() {
        val clock = Clock()
        val state = state(clock)
        var first = 0
        var second = 0
        var third = 0
        state.wait(1) {
            first++
            state.wait(1) { third++ }
        }
        state.wait(1) { second++ }
        assertEquals(1, first)
        assertEquals(1, second)
        assertEquals(0, third)
        clock.advance(10_000)
        assertEquals(1, third)
        assertEquals(1, second)
    }

    @Test fun clearRequestRequiresExactKeysAndNonCoercingRevisionTypes() {
        fun clear() = JSONObject().put("session_id", session).put("expected_revision", 0).put("text_revision", 2)
        assertEquals(InlineClearRequest(session, 0, 2), InlineClearRequest.parse(args(clear())))
        invalid { InlineClearRequest.parse(JSONArray()) }
        invalid { InlineClearRequest.parse(JSONArray().put(clear()).put(clear())) }
        invalid { InlineClearRequest.parse(args(clear().put("text", ""))) }
        invalid { InlineClearRequest.parse(args(clear().also { it.remove("expected_revision") })) }
        invalid { InlineClearRequest.parse(args(clear().put("session_id", "invalid"))) }
        for (value in listOf<Any>(-1, 0.0, "0", false, JSONObject.NULL)) {
            invalid { InlineClearRequest.parse(args(clear().put("expected_revision", value))) }
        }
        for (value in listOf<Any>(-1, 0, 2.0, "2", true, JSONObject.NULL)) {
            invalid { InlineClearRequest.parse(args(clear().put("text_revision", value))) }
        }
    }

    @Test fun clearOfPersistedDraftUpdatesRevisionsAndSettlesWaiterOnce() {
        val clock = Clock()
        val state = state(clock)
        state.observe("已持久化消息", false, true, 250.0, 110.0)
        val expected = state.snapshot().getLong("revision")
        val replies = mutableListOf<JSONObject>()
        state.wait(expected) { replies.add(it) }
        assertTrue(state.clearIfUnchanged(expected, 2))
        val snapshot = state.snapshot()
        assertEquals("", snapshot.getString("text"))
        assertEquals(expected + 1, snapshot.getLong("revision"))
        assertEquals(2L, snapshot.getLong("applied_text_revision"))
        assertTrue(snapshot.getBoolean("focused"))
        assertEquals(250.0, snapshot.getDouble("keyboard_bottom"), 0.0)
        assertEquals(1, replies.size)
        assertEquals("", replies.single().getString("text"))
        assertTrue(clock.jobs.single().cancelled)
        clock.force(0)
        assertEquals(1, replies.size)
        assertFalse(state.clearIfUnchanged(expected, 3)) // Duplicate completion cannot clear another draft.
        assertEquals(snapshot.toString(), state.snapshot().toString())
    }

    @Test fun keystrokeAfterSendSnapshotWinsAgainstDelayedClear() {
        val clock = Clock()
        val state = state(clock)
        val sentRevision = state.snapshot().getLong("revision")
        state.observe("你好\nDraft 🚀 继续输入", false, true, 280.0, 100.0)
        val beforeClear = state.snapshot().toString()
        var replies = 0
        state.wait(state.snapshot().getLong("revision")) { replies++ }
        assertFalse(state.clearIfUnchanged(sentRevision, 2))
        assertEquals(beforeClear, state.snapshot().toString())
        assertEquals(0, replies)
        clock.advance(10_000)
        assertEquals(1, replies)
        assertEquals(beforeClear, state.snapshot().toString())
    }

    @Test fun matchingRevisionDoesNotClearMarkedCandidate() {
        val state = state()
        state.observe("正在选字", true, true, 260.0, 90.0)
        val revision = state.snapshot().getLong("revision")
        val beforeClear = state.snapshot().toString()
        assertFalse(state.clearIfUnchanged(revision, 2))
        assertEquals(beforeClear, state.snapshot().toString())
        state.observe("正在选字", false, true, 260.0, 90.0)
        assertFalse(state.clearIfUnchanged(revision, 2)) // Committing the candidate also advances native revision.
        assertEquals("正在选字", state.snapshot().getString("text"))
    }

    @Test fun newerRustReplacementCannotBeClearedByOlderOrEqualTextRevision() {
        val state = state()
        state.sync(parsed(4, "新预设"))
        val revision = state.snapshot().getLong("revision")
        val beforeClear = state.snapshot().toString()
        assertFalse(state.clearIfUnchanged(revision, 2))
        assertFalse(state.clearIfUnchanged(revision, 4))
        assertEquals(beforeClear, state.snapshot().toString())
        assertTrue(state.clearIfUnchanged(revision, 5))
        assertEquals(5L, state.snapshot().getLong("applied_text_revision"))
        assertEquals("", state.snapshot().getString("text"))
    }

    @Test fun closedOrUninitializedStateCannotBeClearedOrReopened() {
        val state = state()
        val closed = state.close()
        assertFalse(state.clearIfUnchanged(closed.getLong("revision"), 2))
        assertEquals(closed.toString(), state.snapshot().toString())
        val uninitialized = InlineComposerState(otherSession, Clock())
        assertFalse(uninitialized.clearIfUnchanged(1, 1))
        invalid { state.clearIfUnchanged(-1, 2) }
        invalid { state.clearIfUnchanged(1, 0) }
    }

    private class Clock : InlineComposerScheduler {
        data class Job(val due: Long, val task: () -> Unit, var cancelled: Boolean = false)
        var now = 0L
        val jobs = mutableListOf<Job>()
        override fun schedule(delayMs: Long, task: () -> Unit): InlineComposerCancellation {
            val job = Job(now + delayMs, task)
            jobs += job
            return InlineComposerCancellation { job.cancelled = true }
        }
        fun advance(ms: Long) {
            now += ms
            jobs.toList().filter { !it.cancelled && it.due <= now }.forEach {
                it.cancelled = true
                it.task()
            }
        }
        fun force(index: Int) { jobs[index].task() }
    }
}
