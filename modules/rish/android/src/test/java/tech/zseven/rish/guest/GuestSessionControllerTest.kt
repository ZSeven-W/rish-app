package tech.zseven.rish.guest

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Mirrors modules/rish/ios/Tests/LocalGuestModuleTests.mm against a fake
 * runtime: validation fails closed, session state is single and serialized,
 * receipts carry names and digests but never paths.
 *
 * Run with one Gradle command:
 *   ./gradlew :app:testDebugUnitTest --tests 'tech.zseven.rish.guest.*'
 */
class GuestSessionControllerTest {

    private class FakeAssets : GuestAssetProvider {
        var failure: GuestRejection? = null
        override fun stage(): StagedGuestAssets {
            failure?.let { throw it }
            return StagedGuestAssets(
                "/data/user/0/app/files/rish-guest/kernel",
                "/data/user/0/app/files/rish-guest/initramfs",
                "/data/user/0/app/files/rish-guest/scratch-root.img",
            )
        }
    }

    private class FakeBackend : GuestSessionBackend {
        val bootGate = CountDownLatch(0)
        var bootHandle = 42L
        var holdBoot: CountDownLatch? = null
        var lastBootRequest: String? = null
        var lastExecRequest: String? = null
        var reply: String? = """{"ok":true,"exit_code":0,"stdout":"hi\n","stderr":"","boot_units":1234}"""
        val freed = ArrayList<Long>()
        val bootCalls = AtomicInteger()

        override fun boot(requestJson: String): Long {
            bootCalls.incrementAndGet()
            lastBootRequest = requestJson
            holdBoot?.await(30, TimeUnit.SECONDS)
            return bootHandle
        }

        override fun exec(handle: Long, requestJson: String): String? {
            lastExecRequest = requestJson
            return reply
        }

        override fun free(handle: Long) {
            freed.add(handle)
        }
    }

    private class Outcome {
        var receipt: Map<String, Any?>? = null
        var code: String? = null
        val done = CountDownLatch(1)
        fun await(seconds: Long = 5): Outcome {
            assertTrue("call did not settle", done.await(seconds, TimeUnit.SECONDS))
            return this
        }
    }

    private fun controller(assets: FakeAssets = FakeAssets(), backend: FakeBackend = FakeBackend()) =
        GuestSessionController(assets, backend)

    private fun boot(controller: GuestSessionController, request: Any?): Outcome {
        val outcome = Outcome()
        controller.bootGuest(request, { outcome.receipt = it; outcome.done.countDown() }, { code, _ -> outcome.code = code; outcome.done.countDown() })
        return outcome
    }

    private fun exec(controller: GuestSessionController, request: Any?): Outcome {
        val outcome = Outcome()
        controller.guestExec(request, { outcome.receipt = it; outcome.done.countDown() }, { code, _ -> outcome.code = code; outcome.done.countDown() })
        return outcome
    }

    private fun shutdown(controller: GuestSessionController): Outcome {
        val outcome = Outcome()
        controller.shutdownGuest { outcome.receipt = it; outcome.done.countDown() }
        return outcome
    }

    private fun bootRequest(memory: Any? = 1024, schema: Any? = 1) = mapOf("schema_version" to schema, "memory_mib" to memory)
    private fun execRequest(command: Any?, schema: Any? = 1) = mapOf("schema_version" to schema, "command" to command)

    @Test
    fun bootRequestValidationFailsClosedAndLeavesTheSessionIdle() {
        val backend = FakeBackend()
        val controller = controller(backend = backend)
        val invalid = listOf<Any?>(
            mapOf("schema_version" to 1),
            mapOf("schema_version" to 1, "memory_mib" to 1024, "extra" to 1),
            bootRequest(schema = 2),
            bootRequest(schema = true),
            bootRequest(memory = "1024"),
            bootRequest(memory = 255),
            bootRequest(memory = 4097),
            bootRequest(memory = -1),
            bootRequest(memory = 1024.5),
            bootRequest(memory = Double.NaN),
            null,
            "boot",
        )
        for (request in invalid) {
            val outcome = boot(controller, request).await()
            assertNull("request must be rejected: $request", outcome.receipt)
            assertEquals("request $request", GuestErrorCodes.INVALID_REQUEST, outcome.code)
        }
        assertEquals(0, backend.bootCalls.get())
        assertEquals("already_idle", shutdown(controller).await().receipt?.get("status"))
    }

