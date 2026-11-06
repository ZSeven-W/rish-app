package tech.zseven.rish

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import tech.zseven.rish.guest.AndroidGuestAssets
import tech.zseven.rish.guest.GuestAssets
import tech.zseven.rish.guest.GuestRuntimeState
import tech.zseven.rish.guest.GuestSessionController
import tech.zseven.rish.guest.RishGuestNative
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The real proof for Android, mirroring the iOS
 * testGuestBootsAndInstallsTreeFromOfflineRepository: boots the bundled kernel
 * and initramfs in the pure-Rust x86_64 interpreter inside the app process,
 * installs tree from the offline apk repository baked into the initramfs, and
 * runs the installed binary. No mock anywhere. The boot is interpreted and
 * slow, so the timeouts are generous.
 *
 * Skips when the host declares no bundled guest runtime. Once the build
 * enables it, a missing JNI library or guest asset is a real failure.
 *
 * Run with one Gradle command after scripts/prepare-rish-android.sh:
 *   ./gradlew :app:connectedDebugAndroidTest -PrishArchitectures=arm64-v8a \
 *       -Pandroid.testInstrumentationRunnerArguments.class=tech.zseven.rish.LocalGuestBootTest
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class LocalGuestBootTest {

    private class Outcome {
        var receipt: Map<String, Any?>? = null
        var code: String? = null
        val done = CountDownLatch(1)
        fun await(seconds: Long): Outcome {
            assertTrue("call did not settle within ${seconds}s", done.await(seconds, TimeUnit.SECONDS))
            return this
        }
    }

    private fun boot(controller: GuestSessionController, memoryMib: Int, seconds: Long): Outcome {
        val outcome = Outcome()
        controller.bootGuest(
            mapOf("schema_version" to 1, "memory_mib" to memoryMib),
            { outcome.receipt = it; outcome.done.countDown() },
            { code, _ -> outcome.code = code; outcome.done.countDown() },
        )
        return outcome.await(seconds)
    }

    private fun exec(controller: GuestSessionController, command: List<String>, seconds: Long): Outcome {
        val outcome = Outcome()
        controller.guestExec(
            mapOf("schema_version" to 1, "command" to command),
            { outcome.receipt = it; outcome.done.countDown() },
            { code, _ -> outcome.code = code; outcome.done.countDown() },
        )
        return outcome.await(seconds)
    }

    private fun shutdown(controller: GuestSessionController): Outcome {
        val outcome = Outcome()
        controller.shutdownGuest { outcome.receipt = it; outcome.done.countDown() }
        return outcome.await(60)
    }

    @Test
    fun guestBootsAndInstallsTreeFromOfflineRepository() {
        assumeTrue("This host does not bundle the optional guest runtime", BuildConfig.RISH_GUEST_RUNTIME_BUNDLED)
        assertTrue("Guest-enabled host must load the staged runtime and JNI shim", RishGuestNative.available)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(RishGuestNative.protocolVersion() > 0)
        GuestRuntimeState.setGuestRuntimeMounted(false)
        val controller = GuestSessionController(AndroidGuestAssets(context), RishGuestNative)

        val booted = boot(controller, 768, 1500)
        assertNull("boot rejected: ${booted.code}", booted.code)
        val receipt = booted.receipt
        assertNotNull("boot returned no receipt", receipt)
        Log.i(TAG, "GUEST_BOOT_RECEIPT $receipt")
        assertEquals("booted", receipt!!["status"])
        assertEquals(GuestAssets.KERNEL_NAME, receipt["kernel"])
        assertEquals(GuestAssets.INITRAMFS_NAME, receipt["initramfs"])
        assertEquals(GuestAssets.KERNEL_SHA256, receipt["kernel_sha256"])
        assertEquals(GuestAssets.INITRAMFS_SHA256, receipt["initramfs_sha256"])
        assertTrue((receipt["boot_ms"] as Long) > 0)
        assertTrue("shared registry must report a mounted guest after boot", GuestRuntimeState.guestRuntimeMounted)

        try {
            // Single-session semantics: a second boot fails closed.
            assertEquals("E_GUEST_ALREADY_BOOTED", boot(controller, 768, 30).code)

            val uname = exec(controller, listOf("uname", "-m"), 300)
            assertNull("uname rejected: ${uname.code}", uname.code)
            Log.i(TAG, "GUEST_UNAME ${uname.receipt}")
            assertEquals(true, uname.receipt!!["ok"])
            assertEquals(0, uname.receipt!!["exit_code"])
            assertTrue("guest must be the interpreted x86_64 machine: ${uname.receipt}", (uname.receipt!!["stdout"] as String).contains("x86_64"))

            // apk add tree against the build-time-baked offline repository: a
            // real guest command resolving musl, verifying the signed index,
            // and installing both packages.
            val apk = exec(controller, listOf("apk", "add", "tree"), 900)
            assertNull("apk add rejected: ${apk.code}", apk.code)
            Log.i(TAG, "GUEST_APK_ADD ${apk.receipt}")
            assertEquals("apk add ok=false: ${apk.receipt}", true, apk.receipt!!["ok"])
            assertEquals("apk add exit code: ${apk.receipt}", 0, apk.receipt!!["exit_code"])
            assertNotNull("exec receipt must carry the guest boot unit count", apk.receipt!!["boot_units"])
            val apkStdout = apk.receipt!!["stdout"] as String
            assertTrue("apk add output must show the tree install: $apkStdout", apkStdout.contains("Installing tree"))
            assertTrue("apk add output must finish with OK: $apkStdout", apkStdout.contains("OK:"))

            val tree = exec(controller, listOf("sh", "-lc", "/usr/bin/tree --version"), 300)
            assertNull("tree exec rejected: ${tree.code}", tree.code)
            assertEquals("tree run ok=false: ${tree.receipt}", true, tree.receipt!!["ok"])
            assertEquals(0, tree.receipt!!["exit_code"])
            assertTrue("tree binary must report its version: ${tree.receipt}", (tree.receipt!!["stdout"] as String).contains("tree v2.3.2"))
        } finally {
            val stopped = shutdown(controller)
            Log.i(TAG, "GUEST_SHUTDOWN ${stopped.receipt}")
            assertEquals("shutdown", stopped.receipt?.get("status"))
            assertFalse(GuestRuntimeState.guestRuntimeMounted)
        }
    }

    private companion object {
        const val TAG = "LocalGuestBootTest"
    }
}
