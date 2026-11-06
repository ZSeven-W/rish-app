package tech.zseven.rish.gpui

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.text.Editable
import android.text.InputType
import android.text.SpanWatcher
import android.text.Spannable
import android.text.Spanned
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONArray
import java.util.concurrent.atomic.AtomicBoolean

/** Native IME editing only. The caller retains all filesystem authority. */
internal object NativeFileEditor {
    private val dialogs = mutableMapOf<Activity, Dialog>()

    fun dismiss(activity: Activity) { dialogs.remove(activity)?.cancel() }

    fun present(activity: Activity?, args: JSONArray, result: (String?) -> Unit) {
        val screen = activity?.takeUnless { it.isFinishing || it.isDestroyed }
            ?: throw BridgeFailure("E_NATIVE_UI")
        val options = FileEditorOptions.parse(args)
        dismiss(screen)
        val palette = NativeTheme.palette(screen, options.appearance)
        val context = NativeTheme.context(screen, palette)
        val primary = palette.text
        val completion = FileEditorCompletion(result)
        val cancel = NativeTheme.button(context, palette, options.cancelLabel)
        val save = NativeTheme.button(context, palette, options.saveLabel, primary = true)
        val title = TextView(context).apply {
            text = options.title
            setTextColor(primary)
            textSize = 16f
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            maxLines = 2
            setPadding(dp(context, 8), 0, dp(context, 8), 0)
        }
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(context, 12), dp(context, 8), dp(context, 12), dp(context, 8))
            addView(cancel, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(context, 48)))
            addView(title, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
            addView(save, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(context, 48)))
        }
        val error = TextView(context).apply {
            text = options.tooLongMessage
            textSize = 13f
            setTextColor(palette.error)
            setPadding(dp(context, 20), dp(context, 8), dp(context, 20), dp(context, 8))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            visibility = View.GONE
        }
        val field = EditText(context).apply {
            id = View.generateViewId()
            contentDescription = options.title
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
            gravity = Gravity.TOP or Gravity.START
            typeface = Typeface.MONOSPACE
            textSize = 15f
            setTextColor(primary)
            NativeTheme.selection(this, palette)
            setLineSpacing(dp(context, 4).toFloat(), 1f)
            setBackgroundColor(Color.TRANSPARENT)
            setPadding(dp(context, 20), dp(context, 16), dp(context, 20), dp(context, 20))
            setAutofillHints(null)
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            isVerticalScrollBarEnabled = true
            setText(options.initialText)
            setSelection(0)
        }
        val content = NativeBoundedColumn(context, 960).apply {
            setBackgroundColor(palette.panel)
            addView(header, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(context, 64)))
            addView(View(context).apply { setBackgroundColor(palette.line) },
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(context, 1)))
            addView(error)
            addView(field, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        val frame = FrameLayout(context).apply {
            setBackgroundColor(palette.canvas)
            addView(content, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        }
        val dialog = Dialog(context).apply { setContentView(frame) }
        var pendingRefresh = false
        fun validation(): FileEditorValidation = FileEditorValidation.evaluate(field.text.toString(), options.maxBytes,
            BaseInputConnection.getComposingSpanStart(field.text) >= 0 ||
                BaseInputConnection.getComposingSpanEnd(field.text) >= 0)
        fun refresh() {
            val state = validation()
            save.isEnabled = state.canSave
            error.visibility = if (state.tooLong) View.VISIBLE else View.GONE
        }
        fun scheduleRefresh() {
            save.isEnabled = false
            if (pendingRefresh || completion.finished) return
            pendingRefresh = true
            // An IME can change only spans when committing. Inspect the final
            // text and span state on the next turn, without ending composition.
            field.post { pendingRefresh = false; if (!completion.finished) refresh() }
        }
        val watcher = object : TextWatcher, SpanWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) = scheduleRefresh()
            override fun onSpanAdded(text: Spannable?, what: Any?, start: Int, end: Int) = scheduleRefresh()
            override fun onSpanRemoved(text: Spannable?, what: Any?, start: Int, end: Int) = scheduleRefresh()
            override fun onSpanChanged(text: Spannable?, what: Any?, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) = scheduleRefresh()
        }
        field.addTextChangedListener(watcher)
        field.text.setSpan(watcher, 0, field.text.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        cancel.setOnClickListener { dialog.cancel() }
        save.setOnClickListener {
            if (!validation().canSave) { refresh(); return@setOnClickListener }
            try { completion.finish(field.text.toString()) } finally { dialog.dismiss() }
        }
        dialog.setOnCancelListener { completion.finish(null) }
        dialog.setOnDismissListener {
            if (dialogs[screen] === dialog) dialogs.remove(screen)
            field.removeTextChangedListener(watcher)
            field.text.removeSpan(watcher)
            completion.finish(null)
        }
        dialog.setOnShowListener {
            NativeTheme.applyWindow(dialog, frame, palette)
            ViewCompat.setOnApplyWindowInsetsListener(frame) { view, insets ->
                val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
                    or WindowInsetsCompat.Type.ime())
                val wide = view.width - safe.left - safe.right >= dp(context, 760)
                val gutter = if (wide) dp(context, 24) else 0
                view.setPadding(safe.left + gutter, safe.top + gutter, safe.right + gutter, safe.bottom + gutter)
                content.background = NativeTheme.shape(context, palette.panel, if (wide) 18 else 0,
                    if (wide) palette.line else null)
                content.clipToOutline = wide
                insets
            }
            frame.addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
                if (right - left != oldRight - oldLeft) ViewCompat.requestApplyInsets(frame)
            }
            ViewCompat.requestApplyInsets(frame)
            refresh()
            field.requestFocus()
        }
        dialogs[screen] = dialog
        try { dialog.show() } catch (failure: Throwable) {
            dialogs.remove(screen)
            field.removeTextChangedListener(watcher)
            field.text.removeSpan(watcher)
            throw failure
        }
    }

    private fun dp(context: Context, value: Int): Int = (value * context.resources.displayMetrics.density).toInt()

}

