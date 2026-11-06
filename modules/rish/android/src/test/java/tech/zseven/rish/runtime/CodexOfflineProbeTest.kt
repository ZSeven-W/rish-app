package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class CodexOfflineProbeTest {
    private fun fixture(block: (File, File, JSONObject) -> Unit) {
        val root = Files.createTempDirectory("codex-offline-test-").toFile()
        try {
            val binary = File(root, "native/libcodex.so").apply {
                parentFile!!.mkdirs(); writeText("fixture bytes, never executed"); setExecutable(true)
            }
            val receipt = JSONObject().put("schema_version", 1).put("target", "linux-arm64-musl")
                .put("selected_engines", JSONArray().put("codex"))
                .put("packages", JSONObject().put("codex", JSONObject()
                    .put("name", "@openai/codex").put("version", CodexOfflineProbe.PACKAGE_VERSION)
                    .put("binary", "package/vendor/aarch64-unknown-linux-musl/bin/codex")
                    .put("requires_musl_loader", false)
                    .put("output", "libcodex.so").put("binary_sha256", CodexOfflineProbe.sha256(binary))))
            block(root, binary, receipt)
        } finally { root.deleteRecursively() }
    }

    private fun probe(root: File, receipt: JSONObject, runner: CodexProbeCommandRunner,
                      bundled: Boolean = true, abis: List<String> = listOf("arm64-v8a"),
                      appServerRunner: CodexAppServerProbeRunner = CodexAppServerProbeRunner { _, _, _ -> appServerSuccess() },
    ) = CodexOfflineProbe(
        File(root, "native"), File(root, "homes"), { receipt.toString() }, bundled, abis, 10123, 456,
        runner, appServerRunner,
    )

    private fun reason(result: JSONObject) = result.getJSONObject("capability").getString("reason_code")
    private fun success(command: CodexProbeCommand) = CodexProbeCommandResult(0,
        if (command == CodexProbeCommand.VERSION) "codex-cli 0.153.4\n" else "Usage: codex app-server [OPTIONS]\n")
    private fun appServerSuccess() = JSONObject().put("state", "available")
        .put("reason_code", "stdio_handshake_passed").put("process_reaped", true)
        .put("initialize_acknowledged", true).put("initialized_sent", true)
        .put("loaded_thread_count", 0).put("user_agent", "fixture").put("exit_code", 0)
    private val noAppServer = CodexAppServerProbeRunner { _, _, _ ->
        throw AssertionError("app-server must not start")
    }

    @Test fun successfulProbeRunsCommandsThenAppServerInOneFreshHomeAndNeverClaimsTaskExecution() = fixture { root, binary, receipt ->
        val calls = mutableListOf<String>()
        val homes = mutableListOf<File>()
        val runner = CodexProbeCommandRunner { executable, command, home, _ ->
            assertEquals(binary, executable)
            assertTrue(home.isDirectory)
            assertFalse(File(home, ".codex/auth.json").exists())
            calls += command.id; homes += home
            File(home, "generated.txt").writeText("ephemeral")
            success(command)
        }
        val appServer = CodexAppServerProbeRunner { executable, home, _ ->
            assertEquals(binary, executable)
            assertEquals(listOf("version", "app_server_help"), calls.takeLast(2))
            assertEquals(listOf(home, home), homes.takeLast(2))
            assertEquals("ephemeral", File(home, "generated.txt").readText())
            calls += "app_server"; homes += home
            File(home, "server-generated.txt").writeText("ephemeral server state")
            appServerSuccess()
        }
        val subject = probe(root, receipt, runner, appServerRunner = appServer)
        repeat(2) {
            val request = UUID.randomUUID().toString()
            val result = subject.run(request)
            assertEquals("available", result.getJSONObject("capability").getString("state"))
            assertEquals("offline_app_server_passed", reason(result))
            assertEquals("offline_app_server_capability", result.getString("probe_kind"))
            assertEquals(appServerSuccess().toString(), result.getJSONObject("app_server").toString())
            assertEquals(2, result.getJSONArray("commands").length())
            assertEquals("unavailable", result.getJSONObject("execution").getString("state"))
            assertEquals("cli_adapter_unavailable", result.getJSONObject("execution").getString("reason_code"))
            assertEquals(request, result.getString("request_id"))
            assertEquals(10123, result.getInt("uid"))
            assertEquals(CodexOfflineProbe.sha256(binary), result.getJSONObject("artifact").getString("binary_sha256"))
            assertTrue(homes.all { !it.exists() })
        }
        assertEquals(List(2) { listOf("version", "app_server_help", "app_server") }.flatten(), calls)
        assertEquals(2, homes.distinct().size)
        assertTrue(homes.all { !it.exists() })
    }

    @Test fun badReceiptHashAbiAndDisabledLaneNeverLaunchAnything() = fixture { root, binary, receipt ->
        val runner = CodexProbeCommandRunner { _, _, _, _ -> throw AssertionError("must not start") }
        assertEquals("codex_probe_not_bundled", reason(probe(root, receipt, runner, bundled = false).run(UUID.randomUUID().toString())))
        assertEquals("unsupported_abi", reason(probe(root, receipt, runner, abis = listOf("x86_64")).run(UUID.randomUUID().toString())))
        val altered = JSONObject(receipt.toString())
        altered.getJSONArray("selected_engines").put("claude-code")
        assertEquals("invalid_package_receipt", reason(probe(root, altered, runner).run(UUID.randomUUID().toString())))
        val wrongVersion = JSONObject(receipt.toString())
        wrongVersion.getJSONObject("packages").getJSONObject("codex").put("version", "latest")
        assertEquals("invalid_package_receipt", reason(probe(root, wrongVersion, runner).run(UUID.randomUUID().toString())))
        val loader = JSONObject(receipt.toString()).put("musl_loader", JSONObject())
        assertEquals("invalid_package_receipt", reason(probe(root, loader, runner).run(UUID.randomUUID().toString())))
        val loaderFlag = JSONObject(receipt.toString())
        loaderFlag.getJSONObject("packages").getJSONObject("codex").put("requires_musl_loader", "false")
        assertEquals("invalid_package_receipt", reason(probe(root, loaderFlag, runner).run(UUID.randomUUID().toString())))
        val extra = File(root, "native/libmusl_loader.so").apply { writeText("must not be bundled") }
        assertEquals("unexpected_cli_binary", reason(probe(root, receipt, runner).run(UUID.randomUUID().toString())))
        extra.delete()
        binary.appendText("tampered")
        assertEquals("binary_integrity_mismatch", reason(probe(root, receipt, runner).run(UUID.randomUUID().toString())))
    }

    @Test fun firstCommandFailureStopsBeforeHelpAndCleansItsHome() = fixture { root, _, receipt ->
        var home: File? = null
        var calls = 0
        val runner = CodexProbeCommandRunner { _, _, directory, _ ->
            calls++; home = directory
            File(directory, "temporary").writeText("data")
            CodexProbeCommandResult(exitCode = 159, output = "bad system call")
        }
        val result = probe(root, receipt, runner, appServerRunner = noAppServer).run(UUID.randomUUID().toString())
        assertEquals("command_nonzero_exit", reason(result))
        assertEquals(159, result.getJSONArray("commands").getJSONObject(0).getInt("exit_code"))
        assertEquals(1, calls)
        assertFalse(home!!.exists())
    }

    @Test fun secondCommandFailureStopsBeforeAppServerAndCleansItsHome() = fixture { root, _, receipt ->
        val calls = mutableListOf<CodexProbeCommand>()
        var home: File? = null
        val runner = CodexProbeCommandRunner { _, command, directory, _ ->
            calls += command; home = directory
            if (command == CodexProbeCommand.VERSION) success(command)
            else CodexProbeCommandResult(exitCode = 7, output = "help failed")
        }
        val result = probe(root, receipt, runner, appServerRunner = noAppServer).run(UUID.randomUUID().toString())
        assertEquals("command_nonzero_exit", reason(result))
        assertEquals(listOf(CodexProbeCommand.VERSION, CodexProbeCommand.APP_SERVER_HELP), calls)
        assertEquals(2, result.getJSONArray("commands").length())
        assertEquals(7, result.getJSONArray("commands").getJSONObject(1).getInt("exit_code"))
        assertFalse(home!!.exists())
    }

    @Test fun versionMismatchAndUnrecognizedHelpRemainUnavailable() = fixture { root, _, receipt ->
        val wrong = CodexProbeCommandRunner { _, _, _, _ -> CodexProbeCommandResult(0, "codex-cli 0.153.40") }
        assertEquals("cli_version_mismatch", reason(probe(root, receipt, wrong, appServerRunner = noAppServer).run(UUID.randomUUID().toString())))
        val wrongHelp = CodexProbeCommandRunner { _, command, _, _ ->
            if (command == CodexProbeCommand.VERSION) success(command) else CodexProbeCommandResult(0, "unexpected help")
        }
        assertEquals("app_server_help_unrecognized", reason(probe(root, receipt, wrongHelp, appServerRunner = noAppServer).run(UUID.randomUUID().toString())))
    }

    @Test fun cancelledRequestNeverLaunchesAndCancellationBetweenCommandsStops() = fixture { root, _, receipt ->
        var calls = 0
        val runner = CodexProbeCommandRunner { _, command, _, cancelled ->
            calls++; cancelled.set(true); success(command)
        }
        assertEquals("cancelled", reason(probe(root, receipt, runner, appServerRunner = noAppServer).run(UUID.randomUUID().toString(), AtomicBoolean(true))))
        assertEquals(0, calls)
        assertEquals("cancelled", reason(probe(root, receipt, runner, appServerRunner = noAppServer).run(UUID.randomUUID().toString())))
        assertEquals(1, calls)
        assertEquals(0, File(root, "homes").listFiles()!!.size)
    }

    @Test fun cancellationAfterHelpStopsBeforeAppServerAndCleansItsHome() = fixture { root, _, receipt ->
        var home: File? = null
        val runner = CodexProbeCommandRunner { _, command, directory, cancelled ->
            home = directory
            if (command == CodexProbeCommand.APP_SERVER_HELP) cancelled.set(true)
            success(command)
        }
        val result = probe(root, receipt, runner, appServerRunner = noAppServer).run(UUID.randomUUID().toString())
        assertEquals("cancelled", reason(result))
        assertEquals(2, result.getJSONArray("commands").length())
        assertFalse(home!!.exists())
    }

    @Test fun appServerFailurePreservesCommandEvidenceAndItsReasonAndCleansHome() = fixture { root, _, receipt ->
        var home: File? = null
        val runner = CodexProbeCommandRunner { _, command, _, _ -> success(command) }
        val serverResult = appServerSuccess().put("state", "unavailable")
            .put("reason_code", "app_server_initialize_failed").put("initialize_acknowledged", false)
        val appServer = CodexAppServerProbeRunner { _, directory, _ ->
            home = directory
            File(directory, "partial-server-state").writeText("ephemeral")
            serverResult
        }
        val result = probe(root, receipt, runner, appServerRunner = appServer).run(UUID.randomUUID().toString())
        assertEquals("unavailable", result.getJSONObject("capability").getString("state"))
        assertEquals("app_server_initialize_failed", reason(result))
        assertEquals(serverResult.toString(), result.getJSONObject("app_server").toString())
        val commands = result.getJSONArray("commands")
        assertEquals(2, commands.length())
        for ((index, command) in CodexProbeCommand.values().withIndex()) {
            assertEquals(command.id, commands.getJSONObject(index).getString("id"))
            assertEquals(success(command).output, commands.getJSONObject(index).getString("output"))
            assertEquals(0, commands.getJSONObject(index).getInt("exit_code"))
        }
        assertFalse(home!!.exists())
    }

    @Test fun successfulHandshakeCannotClaimAvailableUntilItsProcessIsReaped() = fixture { root, _, receipt ->
        val runner = CodexProbeCommandRunner { _, command, _, _ -> success(command) }
        for (reaped in listOf(false, "true", JSONObject.NULL)) {
            var home: File? = null
            val appServer = CodexAppServerProbeRunner { _, directory, _ ->
                home = directory
                appServerSuccess().put("process_reaped", reaped)
            }
            val result = probe(root, receipt, runner, appServerRunner = appServer).run(UUID.randomUUID().toString())
            assertEquals("unavailable", result.getJSONObject("capability").getString("state"))
            assertEquals("app_server_process_not_reaped", reason(result))
            assertEquals(reaped, result.getJSONObject("app_server").get("process_reaped"))
            assertEquals(2, result.getJSONArray("commands").length())
            assertFalse(home!!.exists())
        }
    }

    @Test fun cancellationDuringAppServerRejectsAnOtherwiseSuccessfulReceiptAndCleansHome() = fixture { root, _, receipt ->
        var home: File? = null
        val runner = CodexProbeCommandRunner { _, command, _, _ -> success(command) }
        val appServer = CodexAppServerProbeRunner { _, directory, cancelled ->
            home = directory
            cancelled.set(true)
            appServerSuccess()
        }
        val result = probe(root, receipt, runner, appServerRunner = appServer).run(UUID.randomUUID().toString())
        assertEquals("unavailable", result.getJSONObject("capability").getString("state"))
        assertEquals("cancelled", reason(result))
        assertEquals(appServerSuccess().toString(), result.getJSONObject("app_server").toString())
        assertEquals(2, result.getJSONArray("commands").length())
        assertFalse(home!!.exists())
    }

    @Test fun cleanupNeverFollowsSymlinksOutOfTheFreshHome() = fixture { root, _, receipt ->
        val outside = File(root, "outside.txt").apply { writeText("keep") }
        val runner = CodexProbeCommandRunner { _, command, home, _ ->
            if (command == CodexProbeCommand.VERSION) Files.createSymbolicLink(File(home, "link").toPath(), outside.toPath())
            success(command)
        }
        assertEquals("offline_app_server_passed", reason(probe(root, receipt, runner).run(UUID.randomUUID().toString())))
        assertEquals("keep", outside.readText())
    }

    @Test fun realRunnerBuildsAnEmptyCredentialFreeEnvironmentAndClosesStdin() = fixture { root, binary, _ ->
        val process = FakeProcess("codex-cli 0.153.4")
        val runner = BoundedCodexProbeCommandRunner { argv, home, env ->
            assertEquals(listOf(binary.absolutePath, "--version"), argv)
            assertEquals(File(root, "home"), home)
            assertEquals(setOf("HOME", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "TMPDIR", "LANG", "LC_ALL"), env.keys)
            assertEquals(home.absolutePath, env["HOME"])
            assertEquals(File(home, ".codex").absolutePath, env["CODEX_HOME"])
            assertEquals(0, File(env.getValue("CODEX_HOME")).listFiles()!!.size)
            process
        }
        val result = runner.run(binary, CodexProbeCommand.VERSION, File(root, "home"), AtomicBoolean())
        assertEquals(0, result.exitCode)
        assertNull(result.errorCode)
        assertTrue(process.stdinClosed)
    }

    @Test fun timeoutAndCancellationDestroyTheSubprocess() = fixture { root, binary, _ ->
        val waiting = FakeProcess("", hangs = true)
        val timed = BoundedCodexProbeCommandRunner(1) { _, _, _ -> waiting }
            .run(binary, CodexProbeCommand.APP_SERVER_HELP, File(root, "timeout"), AtomicBoolean())
        assertEquals("command_timeout", timed.errorCode)
        assertTrue(timed.timedOut)
        assertTrue(waiting.destroyed)

        val cancelled = AtomicBoolean()
        val interrupted = FakeProcess("", hangs = true)
        val stopped = BoundedCodexProbeCommandRunner { _, _, _ -> cancelled.set(true); interrupted }
            .run(binary, CodexProbeCommand.VERSION, File(root, "cancel"), cancelled)
        assertEquals("cancelled", stopped.errorCode)
        assertTrue(interrupted.destroyed)
    }

    @Test fun execFailurePreservesErrnoAndOutputIsBounded() = fixture { root, binary, _ ->
        val failed = BoundedCodexProbeCommandRunner { _, _, _ -> throw IOException("error=13, Permission denied") }
            .run(binary, CodexProbeCommand.VERSION, File(root, "failure"), AtomicBoolean())
        assertEquals("exec_failed", failed.errorCode)
        assertEquals(13, failed.launchErrno)
        val large = BoundedCodexProbeCommandRunner { _, _, _ -> FakeProcess("x".repeat(20_000)) }
            .run(binary, CodexProbeCommand.APP_SERVER_HELP, File(root, "large"), AtomicBoolean())
        assertEquals(CodexOfflineProbe.MAX_OUTPUT_CHARS, large.output.length)
        assertTrue(large.outputTruncated)
    }

    @Test fun requestIdsCannotBecomePathsAndOnlyTwoFixedArgvExist() {
        for (id in listOf("", "../receipt", "codex", "A".repeat(36))) assertFalse(CodexOfflineProbe.validRequestId(id))
        assertTrue(CodexOfflineProbe.validRequestId(UUID.randomUUID().toString()))
        assertEquals(listOf(listOf("--version"), listOf("app-server", "--help")), CodexProbeCommand.values().map { it.args })
    }

    private class FakeProcess(output: String, private val hangs: Boolean = false) : Process() {
        var destroyed = false
        var stdinClosed = false
        private val input = ByteArrayInputStream(output.toByteArray())
        private val stdin = object : ByteArrayOutputStream() {
            override fun close() { stdinClosed = true; super.close() }
        }
        override fun getOutputStream(): OutputStream = stdin
        override fun getInputStream(): InputStream = input
        override fun getErrorStream(): InputStream = ByteArrayInputStream(byteArrayOf())
        override fun waitFor(): Int = 0
        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            if (hangs && !destroyed) { Thread.sleep(2); return false }
            return true
        }
        override fun exitValue(): Int = if (hangs && !destroyed) throw IllegalThreadStateException() else 0
        override fun destroy() { destroyed = true }
        override fun destroyForcibly(): Process { destroyed = true; return this }
        override fun isAlive(): Boolean = hangs && !destroyed
    }
}
