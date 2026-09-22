package tech.zseven.rish

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RuntimeFailure

/**
 * A request this transport cannot carry is refused before anything is sent.
 *
 * A beta tester attached an image to a turn in a workspace and was shown
 * `E_AGENT_EXECUTION_AMBIGUOUS` with only retries that could not succeed. The
 * transport had refused the request while building it -- Android puts no
 * attachment content in front of a model on either path -- but the round had
 * already been marked dispatched, so the core reconciled a turn that provably
 * never left the device as one that might have happened.
 *
 * The refusal itself is right and stays. What these cover is that it is
 * raised by `validate`, with no request sent and no slot left behind, so the
 * round service can learn it while the round is still `not_dispatched`.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidTransportAttachmentTest {

    private fun transport(): AndroidModelTransport = AndroidRuntimeState
        .get(ApplicationProvider.getApplicationContext<Application>()).transport

    private fun message(text: String, attachments: JSONArray): JSONObject = JSONObject()
        .put("role", "user").put("content", text).put("attachments", attachments)

    private fun attachment(): JSONObject = JSONObject()
        .put("schema_version", 1)
        .put("id", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        .put("kind", "image").put("name", "probe.png")
        .put("mime_type", "image/png").put("size", 7853)

    private fun envelope(history: JSONArray, roundId: String): String = JSONObject()
        .put("schema_version", 2)
        .put("harness_id", "dsh")
        .put("model", "deepseek-v4-flash")
        .put("round_id", roundId)
        .put("turn_id", "77777777-7777-4777-8777-777777777777")
        .put("attempt_id", "44444444-4444-4444-8444-444444444444")
        .put("round_index", 0)
        .put("thinking_mode", "off")
        .put("visible_history", history)
        .put("round_transcript", JSONArray())
        .put("project_context", JSONObject.NULL)
        .put("tools", JSONArray())
        .toString()

    private fun codeOf(body: () -> Unit): String = try {
        body()
        "no refusal"
    } catch (failure: RuntimeFailure) {
        failure.code
    }

    /**
     * The whole point: the refusal is available without sending anything, so
     * a caller can act on it before it has committed to having dispatched.
     */
    @Test
    fun anAttachmentBearingHistoryIsRefusedWithoutSendingARequest() {
        val transport = transport()
        val before = transport.sentRequestCount
        val history = JSONArray().put(message("analyse this", JSONArray().put(attachment())))
        val prepared = transport.prepare(envelope(history, "55555555-5555-4555-8555-555555555555"))
        assertEquals(
            "E_COMPLETION_CONTEXT_UNSUPPORTED",
            codeOf { transport.validate(prepared) },
        )
        assertEquals("no request may be sent", before, transport.sentRequestCount)
    }

    /**
     * A prepared request holds a slot that only a run gives back. Without the
     * release, one refused attachment would leave the next round refused as
     * busy over a request nobody ever sent -- a worse trap than the one this
     * fixes.
     */
    @Test
    fun aRefusedPreparationGivesItsSlotBack() {
        val transport = transport()
        val id = "55555555-5555-4555-8555-555555555556"
        val history = JSONArray().put(message("analyse this", JSONArray().put(attachment())))
        val first = transport.prepare(envelope(history, id))
        codeOf { transport.validate(first) }
        // The same id prepares again, which `prepare` refuses as
        // E_COMPLETION_BUSY while a request of that id is still active.
        val second = transport.prepare(envelope(JSONArray().put(message("hello", JSONArray())), id))
        assertEquals("no refusal", codeOf { transport.validate(second) })
        transport.discard(second)
        assertEquals(0, transport.activeRequestCount())
    }

    /** A history with no attachment is not refused, so the gate is the attachment. */
    @Test
    fun aPlainHistoryPassesValidation() {
        val transport = transport()
        val history = JSONArray().put(message("hello", JSONArray()))
        val prepared = transport.prepare(
            envelope(history, "55555555-5555-4555-8555-555555555557"),
        )
        assertEquals("no refusal", codeOf { transport.validate(prepared) })
        transport.discard(prepared)
    }

    /**
     * An assistant turn carrying an attachment is refused the same way. The
     * history is projected from the conversation, so a reply that somehow
     * carried one must not slip past a check written only for user turns.
     */
    @Test
    fun anAssistantAttachmentIsRefusedToo() {
        val transport = transport()
        val history = JSONArray()
            .put(message("hi", JSONArray()))
            .put(
                JSONObject().put("role", "assistant").put("content", "here")
                    .put("attachments", JSONArray().put(attachment())),
            )
        val prepared = transport.prepare(
            envelope(history, "55555555-5555-4555-8555-555555555558"),
        )
        assertEquals(
            "E_COMPLETION_CONTEXT_UNSUPPORTED",
            codeOf { transport.validate(prepared) },
        )
        if (transport.activeRequestCount() != 0) fail("the refused request kept its slot")
    }
}
