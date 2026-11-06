package tech.zseven.rish.gpui

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.SpanWatcher
import android.text.Spannable
import android.text.Spanned
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewTreeObserver
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Native text in a bounded Activity child window over GPUI's native surface. */
internal object NativeInlineComposer {
    private val main = Handler(Looper.getMainLooper())
    private var attached = WeakReference<Activity>(null)
    private var current: Host? = null
    private var lastClosed: JSONObject? = null
    private val retiredSessions = mutableSetOf<String>()
    private var registeredApplication: Application? = null
    private var resumed = false
    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityPaused(activity: Activity) {
            if (attached.get() === activity) { resumed = false; closeCurrent() }
        }
        override fun onActivityDestroyed(activity: Activity) { detach(activity) }
        override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityResumed(activity: Activity) { if (attached.get() === activity) resumed = true }
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    }

    fun attach(activity: Activity) {
        if (attached.get() !== activity) { resumed = false; closeCurrent() }
        attached = WeakReference(activity)
        if (registeredApplication !== activity.application) {
            registeredApplication?.unregisterActivityLifecycleCallbacks(lifecycle)
            registeredApplication = activity.application
            activity.application.registerActivityLifecycleCallbacks(lifecycle)
        }
    }
    fun detach(activity: Activity) {
        if (attached.get() !== activity) return
        resumed = false
        closeCurrent()
        attached.clear()
        registeredApplication?.unregisterActivityLifecycleCallbacks(lifecycle)
        registeredApplication = null
    }

    fun sync(activity: Activity?, args: JSONArray): JSONObject {
        val request = InlineSyncRequest.parse(args)
        val screen = activity?.takeUnless { it.isFinishing || it.isDestroyed }
            ?: throw BridgeFailure("E_INLINE_COMPOSER_UNAVAILABLE")
        if (!resumed || screen !== attached.get()) {
            android.util.Log.w("RishInlineComposer", "sync ${request.sessionId} refused: foreground=$resumed owner=${screen === attached.get()}")
            throw BridgeFailure("E_INLINE_COMPOSER_UNAVAILABLE")
        }
        if (current?.sessionId != request.sessionId) {
            // Closed native counters are terminal; reopening requires a fresh session ID.
            if (request.sessionId in retiredSessions) {
                android.util.Log.w("RishInlineComposer", "sync ${request.sessionId} refused: retired")
                throw BridgeFailure("E_INLINE_COMPOSER_STALE")
            }
            val surface = screen.window.decorView.takeIf { it.isAttachedToWindow && it.width > 0 && it.height > 0 }
                ?: throw BridgeFailure("E_INLINE_COMPOSER_UNAVAILABLE")
            val hadFocus = current?.focused() == true
            closeCurrent()
            current = Host(screen, surface, request.sessionId)
            lastClosed = null
            return current!!.sync(request, hadFocus)
        }
        return current!!.sync(request)
    }
    fun snapshot(args: JSONArray): JSONObject {
        val request = InlineSessionRequest.parse(args)
        val host = matching(request.sessionId)
        return host?.snapshot() ?: closed(request.sessionId)
    }
    fun wait(args: JSONArray, result: (JSONObject) -> Unit) {
        val request = InlineWaitRequest.parse(args)
        val host = matching(request.sessionId)
        if (host == null) result(closed(request.sessionId))
        else {
            host.snapshot() // Flush pending IME spans before deciding whether this waiter is current.
            host.state.wait(request.afterRevision, result)
        }
    }
    fun clearIfUnchanged(args: JSONArray): JSONObject {
        val request = InlineClearRequest.parse(args)
        val host = matching(request.sessionId)
        return host?.clearIfUnchanged(request) ?: JSONObject().put("cleared", false).put("snapshot", closed(request.sessionId))
    }
    fun close(args: JSONArray): JSONObject {
        val request = InlineSessionRequest.parse(args)
        matching(request.sessionId) ?: return closed(request.sessionId)
        return closeCurrent() ?: throw BridgeFailure("E_INLINE_COMPOSER_UNAVAILABLE")
    }
    private fun matching(sessionId: String): Host? {
        val host = current
        if (host != null && host.sessionId != sessionId) throw BridgeFailure("E_INLINE_COMPOSER_STALE")
        return host
    }
    private fun closed(sessionId: String): JSONObject = lastClosed?.takeIf { it.optString("session_id") == sessionId }
        ?: throw BridgeFailure("E_INLINE_COMPOSER_STALE")
    private fun closeCurrent(): JSONObject? {
        val host = current ?: return null
        current = null
        retiredSessions.add(host.sessionId)
        return host.dispose().also { lastClosed = it }
    }
    private class Host(private val activity: Activity, private val surface: View, val sessionId: String) {
        val state = InlineComposerState(sessionId, object : InlineComposerScheduler {
            override fun schedule(delayMs: Long, task: () -> Unit): InlineComposerCancellation {
                val runnable = Runnable(task)
                main.postDelayed(runnable, delayMs)
                return InlineComposerCancellation { main.removeCallbacks(runnable) }
            }
        })
        private var request: InlineSyncRequest? = null
        private var disposed = false
        private var applying = false
        private var scheduled = false
        private var preferredHeight = 80.0
        private val field = InlineEditText(activity).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
            isSingleLine = false
            gravity = Gravity.TOP or Gravity.START
            textSize = 15f
            setLineSpacing(NativeTheme.dp(context, 3).toFloat(), 1f)
            // Match the GPUI absent-editor fallback's vertical text inset.
            setPadding(0, NativeTheme.dp(context, 8), 0, NativeTheme.dp(context, 8))
            setBackgroundColor(Color.TRANSPARENT)
            setHorizontallyScrolling(false)
            isVerticalScrollBarEnabled = true
            setAutofillHints(null)
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            filters = arrayOf(InputFilter { source, start, end, dest, dstart, dend ->
                InlineComposerInput.replacement(source, start, end, dest, dstart, dend)
            })
            visibility = View.INVISIBLE
            tag = sessionId
        }
        private val panel = NativeInlineWindow(activity, field)
        private val watcher = object : TextWatcher, SpanWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) { watchSpans(); schedule() }
            override fun onSpanAdded(text: Spannable?, what: Any?, start: Int, end: Int) { if (what !== this) schedule() }
            override fun onSpanRemoved(text: Spannable?, what: Any?, start: Int, end: Int) { if (what !== this) schedule() }
            override fun onSpanChanged(text: Spannable?, what: Any?, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) { if (what !== this) schedule() }
        }
        private val globalLayout = ViewTreeObserver.OnGlobalLayoutListener {
            if (!disposed) { layout(); flush() }
        }
        private val focusChanged = View.OnFocusChangeListener { _, _ -> schedule() }
        private val fieldLayoutChanged = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> schedule() }

        init {
            // The bounded panel owns only the editor rectangle. NativeActivity
            // keeps its own render surface and input queue for the GPUI canvas.
            field.addTextChangedListener(watcher)
            field.onFocusChangeListener = focusChanged
            field.addOnLayoutChangeListener(fieldLayoutChanged)
            field.changed = { schedule() }
            field.windowFocus = { panel.windowFocusChanged(it) }
            field.dismissFocus = { panel.resign() }
            watchSpans()
            activity.window.decorView.viewTreeObserver.addOnGlobalLayoutListener(globalLayout)
            ViewCompat.setOnApplyWindowInsetsListener(field) { _, value ->
                schedule()
                value // The panel consumes no insets; the Activity retains its own dispatch.
            }
            ViewCompat.setWindowInsetsAnimationCallback(field, object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(value: WindowInsetsCompat, runningAnimations: MutableList<WindowInsetsAnimationCompat>): WindowInsetsCompat {
                    schedule()
                    return value
                }
            })
            ViewCompat.requestApplyInsets(field)
        }
        fun focused() = field.hasFocus() && field.hasWindowFocus() && field.visibility == View.VISIBLE
        fun sync(value: InlineSyncRequest, initialFocus: Boolean = false): JSONObject {
            if (disposed) throw BridgeFailure("E_INLINE_COMPOSER_STALE")
            if (request != null) flush()
            val replace = state.sync(value)
            request = value
            applying = true
            try {
                if (replace) {
                    field.setText(value.text)
                    field.setSelection(field.text.length)
                    watchSpans()
                }
                val palette = NativeTheme.palette(activity, value.appearance)
                field.setTextColor(palette.text)
                field.setHintTextColor(palette.muted)
                NativeTheme.selection(field, palette)
                field.hint = value.placeholder
                field.contentDescription = value.placeholder
                field.visibility = if (value.visible) View.VISIBLE else View.INVISIBLE
                layout()
                if (!value.visible || value.focus == false) resign()
                else if (value.focus == true || (replace && initialFocus)) {
                    panel.requestFocus()
                }
            } finally { applying = false }
            flush()
            return state.snapshot()
        }
        fun snapshot(): JSONObject { flush(); return state.snapshot() }
        fun clearIfUnchanged(value: InlineClearRequest): JSONObject {
            flush()
            val cleared = state.clearIfUnchanged(value.expectedRevision, value.textRevision)
            if (cleared) {
                applying = true
                try {
                    field.setText("")
                    field.setSelection(0)
                    watchSpans()
                } finally { applying = false }
                flush()
            }
            return JSONObject().put("cleared", cleared).put("snapshot", state.snapshot())
        }
        fun dispose(): JSONObject {
            flush()
            // Mark terminal before clearFocus/removeView can produce callbacks.
            val final = state.close()
            disposed = true
            resign()
            field.changed = null
            field.windowFocus = null
            field.dismissFocus = null
            field.onFocusChangeListener = null
            field.removeOnLayoutChangeListener(fieldLayoutChanged)
            field.removeTextChangedListener(watcher)
            field.text.removeSpan(watcher)
            val observer = activity.window.decorView.viewTreeObserver
            if (observer.isAlive) observer.removeOnGlobalLayoutListener(globalLayout)
            ViewCompat.setOnApplyWindowInsetsListener(field, null)
            ViewCompat.setWindowInsetsAnimationCallback(field, null)
            panel.dispose()
            return final
        }
        private fun watchSpans() {
            if (field.text.getSpanStart(watcher) < 0) field.text.setSpan(watcher, 0, field.text.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
        private fun schedule() {
            if (disposed || applying || scheduled) return
            scheduled = true
            field.post { scheduled = false; if (!disposed) flush() }
        }
        private fun flush() {
            if (disposed || applying) return
            val value = request ?: return
            val marked = BaseInputConnection.getComposingSpanStart(field.text) >= 0 || BaseInputConnection.getComposingSpanEnd(field.text) >= 0
            if (field.width > 0) {
                val pixelHeight = (field.layout?.height ?: field.lineHeight) + field.totalPaddingTop + field.totalPaddingBottom
                preferredHeight = ceil(pixelHeight / value.scale).coerceIn(80.0, 168.0)
            }
            state.observe(field.text.toString(), marked, focused(), keyboardBottom(value), preferredHeight)
        }
        private fun layout() {
            val value = request ?: return
            if (!surface.isAttachedToWindow) return
            // TYPE_APPLICATION_PANEL is relative to the attached Activity
            // window, including split-screen/freeform origins on API 26+.
            val frame = InlineComposerGeometry.frame(value.rect, value.scale, 0.0, 0.0,
                surface.width.toDouble(), surface.height.toDouble(), 0.0, 0.0)
            panel.place(frame, value.visible)
        }
        private fun keyboardBottom(value: InlineSyncRequest): Double {
            if (!focused()) return 0.0
            // A bounded child window receives panel-relative IME insets. Read
            // the Activity root to keep the overlap in GPUI viewport coordinates.
            val currentInsets = ViewCompat.getRootWindowInsets(surface) ?: return 0.0
            val ime = currentInsets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val bars = currentInsets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
            if (!currentInsets.isVisible(WindowInsetsCompat.Type.ime()) || ime <= bars) return 0.0
            val origin = IntArray(2).also(surface::getLocationOnScreen)
            val keyboardTop = if (Build.VERSION.SDK_INT >= 30) {
                activity.windowManager.currentWindowMetrics.bounds.bottom - ime
            } else {
                // On older Android a resized surface already ends at this frame.
                Rect().also(surface::getWindowVisibleDisplayFrame).bottom
            }
            return InlineComposerGeometry.keyboardBottom(origin[1] + surface.height.toDouble(), keyboardTop.toDouble(),
                value.viewport[1], value.scale, focused = true)
        }
        private fun resign() = panel.resign()
    }
}

