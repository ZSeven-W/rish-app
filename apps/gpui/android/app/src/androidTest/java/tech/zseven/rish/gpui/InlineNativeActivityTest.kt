package tech.zseven.rish.gpui

import android.graphics.Bitmap
import android.graphics.Rect
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inspector.WindowInspector
import android.widget.EditText
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.gpui.mobile.GpuiActivity
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import tech.zseven.rish.runtime.AndroidRuntimeState

@RunWith(AndroidJUnit4::class)
class InlineNativeActivityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun onMain(body: () -> Unit) = instrumentation.runOnMainSync(body)
    private fun editor(view: View): EditText? {
        if (view is EditText && view.javaClass.simpleName == "InlineEditText" && view.isAttachedToWindow &&
            view.isShown && view.width > 20 && view.height > 20) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) editor(view.getChildAt(index))?.let { return it }
        return null
    }
    private fun awaitEditor(): EditText? {
        repeat(100) {
            var found: EditText? = null
            onMain { found = WindowInspector.getGlobalWindowViews().firstNotNullOfOrNull(::editor) }
            if (found != null) return found
            Thread.sleep(50)
        }
        return null
    }
    private fun awaitHostFocus(scenario: ActivityScenario<GpuiActivity>) {
        repeat(100) {
            var ready = false
            scenario.onActivity { ready = it.hasWindowFocus() && GpuiActivity.nativeIsInitialized() }
            if (ready) return
            Thread.sleep(50)
        }
        fail("The real GPUI Activity must own its window before injecting a touch")
    }
    private fun snapshot(field: EditText): JSONObject = NativeInlineComposer.snapshot(
        JSONArray().put(JSONObject().put("session_id", field.tag as String)))

    private fun imeBounds(): Rect? = instrumentation.uiAutomation.windows
        .firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        ?.let { window -> Rect().also(window::getBoundsInScreen) }
    private fun awaitIme(): Rect {
        repeat(150) { imeBounds()?.let { return it }; Thread.sleep(50) }
        error("The real software IME did not become visible")
    }
    private fun tap(x: Float, y: Float) {
        val down = SystemClock.uptimeMillis()
        instrumentation.sendPointerSync(MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0))
        instrumentation.sendPointerSync(MotionEvent.obtain(down, down + 30, MotionEvent.ACTION_UP, x, y, 0))
    }
    private fun sentMessages(): Int {
        val loaded = AndroidRuntimeState.get(instrumentation.targetContext).loadSnapshot()
        if (loaded.optString("status") != "present") return 0
        val chats = JSONObject(loaded.getString("session_json")).getJSONArray("conversations")
        var count = 0
        for (i in 0 until chats.length()) {
            val messages = chats.getJSONObject(i).getJSONArray("messages")
            for (j in 0 until messages.length()) {
                val message = messages.getJSONObject(j)
                if (message.optString("role") == "user" && message.optString("text") == "中文输入\n第二行") count++
            }
        }
        return count
    }

    @Test fun pausedNativeEditorRestoresItsAcknowledgedDraft() {
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            awaitHostFocus(scenario)
            val first = requireNotNull(awaitEditor())
            onMain {
                first.setText("暂停恢复验证")
                assertEquals("暂停恢复验证", snapshot(first).getString("text"))
            }
            Thread.sleep(300)
            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            val restored = awaitEditor()
            onMain {
                assertNotNull("Foreground must recreate the closed native editor", restored)
                assertEquals("暂停恢复验证", restored!!.text.toString())
            }
        }
    }

    @Test fun actualNativeActivityEditsChineseInPlaceAndRestoresAfterPause() {
        instrumentation.uiAutomation.serviceInfo = instrumentation.uiAutomation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            awaitHostFocus(scenario)
            var field = awaitEditor()
            if (field == null) {
                // Capture the actual bridge refusal on the old NativeActivity
                // host, instead of only reporting a generic missing-view timeout.
                scenario.onActivity { activity ->
                    NativeInlineComposer.sync(activity, JSONArray().put(JSONObject()
                        .put("session_id", UUID.randomUUID().toString()).put("text_revision", 1)
                        .put("text", "").put("rect", JSONArray(listOf(20, 140, 280, 80)))
                        .put("viewport", JSONArray(listOf(400, 800))).put("scale", 1)
                        .put("visible", true).put("focus", false).put("appearance", "light")
                        .put("placeholder", "NativeActivity inline regression")))
                }
                fail("The actual GPUI shell did not attach an inline editor")
            }
            val initial = field!!
            var location = IntArray(2)
            onMain {
                assertTrue(initial.hint.isNotBlank())
                assertEquals(WindowManager.LayoutParams.TYPE_APPLICATION_PANEL,
                    (initial.rootView.layoutParams as WindowManager.LayoutParams).type)
                initial.getLocationOnScreen(location)
            }
            tap(location[0] + 12f, location[1] + 12f)
            val keyboard = awaitIme()
            Thread.sleep(500)
            onMain {
                assertTrue(initial.hasFocus() && initial.hasWindowFocus())
                initial.getLocationOnScreen(location)
                assertTrue("Editor must remain above the real keyboard", location[1] + initial.height <= keyboard.top + 2)
                val connection = requireNotNull(initial.onCreateInputConnection(EditorInfo()))
                connection.setComposingText("中文输入", 1)
                assertTrue(snapshot(initial).getBoolean("composing"))
                connection.finishComposingText()
                connection.commitText("\n第二行", 1)
                assertEquals("中文输入\n第二行", snapshot(initial).getString("text"))
                assertFalse(snapshot(initial).getBoolean("composing"))
            }
            Thread.sleep(500)
            val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            File(instrumentation.targetContext.cacheDir, "inline-native-chinese.png").outputStream().use {
                assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
            bitmap.recycle()
            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            field = awaitEditor()
            onMain {
                assertNotNull(field)
                assertEquals("中文输入\n第二行", field!!.text.toString())
                assertNotEquals(initial.tag, field!!.tag)
                field!!.getLocationOnScreen(location)
            }
            // An outside tap must reach a real GPUI control, not only blur
            // the native panel. Opening model configuration hides the composer.
            val scale = instrumentation.targetContext.resources.displayMetrics.density
            tap(location[0] + field!!.width - 135f * scale, location[1] + field!!.height + 22f * scale)
            repeat(100) { if (!field!!.isShown) return@repeat; Thread.sleep(30) }
            onMain { assertFalse("The model control outside the input panel must open", field!!.isShown) }

        }
    }

    @Test fun oneSendTapOutsideInlinePanelCommitsExactlyOnce() {
        assertFalse(AndroidRuntimeState.get(instrumentation.targetContext).proof()
            .getJSONObject("proof").getJSONObject("checks").getBoolean("credential_in_secure_store"))
        val sentBefore = sentMessages()
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            awaitHostFocus(scenario)
            val field = requireNotNull(awaitEditor())
            onMain { field.setText("中文输入\n第二行"); snapshot(field) }
            Thread.sleep(500)
            val location = IntArray(2)
            onMain { field.getLocationOnScreen(location) }
            val scale = instrumentation.targetContext.resources.displayMetrics.density
            tap(location[0] + field.width - 18f * scale, location[1] + field.height + 22f * scale)
            repeat(160) { if (sentMessages() == sentBefore + 1) return@repeat; Thread.sleep(50) }
            assertEquals("One Send tap must commit exactly one user message", sentBefore + 1, sentMessages())
            Thread.sleep(300)
            assertEquals(sentBefore + 1, sentMessages())
        }
    }
}
