package tech.zseven.rish

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidSubscriptionAuthProcessFactory
import tech.zseven.rish.runtime.BoundedCodexProbeCommandRunner
import tech.zseven.rish.runtime.CodexOfflineProbe
import tech.zseven.rish.runtime.CodexOfflineProbeService

/** Exercises offline commands and two fresh stdio handshakes under the app UID. */
@RunWith(AndroidJUnit4::class)
class AndroidCodexOfflineProbeTest {
    private val context = ApplicationProvider.getApplicationContext<android.app.Application>()

    @Test
    fun packagedCodexSupportsOfflineCommandsWithoutEnablingTaskExecution() {
        assumeTrue("The dedicated Codex probe package is not bundled", BuildConfig.RISH_CODEX_PROBE_BUNDLED)
        assertFalse("The legacy authentication probe must remain disabled", BuildConfig.RISH_OFFICIAL_CLI_ENABLED)
        assertTrue("The pinned Codex package requires arm64-v8a", Build.SUPPORTED_ABIS.contains("arm64-v8a"))
        assertNoActiveNetwork("before_package_checks")

        val requestId = UUID.randomUUID().toString()
        val probe = probeIntent(requestId)
        val service = context.packageManager.resolveService(probe, 0)
        assertNotNull("Codex probe builds must register their internal service", service)
        assertFalse("The offline probe service must not be exported", service!!.serviceInfo.exported)

        val nativeDirectory = File(context.applicationInfo.nativeLibraryDir)
        val binary = File(nativeDirectory, "libcodex.so")
        assertTrue("Codex must be extracted into nativeLibraryDir", binary.isFile)
        assertFalse("The Codex-only package must not include Claude", File(nativeDirectory, "libclaude_code.so").exists())
        assertFalse("The static Codex package must not include a musl loader", File(nativeDirectory, "libmusl_loader.so").exists())
        val authentication = AndroidSubscriptionAuthProcessFactory(context)
        assertFalse("Probe-only Codex bytes must not enable production authentication", authentication.available("codex"))
        assertFalse("The probe package must not enable Claude authentication", authentication.available("claude-code"))
        val authHome = File(context.cacheDir, "forbidden-codex-auth-$requestId")
        assertFalse("The auth rejection check needs an uncreated home", authHome.exists())
        val rejected = assertThrows(IllegalStateException::class.java) {
            authentication.start("codex", listOf("login", "status"), authHome)
        }
        assertEquals("E_CLI_AUTH_DISABLED", rejected.message)
        assertFalse("Disabled authentication must reject before preparing a home", authHome.exists())
        val manifest = context.assets.open("codex-offline-probe-manifest.json")
            .bufferedReader().use { JSONObject(it.readText()) }
        assertEquals(setOf("schema_version", "target", "selected_engines", "packages"),
            manifest.keys().asSequence().toSet())
        assertEquals(1, manifest.getInt("schema_version"))
        assertEquals("linux-arm64-musl", manifest.getString("target"))
        assertEquals(listOf("codex"), strings(manifest.getJSONArray("selected_engines")))
        assertEquals(setOf("codex"), manifest.getJSONObject("packages").keys().asSequence().toSet())
        val codex = manifest.getJSONObject("packages").getJSONObject("codex")
        assertEquals("@openai/codex", codex.getString("name"))
        assertEquals("0.153.4-linux-arm64", codex.getString("version"))
        assertEquals("libcodex.so", codex.getString("output"))
        assertEquals("The static package must declare a Boolean false loader dependency", false,
            codex.get("requires_musl_loader"))
        val expectedHash = codex.getString("binary_sha256")
        assertTrue("The package receipt needs a SHA-256", Regex("[0-9a-f]{64}").matches(expectedHash))
        assertEquals("APK packaging must preserve the verified binary bytes", expectedHash, sha256(binary))

        // A completed, reaped process and removed home must precede a second
        // UUID. Neither request may reuse a live server or previous CLI state.
        val requestIds = listOf(requestId, UUID.randomUUID().toString())
        assertEquals(2, requestIds.toSet().size)
        for ((index, id) in requestIds.withIndex()) {
            runFreshProbe(id, expectedHash, index + 1)
        }
        assertNoActiveNetwork("after_both_probes")
        assertFalse("Offline handshakes must not enable production authentication", authentication.available("codex"))
    }

