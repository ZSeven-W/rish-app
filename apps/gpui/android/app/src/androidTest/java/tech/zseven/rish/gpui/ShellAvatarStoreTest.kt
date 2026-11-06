package tech.zseven.rish.gpui

import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.ExifInterface
import android.system.Os
import android.system.OsConstants
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ShellAvatarStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixture(test: (Context, File) -> Unit) {
        val root = File(context.cacheDir, "avatar-test-${UUID.randomUUID()}").apply { mkdirs() }
        val files = File(root, "files").apply { mkdir() }
        val scoped = object : ContextWrapper(context) { override fun getFilesDir(): File = files }
        try { test(scoped, root) } finally { root.deleteRecursively() }
    }
    private fun png(width: Int = 900, height: Int = 450): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return try {
            bitmap.eraseColor(Color.rgb(24, 86, 180))
            ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        } finally { bitmap.recycle() }
    }

    @Test fun normalizedPngIsPrivateAtomicBoundedAndHasOnlyPortableMetadata() = fixture { scoped, _ ->
        val image = ShellAvatarImage.encode(png())
        assertEquals(512, image.width)
        assertEquals(256, image.height)
        val avatar = ShellAvatarStore.save(scoped, image) { false }
        assertEquals(setOf("id", "sha256", "mime_type", "width", "height", "byte_length"), avatar.keys().asSequence().toSet())
        assertEquals(avatar.getString("id"), UUID.fromString(avatar.getString("id")).toString())
        val directory = File(ShellAssistantRoutes.storageDirectory(scoped), "avatars")
        val file = File(directory, "${avatar.getString("id")}.png")
        val bytes = file.readBytes()
        assertArrayEquals(image.bytes, bytes)
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        assertEquals(sha, avatar.getString("sha256"))
        assertEquals(bytes.size, avatar.getInt("byte_length"))
        assertEquals("image/png", avatar.getString("mime_type"))
        assertTrue(bytes.size <= 2 * 1024 * 1024)
        assertEquals(0x1c0, Os.lstat(directory.path).st_mode and 0x1ff)
        val stat = Os.lstat(file.path)
        assertTrue(OsConstants.S_ISREG(stat.st_mode))
        assertEquals(1L, stat.st_nlink)
        assertEquals(0x180, stat.st_mode and 0x1ff)
        assertEquals(listOf(file.name), directory.list()!!.toList())
        assertFalse(File(ShellAssistantRoutes.storageDirectory(scoped), "assistant-v1.json").exists())
    }

    @Test fun imageImportNeverAssignsOrRewritesAnyBotProfile() = fixture { scoped, _ ->
        val store = File(ShellAssistantRoutes.storageDirectory(scoped), "assistant-v1.json")
        val existing = """{"revision":31,"profile":{"name":"Default Bot"},"bots":[{"id":"bot-b","profile":{"name":"Other Bot"}}]}""".toByteArray()
        store.writeBytes(existing)
        val image = ShellAvatarImage.encode(png(16, 16))
        val first = ShellAvatarStore.save(scoped, image) { false }
        val second = ShellAvatarStore.save(scoped, image) { false }
        assertNotEquals(first.getString("id"), second.getString("id"))
        assertArrayEquals(existing, store.readBytes())
        for (result in listOf(first, second)) {
            assertFalse(result.has("bot_id"))
            assertFalse(result.has("profile"))
        }
    }

    @Test fun jpegOrientationIsAppliedAndGpsAndCommentAreNotCopiedToPng() = fixture { _, root ->
        val source = File(root, "source.jpg")
        val bitmap = Bitmap.createBitmap(640, 320, Bitmap.Config.ARGB_8888)
        try { source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) } }
        finally { bitmap.recycle() }
        val privateComment = "private-comment-${UUID.randomUUID()}"
        ExifInterface(source.path).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            setAttribute(ExifInterface.TAG_USER_COMMENT, privateComment)
            setAttribute(ExifInterface.TAG_GPS_LATITUDE, "30/1,15/1,0/1")
            setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, "N")
            saveAttributes()
        }
        val image = ShellAvatarImage.encode(source.readBytes())
        assertEquals(256, image.width)
        assertEquals(512, image.height)
        val normalized = BitmapFactory.decodeByteArray(image.bytes, 0, image.bytes.size)
        try { assertEquals(256, normalized.width); assertEquals(512, normalized.height) }
        finally { normalized.recycle() }
        val exif = ExifInterface(ByteArrayInputStream(image.bytes))
        assertNull(exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE))
        assertNull(exif.getAttribute(ExifInterface.TAG_USER_COMMENT))
        assertFalse(image.bytes.toString(Charsets.ISO_8859_1).contains(privateComment))
    }

    @Test fun cancelledImportNeverPublishesMetadataOrLeavesTemporaryFiles() = fixture { scoped, _ ->
        val image = ShellAvatarImage.encode(png(16, 16))
        for (cancelAt in 1..3) {
            var checkpoints = 0
            assertThrows(BridgeFailure::class.java) {
                ShellAvatarStore.save(scoped, image) { ++checkpoints >= cancelAt }
            }
            val directory = File(ShellAssistantRoutes.storageDirectory(scoped), "avatars")
            assertTrue(directory.listFiles()!!.isEmpty())
        }
    }

    @Test fun symlinkAvatarDirectoryCannotRedirectImports() = fixture { scoped, root ->
        val outside = File(root, "outside").apply { mkdir() }
        val avatars = File(ShellAssistantRoutes.storageDirectory(scoped), "avatars")
        Os.symlink(outside.path, avatars.path)
        assertThrows(Exception::class.java) { ShellAvatarStore.save(scoped, ShellAvatarImage.encode(png(16, 16))) { false } }
        assertTrue(outside.listFiles()!!.isEmpty())
    }

    @Test fun malformedOrOversizedEncodedInputsAreRejectedBeforeStorage() {
        assertThrows(BridgeFailure::class.java) { ShellAvatarImage.encode(byteArrayOf(1, 2, 3)) }
        assertThrows(BridgeFailure::class.java) { ShellAvatarImage.encode(ByteArray(ShellAvatarContract.MAX_SOURCE_BYTES + 1)) }
    }
}
