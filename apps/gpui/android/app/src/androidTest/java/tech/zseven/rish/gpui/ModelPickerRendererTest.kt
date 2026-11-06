package tech.zseven.rish.gpui

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.os.SystemClock
import android.system.Os
import android.view.InputDevice
import android.view.MotionEvent
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.gpui.mobile.GpuiActivity
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Run on an isolated, fresh phone emulator in light mode; never sends a message. */
@RunWith(AndroidJUnit4::class)
class ModelPickerRendererTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test fun emptyModelPickerPaintsAnOpaquePanel() = withRequestedBackend {
        val context = instrumentation.targetContext
        val configuration = context.resources.configuration
        assumeTrue("Use a portrait phone emulator", configuration.screenWidthDp in 360..600 &&
            configuration.orientation == Configuration.ORIENTATION_PORTRAIT)
        assumeTrue("This pixel fixture uses light mode", configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK != Configuration.UI_MODE_NIGHT_YES)

        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            val deadline = SystemClock.uptimeMillis() + 20_000
            while (!GpuiActivity.nativeIsInitialized() && SystemClock.uptimeMillis() < deadline) {
                Thread.sleep(25)
            }
            assertTrue("The renderer must initialize", GpuiActivity.nativeIsInitialized())
            Thread.sleep(1_000)
            val initial = capture("model-picker-before.png")
            // The new-chat model control is centered in the bottom composer row.
            val x = initial.width * 0.52f
            val y = initial.height - 72f * context.resources.displayMetrics.density
            initial.recycle()
            tap(x, y)
            Thread.sleep(1_000)
            var initialTitlePixels = 0
            repeat(5) { frame ->
                if (frame > 0) {
                    scenario.moveToState(Lifecycle.State.CREATED)
                    val stoppedDeadline = SystemClock.uptimeMillis() + 5_000
                    while (GpuiActivity.nativeIsInitialized() && SystemClock.uptimeMillis() < stoppedDeadline) {
                        Thread.sleep(25)
                    }
                    assertTrue("A stopped Activity must not advertise a usable renderer",
                        !GpuiActivity.nativeIsInitialized())
                    scenario.moveToState(Lifecycle.State.RESUMED)
                    Thread.sleep(1_000)
                    assertTrue("A resumed Activity must have a configured surface",
                        GpuiActivity.nativeIsInitialized())
                }
                val bitmap = capture("model-picker-open-$frame.png")
                try {
                    // The lower-center interior is empty even with the no-models hint.
                    // A missed tap leaves the off-white chat here. Vulkan corruption
                    // used to leave striped transparent fragments over that chat.
                    var opaque = 0
                    var sampled = 0
                    for (yPixel in bitmap.height * 72 / 100 until bitmap.height * 84 / 100 step 2) {
                        for (xPixel in bitmap.width * 25 / 100 until bitmap.width * 75 / 100 step 3) {
                            val pixel = bitmap.getPixel(xPixel, yPixel)
                            if (Color.red(pixel) >= 252 && Color.green(pixel) >= 252 &&
                                Color.blue(pixel) >= 252) opaque++
                            sampled++
                        }
                    }
                    val ratio = opaque.toDouble() / sampled
                    assertTrue("Opaque model panel fraction $ratio in frame $frame; inspect saved PNG", ratio > 0.98)
                    // The title also uses the retained glyph atlas. An opaque
                    // panel alone would miss text disappearing after reattach.
                    var titlePixels = 0
                    for (yPixel in bitmap.height * 25 / 100 until bitmap.height * 30 / 100) {
                        for (xPixel in bitmap.width * 25 / 100 until bitmap.width * 75 / 100) {
                            val pixel = bitmap.getPixel(xPixel, yPixel)
                            if (Color.red(pixel) < 96 && Color.green(pixel) < 96 &&
                                Color.blue(pixel) < 96) titlePixels++
                        }
                    }
                    assertTrue("The model picker title must be visible in frame $frame", titlePixels > 200)
                    if (frame == 0) initialTitlePixels = titlePixels
                    else assertTrue("The title glyphs must survive window replacement in frame $frame",
                        titlePixels in (initialTitlePixels * 9 / 10)..(initialTitlePixels * 11 / 10))
                } finally {
                    bitmap.recycle()
                }
                Thread.sleep(250)
            }
        }
    }

    private fun withRequestedBackend(body: () -> Unit) {
        val backend = InstrumentationRegistry.getArguments().getString("backend")
        require(backend == null || backend == "gl" || backend == "vulkan")
        val previous = Os.getenv("WGPU_BACKEND")
        if (backend != null) Os.setenv("WGPU_BACKEND", backend, true)
        try {
            body()
        } finally {
            if (backend != null) {
                if (previous == null) Os.unsetenv("WGPU_BACKEND")
                else Os.setenv("WGPU_BACKEND", previous, true)
            }
        }
    }

    private fun tap(x: Float, y: Float) {
        val down = SystemClock.uptimeMillis()
        for (action in intArrayOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try {
                assertTrue("Touch injection must succeed", instrumentation.uiAutomation.injectInputEvent(event, true))
            } finally {
                event.recycle()
            }
            if (action == MotionEvent.ACTION_DOWN) Thread.sleep(80)
        }
    }

    private fun capture(name: String): Bitmap {
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(instrumentation.targetContext.cacheDir, name).outputStream().use { stream ->
            assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
        return bitmap
    }
}
