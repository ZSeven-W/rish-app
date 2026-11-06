package tech.zseven.rish.gpui

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.provider.MediaStore
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.gpui.mobile.GpuiActivity
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Exercises the real OS picker and async import without reading the user's library. */
@RunWith(AndroidJUnit4::class)
class ShellAvatarPickerTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val automation get() = instrumentation.uiAutomation
    private fun request() = JSONArray().put(JSONObject().put("schema_version", 1).put("userInitiated", true))

    private fun find(node: AccessibilityNodeInfo?, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        if (node == null) return null
        if (predicate(node)) return node
        for (index in 0 until node.childCount) find(node.getChild(index), predicate)?.let { return it }
        return null
    }

    private fun awaitNode(predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        repeat(200) {
            find(automation.rootInActiveWindow, predicate)?.let { return it }
            Thread.sleep(50)
        }
        val tree = StringBuilder()
        fun describe(node: AccessibilityNodeInfo?, depth: Int) {
            if (node == null) return
            tree.appendLine("${" ".repeat(depth)}${node.viewIdResourceName} ${node.className} ${node.text} ${node.contentDescription}")
            for (index in 0 until node.childCount) describe(node.getChild(index), depth + 1)
        }
        describe(automation.rootInActiveWindow, 0)
        error("System picker control did not appear:\n$tree")
    }

    private fun capture(name: String) {
        val bitmap = requireNotNull(automation.takeScreenshot())
        try { File(context.cacheDir, name).outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
    }

    @Test fun realSystemPickerCancellationSettlesExactlyOnce() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        val completed = CountDownLatch(1)
        val calls = AtomicInteger()
        var result: Result<JSONObject?>? = null
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            scenario.onActivity { screen ->
                ShellAvatarPicker.present(screen, request()) { value ->
                    result = value; calls.incrementAndGet(); completed.countDown()
                }
            }
            awaitNode { it.packageName?.toString()?.contains("providers.media") == true }
            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            assertTrue("The actual system cancellation must resolve", completed.await(10, TimeUnit.SECONDS))
            assertTrue(result!!.isSuccess)
            assertNull(result!!.getOrThrow())
            Thread.sleep(300)
            assertEquals(1, calls.get())
        }
    }

    @Test fun realSystemPickerSelectionImportsOnlyFreshPrivatePixels() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        val resolver = context.contentResolver
        val uri = requireNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "rish-avatar-test-${UUID.randomUUID()}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RishAvatarTests")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }))
        val source = Bitmap.createBitmap(900, 450, Bitmap.Config.ARGB_8888)
        try {
            source.eraseColor(Color.rgb(24, 86, 180))
            resolver.openOutputStream(uri)!!.use { assertTrue(source.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { source.recycle() }
        resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        val completed = CountDownLatch(1)
        val calls = AtomicInteger()
        var result: Result<JSONObject?>? = null
        var imported: JSONObject? = null
        try {
            ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
                scenario.onActivity { screen ->
                    ShellAvatarPicker.present(screen, request()) { value ->
                        result = value; calls.incrementAndGet(); completed.countDown()
                    }
                }
                var thumbnail = awaitNode { it.viewIdResourceName?.endsWith(":id/icon_thumbnail") == true }
                capture("avatar-system-picker.png")
                while (!thumbnail.isClickable && thumbnail.parent != null) thumbnail = thumbnail.parent
                assertTrue("Select the generated test image in the real OS picker", thumbnail.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                assertTrue("The actual system selection must import asynchronously", completed.await(15, TimeUnit.SECONDS))
                val response = requireNotNull(result!!.getOrThrow())
                assertEquals(1, response.getInt("schema_version"))
                val avatar = response.getJSONObject("avatar").also { imported = it }
                assertEquals(512, avatar.getInt("width"))
                assertEquals(256, avatar.getInt("height"))
                assertEquals("image/png", avatar.getString("mime_type"))
                val stored = File(ShellAssistantRoutes.storageDirectory(context), "avatars/${avatar.getString("id")}.png")
                assertEquals(stored.length(), avatar.getLong("byte_length"))
                assertTrue(stored.isFile)
                Thread.sleep(300)
                assertEquals(1, calls.get())
            }
        } finally {
            imported?.let { ShellAvatarStore.discardUnpublished(context, it) }
            resolver.delete(uri, null, null)
        }
    }
}
