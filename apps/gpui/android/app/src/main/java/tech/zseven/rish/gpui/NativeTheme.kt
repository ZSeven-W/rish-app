package tech.zseven.rish.gpui

import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

/** Shares the GPUI palette without changing native input or bridge semantics. */
internal data class NativePalette(
    val dark: Boolean, val canvas: Int, val panel: Int, val surface: Int,
    val raised: Int, val line: Int, val text: Int, val muted: Int, val accent: Int,
) {
    val onAccent: Int get() = if (dark) 0xff242722.toInt() else Color.WHITE
    val error: Int get() = if (dark) 0xffffaaa5.toInt() else 0xffb93b32.toInt()
}

internal object NativeTheme {
    fun dp(context: Context, value: Int) = (value * context.resources.displayMetrics.density).toInt()
    fun palette(context: Context, appearance: String? = null): NativePalette {
        val dark = appearance?.let { it == "dark" }
            ?: (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES)
        fun color(value: String) = Color.parseColor("#$value")
        return if (dark) NativePalette(true, color("151715"), color("20231F"), color("1B1E1A"),
            color("2B3029"), color("373E34"), color("EDF0E9"), color("A4AE9D"), color("E9EEE3"))
        else NativePalette(false, color("F8F8F6"), Color.WHITE, color("F0F1EE"), color("E8EAE5"),
            color("E1E4DE"), color("242722"), color("71766D"), color("272B25"))
    }
    fun context(activity: Activity, palette: NativePalette): Context = ContextThemeWrapper(activity,
        if (palette.dark) android.R.style.Theme_Material_NoActionBar else android.R.style.Theme_Material_Light_NoActionBar)
    fun shape(context: Context, fill: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
        cornerRadius = dp(context, radius).toFloat()
        setColor(fill)
        stroke?.let { setStroke(dp(context, 1), it) }
    }
    fun field(field: EditText, palette: NativePalette) = field.apply {
        textSize = 16f
        minHeight = dp(context, 52)
        setTextColor(palette.text)
        setHintTextColor(palette.muted)
        selection(this, palette)
        setPadding(dp(context, 14), dp(context, 13), dp(context, 14), dp(context, 13))
        background = StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), shape(context, palette.panel, 12, palette.muted))
            addState(intArrayOf(), shape(context, palette.surface, 12, palette.line))
        }
    }
    fun selection(field: EditText, palette: NativePalette) {
        field.highlightColor = (palette.accent and 0x00ffffff) or 0x33000000
        if (Build.VERSION.SDK_INT >= 29) {
            field.textCursorDrawable?.setTint(palette.accent)
            field.textSelectHandleLeft?.setTint(palette.accent)
            field.textSelectHandleRight?.setTint(palette.accent)
            field.textSelectHandle?.setTint(palette.accent)
        }
    }
    fun button(context: Context, palette: NativePalette, value: String, primary: Boolean = false) = Button(context).apply {
        text = value
        textSize = 15f
        isAllCaps = false
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        minHeight = dp(context, 48)
        minimumHeight = dp(context, 48)
        minWidth = dp(context, 64)
        minimumWidth = dp(context, 64)
        setPadding(dp(context, 16), 0, dp(context, 16), 0)
        stateListAnimator = null
        setTextColor(ColorStateList(arrayOf(intArrayOf(android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(if (primary) palette.onAccent else palette.text, palette.muted)))
        background = StateListDrawable().apply {
            addState(intArrayOf(-android.R.attr.state_enabled), shape(context, palette.raised, 12))
            addState(intArrayOf(android.R.attr.state_pressed), shape(context, if (primary) palette.muted else palette.raised, 12))
            addState(intArrayOf(), shape(context, if (primary) palette.accent else Color.TRANSPARENT, 12))
        }
    }
    fun applyWindow(dialog: Dialog, content: View, palette: NativePalette) {
        dialog.window?.let { window ->
            window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
            window.setBackgroundDrawableResource(android.R.color.transparent)
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            window.setDimAmount(0.32f)
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            WindowCompat.setDecorFitsSystemWindows(window, false)
            WindowCompat.getInsetsController(window, content).apply {
                isAppearanceLightStatusBars = !palette.dark
                isAppearanceLightNavigationBars = !palette.dark
            }
        }
    }
    fun styleAlert(dialog: AlertDialog, palette: NativePalette) {
        val context = dialog.context
        dialog.window?.let { window ->
            window.setBackgroundDrawable(shape(context, palette.panel, 28, palette.line))
            val width = context.resources.displayMetrics.widthPixels - dp(context, 32)
            window.setLayout(minOf(width, dp(context, 560)), WindowManager.LayoutParams.WRAP_CONTENT)
        }
        listOf(AlertDialog.BUTTON_NEGATIVE, AlertDialog.BUTTON_POSITIVE).forEach { which ->
            dialog.getButton(which)?.apply {
                minHeight = dp(context, 48)
                isAllCaps = false
                setTextColor(palette.text)
            }
        }
        dialog.listView?.apply {
            minimumHeight = dp(context, 48)
            setBackgroundColor(palette.panel)
        }
    }
}

/** Measures against the current dialog viewport, so Split View and rotation are live. */
internal class NativeBoundedColumn(context: Context, private val maxWidthDp: Int) : LinearLayout(context) {
    init { orientation = VERTICAL }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val available = MeasureSpec.getSize(widthMeasureSpec)
        val bound = minOf(available, NativeTheme.dp(context, maxWidthDp))
        super.onMeasure(MeasureSpec.makeMeasureSpec(bound, MeasureSpec.getMode(widthMeasureSpec)), heightMeasureSpec)
    }
}

