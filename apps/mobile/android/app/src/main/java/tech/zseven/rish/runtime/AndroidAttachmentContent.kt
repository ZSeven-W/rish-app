package tech.zseven.rish.runtime

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.nio.charset.CodingErrorAction

/**
 * Turning the attachments a message carries into something a model is shown.
 *
 * A message in the visible history carries only *references* -- id, kind,
 * name, mime type, size -- because that is all the transcript keeps and all a
 * receipt digest should bind. The bytes live in the attachment store. This is
 * the one place that fetches them and decides what each kind becomes, for
 * both the plain chat path and the agent round path, so the two cannot answer
 * differently about the same file.
 *
 * **What each kind becomes.**
 * - An image becomes a content part the request builder spells per dialect.
 *   The part shape here is the app's own (`{type:"image", mime_type, data}`),
 *   not any provider's; `completion_request` owns every wire spelling.
 * - Text is read as UTF-8 and folded into the message's words, fenced and
 *   named, exactly as iOS does. It needs no dialect support at all.
 * - A PDF is **refused**. Android has no text extractor here -- `PdfRenderer`
 *   draws pages, it does not read them -- and adding a library for it is not
 *   this change. Sending the words around a PDF while silently dropping the
 *   PDF would answer a question about a document the model never saw, so the
 *   person is told instead.
 *
 * Nothing here is best-effort. A reference the store cannot honour fails the
 * request rather than quietly shrinking what the model is shown.
 */
internal class AndroidAttachmentContent(private val store: AndroidAttachmentStore?) {

    class Refused(val code: String, val reason: String) : Exception(reason)

    /**
     * What one message became: the words to send, and the image parts to send
     * beside them. `pictures` empty means the content stays a plain string,
     * which is what every turn without an image has always been.
     */
    class Projected(val words: String, val pictures: JSONArray)

    /**
     * The running totals for one request. The caps are per request, not per
     * message, because a conversation accumulates attachments and it is the
     * whole body a provider refuses.
     */
    class Budget {
        var count = 0
        var rawBytes = 0L
        var expandedBytes = 0L
    }

    /**
     * One message's words and images.
     *
     * `supportsImages` is the caller's answer about the *effective* model.
     * This file does not read the catalog: the transport knows which model the
     * request is actually for after mapping, and a picture sent to a model
     * that cannot see one is refused rather than dropped.
     */
    fun project(
        message: JSONObject,
        supportsImages: Boolean,
        budget: Budget,
    ): Projected {
        val references = message.optJSONArray("attachments") ?: JSONArray()
        val words = if (message.isNull("content")) "" else message.optString("content")
        if (references.length() == 0) return Projected(words, JSONArray())
        val attachments = store
            ?: throw Refused(UNSUPPORTED, "This build cannot read attachments")

        val pictures = JSONArray()
        val projections = ArrayList<String>()
        for (index in 0 until references.length()) {
            val reference = references.optJSONObject(index)
                ?: throw Refused(INVALID, "An attachment reference is not an object")
            val id = reference.optString("id")
            val kind = reference.optString("kind")
            val mime = reference.optString("mime_type")
            val size = reference.optLong("size", -1L)
            if (id.isEmpty() || kind.isEmpty() || mime.isEmpty() || size <= 0L) {
                throw Refused(INVALID, "An attachment reference is incomplete")
            }
            budget.count += 1
            if (budget.count > MAX_COUNT) {
                throw Refused(TOO_LARGE, "Too many attachments in this conversation")
            }
            budget.rawBytes += size
            if (budget.rawBytes > MAX_RAW_BYTES) {
                throw Refused(TOO_LARGE, "The attachments in this conversation are too large")
            }

            // The descriptor the store wrote is the truth about the bytes it
            // holds; the reference travelled through JavaScript and a session
            // file to get here. They must agree, or the model would be shown
            // something other than what the transcript says it was shown.
            val descriptor = attachments.descriptor(id)
                ?: throw Refused(MISSING, "An attachment is no longer on this device")
            if (descriptor.optString("kind") != kind ||
                descriptor.optString("mime_type") != mime ||
                descriptor.optLong("size", -1L) != size
            ) {
                throw Refused(INVALID, "An attachment does not match its reference")
            }
            val payload = attachments.payload(id)
                ?: throw Refused(MISSING, "An attachment is no longer on this device")
            val bytes = try {
                payload.readBytes()
            } catch (_: IOException) {
                throw Refused(MISSING, "An attachment could not be read")
            }
            if (bytes.size.toLong() != size) {
                throw Refused(INVALID, "An attachment changed size on disk")
            }

            when (kind) {
                "image" -> {
                    if (!supportsImages) {
                        throw Refused(UNSUPPORTED, "This model cannot read images")
                    }
                    if (mime !in PICTURE_MIMES) {
                        throw Refused(UNSUPPORTED, "This image format cannot be sent")
                    }
                    pictures.put(
                        JSONObject().put("type", "image").put("mime_type", mime)
                            .put("data", Base64.encodeToString(bytes, Base64.NO_WRAP)),
                    )
                }
                "text" -> projections.add(fenced(reference, decoded(bytes), "TEXT"))
                else -> throw Refused(
                    UNSUPPORTED,
                    "A $kind attachment cannot be sent to a model yet",
                )
            }
        }

        val expanded = (if (words.isEmpty()) projections else listOf(words) + projections)
            .joinToString("\n\n")
        budget.expandedBytes += expanded.toByteArray().size.toLong()
        if (budget.expandedBytes > MAX_EXPANDED_BYTES) {
            throw Refused(TOO_LARGE, "The attachment text in this conversation is too long")
        }
        return Projected(expanded, pictures)
    }

    /**
     * A text attachment named and fenced, so the model can tell the person's
     * own words from a file's and can quote the file by name.
     */
    private fun fenced(reference: JSONObject, body: String, label: String): String {
        val name = reference.optString("name").ifEmpty { "attachment" }
        return "--- BEGIN $label: $name ---\n$body\n--- END $label: $name ---"
    }

    /**
     * Strict UTF-8. A text attachment that is not UTF-8 is refused rather
     * than silently filled with replacement characters: what the model would
     * be shown is then not what the file says.
     */
    private fun decoded(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) {
            throw Refused(UNSUPPORTED, "A text attachment is not valid UTF-8")
        }
    }

    private companion object {
        /** The formats every provider in the catalog takes; the core agrees. */
        val PICTURE_MIMES = setOf("image/png", "image/jpeg", "image/gif", "image/webp")
        const val MAX_COUNT = 24
        const val MAX_RAW_BYTES = 24L * 1024L * 1024L
        const val MAX_EXPANDED_BYTES = 4L * 1024L * 1024L
        const val INVALID = "E_COMPLETION_CONTEXT_INVALID"
        const val MISSING = "E_COMPLETION_CONTEXT_INVALID"
        const val UNSUPPORTED = "E_COMPLETION_CONTEXT_UNSUPPORTED"
        const val TOO_LARGE = "E_COMPLETION_BODY_TOO_LARGE"
    }
}
