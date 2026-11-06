package tech.zseven.rish.runtime

import android.content.ContentResolver
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * What an attachment is once it has been picked, on Android.
 *
 * The picker itself belongs to the bridge -- it needs an activity -- and
 * everything that decides whether the thing picked may become an attachment
 * lives here: the kind, the limits, the copy into app-private storage, and
 * the thumbnail the composer shows.
 *
 * **Why the bytes are copied.** A document URI is a borrowed permission. It
 * can be revoked, the file behind it can be replaced, and after a restart it
 * may resolve to nothing. An attachment the person has put in a draft has to
 * still be there when the message is sent, so the bytes are taken once and
 * the URI is not kept.
 *
 * The limits are the reader's, not this file's: a text attachment is at most
 * 1 MiB and anything else 8 MiB, matching `MAX_TEXT_ATTACHMENT_SIZE` and
 * `MAX_BINARY_ATTACHMENT_SIZE`, because a descriptor past them is refused by
 * the store that would hold it.
 */
internal class AndroidAttachmentStore(private val home: File) {

    class Refused(val code: String, val reason: String) : Exception(reason)

    /**
     * Takes one picked document and answers its descriptor, or null when it
     * is not something this app accepts. A selection of several is not
     * refused wholesale because one of them was a video.
     */
    fun accept(resolver: ContentResolver, uri: Uri): JSONObject? {
        val mime = (resolver.getType(uri) ?: return null).lowercase()
        val kind = kindFor(mime) ?: return null
        val metadata = metadata(resolver, uri)
        val name = metadata.first ?: defaultName(kind)
        val cap = if (kind == "text") MAX_TEXT_BYTES else MAX_BINARY_BYTES
        // The size the provider reports is a hint; the copy below is what
        // actually decides, so a provider that lies cannot get past the cap.
        val declared = metadata.second
        if (declared != null && declared > cap) return null

        val id = UUID.randomUUID().toString()
        val payload = File(root(), id)
        val bytes = try {
            resolver.openInputStream(uri).use { input ->
                input ?: return null
                payload.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > cap) {
                            payload.delete()
                            return null
                        }
                        output.write(buffer, 0, read)
                    }
                    total
                }
            }
        } catch (_: IOException) {
            payload.delete()
            throw Refused(PERSISTENCE, "The attachment could not be read")
        } catch (_: SecurityException) {
            payload.delete()
            // The permission behind the URI was gone before the read: not an
            // error to report, just nothing to attach.
            return null
        }
        if (bytes <= 0L) {
            payload.delete()
            return null
        }

        val descriptor = JSONObject()
            .put("schema_version", 1)
            .put("id", id)
            .put("kind", kind)
            .put("name", name.take(MAX_NAME_LENGTH))
            .put("mime_type", mime.take(MAX_MIME_LENGTH))
            .put("size", bytes)
        thumbnail(payload, kind)?.let { descriptor.put("thumbnail_data_url", it) }
        try {
            File(root(), "$id$SIDECAR").writeText(descriptor.toString())
        } catch (_: IOException) {
            payload.delete()
            throw Refused(PERSISTENCE, "The attachment could not be stored")
        }
        return descriptor
    }

    /** `discard`: the attachments named, and nothing else. */
    fun discard(ids: List<String>): JSONObject {
        var discarded = 0
        for (id in ids) {
            if (!identifier(id)) continue
            val payload = File(root(), id)
            val sidecar = File(root(), "$id$SIDECAR")
            val present = payload.exists() || sidecar.exists()
            payload.delete()
            sidecar.delete()
            if (present) discarded += 1
        }
        return JSONObject().put("schema_version", 1).put("discarded_count", discarded)
    }

    /**
     * `prune`: everything the session no longer refers to.
     *
     * The caller passes what it still holds, which is the only place that
     * knows -- an attachment in a draft is referenced by nothing durable yet
     * and must survive, so the list is the truth rather than the store's own
     * guess at reachability.
     */
    fun prune(referenced: List<String>): JSONObject {
        val keep = referenced.filter { identifier(it) }.toSet()
        var removed = 0
        val files = root().listFiles() ?: return JSONObject()
            .put("schema_version", 1).put("removed_count", 0)
        for (file in files) {
            val id = file.name.removeSuffix(SIDECAR)
            if (keep.contains(id)) continue
            if (file.delete() && !file.name.endsWith(SIDECAR)) removed += 1
        }
        return JSONObject().put("schema_version", 1).put("removed_count", removed)
    }

    /** `preview`: the thumbnail this attachment already has, or none. */
    fun preview(id: String): JSONObject {
        if (!identifier(id)) throw Refused(INVALID, "Attachment id is invalid")
        val descriptor = descriptor(id)
        val thumbnail = descriptor?.opt("thumbnail_data_url") as? String
        return JSONObject()
            .put("schema_version", 1)
            .put("id", id)
            .put("thumbnail_data_url", thumbnail ?: JSONObject.NULL)
    }

    /** The stored descriptor, for the bridge's own preview. */
    fun descriptor(id: String): JSONObject? {
        if (!identifier(id)) return null
        val sidecar = File(root(), "$id$SIDECAR")
        if (!sidecar.isFile) return null
        return try {
            JSONObject(sidecar.readText())
        } catch (_: Exception) {
            null
        }
    }

    /** The bytes themselves, for a viewer this app hands the file to. */
    fun payload(id: String): File? {
        if (!identifier(id)) return null
        return File(root(), id).takeIf { it.isFile }
    }

    private fun root(): File {
        val root = File(home, DIRECTORY)
        if (!root.isDirectory && !root.mkdirs()) {
            throw Refused(PERSISTENCE, "Attachment storage could not be opened")
        }
        return root
    }

    /**
     * The three kinds a message may carry. Anything else is not refused
     * loudly -- the person picked it, they did not do anything wrong -- it is
     * simply not an attachment.
     */
    private fun kindFor(mime: String): String? = when {
        mime.startsWith("image/") -> "image"
        mime.startsWith("text/") -> "text"
        mime == "application/pdf" -> "pdf"
        else -> null
    }

    private fun metadata(resolver: ContentResolver, uri: Uri): Pair<String?, Long?> {
        var cursor: Cursor? = null
        return try {
            cursor = resolver.query(uri, null, null, null, null)
            if (cursor == null || !cursor.moveToFirst()) return null to null
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
            val name = if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                cursor.getString(nameIndex)
            } else {
                null
            }
            val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                cursor.getLong(sizeIndex)
            } else {
                null
            }
            name?.takeIf { it.isNotBlank() && !it.contains(' ') } to size
        } catch (_: Exception) {
            null to null
        } finally {
            cursor?.close()
        }
    }

    private fun defaultName(kind: String): String = when (kind) {
        "image" -> "image"
        "pdf" -> "document.pdf"
        else -> "text.txt"
    }

    /**
     * A small JPEG the composer can draw immediately.
     *
     * It is sampled down while decoding rather than after, so a photograph
     * from a modern camera never becomes a full-size bitmap in memory, and
     * the result is dropped entirely if it would be too large to carry in a
     * descriptor.
     */
    private fun thumbnail(payload: File, kind: String): String? {
        if (kind != "image") return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(payload.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (
                bounds.outWidth / sample > THUMBNAIL_EDGE * 2 ||
                bounds.outHeight / sample > THUMBNAIL_EDGE * 2
            ) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            val decoded = BitmapFactory.decodeFile(payload.absolutePath, options) ?: return null
            val scale = minOf(
                1f,
                THUMBNAIL_EDGE.toFloat() / maxOf(decoded.width, decoded.height).toFloat(),
            )
            val scaled = if (scale >= 1f) decoded else Bitmap.createScaledBitmap(
                decoded,
                maxOf(1, (decoded.width * scale).toInt()),
                maxOf(1, (decoded.height * scale).toInt()),
                true,
            )
            val stream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, THUMBNAIL_QUALITY, stream)
            if (scaled !== decoded) scaled.recycle()
            decoded.recycle()
            val encoded = Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
            if (encoded.length > MAX_THUMBNAIL_CHARS) null
            else "data:image/jpeg;base64,$encoded"
        } catch (_: Throwable) {
            // A thumbnail is a convenience. An image that will not decode is
            // still an attachment.
            null
        }
    }

    private fun identifier(id: String?): Boolean =
        id != null && UUID_PATTERN.matches(id)

    private companion object {
        val UUID_PATTERN =
            Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        const val DIRECTORY = "attachments"
        const val SIDECAR = ".json"
        const val MAX_TEXT_BYTES = 1024L * 1024L
        const val MAX_BINARY_BYTES = 8L * 1024L * 1024L
        const val MAX_NAME_LENGTH = 256
        const val MAX_MIME_LENGTH = 256
        const val THUMBNAIL_EDGE = 192
        const val THUMBNAIL_QUALITY = 70
        const val MAX_THUMBNAIL_CHARS = 96 * 1024
        const val INVALID = "E_ATTACHMENT_INVALID"
        const val PERSISTENCE = "E_ATTACHMENT_PERSISTENCE"
    }
}
