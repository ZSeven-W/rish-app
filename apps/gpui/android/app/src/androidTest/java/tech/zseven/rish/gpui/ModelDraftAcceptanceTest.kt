package tech.zseven.rish.gpui

import android.graphics.Bitmap
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inspector.WindowInspector
import android.widget.EditText
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.gpui.mobile.GpuiActivity
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import tech.zseven.rish.runtime.AndroidRuntimeState

/**
 * Opt-in physical-input acceptance on an isolated Pixel XL (1440x2560, 560dpi).
 * No credentials, discovery, sends, direct model writes or session fixture writes.
 * Prepare and optionally retire the model, force-stopping before either restore.
 * The cache receipt is test evidence only; the app never reads it.
 */
@RunWith(AndroidJUnit4::class)
class ModelDraftAcceptanceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val arguments = InstrumentationRegistry.getArguments()
    private val context get() = instrumentation.targetContext
    private val runtime get() = AndroidRuntimeState.get(context)
    private val runId = (arguments.getString("modelRun") ?: "20261106").also {
        require(it.matches(Regex("[a-z0-9-]{1,32}")))
    }
    private val modelId = "rish-p0-android-$runId"
    private val modelName = "Rish Android P0 QA"
    private val modelRow get() = "$modelId | $modelName"
    private val draft = "Rish Android unsent draft 20261106"
    private val receipt get() = File(context.cacheDir, "model-draft-qa-receipt.json")

    @Test fun providerEditorTouchProbe() = launch {
        openProviderEditor()
        capture("model-draft-qa-editor-probe.png")
    }

    /** Explicit recovery between failed runs, through the editor; never clear unrelated text. */
    @Test fun clearOnlySyntheticNewChatDraft() = launch {
        val initial = session()
        assertEquals("new-draft", draftKey(initial))
        assertEquals(draft, initial.getJSONObject("composer_drafts").getString("new-draft"))
        val field = awaitEditor(true)
        assertEquals(draft, readText(field))
        tapView(field)
        instrumentation.runOnMainSync {
            assertTrue(requireNotNull(field.onCreateInputConnection(EditorInfo())).setSelection(0, field.text.length))
        }
        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_DEL)
        await("The synthetic draft must be deliberately cleared through the normal save path") {
            readText(field).isEmpty() && session().optJSONObject("composer_drafts")?.has("new-draft") != true
        }
    }

    @Test fun prepareModelAndDraft() = launch {
        require(arguments.getString("manual") != null && arguments.getString("save") != null) {
            "Calibrate manual/save from providerEditorTouchProbe before touching the provider form"
        }
        val initial = session()
        val initialMessages = messageCount(initial)
        assertEquals("Use a fresh chat so Done must create a new conversation", "new-draft", draftKey(initial))
        assertTrue("Never replace a saved new-chat draft before hydration",
            initial.optJSONObject("composer_drafts")?.optString("new-draft").isNullOrEmpty())
        val catalogBefore = runtime.providerModels.list()
        assertNull("Use an unused modelRun; old registry data must not satisfy this run", model(catalogBefore))
        val revision = catalogBefore.getLong("revision")
        val first = awaitEditor(inline = true)
        val before = readText(first)
        assertTrue("Start with an empty editor; never overwrite or reuse an old unsent draft", before.isEmpty())
        typeInto(first, draft)
        await("The new draft must reach the existing durable session store") {
            session().optJSONObject("composer_drafts")?.optString(draftKey(session())) == draft
        }
        capture("model-draft-qa-unsent.png")
        dismissKeyboard()
        openProviderEditor()
        tapArgument("manual", 700f, 1800f)
        val field = awaitManualModelEditor()
        val original = readText(field)
        assertFalse(original.lineSequence().any { it.substringBefore('|').trim() == modelId })
        val addition = (if (original.isBlank()) "" else "\n") + modelRow
        typeInto(field, addition)
        assertEquals("Key events must append to the real native field", original + addition, readText(field))
        dismissKeyboard()
        capture("model-draft-qa-manual-input.png")
        finishManualModelEdit()
        // All GPUI points below are calibrated by the probe; overrides are pixels.
        swipeArgument("saveSwipe", 1100f, 2200f, 1100f, 1350f)
        capture("model-draft-qa-before-save.png")
        tapArgument("save", 700f, 2210f)
        await("Saving through the UI must persist the exact model ID and label") {
            model(runtime.providerModels.list())?.let {
                it.optString("name") == modelName && !it.optBoolean("supports_images", true)
            } == true
        }
        val savedCatalog = runtime.providerModels.list()
        assertTrue("This UI save must advance the catalog", savedCatalog.getLong("revision") > revision)
        capture("model-draft-qa-saved.png")
        tapArgument("back", 155f, 685f)
        capture("model-draft-qa-selector.png")
        tapArgument("select", 650f, 1140f)
        capture("model-draft-qa-configure.png")
        tapArgument("done", 700f, 2310f)
        await("Done must persist the chosen model and move the original new-chat draft") {
            val value = session()
            activeConversation(value)?.optString("model_id") == modelId &&
                value.optJSONObject("composer_drafts")?.optString(draftKey(value)) == draft
        }
        assertEquals(draft, readText(awaitEditor(inline = true)))
        val committed = session()
        assertEquals("No user message may be sent", initialMessages, messageCount(committed))
        assertFalse("First chat creation must consume the new-chat draft slot",
            committed.getJSONObject("composer_drafts").has("new-draft"))
        val loaded = runtime.sessions.load()
        val evidence = JSONObject()
            .put("generation", loaded.getJSONObject("snapshot").getLong("generation"))
            .put("digest", loaded.getJSONObject("snapshot").getString("session_sha256"))
            .put("writer_launch_id", loaded.getString("writer_launch_instance_id"))
            .put("conversation_id", committed.getString("active_conversation_id"))
            .put("model_id", modelId).put("model_name", modelName).put("draft", draft)
            .put("message_count", initialMessages)
        writeReceipt(evidence, loaded, savedCatalog.getLong("revision"), retired = false)
        capture("model-draft-qa-committed.png")
    }

    @Test fun retireModelWithoutChangingConversation() = launch {
        require(arguments.getString("manual") != null && arguments.getString("save") != null) {
            "Calibrate the populated provider form's manual/save coordinates before retirement"
        }
        val old = readReceipt(retired = false)
        assertRestored(old, retired = false)
        assertSessionUnchanged(old, runtime.sessions.load())
        assertEquals(draft, readText(awaitEditor(inline = true)))
        assertEquals("Retirement requires a provider with only this fixture's model",
            1, provider(runtime.providerModels.list()).getJSONArray("models").length())
        openProviderEditor()
        tapArgument("manual", 700f, 1800f)
        val field = awaitManualModelEditor()
        assertEquals("Never delete a list containing other models", modelRow, readText(field))
        tapView(field)
        instrumentation.runOnMainSync {
            assertTrue(requireNotNull(field.onCreateInputConnection(EditorInfo())).setSelection(0, field.text.length))
        }
        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_DEL)
        assertEquals("", readText(field))
        finishManualModelEdit()
        swipeArgument("saveSwipe", 1100f, 2200f, 1100f, 1350f)
        capture("model-draft-qa-before-retire.png")
        tapArgument("save", 700f, 2210f)
        await("Saving an empty list must retire the exact fixture model") {
            val catalog = runtime.providerModels.list()
            model(catalog) == null && model(catalog, retired = true)?.optString("name") == modelName
        }
        val catalog = runtime.providerModels.list()
        val revision = catalog.getLong("revision")
        assertEquals(old.getLong("catalog_revision") + 1, revision)
        val loaded = runtime.sessions.load()
        assertSessionUnchanged(old, loaded)
        writeReceipt(old, loaded, revision, retired = true)
        assertRestored(old, retired = true)
        capture("model-draft-qa-retired.png")
    }

    @Test fun restoreAfterProcessRestart() = restore(retired = false)

    @Test fun restoreRetiredModelAfterProcessRestart() = restore(retired = true)

    private fun restore(retired: Boolean) {
        requireOptIn()
        val old = readReceipt(retired)
        // Read persisted authority before the UI can restore or schedule any save.
        val loaded = runtime.sessions.load()
        assertNotEquals("The app must be running in a new process", old.getInt("pid"), Process.myPid())
        assertNotEquals("Requires a cold start",
            old.getString("launch_id"), loaded.getString("current_launch_instance_id"))
        assertSessionUnchanged(old, loaded)
        assertRestored(old, retired)
        launch {
            assertEquals(draft, readText(awaitEditor(inline = true)))
            assertSessionUnchanged(old, runtime.sessions.load())
            assertRestored(old, retired)
            capture(if (retired) "model-draft-qa-retired-cold-restored.png" else "model-draft-qa-cold-restored.png")
            if (retired) {
                tapArgument("picker", 750f, 2300f)
                capture("model-draft-qa-retired-picker.png")
                assertSessionUnchanged(old, runtime.sessions.load())
            }
            instrumentation.sendStatus(0, Bundle().apply {
                putString("model_draft_restart", JSONObject().put("previous_pid", old.getInt("pid"))
                    .put("pid", Process.myPid()).put("previous_launch_id", old.getString("launch_id"))
                    .put("launch_id", loaded.getString("current_launch_instance_id"))
                    .put("model_id", modelId).put("retired", retired)
                    .put("draft", draft).toString())
            })
        }
    }

    private fun readReceipt(retired: Boolean): JSONObject = JSONObject(receipt.readText()).also {
        assertEquals("Use the modelRun from the preparation receipt", modelId, it.getString("model_id"))
        assertEquals("Run the matching catalog phase first", retired, it.getBoolean("retired"))
    }

    private fun writeReceipt(value: JSONObject, loaded: JSONObject, revision: Long, retired: Boolean) {
        value.put("pid", Process.myPid()).put("launch_id", loaded.getString("current_launch_instance_id"))
            .put("catalog_revision", revision).put("retired", retired)
        receipt.writeText(value.toString())
        instrumentation.sendStatus(0, Bundle().apply { putString("model_draft_receipt", value.toString()) })
    }

    private fun assertSessionUnchanged(old: JSONObject, loaded: JSONObject) {
        assertEquals(old.getString("writer_launch_id"), loaded.getString("writer_launch_instance_id"))
        assertEquals(old.getLong("generation"), loaded.getJSONObject("snapshot").getLong("generation"))
        assertEquals(old.getString("digest"), loaded.getJSONObject("snapshot").getString("session_sha256"))
    }

    private fun assertRestored(old: JSONObject, retired: Boolean) {
        val current = session()
        assertEquals(10, current.getInt("schema_version"))
        assertEquals(old.getString("conversation_id"), current.getString("active_conversation_id"))
        assertEquals(modelId, activeConversation(current)!!.getString("model_id"))
        assertEquals(draft, current.getJSONObject("composer_drafts").getString(draftKey(current)))
        assertEquals(old.getInt("message_count"), messageCount(current))
        val catalog = runtime.providerModels.list()
        assertEquals(old.getLong("catalog_revision"), catalog.getLong("revision"))
        assertEquals(modelName, model(catalog, retired)?.getString("name"))
        assertNull(model(catalog, retired = !retired))
    }

    private fun requireOptIn() {
        assumeTrue("Pass -e modelDraftQa true on an isolated emulator", arguments.getString("modelDraftQa") == "true")
        assertEquals(560, context.resources.displayMetrics.densityDpi)
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { assertEquals(1440, image.width); assertEquals(2560, image.height) } finally { image.recycle() }
    }

    private fun launch(body: () -> Unit) {
        requireOptIn()
        val backend = arguments.getString("backend") ?: "gl"
        require(backend in setOf("auto", "gl", "vulkan"))
        val previous = Os.getenv("WGPU_BACKEND")
        if (backend == "auto") Os.unsetenv("WGPU_BACKEND") else Os.setenv("WGPU_BACKEND", backend, true)
        try {
            ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
                await("The renderer must initialize") { GpuiActivity.nativeIsInitialized() }
                await("The host window must own focus") {
                    var ready = false
                    scenario.onActivity { ready = it.hasWindowFocus() }
                    ready
                }
                awaitEditor(inline = true)
                Thread.sleep(700)
                try { body() } catch (error: Throwable) {
                    capture("model-draft-qa-failure.png")
                    throw error
                }
            }
        } finally {
            if (previous == null) Os.unsetenv("WGPU_BACKEND") else Os.setenv("WGPU_BACKEND", previous, true)
        }
    }

    private fun openProviderEditor() {
        dismissKeyboard()
        tapArgument("picker", 750f, 2300f)
        val providers = runtime.providerModels.list().getJSONArray("providers")
        if ((0 until providers.length()).any { providers.getJSONObject(it).getJSONArray("models").length() > 0 }) {
            tapArgument("modelRow", 700f, 1890f)
        }
        capture("model-draft-qa-models.png")
        tapArgument("add", 650f, 875f)
        capture("model-draft-qa-providers.png")
        tapArgument("provider", 650f, 1220f)
        swipeArgument("editorSwipe", 1100f, 2250f, 1100f, 1100f)
    }

    private fun session(): JSONObject {
        val load = runtime.sessions.load()
        return if (load.optString("status") == "present") JSONObject(load.getString("session_json")) else JSONObject()
    }
    private fun draftKey(value: JSONObject) = value.optString("active_conversation_id").takeUnless {
        it.isEmpty() || it == "null"
    } ?: "new-draft"
    private fun activeConversation(value: JSONObject): JSONObject? {
        val rows = value.optJSONArray("conversations") ?: return null
        return (0 until rows.length()).map(rows::getJSONObject).find { it.optString("id") == draftKey(value) }
    }
    private fun messageCount(value: JSONObject): Int {
        val rows = value.optJSONArray("conversations") ?: return 0
        return (0 until rows.length()).sumOf { rows.getJSONObject(it).getJSONArray("messages").length() }
    }
    private fun provider(value: JSONObject): JSONObject {
        val rows = value.getJSONArray("providers")
        return (0 until rows.length()).map(rows::getJSONObject).first { it.getString("harness_id") == "dsh" }
    }
    private fun model(value: JSONObject, retired: Boolean = false): JSONObject? {
        val rows = provider(value).getJSONArray(if (retired) "retired_models" else "models")
        return (0 until rows.length()).map(rows::getJSONObject).find { it.getString("id") == modelId }
    }

    private fun views(): List<View> {
        fun flatten(view: View): List<View> = listOf(view) + if (view is ViewGroup)
            (0 until view.childCount).flatMap { flatten(view.getChildAt(it)) } else emptyList()
        return WindowInspector.getGlobalWindowViews().flatMap(::flatten).filter {
            it.isAttachedToWindow && it.isShown && it.width > 0 && it.height > 0
        }
    }
    private fun findEditor(inline: Boolean): EditText? {
        var field: EditText? = null
        instrumentation.runOnMainSync {
            field = views().filterIsInstance<EditText>().firstOrNull {
                (it.javaClass.simpleName == "InlineEditText") == inline
            }
        }
        return field
    }
    private fun awaitEditor(inline: Boolean): EditText {
        await("The ${if (inline) "inline" else "manual model"} native editor must be visible") { findEditor(inline) != null }
        return requireNotNull(findEditor(inline))
    }
    private fun awaitManualModelEditor(): EditText {
        val field = awaitEditor(inline = false)
        assertTrue("Only edit the manual model list", nativeLabels().any {
            it == "Model IDs · one per line, optional | name" || it == "模型 ID · 每行一个，可填写 | 名称"
        })
        return field
    }
    private fun finishManualModelEdit() {
        dismissKeyboard()
        tapNativeButton(if (nativeLabels().contains("Done")) "Done" else "完成")
        await("The manual editor must close") { findEditor(inline = false) == null }
        dismissKeyboard()
    }
    private fun readText(field: EditText): String {
        var text = ""
        instrumentation.runOnMainSync { text = field.text.toString() }
        return text
    }
    private fun nativeLabels(): List<String> {
        var labels = emptyList<String>()
        instrumentation.runOnMainSync { labels = views().filterIsInstance<TextView>().map { it.text.toString() } }
        return labels
    }
    private fun typeInto(field: EditText, text: String) {
        tapView(field)
        await("The physical touch must focus the native editor") {
            var focused = false
            instrumentation.runOnMainSync { focused = field.hasFocus() && field.hasWindowFocus() }
            focused
        }
        instrumentation.runOnMainSync {
            val connection = requireNotNull(field.onCreateInputConnection(EditorInfo()))
            assertTrue(connection.setSelection(field.text.length, field.text.length))
        }
        instrumentation.sendStringSync(text)
        instrumentation.runOnMainSync {
            assertTrue(requireNotNull(field.onCreateInputConnection(EditorInfo())).finishComposingText())
        }
        Thread.sleep(500)
    }
    private fun dismissKeyboard() {
        instrumentation.runOnMainSync {
            views().filterIsInstance<EditText>().firstOrNull { it.hasFocus() }?.let {
                val input = context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
                input.hideSoftInputFromWindow(it.windowToken, 0)
            }
        }
        Thread.sleep(700)
    }
    private fun tapNativeButton(label: String) {
        var button: View? = null
        await("Native button $label must become enabled after the IME commits") {
            instrumentation.runOnMainSync {
                button = views().filterIsInstance<TextView>().firstOrNull { it.text.toString() == label && it.isClickable && it.isEnabled }
            }
            button != null
        }
        tapView(requireNotNull(button) { "Native button $label must be visible and enabled" })
    }
    private fun tapView(view: View) {
        var x = 0f; var y = 0f
        instrumentation.runOnMainSync {
            val at = IntArray(2); view.getLocationOnScreen(at)
            x = at[0] + view.width / 2f; y = at[1] + view.height / 2f
        }
        touch(x, y, x, y, 80)
    }
    private fun tapArgument(name: String, x: Float, y: Float) {
        val point = arguments.getString(name)?.split(',')?.map(String::toFloat) ?: listOf(x, y)
        require(point.size == 2)
        touch(point[0], point[1], point[0], point[1], 80)
        Thread.sleep(850)
    }
    private fun swipeArgument(name: String, x1: Float, y1: Float, x2: Float, y2: Float) {
        val points = arguments.getString(name)?.split(',')?.map(String::toFloat) ?: listOf(x1, y1, x2, y2)
        require(points.size == 4)
        touch(points[0], points[1], points[2], points[3], 700)
        Thread.sleep(850)
    }
    private fun touch(x1: Float, y1: Float, x2: Float, y2: Float, duration: Long) {
        val start = SystemClock.uptimeMillis()
        val steps = if (x1 == x2 && y1 == y2) 1 else 35
        for (index in 0..steps + 1) {
            val fraction = (index.toFloat() / steps).coerceAtMost(1f)
            val action = when (index) { 0 -> MotionEvent.ACTION_DOWN; steps + 1 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
            val event = MotionEvent.obtain(start, SystemClock.uptimeMillis(), action,
                x1 + (x2 - x1) * fraction, y1 + (y2 - y1) * fraction, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
            if (index <= steps) Thread.sleep(duration / (steps + 1))
        }
    }
    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 20_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(50)
        }
        fail(message)
    }
    private fun capture(name: String) {
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            File(context.cacheDir, name).outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }
}
