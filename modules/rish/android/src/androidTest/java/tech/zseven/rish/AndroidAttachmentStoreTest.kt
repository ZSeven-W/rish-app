package tech.zseven.rish

import android.graphics.Bitmap
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAttachmentStore
import java.io.File
import java.util.UUID

/**
 * What may become an attachment, and what happens to it afterwards.
 *
 * The picker needs an activity and is not exercised here; everything it
 * hands over is. These go through a real content URI and the app's own
 * `FileProvider`, so the mime type, the name and the bytes arrive the same
 * way a document from another app would.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidAttachmentStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun store(body: (AndroidAttachmentStore, File) -> Unit) {
        val home = File(context.cacheDir, "attachments-home-${UUID.randomUUID()}")
        val staging = File(context.cacheDir, "captures").apply { mkdirs() }
        try {
            body(AndroidAttachmentStore(home), staging)
        } finally {
            home.deleteRecursively()
            staging.listFiles()?.forEach { it.delete() }
        }
    }

    /** A file only this app can see, offered the way a picker offers one. */
    private fun shared(staging: File, name: String, body: (File) -> Unit): Uri {
        val file = File(staging, name)
        body(file)
        return FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    }

    private fun accept(store: AndroidAttachmentStore, uri: Uri) =
        store.accept(context.contentResolver, uri)

    /** A text file arrives as text, with its name, its type and its bytes. */
    @Test fun aTextFileBecomesATextAttachment() = store { store, staging ->
        val uri = shared(staging, "notes.txt") { it.writeText("hello\n") }
        val descriptor = accept(store, uri) ?: throw AssertionError("nothing was accepted")
        assertEquals(1, descriptor.getInt("schema_version"))
        assertEquals("text", descriptor.getString("kind"))
        assertEquals("notes.txt", descriptor.getString("name"))
        assertEquals("text/plain", descriptor.getString("mime_type"))
        assertEquals(6L, descriptor.getLong("size"))
        // The bytes were copied: a borrowed URI is not what the draft keeps.
        val payload = store.payload(descriptor.getString("id"))
        assertNotNull("the payload was not stored", payload)
        assertEquals("hello\n", payload!!.readText())
    }

    /** An image carries a thumbnail the composer can draw at once. */
    @Test fun anImageCarriesAThumbnail() = store { store, staging ->
        val uri = shared(staging, "shot.png") { file ->
            val bitmap = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(0xFF3366CCL.toInt())
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        val descriptor = accept(store, uri) ?: throw AssertionError("nothing was accepted")
        assertEquals("image", descriptor.getString("kind"))
        val thumbnail = descriptor.optString("thumbnail_data_url")
        assertTrue(thumbnail, thumbnail.startsWith("data:image/jpeg;base64,"))
        // And it is small enough to carry in a descriptor.
        assertTrue(thumbnail.length.toString(), thumbnail.length < 96 * 1024)
        val read = store.preview(descriptor.getString("id"))
        assertEquals(thumbnail, read.getString("thumbnail_data_url"))
    }

    /**
     * Two refusals that are not errors: a type this app cannot show, and a
     * file past the limit the store that would hold it enforces. The person
     * picked something; nothing went wrong, it simply is not an attachment.
     */
    @Test fun whatCannotBeAnAttachmentIsNotOne() = store { store, staging ->
        val zip = shared(staging, "bundle.zip") { it.writeBytes(byteArrayOf(0x50, 0x4b, 3, 4)) }
        assertNull(accept(store, zip))

        val huge = shared(staging, "huge.txt") { file ->
            file.outputStream().use { out ->
                val chunk = ByteArray(64 * 1024) { 'a'.code.toByte() }
                repeat(20) { out.write(chunk) } // 1.25 MiB, past the text cap
            }
        }
        assertNull(accept(store, huge))
        // And nothing it half-copied was left behind.
        assertEquals(0, store.prune(emptyList()).getInt("removed_count"))
    }

    /** Discard takes the ones named, and prune takes everything else. */
    @Test fun discardTakesTheNamedOnesAndPruneTakesTheRest() = store { store, staging ->
        val first = accept(store, shared(staging, "one.txt") { it.writeText("one") })!!
            .getString("id")
        val second = accept(store, shared(staging, "two.txt") { it.writeText("two") })!!
            .getString("id")
        val third = accept(store, shared(staging, "three.txt") { it.writeText("three") })!!
            .getString("id")

        assertEquals(1, store.discard(listOf(first)).getInt("discarded_count"))
        assertNull(store.payload(first))
        assertNotNull(store.payload(second))
        // Discarding what is already gone is not a failure, and not a count.
        assertEquals(0, store.discard(listOf(first)).getInt("discarded_count"))

        assertEquals(1, store.prune(listOf(second)).getInt("removed_count"))
        assertNotNull(store.payload(second))
        assertNull(store.payload(third))
    }

    /** A preview of something that is not there answers, rather than throws. */
    @Test fun aPreviewOfNothingIsAnAnswer() = store { store, _ ->
        val missing = UUID.randomUUID().toString()
        val preview = store.preview(missing)
        assertEquals(missing, preview.getString("id"))
        assertTrue(preview.isNull("thumbnail_data_url"))
        // A malformed id is a different thing: that is a bad request.
        val code = try {
            "answered: " + store.preview("../escape")
        } catch (refused: AndroidAttachmentStore.Refused) {
            refused.code
        }
        assertEquals("E_ATTACHMENT_INVALID", code)
    }

}