    @Test
    fun readOnlySandboxCanaryReportsEnforcementOrAnUnavailableLauncher() {
        assumeTrue("Requires the dedicated Codex probe build", BuildConfig.RISH_CODEX_PROBE_BUNDLED)
        assertNoActiveNetwork("before_sandbox_canary")
        assertEquals(context.applicationInfo.uid, Process.myUid())
        val binary = File(context.applicationInfo.nativeLibraryDir, "libcodex.so")
        assertTrue(binary.canExecute())
        val home = Files.createTempDirectory(context.cacheDir.toPath(), "codex-sandbox-canary-").toFile()
        try {
            val input = File(home, "read.txt").apply { writeText("rish-canary") }
            val output = File(home, "write.txt")
            val command = listOf("/system/bin/sh", "-c", """
                value=$(/system/bin/cat "$1") || exit 40
                [ "${'$'}value" = rish-canary ] || exit 40
                printf 'RISH_READ_OK\n'
                printf 'rish-written' > "$2" || exit 42
            """.trimIndent(), "canary", input.absolutePath, output.absolutePath)
            val environment = BoundedCodexProbeCommandRunner.environment(home)
            val control = runCanary(command, home, environment)
            assertEquals(control.second, 0, control.first)
            assertTrue(control.second.contains("RISH_READ_OK"))
            assertEquals("rish-written", output.readText())
            assertTrue(output.delete())

            val (exit, diagnostics) = runCanary(listOf(binary.absolutePath, "sandbox", "linux", "--") + command,
                home, environment)
            val readAllowed = diagnostics.lineSequence().any { it == "RISH_READ_OK" }
            val reason = when {
                exit == 42 && readAllowed -> "read_only_enforced"
                exit == 101 && !readAllowed && diagnostics.contains("bubblewrap is unavailable") -> "bubblewrap_unavailable"
                else -> "unexpected_sandbox_result"
            }
            InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                putString("codex_sandbox_canary", reason)
                putInt("codex_sandbox_exit", exit)
                putBoolean("codex_sandbox_canary_ran", readAllowed)
                putBoolean("codex_sandbox_write_observed", output.exists())
            })
            assertFalse("The sandbox canary wrote to its read-only home", output.exists())
            assertTrue("Unclassified sandbox result ($exit): $diagnostics", reason != "unexpected_sandbox_result")
            assertNoActiveNetwork("after_sandbox_canary")
        } finally {
            CodexOfflineProbe.removeTree(home)
        }
    }

    private fun runCanary(argv: List<String>, home: File, env: Map<String, String>): Pair<Int, String> {
        val child = ProcessBuilder(argv).directory(home).redirectErrorStream(true).apply {
            environment().clear()
            environment().putAll(env)
        }.start()
        try {
            child.outputStream.close()
            assertTrue("Sandbox canary exceeded its deadline", child.waitFor(8, TimeUnit.SECONDS))
            val bytes = ByteArray(8192)
            val read = child.inputStream.use { it.read(bytes) }
            val diagnostics = if (read > 0) String(bytes, 0, read, Charsets.UTF_8) else ""
            return child.exitValue() to diagnostics
        } finally {
            if (child.isAlive) {
                child.destroyForcibly()
                assertTrue("Sandbox canary did not stop", child.waitFor(2, TimeUnit.SECONDS))
            }
        }
    }

    private fun runFreshProbe(requestId: String, expectedHash: String, iteration: Int) {
        assertNoActiveNetwork("before_probe_$iteration")
        val probe = probeIntent(requestId)
        val resultFile = CodexOfflineProbeService.resultFile(context, requestId)
        assertFalse("A fresh request must not consume a stale receipt", resultFile.exists())
        assertRequestHomeRemoved(requestId)
        try {
            assertNotNull("The offline probe service did not start", context.startService(probe))
            val deadline = SystemClock.uptimeMillis() + 70_000
            while (!resultFile.isFile && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(50)
            assertTrue("The app-UID offline probe did not produce a receipt within 70 seconds", resultFile.isFile)
            val result = JSONObject(resultFile.readText())
            InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                putInt("codex_offline_probe_iteration", iteration)
                putString("codex_offline_probe_receipt", result.toString())
            })
            val evidence = "Offline Codex probe receipt: $result"
            assertEquals(evidence, 1, result.getInt("schema_version"))
            assertEquals(evidence, "codex", result.getString("engine_id"))
            assertEquals(evidence, requestId, result.getString("request_id"))
            assertEquals(evidence, "offline_app_server_capability", result.getString("probe_kind"))
            assertEquals(evidence, context.applicationInfo.uid, result.getInt("uid"))
            assertEquals(evidence, Process.myUid(), result.getInt("uid"))
            assertTrue(evidence, result.getInt("pid") > 0)
            val artifact = result.getJSONObject("artifact")
            assertEquals(evidence, "0.153.4-linux-arm64", artifact.getString("package_version"))
            assertEquals(evidence, expectedHash, artifact.getString("binary_sha256"))

            // An incompatibility is a failed enabled-lane test with its real
            // receipt, not an assumption skip or a claim of task readiness.
            assertEquals(evidence, "available", result.getJSONObject("capability").getString("state"))
            assertEquals(evidence, "offline_app_server_passed", result.getJSONObject("capability").getString("reason_code"))
            val execution = result.getJSONObject("execution")
            assertEquals(evidence, "unavailable", execution.getString("state"))
            assertEquals(evidence, "cli_adapter_unavailable", execution.getString("reason_code"))
            val commands = result.getJSONArray("commands")
            assertEquals(evidence, 2, commands.length())
            val expectedCommands = listOf(
                "version" to listOf("--version"),
                "app_server_help" to listOf("app-server", "--help"),
            )
            for ((index, expected) in expectedCommands.withIndex()) {
                val command = commands.getJSONObject(index)
                assertEquals(evidence, expected.first, command.getString("id"))
                assertEquals(evidence, expected.second, strings(command.getJSONArray("args")))
                assertEquals(evidence, 0, command.getInt("exit_code"))
                assertFalse(evidence, command.getBoolean("timed_out"))
                assertTrue(evidence, command.isNull("error_code"))
                assertTrue(evidence, command.has("output_truncated"))
            }
            val version = commands.getJSONObject(0)
            assertFalse(evidence, version.getBoolean("output_truncated"))
            assertEquals(evidence, "0.153.4", Regex("\\d+\\.\\d+\\.\\d+")
                .find(version.getString("output"))?.value)
            assertTrue(evidence, commands.getJSONObject(1).getString("output").contains("app-server"))

            val appServer = result.getJSONObject("app_server")
            assertEquals(evidence, "available", appServer.getString("state"))
            assertEquals(evidence, "stdio_handshake_passed", appServer.getString("reason_code"))
            assertEquals(evidence, true, appServer.get("initialize_acknowledged"))
            assertEquals(evidence, true, appServer.get("initialized_sent"))
            assertEquals(evidence, 0, appServer.getInt("loaded_thread_count"))
            assertTrue(evidence, appServer.getString("user_agent").isNotBlank())
            assertEquals(evidence, 0, appServer.getInt("exit_code"))
            assertEquals(evidence, true, appServer.get("process_reaped"))
            assertTrue(evidence, appServer.getString("stderr").length <= 8192)
            assertTrue(evidence, appServer.has("stderr_truncated"))
            assertNoActiveNetwork("after_probe_$iteration")
        } finally {
            // Service destruction requests cancellation asynchronously. Wait
            // until teardown and final publication finish before deleting our
            // receipt, otherwise the worker can recreate it after this test.
            context.stopService(probe)
            val cleanupDeadline = SystemClock.uptimeMillis() + 8_000
            while (CodexOfflineProbeService.requestIsActive(requestId) &&
                SystemClock.uptimeMillis() < cleanupDeadline) SystemClock.sleep(50)
            assertFalse("Codex probe worker did not finish cleanup within 8 seconds: $requestId",
                CodexOfflineProbeService.requestIsActive(requestId))
            assertRequestHomeRemoved(requestId)
            assertTrue("Could not remove the completed probe receipt: $requestId",
                !resultFile.exists() || resultFile.delete())
        }
    }

    private fun probeIntent(requestId: String): Intent =
        Intent(context, CodexOfflineProbeService::class.java)
            .setAction(CodexOfflineProbeService.ACTION)
            .putExtra(CodexOfflineProbeService.EXTRA_REQUEST_ID, requestId)
            .putExtra(CodexOfflineProbeService.EXTRA_ENGINE_ID, "codex")

    private fun assertNoActiveNetwork(phase: String) {
        // Read-only shell observation avoids adding a production permission.
        // Fail closed if this Android version does not expose the expected line.
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand("dumpsys connectivity")
        val dump = ParcelFileDescriptor.AutoCloseInputStream(descriptor)
            .bufferedReader().use { it.readText() }
        assertTrue("Offline probe requires 'Active default network: none' ($phase)",
            Regex("(?m)^\\s*Active default network:\\s*none\\s*$").containsMatchIn(dump))
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
            putString("codex_offline_network_assertion", "$phase: Active default network: none")
        })
    }

    private fun assertRequestHomeRemoved(requestId: String) {
        val homes = File(context.cacheDir, "codex-offline-probe-homes")
        if (!homes.exists()) return
        val children = homes.listFiles()
        assertNotNull("Could not inspect the offline probe homes", children)
        assertFalse("The request left a temporary Codex home behind: $requestId",
            children!!.any { it.name.startsWith("codex-probe-$requestId-") })
    }

    private fun strings(array: JSONArray): List<String> =
        (0 until array.length()).map(array::getString)

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