    @Test
    fun bridgeStyleDoublesAreAcceptedAsIntegers() {
        val backend = FakeBackend()
        val controller = controller(backend = backend)
        val outcome = boot(controller, hashMapOf("schema_version" to 1.0, "memory_mib" to 512.0)).await()
        assertNull(outcome.code)
        assertEquals(512L, outcome.receipt?.get("memory_mib"))
        val envelope = JSONObject(backend.lastBootRequest!!)
        assertEquals(512, envelope.getInt("memory_mib"))
        assertEquals(0, envelope.getJSONArray("command").length())
        assertEquals(GuestAssets.COMMAND_LINE, envelope.getString("command_line"))
        assertTrue(envelope.getString("kernel_path").endsWith("/kernel"))
    }

    @Test
    fun execBeforeBootFailsClosed() {
        val outcome = exec(controller(), execRequest(listOf("uname", "-a"))).await()
        assertNull(outcome.receipt)
        assertEquals(GuestErrorCodes.NOT_BOOTED, outcome.code)
    }

    @Test
    fun execRequestValidationPrecedesSessionState() {
        val controller = controller()
        val oversizedArg = "a".repeat(5000)
        val invalid = listOf<Any?>(
            emptyMap<String, Any?>(),
            mapOf("schema_version" to 1),
            execRequest(listOf("true"), schema = 2),
            execRequest("uname"),
            execRequest(emptyList<String>()),
            execRequest(listOf(1, 2)),
            execRequest(listOf("", "x")),
            execRequest(listOf("x\u0000y")),
            execRequest(listOf(oversizedArg)),
            execRequest(List(65) { "x" }),
            execRequest(List(20) { "a".repeat(4000) }),
        )
        for (request in invalid) {
            val outcome = exec(controller, request).await()
            assertNull("request must be rejected: $request", outcome.receipt)
            assertEquals("request $request", GuestErrorCodes.INVALID_REQUEST, outcome.code)
        }
    }

    @Test
    fun shutdownWhenIdleIsIdempotent() {
        val controller = controller()
        assertEquals("already_idle", shutdown(controller).await().receipt?.get("status"))
        assertEquals("already_idle", shutdown(controller).await().receipt?.get("status"))
    }

    @Test
    fun bootExecShutdownRoundTripKeepsPathsOutOfReceipts() {
        val backend = FakeBackend()
        val controller = controller(backend = backend)
        GuestRuntimeState.setGuestRuntimeMounted(false)

        val booted = boot(controller, bootRequest()).await()
        assertNull(booted.code)
        val receipt = booted.receipt!!
        assertEquals("booted", receipt["status"])
        assertEquals(GuestAssets.KERNEL_NAME, receipt["kernel"])
        assertEquals(GuestAssets.INITRAMFS_NAME, receipt["initramfs"])
        assertEquals(GuestAssets.KERNEL_SHA256, receipt["kernel_sha256"])
        assertEquals(GuestAssets.INITRAMFS_SHA256, receipt["initramfs_sha256"])
        assertFalse((receipt["kernel"] as String).contains("/"))
        assertTrue(GuestRuntimeState.guestRuntimeMounted)

        val doubleBoot = boot(controller, bootRequest()).await()
        assertEquals(GuestErrorCodes.ALREADY_BOOTED, doubleBoot.code)
        assertEquals(1, backend.bootCalls.get())

        val ran = exec(controller, execRequest(listOf("echo", "hi"))).await()
        assertNull(ran.code)
        val execReceipt = ran.receipt!!
        assertEquals(true, execReceipt["ok"])
        assertEquals(0, execReceipt["exit_code"])
        assertEquals("hi\n", execReceipt["stdout"])
        assertEquals(1234L, execReceipt["boot_units"])
        assertEquals(false, execReceipt["stdout_truncated"])
        assertEquals("""{"command":["echo","hi"]}""", backend.lastExecRequest)

        assertEquals("shutdown", shutdown(controller).await().receipt?.get("status"))
        assertEquals(listOf(42L), backend.freed)
        assertFalse(GuestRuntimeState.guestRuntimeMounted)
        assertEquals(GuestErrorCodes.NOT_BOOTED, exec(controller, execRequest(listOf("true"))).await().code)
    }

