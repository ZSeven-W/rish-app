package tech.zseven.rish.gpui

import android.app.Activity
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.ActionMode
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import dev.gpui.mobile.GpuiActivity

/** A bounded, transparent child window; the Activity retains its native surface/input queue. */
internal class NativeInlineWindow(private val activity: Activity, private val field: EditText) {
    private val windows = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val main = Handler(Looper.getMainLooper())
    private var attached = false
    private var disposed = false
    private var visible = false
    private var focusable = false
    private var showIme = false
    private var focusGeneration = 0
    private var clearBack: (() -> Unit)? = null
    private val root = object : FrameLayout(activity) {
        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) { resign(); return true }
            return super.dispatchTouchEvent(event)
        }
        // A raw ViewRoot does not implement text-selection ActionMode. Delegate
        // to the Activity decor, keeping the original editor as the anchor.
        override fun startActionModeForChild(view: View, callback: ActionMode.Callback, type: Int): ActionMode? =
            (activity.window.decorView as ViewGroup).startActionModeForChild(view, callback, type)
        override fun startActionModeForChild(view: View, callback: ActionMode.Callback): ActionMode? =
            (activity.window.decorView as ViewGroup).startActionModeForChild(view, callback)
    }.apply { addView(field, FrameLayout.LayoutParams(-1, -1)) }
    private val params = WindowManager.LayoutParams(1, 1,
        WindowManager.LayoutParams.TYPE_APPLICATION_PANEL,
        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT).apply {
        gravity = Gravity.TOP or Gravity.LEFT
        softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
        dimAmount = 0f
        windowAnimations = 0
        title = "Rish inline composer"
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    init {
        field.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { requestFocus(); false }
                MotionEvent.ACTION_OUTSIDE -> { resign(); true }
                else -> false
            }
        }
    }

    fun place(frame: InlineComposerFrame, shown: Boolean) {
        if (disposed) return
        val previous = listOf(params.x, params.y, params.width, params.height, params.flags)
        visible = shown && frame.width > 0 && frame.height > 0
        if (!visible) resign()
        root.visibility = if (visible) View.VISIBLE else View.INVISIBLE
        field.visibility = if (visible) View.VISIBLE else View.INVISIBLE
        params.x = frame.x; params.y = frame.y
        params.width = frame.width.coerceAtLeast(1)
        params.height = frame.height.coerceAtLeast(1)
        if (visible) params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        else params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        if (!attached && visible) {
            params.token = activity.window.decorView.windowToken
                ?: throw BridgeFailure("E_INLINE_COMPOSER_UNAVAILABLE")
            windows.addView(root, params)
            attached = true
        } else if (attached && previous != listOf(params.x, params.y, params.width, params.height, params.flags)) {
            windows.updateViewLayout(root, params)
        }
    }

    fun requestFocus() {
        if (!attached || !visible || disposed || activity.isFinishing || activity.isDestroyed) return
        showIme = true
        if (!focusable) {
            focusable = true
            // Publish before the main window receives its real LostFocus event.
            GpuiActivity.nativeSetEmbeddedInputFocus(true, false)
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
            windows.updateViewLayout(root, params)
        }
        field.requestFocus()
        val generation = ++focusGeneration
        main.postDelayed({
            if (!disposed && generation == focusGeneration && !field.hasWindowFocus()) {
                GpuiActivity.nativeSetEmbeddedInputFocus(false, false)
            }
        }, 500)
        if (field.hasWindowFocus()) windowFocusChanged(true)
    }

    fun windowFocusChanged(focused: Boolean) {
        if (disposed) return
        ++focusGeneration
        GpuiActivity.nativeSetEmbeddedInputFocus(false, focused && focusable && visible)
        if (!focused) { clearBack?.invoke(); clearBack = null; return }
        if (Build.VERSION.SDK_INT >= 33 && clearBack == null) {
            field.findOnBackInvokedDispatcher()?.let { dispatcher ->
                val callback = OnBackInvokedCallback { resign() }
                dispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
                clearBack = { dispatcher.unregisterOnBackInvokedCallback(callback) }
            }
        }
        if (showIme) {
            val generation = focusGeneration
            field.post { showKeyboardWhenReady(generation, 0) }
        }
    }

    private fun showKeyboardWhenReady(generation: Int, attempt: Int) {
        if (disposed || generation != focusGeneration || !visible || !focusable || !showIme ||
            !field.hasFocus() || !field.hasWindowFocus()) return
        if (inputMethod()?.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT) == true) showIme = false
        else if (attempt < 4) main.postDelayed({ showKeyboardWhenReady(generation, attempt + 1) }, 60)
    }

    fun resign() {
        showIme = false
        ++focusGeneration
        clearBack?.invoke(); clearBack = null
        if (attached && field.hasFocus()) inputMethod()?.hideSoftInputFromWindow(field.windowToken, 0)
        field.clearFocus()
        if (focusable) {
            focusable = false
            params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            if (attached && !disposed) windows.updateViewLayout(root, params)
        }
        GpuiActivity.nativeSetEmbeddedInputFocus(false, false)
    }

    fun dispose() {
        if (disposed) return
        resign()
        disposed = true
        field.setOnTouchListener(null)
        if (attached) { windows.removeViewImmediate(root); attached = false }
    }

    private fun inputMethod() = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
}