/** Width-limited form with a scrollable body and persistent 48 dp actions above the IME. */
internal class NativeFormDialog(
    context: Context, val palette: NativePalette, title: String, cancelLabel: String,
    submitLabel: String, body: View, maxWidthDp: Int = 560,
) : Dialog(context) {
    val submit = NativeTheme.button(context, palette, submitLabel, primary = true)
    val cancel = NativeTheme.button(context, palette, cancelLabel)
    private val frame = FrameLayout(context)
    private val card = NativeBoundedColumn(context, maxWidthDp)

    init {
        setTitle(title)
        val heading = TextView(context).apply {
            text = title
            textSize = 19f
            setTextColor(palette.text)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER_VERTICAL
            maxLines = 2
            setPadding(NativeTheme.dp(context, 20), NativeTheme.dp(context, 12), NativeTheme.dp(context, 8), NativeTheme.dp(context, 12))
        }
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, NativeTheme.dp(context, 4), NativeTheme.dp(context, 8), NativeTheme.dp(context, 4))
            addView(heading, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(cancel)
        }
        val scroll = ScrollView(context).apply { isFillViewport = false; addView(body) }
        val footer = LinearLayout(context).apply {
            setPadding(NativeTheme.dp(context, 20), NativeTheme.dp(context, 16), NativeTheme.dp(context, 20), NativeTheme.dp(context, 20))
            addView(submit, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, NativeTheme.dp(context, 48)))
        }
        card.apply {
            background = NativeTheme.shape(context, palette.panel, 28, palette.line)
            clipToOutline = true
            isClickable = true
            addView(header)
            addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(footer)
        }
        frame.addView(card, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        frame.setOnClickListener { cancel() }
        cancel.setOnClickListener { cancel() }
        setContentView(frame)
        ViewCompat.setOnApplyWindowInsetsListener(frame) { view, insets ->
            val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.ime())
            val gutter = NativeTheme.dp(context, 12)
            view.setPadding(safe.left + gutter, safe.top + gutter, safe.right + gutter, safe.bottom + gutter)
            insets
        }
    }
    override fun onStart() {
        super.onStart()
        NativeTheme.applyWindow(this, frame, palette)
        ViewCompat.requestApplyInsets(frame)
    }
}
