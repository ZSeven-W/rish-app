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

    /** A file that says it is a PDF and will not open as one is refused, not dropped. */
    @Test
    fun aFileThatIsNotReallyAPdfIsRefused() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "pdf", "application/pdf", "contract.pdf", png)
        val history = JSONArray().put(message("summarise", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        assertEquals(
            "E_COMPLETION_CONTEXT_INVALID",
            codeOf { transport.validate(prepared) },
        )
        assertEquals(0, transport.activeRequestCount())
    }

    /** A real PDF, one flat colour per page, written with the platform's own writer. */
    private fun pdf(vararg colours: Int): ByteArray = pdfSized(200, 300, *colours)

    private fun pdfSized(width: Int, height: Int, vararg colours: Int): ByteArray {
        val document = android.graphics.pdf.PdfDocument()
        colours.forEachIndexed { index, colour ->
            val page = document.startPage(
                android.graphics.pdf.PdfDocument.PageInfo.Builder(width, height, index + 1).create(),
            )
            page.canvas.drawColor(colour)
            document.finishPage(page)
        }
        val out = java.io.ByteArrayOutputStream()
        document.writeTo(out)
        document.close()
        return out.toByteArray()
    }

    /** The colour at the centre of a drawn page, as decoded from what would be sent. */
    private fun centre(part: JSONObject): Int {
        assertEquals("image", part.getString("type"))
        assertEquals("image/jpeg", part.getString("mime_type"))
        val bytes = Base64.decode(part.getString("data"), Base64.NO_WRAP)
        val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        // The long edge is what the renderer fixes; a 200x300 page is portrait.
        assertEquals(1600, bitmap.height)
        return bitmap.getPixel(bitmap.width / 2, bitmap.height / 2)
    }

    private fun near(expected: Int, actual: Int): Boolean =
        Math.abs(android.graphics.Color.red(expected) - android.graphics.Color.red(actual)) < 40 &&
            Math.abs(android.graphics.Color.green(expected) - android.graphics.Color.green(actual)) < 40 &&
            Math.abs(android.graphics.Color.blue(expected) - android.graphics.Color.blue(actual)) < 40

    /**
     * Every page, drawn, in order, and the words say which pictures are
     * which pages of which file. The colours are the proof the pages were
     * really drawn and not sent as blank frames.
     */
    @Test
    fun aPdfReachesTheModelAsEveryPageDrawnInOrder() {
        val home = home()
        val transport = transport(home)
        val colours = intArrayOf(android.graphics.Color.RED, android.graphics.Color.BLUE, android.graphics.Color.GREEN)
        val reference = stage(home, "pdf", "application/pdf", "report.pdf", pdf(*colours))
        val history = JSONArray().put(message("what colours", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        transport.validate(prepared)
        val content = transport.composedForTest(prepared).getJSONObject(0).getJSONArray("content")
        assertEquals(4, content.length())
        val words = content.getJSONObject(0).getString("text")
        assertTrue(words, words.startsWith("what colours\n\n"))
        assertTrue(words, words.contains("BEGIN PDF: report.pdf"))
        assertTrue(words, words.contains("Images 1-3 of this message are pages 1-3 of this PDF, in order."))
        for (index in colours.indices) {
            val seen = centre(content.getJSONObject(index + 1))
            assertTrue("page ${index + 1} is not its colour: ${Integer.toHexString(seen)}", near(colours[index], seen))
        }
        transport.discard(prepared)
    }

    /** Pictures are numbered across the message, so a PDF after an image says so. */
    @Test
    fun aPdfAfterAnImageNamesItsOwnPictures() {
        val home = home()
        val transport = transport(home)
        val image = stage(home, "image", "image/png", "probe.png", png)
        val document = stage(home, "pdf", "application/pdf", "two.pdf", pdf(android.graphics.Color.RED, android.graphics.Color.BLUE))
        val history = JSONArray().put(message("compare", JSONArray().put(image).put(document)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-flash"))
        transport.validate(prepared)
        val content = transport.composedForTest(prepared).getJSONObject(0).getJSONArray("content")
        assertEquals(4, content.length())
        val words = content.getJSONObject(0).getString("text")
        assertTrue(words, words.contains("Images 2-3 of this message are pages 1-2 of this PDF, in order."))
        transport.discard(prepared)
    }

    /** A model that reads no images is told, before anything is sent. */
    @Test
    fun aPdfIsRefusedForAModelThatCannotSeePages() {
        val home = home()
        val transport = transport(home)
        val before = transport.sentRequestCount
        val reference = stage(home, "pdf", "application/pdf", "report.pdf", pdf(android.graphics.Color.RED))
        val history = JSONArray().put(message("summarise", JSONArray().put(reference)))
        val prepared = transport.prepare(envelope(history, "deepseek-v4-pro"))
        assertEquals("E_COMPLETION_CONTEXT_UNSUPPORTED", codeOf { transport.validate(prepared) })
        assertEquals("no request may be sent", before, transport.sentRequestCount)
        assertEquals(0, transport.activeRequestCount())
    }

    /** Too long is refused whole: the first pages alone would answer about pages unseen. */
    @Test
    fun aPdfLongerThanTheCapIsRefusedWholeNotCut() {
        val home = home()
        val transport = transport(home)
        val within = stage(home, "pdf", "application/pdf", "twenty.pdf", pdf(*IntArray(20) { android.graphics.Color.WHITE }))
        val accepted = transport.prepare(
            envelope(JSONArray().put(message("ok", JSONArray().put(within))), "deepseek-v4-flash"),
        )
        assertEquals("no refusal", codeOf { transport.validate(accepted) })
        transport.discard(accepted)
        val over = stage(home, "pdf", "application/pdf", "long.pdf", pdf(*IntArray(21) { android.graphics.Color.WHITE }))
        val refused = transport.prepare(
            envelope(JSONArray().put(message("summarise", JSONArray().put(over))), "deepseek-v4-flash"),
        )
        assertEquals("E_COMPLETION_BODY_TOO_LARGE", codeOf { transport.validate(refused) })
        assertEquals(0, transport.activeRequestCount())
    }

    /** A till receipt drawn to a 1600-pixel strip would be unreadable; it is refused, not sent. */
    @Test
    fun aPageTooLongToReadIsRefused() {
        val home = home()
        val transport = transport(home)
        val reference = stage(home, "pdf", "application/pdf", "receipt.pdf", pdfSized(100, 1000, android.graphics.Color.WHITE))
        val prepared = transport.prepare(
            envelope(JSONArray().put(message("total?", JSONArray().put(reference))), "deepseek-v4-flash"),
        )
        assertEquals("E_COMPLETION_CONTEXT_UNSUPPORTED", codeOf { transport.validate(prepared) })
        assertEquals(0, transport.activeRequestCount())
    }

    /**
     * Pictures of every kind share one budget: the request crosses into the
     * shared core as one string the bridge caps, and a body past it would fail
     * after the round was marked dispatched. Two 7 MiB images are over it.
     */
    @Test
    fun picturesPastTheBridgeBudgetAreRefusedBeforeDispatch() {
        val home = home()
        val transport = transport(home)
        val big = ByteArray(7 * 1024 * 1024) { 1 }
        val first = stage(home, "image", "image/jpeg", "a.jpg", big)
        val second = stage(home, "image", "image/jpeg", "b.jpg", big)
        val prepared = transport.prepare(
            envelope(JSONArray().put(message("both", JSONArray().put(first).put(second))), "deepseek-v4-flash"),
        )
        assertEquals("E_COMPLETION_BODY_TOO_LARGE", codeOf { transport.validate(prepared) })
        assertEquals(0, transport.activeRequestCount())
    }

    /** The same PDF sent again -- every round resends history -- still arrives whole. */
    @Test
    fun aPdfInHistoryIsSentWholeEveryRound() {
        val home = home()
        val transport = transport(home)
        val colours = intArrayOf(android.graphics.Color.RED, android.graphics.Color.BLUE)
        val reference = stage(home, "pdf", "application/pdf", "again.pdf", pdf(*colours))
        repeat(2) {
            val prepared = transport.prepare(
                envelope(JSONArray().put(message("again", JSONArray().put(reference))), "deepseek-v4-flash"),
            )
            transport.validate(prepared)
            val content = transport.composedForTest(prepared).getJSONObject(0).getJSONArray("content")
            assertEquals(3, content.length())
            assertTrue(near(colours[0], centre(content.getJSONObject(1))))
            assertTrue(near(colours[1], centre(content.getJSONObject(2))))
            transport.discard(prepared)
        }
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
