package tech.zseven.rish.gpui

import android.graphics.Bitmap
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.gpui.mobile.GpuiActivity
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.TimeUnit

/** Run on an isolated wide emulator so the real sidebar loads the embedded PNG. */
@RunWith(AndroidJUnit4::class)
class DesignRendererSmokeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test fun embeddedAvatarRendersAcrossPauseAndResume() {
        val context = instrumentation.targetContext
        assertTrue("Use a wide emulator for the persistent avatar sidebar", context.resources.configuration.screenWidthDp >= 900)
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            awaitRenderer()
            capture("design-before-pause.png")
            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            awaitRenderer()
            capture("design-after-resume.png")
            scenario.onActivity { assertTrue(!it.isFinishing && !it.isDestroyed) }
        }
    }

    private fun awaitRenderer() {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (!GpuiActivity.nativeIsInitialized() && System.nanoTime() < deadline) Thread.sleep(25)
        assertTrue("The real GPUI renderer must initialize", GpuiActivity.nativeIsInitialized())
        // The PNG is decoded asynchronously after its element first mounts.
        Thread.sleep(2_000)
    }

    private fun capture(name: String) {
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val output = File(instrumentation.targetContext.cacheDir, name)
        output.outputStream().use { stream ->
            assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
        bitmap.recycle()
        assertTrue("Keep a rendered-image artifact for visual inspection", output.length() > 0)
    }
}