private class InlineEditText(context: Context) : EditText(context) {
    var changed: (() -> Unit)? = null
    var windowFocus: ((Boolean) -> Unit)? = null
    var dismissFocus: (() -> Unit)? = null
    override fun onSelectionChanged(start: Int, end: Int) { super.onSelectionChanged(start, end); changed?.invoke() }
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        windowFocus?.invoke(hasWindowFocus)
        changed?.invoke()
    }
    override fun onKeyPreIme(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_ESCAPE) {
            if (event.action == KeyEvent.ACTION_UP) dismissFocus?.invoke()
            return true
        }
        return super.onKeyPreIme(keyCode, event)
    }
}

internal data class InlineComposerFrame(val x: Int, val y: Int, val width: Int, val height: Int)
internal object InlineComposerGeometry {
    fun frame(rect: List<Double>, scale: Double, surfaceX: Double, surfaceY: Double, surfaceWidth: Double,
              surfaceHeight: Double, parentX: Double, parentY: Double): InlineComposerFrame {
        val x = (rect[0] * scale).coerceIn(0.0, surfaceWidth)
        val y = (rect[1] * scale).coerceIn(0.0, surfaceHeight)
        val right = ((rect[0] + rect[2]) * scale).coerceIn(0.0, surfaceWidth)
        val bottom = ((rect[1] + rect[3]) * scale).coerceIn(0.0, surfaceHeight)
        return InlineComposerFrame((surfaceX - parentX + x).roundToInt(), (surfaceY - parentY + y).roundToInt(),
            max(0.0, right - x).roundToInt(), max(0.0, bottom - y).roundToInt())
    }
    fun keyboardBottom(surfaceBottom: Double, keyboardTop: Double, viewportHeight: Double, scale: Double, focused: Boolean): Double =
        if (!focused) 0.0 else min(viewportHeight, max(0.0, surfaceBottom - keyboardTop) / scale)
}

/** Rejected replacements must retain both the selected text and its native spans. */
internal object InlineComposerInput {
    fun replacement(source: CharSequence, start: Int, end: Int, dest: CharSequence, dstart: Int, dend: Int): CharSequence? {
        val candidate = dest.subSequence(0, dstart).toString() + source.subSequence(start, end) + dest.subSequence(dend, dest.length)
        return try { InlineComposerProtocol.text(candidate); null }
        catch (_: BridgeFailure) { dest.subSequence(dstart, dend) }
    }
}
