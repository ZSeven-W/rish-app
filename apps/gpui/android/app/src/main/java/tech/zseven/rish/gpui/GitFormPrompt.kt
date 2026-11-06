package tech.zseven.rish.gpui

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.text.Editable
import android.text.InputType
import android.text.SpanWatcher
import android.text.Spannable
import android.text.Spanned
import android.text.TextWatcher
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject

/** Ordinary Git metadata only. Authentication remains in the separate native credential prompt. */
internal object GitFormPrompt {
    private val dialogs = mutableMapOf<Activity, Dialog>()
    fun dismiss(activity: Activity) { dialogs.remove(activity)?.cancel() }

    fun present(activity: Activity?, args: JSONArray, result: (JSONObject?) -> Unit) {
        val screen = activity?.takeUnless { it.isFinishing || it.isDestroyed } ?: throw BridgeFailure("E_NATIVE_UI")
        val options = GitFormOptions.parse(args)
        dismiss(screen)
        val palette = NativeTheme.palette(screen, options.appearance)
        val context = NativeTheme.context(screen, palette)
        val secondary = palette.muted
        val form = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 20), 0, dp(context, 20), dp(context, 8))
        }
        val fields = options.fields.mapIndexed { index, spec ->
            val field = EditText(context).apply {
                id = View.generateViewId()
                inputType = InputType.TYPE_CLASS_TEXT or when (spec.key) {
                    "url" -> InputType.TYPE_TEXT_VARIATION_URI
                    "author_email" -> InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                    else -> InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                }
                isSingleLine = true
                imeOptions = (if (index == options.fields.lastIndex) EditorInfo.IME_ACTION_DONE else EditorInfo.IME_ACTION_NEXT) or
                    EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
                NativeTheme.field(this, palette)
                hint = spec.placeholder
                setAutofillHints(null)
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
                setText(spec.value)
                setSelection(text.length)
            }
            form.addView(TextView(context).apply {
                text = spec.label
                textSize = 13f
                setTextColor(secondary)
                labelFor = field.id
                setPadding(0, dp(context, 12), 0, dp(context, 7))
            })
            form.addView(field, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            field
        }
        form.addView(TextView(context).apply {
            text = options.hint
            textSize = 13f
            setTextColor(secondary)
            setPadding(0, dp(context, 12), 0, 0)
        })
        val error = TextView(context).apply {
            text = options.invalidMessage
            textSize = 13f
            setTextColor(palette.error)
            setPadding(0, dp(context, 8), 0, 0)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            visibility = View.GONE
        }
        form.addView(error)
        val completion = GitFormCompletion(result)
        val dialog = NativeFormDialog(context, palette, options.title, options.cancelLabel, options.submitLabel, form)
        dialog.setOnCancelListener { completion.finish(null) }
        var edited = false
        var attempted = false
        var scheduled = false
        fun composing() = fields.any { BaseInputConnection.getComposingSpanStart(it.text) >= 0 || BaseInputConnection.getComposingSpanEnd(it.text) >= 0 }
        fun value() = GitFormValidation.evaluate(options.kind, fields.map { it.text.toString() }, composing())
        fun refresh() {
            val valid = value() != null
            dialog.submit.isEnabled = valid
            val filled = fields.all { it.text.toString().isNotBlank() }
            error.visibility = if ((attempted || (edited && filled)) && !valid && !composing()) View.VISIBLE else View.GONE
        }
        fun scheduleRefresh() {
            if (scheduled || completion.finished) return
            scheduled = true
            form.post { scheduled = false; if (!completion.finished) refresh() }
        }
        val watcher = object : TextWatcher, SpanWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) { edited = true; scheduleRefresh() }
            override fun onSpanAdded(text: Spannable?, what: Any?, start: Int, end: Int) = scheduleRefresh()
            override fun onSpanRemoved(text: Spannable?, what: Any?, start: Int, end: Int) = scheduleRefresh()
            override fun onSpanChanged(text: Spannable?, what: Any?, oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) = scheduleRefresh()
        }
        fun submit() {
            val accepted = value()
            if (accepted == null) { attempted = true; refresh(); return }
            try { completion.finish(accepted) } finally { dialog.dismiss() }
        }
        fields.forEachIndexed { index, field ->
            field.addTextChangedListener(watcher)
            field.text.setSpan(watcher, 0, field.text.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
            field.setOnEditorActionListener { _, action, key ->
                if (action == EditorInfo.IME_ACTION_DONE || action == EditorInfo.IME_ACTION_NEXT || key?.keyCode == KeyEvent.KEYCODE_ENTER) {
                    if (!composing() && (key == null || key.action == KeyEvent.ACTION_UP)) {
                        if (index < fields.lastIndex) fields[index + 1].requestFocus() else submit()
                    }
                    true
                } else false
            }
        }
        dialog.setOnDismissListener {
            if (dialogs[screen] === dialog) dialogs.remove(screen)
            fields.forEach { it.removeTextChangedListener(watcher); it.text.removeSpan(watcher) }
            completion.finish(null)
        }
        dialog.setOnShowListener {
            dialog.submit.setOnClickListener { submit() }
            refresh()
            fields.first().requestFocus()
            dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        dialogs[screen] = dialog
        try { dialog.show() } catch (failure: Throwable) { dialogs.remove(screen); throw failure }
    }

    private fun dp(context: Context, value: Int) = (value * context.resources.displayMetrics.density).toInt()

}
