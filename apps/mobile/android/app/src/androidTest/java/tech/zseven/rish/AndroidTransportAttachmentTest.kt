package tech.zseven.rish

import android.app.Application
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAttachmentStore
import tech.zseven.rish.runtime.AndroidCredentialStore
import tech.zseven.rish.runtime.AndroidDshModelCatalog
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.RuntimeFailure
import java.io.File
import java.util.UUID

/**
 * What an attachment becomes on the way to a model, and what is refused.
 *
 * A beta tester attached an image to a turn in a workspace and was shown
 * `E_AGENT_EXECUTION_AMBIGUOUS`: the transport refused every attachment, and
 * because the round had already been marked dispatched, a request that never
 * left the device was reconciled as one that might have happened. The refusal
 * is gone for the kinds this platform can carry; what stays is that anything
 * it cannot carry fails **before** a byte is sent.
 *
 * The bytes are the point. A test that only checked a part was present would
 * pass over an empty one, which is the failure mode two of the three dialects
 * already had.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidTransportAttachmentTest {

    private val context = ApplicationProvider.getApplicationContext<Application>()
    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    private fun home(): File =
        File(context.cacheDir, "attachment-content-${UUID.randomUUID()}").also { it.mkdirs() }

    private fun transport(home: File): AndroidModelTransport {
        AndroidDshModelCatalog.initialize(context)
        val namespace = "attachment-${UUID.randomUUID()}"
        return AndroidModelTransport(
            AndroidCredentialStore(context, namespace),
            AndroidProviderConfiguration(context, "$namespace.providers"),
            AndroidAttachmentStore(home),
        )
    }

    /**
     * An attachment as the store holds one: the bytes, and the sidecar that
     * says what they are. Written directly because the picker needs an
     * activity and a document URI, and neither is what is under test.
     */
    private fun stage(
        home: File,
        kind: String,
        mime: String,
        name: String,
        bytes: ByteArray,
    ): JSONObject {
        val id = UUID.randomUUID().toString()
        val root = File(home, "attachments").also { it.mkdirs() }
        File(root, id).writeBytes(bytes)
        val descriptor = JSONObject().put("schema_version", 1).put("id", id)
            .put("kind", kind).put("name", name).put("mime_type", mime)
            .put("size", bytes.size.toLong())
        File(root, "$id.json").writeText(descriptor.toString())
        return JSONObject().put("schema_version", 1).put("id", id).put("kind", kind)
            .put("name", name).put("mime_type", mime).put("size", bytes.size.toLong())
    }

    private fun message(text: String, attachments: JSONArray): JSONObject = JSONObject()
        .put("role", "user").put("content", text).put("attachments", attachments)

    private fun envelope(history: JSONArray, model: String): String = JSONObject()
        .put("schema_version", 2)
        .put("harness_id", "dsh")
        .put("model", model)
        .put("round_id", UUID.randomUUID().toString())
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

    /** The one that matters: the real bytes reach the request body. */
    @Test
    fun anImageReachesTheRequestAsItsOwnBytes() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "image", "image/png", "probe.png", png)
        val history = JSONArray().put(message("what is this", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        transport.validate(prepared)

        val messages = transport.composedForTest(prepared)
        val content = messages.getJSONObject(0).getJSONArray("content")
        assertEquals(2, content.length())
        assertEquals("text", content.getJSONObject(0).getString("type"))
        assertEquals("what is this", content.getJSONObject(0).getString("text"))
        val picture = content.getJSONObject(1)
        assertEquals("image", picture.getString("type"))
        assertEquals("image/png", picture.getString("mime_type"))
        assertEquals(
            Base64.encodeToString(png, Base64.NO_WRAP),
            picture.getString("data"),
        )
        transport.discard(prepared)
    }

    /**
     * And the dialect spells it, so the body a provider would receive really
     * carries the picture rather than an empty block.
     */
    @Test
    fun theChatBodyCarriesTheDataUrl() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "image", "image/png", "probe.png", png)
        val history = JSONArray().put(message("what is this", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        transport.validate(prepared)
        val body = transport.requestBody(
            "chat-completions", "deepseek-v4-flash", "off", false, false,
            transport.composedForTest(prepared), JSONArray(),
        )
        val content = body.getJSONArray("messages").getJSONObject(0).getJSONArray("content")
        val url = content.getJSONObject(1).getJSONObject("image_url").getString("url")
        assertEquals(
            "data:image/png;base64,${Base64.encodeToString(png, Base64.NO_WRAP)}",
            url,
        )
        transport.discard(prepared)
    }

    /** Text is folded into the words, named, so the model can quote it. */
    @Test
    fun aTextAttachmentBecomesFencedWordsInTheSameTurn() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "text", "text/plain", "notes.txt", "hello file".toByteArray())
        val history = JSONArray().put(message("summarise", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-pro"))
        transport.validate(prepared)
        val content = transport.composedForTest(prepared).getJSONObject(0).getString("content")
        assertTrue(content, content.startsWith("summarise\n\n"))
        assertTrue(content, content.contains("BEGIN TEXT: notes.txt"))
        assertTrue(content, content.contains("hello file"))
        transport.discard(prepared)
    }

    /**
     * A model with no eyes is told about, not shown. V4 Pro takes no images
     * in the shipped catalog, so this is the person's own configuration
     * refusing rather than a provider answering nonsense.
     */
    @Test
    fun anImageIsRefusedForAModelThatCannotSeeOne() {
        val home = home()
        val transport = transport(home)
        val before = transport.sentRequestCount
        val reference = stage(home, "image", "image/png", "probe.png", png)
        val history = JSONArray().put(message("what is this", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-pro"))
        assertEquals(
            "E_COMPLETION_CONTEXT_UNSUPPORTED",
            codeOf { transport.validate(prepared) },
        )
        assertEquals("no request may be sent", before, transport.sentRequestCount)
        assertEquals(0, transport.activeRequestCount())
    }

    /** A PDF has no projection here, so it is refused rather than dropped. */
    @Test
    fun aPdfIsRefusedBecauseNothingHereCanReadOne() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "pdf", "application/pdf", "contract.pdf", png)
        val history = JSONArray().put(message("summarise", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        assertEquals(
            "E_COMPLETION_CONTEXT_UNSUPPORTED",
            codeOf { transport.validate(prepared) },
        )
        assertEquals(0, transport.activeRequestCount())
    }

    /**
     * The reference travelled through JavaScript and a session file; the
     * descriptor is what the store actually holds. If they disagree, the
     * model would be shown something other than what the transcript says.
     */
    @Test
    fun aReferenceThatDoesNotMatchTheStoredBytesIsRefused() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "image", "image/png", "probe.png", png)
        reference.put("size", png.size.toLong() + 1)
        val history = JSONArray().put(message("what is this", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        assertEquals(
            "E_COMPLETION_CONTEXT_INVALID",
            codeOf { transport.validate(prepared) },
        )
    }

    /** An attachment the store no longer holds fails rather than vanishing. */
    @Test
    fun anAttachmentThatIsGoneFailsTheRequest() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "image", "image/png", "probe.png", png)
        File(File(home, "attachments"), reference.getString("id")).delete()
        val history = JSONArray().put(message("what is this", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        assertEquals(
            "E_COMPLETION_CONTEXT_INVALID",
            codeOf { transport.validate(prepared) },
        )
    }

    /**
     * A turn with nothing attached stays a plain string. Every frozen request
     * body records that shape, so this is what keeps them from moving.
     */
    @Test
    fun aTurnWithNoAttachmentKeepsPlainWords() {
        val home = home()
        val transport = transport(home)
        val history = JSONArray().put(message("hello", JSONArray()))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        transport.validate(prepared)
        assertEquals(
            "hello",
            transport.composedForTest(prepared).getJSONObject(0).getString("content"),
        )
        transport.discard(prepared)
    }

    /** An assistant turn carrying one is a transcript nothing here wrote. */
    @Test
    fun anAssistantAttachmentIsRefused() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "image", "image/png", "probe.png", png)
        val history = JSONArray()
            .put(message("hi", JSONArray()))
            .put(
                JSONObject().put("role", "assistant").put("content", "here")
                    .put("attachments", JSONArray().put(reference)),
            )
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        assertEquals(
            "E_COMPLETION_CONTEXT_UNSUPPORTED",
            codeOf { transport.validate(prepared) },
        )
    }

    /**
     * A prepared request holds a slot that only a run gives back. Without the
     * release, one refused attachment would leave the next round refused as
     * busy over a request nobody ever sent.
     */
    @Test
    fun aRefusedPreparationGivesItsSlotBack() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "pdf", "application/pdf", "contract.pdf", png)
        val first = transport.prepare(
            envelope(JSONArray().put(message("x", JSONArray().put(reference))), "deepseek-v4-flash"),
        )
        codeOf { transport.validate(first) }
        assertEquals(0, transport.activeRequestCount())
        val second = transport.prepare(
            envelope(JSONArray().put(message("hello", JSONArray())), "deepseek-v4-flash"),
        )
        assertEquals("no refusal", codeOf { transport.validate(second) })
        transport.discard(second)
        assertEquals(0, transport.activeRequestCount())
    }

    /** Keeps the instrumentation context referenced for the runner. */
    @Test
    fun theTestContextIsTheAppUnderTest() {
        assertEquals(
            context.packageName,
            InstrumentationRegistry.getInstrumentation().targetContext.packageName,
        )
    }
}