internal data class FileEditorOptions(
    val initialText: String, val title: String, val appearance: String, val saveLabel: String,
    val cancelLabel: String, val maxBytes: Int, val tooLongMessage: String,
) {
    companion object {
        private val stringKeys = setOf("initial_text", "title", "appearance", "save_label", "cancel_label", "too_long_message")
        private val keys = stringKeys + "max_bytes"

        fun parse(args: JSONArray): FileEditorOptions {
            if (args.length() != 1) throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            val source = args.optJSONObject(0) ?: throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            val limit = source.opt("max_bytes")
            if (source.keys().asSequence().toSet() != keys || stringKeys.any { source.opt(it) !is String } ||
                source.optString("appearance") !in setOf("light", "dark") ||
                (limit !is Int && limit !is Long) || (limit as Number).toLong() !in 1L..262144L)
                throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            val initialText = source.getString("initial_text")
            if (!FileEditorValidation.evaluate(initialText, limit.toInt()).canSave)
                throw BridgeFailure("E_BRIDGE_ARGUMENTS")
            return FileEditorOptions(initialText, source.getString("title"),
                source.getString("appearance"), source.getString("save_label"), source.getString("cancel_label"),
                limit.toInt(), source.getString("too_long_message"))
        }
    }
}

internal data class FileEditorValidation(val canSave: Boolean, val tooLong: Boolean) {
    companion object {
        fun evaluate(text: String, maxBytes: Int, composing: Boolean = false): FileEditorValidation {
            if (composing) return FileEditorValidation(false, false)
            // UTF-8 encoding otherwise replaces an unpaired UTF-16 surrogate
            // with '?', violating the promise to save the exact editor text.
            if (!wellFormedUtf16(text)) return FileEditorValidation(false, false)
            val tooLong = text.toByteArray(Charsets.UTF_8).size > maxBytes
            return FileEditorValidation(!tooLong, tooLong)
        }

        private fun wellFormedUtf16(text: String): Boolean {
            var index = 0
            while (index < text.length) {
                val value = text[index++]
                if (Character.isHighSurrogate(value)) {
                    if (index == text.length || !Character.isLowSurrogate(text[index++])) return false
                } else if (Character.isLowSurrogate(value)) return false
            }
            return true
        }
    }
}

internal class FileEditorCompletion(private val result: (String?) -> Unit) {
    private val settled = AtomicBoolean(false)
    val finished: Boolean get() = settled.get()
    fun finish(value: String?) { if (settled.compareAndSet(false, true)) result(value) }
}