    @Test
    fun shutdownDuringBootCancelsTheBootAndFreesTheHandle() {
        val backend = FakeBackend()
        val hold = CountDownLatch(1)
        backend.holdBoot = hold
        val controller = controller(backend = backend)

        val booting = boot(controller, bootRequest())
        // Wait until the boot thread is inside the backend.
        val deadline = System.currentTimeMillis() + 5_000
        while (backend.bootCalls.get() == 0 && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertEquals(1, backend.bootCalls.get())

        assertEquals(GuestErrorCodes.BOOT_IN_PROGRESS, exec(controller, execRequest(listOf("true"))).await().code)
        assertEquals(GuestErrorCodes.BOOT_IN_PROGRESS, boot(controller, bootRequest()).await().code)
        assertEquals("shutdown_scheduled", shutdown(controller).await().receipt?.get("status"))

        hold.countDown()
        booting.await()
        assertEquals(GuestErrorCodes.BOOT_CANCELLED, booting.code)
        assertEquals(listOf(42L), backend.freed)
        assertFalse(GuestRuntimeState.guestRuntimeMounted)
        assertEquals("already_idle", shutdown(controller).await().receipt?.get("status"))
    }

    @Test
    fun bootFailureReturnsToIdle() {
        val backend = FakeBackend()
        backend.bootHandle = 0L
        val controller = controller(backend = backend)
        assertEquals(GuestErrorCodes.BOOT_FAILED, boot(controller, bootRequest()).await().code)
        assertEquals("already_idle", shutdown(controller).await().receipt?.get("status"))
        assertTrue(backend.freed.isEmpty())
    }

    @Test
    fun assetFailuresSurfaceTheirCodesBeforeAnyBoot() {
        val backend = FakeBackend()
        val assets = FakeAssets()
        val controller = controller(assets, backend)
        assets.failure = GuestRejection(GuestErrorCodes.ASSETS_MISSING, "missing")
        assertEquals(GuestErrorCodes.ASSETS_MISSING, boot(controller, bootRequest()).await().code)
        assets.failure = GuestRejection(GuestErrorCodes.ASSET_INTEGRITY, "tampered")
        assertEquals(GuestErrorCodes.ASSET_INTEGRITY, boot(controller, bootRequest()).await().code)
        assertEquals(0, backend.bootCalls.get())
        assertEquals("already_idle", shutdown(controller).await().receipt?.get("status"))
    }

    @Test
    fun execRepliesAreInterpretedLikeIOS() {
        val backend = FakeBackend()
        val controller = controller(backend = backend)
        boot(controller, bootRequest()).await()

        backend.reply = null
        assertEquals(GuestErrorCodes.EXEC_FAILED, exec(controller, execRequest(listOf("true"))).await().code)

        backend.reply = "not json"
        assertEquals(GuestErrorCodes.EXEC_FAILED, exec(controller, execRequest(listOf("true"))).await().code)

        backend.reply = """{"ok":false,"error":"guest agent closed"}"""
        assertEquals(GuestErrorCodes.EXEC_FAILED, exec(controller, execRequest(listOf("true"))).await().code)

        backend.reply = """{"ok":false,"exit_code":3,"stdout":"","stderr":"boom"}"""
        val failed = exec(controller, execRequest(listOf("false"))).await()
        assertNull(failed.code)
        assertEquals(false, failed.receipt?.get("ok"))
        assertEquals(3, failed.receipt?.get("exit_code"))
        assertEquals("boom", failed.receipt?.get("stderr"))
        assertNull(failed.receipt?.get("boot_units"))

        val long = "x".repeat(GuestSessionController.MAXIMUM_STREAM_LENGTH + 10)
        backend.reply = JSONObject().put("ok", true).put("exit_code", 0).put("stdout", long).put("stderr", "").toString()
        val truncated = exec(controller, execRequest(listOf("yes"))).await()
        assertEquals(true, truncated.receipt?.get("stdout_truncated"))
        assertEquals(GuestSessionController.MAXIMUM_STREAM_LENGTH, (truncated.receipt?.get("stdout") as String).length)
        assertEquals(false, truncated.receipt?.get("stderr_truncated"))
    }

    @Test
    fun closeReleasesALiveSession() {
        val backend = FakeBackend()
        val controller = controller(backend = backend)
        boot(controller, bootRequest()).await()
        controller.close()
        assertEquals("already_idle", shutdown(controller).await().receipt?.get("status"))
        assertEquals(listOf(42L), backend.freed)
    }

    /**
     * The runtime makes its own throwaway root disk when the caller names none,
     * and it makes it in Rust's temp_dir(): TMPDIR, or /tmp when that is unset.
     * Inside the 卓易通 compatibility layer TMPDIR is unset and /tmp is not
     * writable, so every boot was refused in 37ms before the guest was touched.
     * Naming the path keeps the runtime out of a directory it may not own.
     */
    @Test
    fun bootRequestNamesARootDiskSoTheRuntimeNeverLooksForATempDirectory() {
        val assets = FakeAssets()
        val backend = FakeBackend()
        val controller = GuestSessionController(assets, backend)
        val outcome = Outcome()
        controller.bootGuest(
            mapOf("schema_version" to 1, "memory_mib" to 256),
            { outcome.receipt = it; outcome.done.countDown() },
            { code, _ -> outcome.code = code; outcome.done.countDown() },
        )
        assertTrue(outcome.done.await(30, TimeUnit.SECONDS))
        assertNull(outcome.code)
        val request = JSONObject(backend.lastBootRequest!!)
        assertEquals("/data/user/0/app/files/rish-guest/scratch-root.img", request.getString("root_disk_path"))
        controller.close()
    }
}
