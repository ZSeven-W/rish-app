package tech.zseven.rish.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** This capability probe never starts a server, restores credentials, or runs a task. */
internal class CodexOfflineProbe(
    private val nativeDirectory: File,
    private val workDirectory: File,
    private val readManifest: () -> String,
    private val bundled: Boolean,
    private val supportedAbis: List<String>,
    private val uid: Int,
    private val pid: Int,
    private val commandRunner: CodexProbeCommandRunner = BoundedCodexProbeCommandRunner(),
) {
    fun run(requestId: String, cancelled: AtomicBoolean = AtomicBoolean()): JSONObject {
        require(validRequestId(requestId))
        val result = envelope(requestId, uid, pid)
        var home: File? = null
        try {
            if (!bundled) return fail(result, "codex_probe_not_bundled")
            if ("arm64-v8a" !in supportedAbis) return fail(result, "unsupported_abi")
            if (cancelled.get()) return fail(result, "cancelled")
            val receipt = try { parseManifest(readManifest()) } catch (_: Exception) {
                return fail(result, "invalid_package_receipt")
            }
            if (listOf("libclaude_code.so", "libmusl_loader.so").any { File(nativeDirectory, it).exists() }) {
                return fail(result, "unexpected_cli_binary")
            }
            val artifact = JSONObject().put("package_version", receipt.packageVersion)
                .put("expected_cli_version", CLI_VERSION)
                .put("expected_binary_sha256", receipt.binarySha256)
            result.put("artifact", artifact)
            val executable = File(nativeDirectory, "libcodex.so")
            if (!executable.isFile || Files.isSymbolicLink(executable.toPath())) {
                return fail(result, "codex_binary_missing")
            }
            val actualHash = sha256(executable)
            artifact.put("binary_sha256", actualHash)
            if (actualHash != receipt.binarySha256) return fail(result, "binary_integrity_mismatch")
            if (!executable.canExecute()) return fail(result, "binary_not_executable")
            if (cancelled.get()) return fail(result, "cancelled")

            check(workDirectory.isDirectory || workDirectory.mkdirs())
            home = Files.createTempDirectory(workDirectory.toPath(), "codex-probe-$requestId-").toFile()
            val commands = result.getJSONArray("commands")
            for (command in CodexProbeCommand.values()) {
                if (cancelled.get()) return fail(result, "cancelled")
                val outcome = commandRunner.run(executable, command, home, cancelled)
                commands.put(outcome.toJson(command))
                if (outcome.errorCode != null) return fail(result, outcome.errorCode)
                if (outcome.timedOut) return fail(result, "command_timeout")
                if (outcome.exitCode != 0) return fail(result, "command_nonzero_exit")
                if (command == CodexProbeCommand.VERSION &&
                    Regex("(?<![0-9.])${Regex.escape(CLI_VERSION)}(?![0-9.])").find(outcome.output) == null) {
                    return fail(result, "cli_version_mismatch")
                }
                if (command == CodexProbeCommand.APP_SERVER_HELP &&
                    !outcome.output.contains("app-server", ignoreCase = true)) {
                    return fail(result, "app_server_help_unrecognized")
                }
            }
            if (cancelled.get()) return fail(result, "cancelled")
            result.put("capability", JSONObject().put("state", "available")
                .put("reason_code", "offline_commands_passed"))
            return result
        } catch (_: Exception) {
            return fail(result, if (cancelled.get()) "cancelled" else "probe_io_error")
        } finally {
            // Never follow a child symlink into another application's data or
            // a real Codex home. Only this invocation's fresh home is removed.
            try { home?.let { removeTree(it) } } catch (_: Exception) {
                fail(result, "probe_cleanup_failed")
            }
        }
    }

    private data class Receipt(val packageVersion: String, val binarySha256: String)

    private fun parseManifest(text: String): Receipt {
        val manifest = JSONObject(text)
        require(manifest.keys().asSequence().toSet() == setOf("schema_version", "target", "selected_engines", "packages"))
        require(manifest.opt("schema_version") == 1)
        require(manifest.getString("target") == "linux-arm64-musl")
        val engines = manifest.getJSONArray("selected_engines")
        require(engines.length() == 1 && engines.getString(0) == "codex")
        val packages = manifest.getJSONObject("packages")
        require(packages.keys().asSequence().toSet() == setOf("codex"))
        val codex = packages.getJSONObject("codex")
        require(codex.getString("name") == "@openai/codex")
        require(codex.getString("version") == PACKAGE_VERSION)
        require(codex.getString("output") == "libcodex.so")
        require(codex.opt("requires_musl_loader") == false)
        require(codex.getString("binary") == "package/vendor/aarch64-unknown-linux-musl/bin/codex")
        val hash = codex.getString("binary_sha256")
        require(Regex("[0-9a-f]{64}").matches(hash))
        return Receipt(PACKAGE_VERSION, hash)
    }

    companion object {
        const val MANIFEST_ASSET = "codex-offline-probe-manifest.json"
        const val CLI_VERSION = "0.153.4"
        const val PACKAGE_VERSION = "0.153.4-linux-arm64"
        const val MAX_OUTPUT_CHARS = 8192

        fun validRequestId(value: String): Boolean =
            Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}").matches(value)

        fun envelope(requestId: String, uid: Int, pid: Int): JSONObject = JSONObject()
            .put("schema_version", 1).put("engine_id", "codex").put("request_id", requestId)
            .put("uid", uid).put("pid", pid).put("probe_kind", "offline_command_capability")
            .put("commands", JSONArray())
            .put("capability", JSONObject().put("state", "unavailable").put("reason_code", "not_probed"))
            .put("execution", JSONObject().put("state", "unavailable").put("reason_code", "cli_adapter_unavailable"))

        fun fail(result: JSONObject, reason: String): JSONObject = result.put("capability",
            JSONObject().put("state", "unavailable").put("reason_code", reason))

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { stream ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }

        private fun removeTree(file: File) {
            if (Files.isDirectory(file.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                file.listFiles()?.forEach(::removeTree)
            }
            Files.deleteIfExists(file.toPath())
        }
    }
}

/** No entry point accepts arbitrary argv, another engine, or an auth command. */
internal enum class CodexProbeCommand(val id: String, val args: List<String>) {
    VERSION("version", listOf("--version")),
    APP_SERVER_HELP("app_server_help", listOf("app-server", "--help")),
}

internal data class CodexProbeCommandResult(
    val exitCode: Int? = null,
    val output: String = "",
    val timedOut: Boolean = false,
    val errorCode: String? = null,
    val elapsedMs: Long = 0,
    val outputTruncated: Boolean = false,
    val launchErrno: Int? = null,
) {
    fun toJson(command: CodexProbeCommand): JSONObject = JSONObject()
        .put("id", command.id).put("args", JSONArray(command.args))
        .put("exit_code", exitCode ?: JSONObject.NULL).put("timed_out", timedOut)
        .put("error_code", errorCode ?: JSONObject.NULL).put("elapsed_ms", elapsedMs)
        .put("output", output.take(CodexOfflineProbe.MAX_OUTPUT_CHARS))
        .put("output_truncated", outputTruncated || output.length > CodexOfflineProbe.MAX_OUTPUT_CHARS)
        .put("launch_errno", launchErrno ?: JSONObject.NULL)
}

internal fun interface CodexProbeCommandRunner {
    fun run(executable: File, command: CodexProbeCommand, home: File, cancelled: AtomicBoolean): CodexProbeCommandResult
}

internal class BoundedCodexProbeCommandRunner(
    private val timeoutMs: Long = 15_000,
    private val startProcess: (List<String>, File, Map<String, String>) -> Process = { argv, home, env ->
        ProcessBuilder(argv).directory(home).redirectErrorStream(true).apply {
            environment().clear()
            environment().putAll(env)
        }.start()
    },
) : CodexProbeCommandRunner {
    override fun run(executable: File, command: CodexProbeCommand, home: File, cancelled: AtomicBoolean): CodexProbeCommandResult {
        val started = System.nanoTime()
        var process: Process? = null
        var reader: Thread? = null
        val output = StringBuilder()
        var truncated = false
        val readerFailed = AtomicBoolean()
        fun elapsed() = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        fun result(exit: Int? = null, timedOut: Boolean = false, error: String? = null, errno: Int? = null) =
            synchronized(output) {
                CodexProbeCommandResult(exit, output.toString(), timedOut, error, elapsed(), truncated, errno)
            }
        try {
            if (cancelled.get()) return result(error = "cancelled")
            val env = environment(home)
            process = startProcess(listOf(executable.absolutePath) + command.args, home, env)
            val running = process
            // Even an unexpectedly interactive binary cannot consume input.
            running.outputStream.close()
            reader = Thread({
                try {
                    running.inputStream.bufferedReader(Charsets.UTF_8).use { stream ->
                        val buffer = CharArray(1024)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            synchronized(output) {
                                val remaining = CodexOfflineProbe.MAX_OUTPUT_CHARS - output.length
                                output.append(buffer, 0, minOf(count, remaining))
                                if (count > remaining) truncated = true
                            }
                        }
                    }
                } catch (_: IOException) { readerFailed.set(true) }
            }, "codex-offline-output").apply { isDaemon = true; start() }
            while (!running.waitFor(100, TimeUnit.MILLISECONDS)) {
                if (cancelled.get()) return result(error = "cancelled")
                if (elapsed() >= timeoutMs) return result(timedOut = true, error = "command_timeout")
            }
            reader.join(2000)
            if (reader.isAlive) return result(exit = running.exitValue(), error = "output_drain_timeout")
            if (readerFailed.get()) return result(exit = running.exitValue(), error = "output_read_failed")
            return result(exit = running.exitValue())
        } catch (_: InterruptedException) {
            cancelled.set(true)
            return result(error = "cancelled")
        } catch (error: IOException) {
            val errno = generateSequence<Throwable>(error) { it.cause }
                .mapNotNull { Regex("error=(\\d+)").find(it.message.orEmpty())?.groupValues?.get(1)?.toIntOrNull() }
                .firstOrNull()
            return result(error = "exec_failed", errno = errno)
        } catch (_: Exception) {
            return result(error = "process_setup_failed")
        } finally {
            // Clear an interrupt only to finish bounded teardown; the explicit
            // cancellation flag remains set for the surrounding probe.
            Thread.interrupted()
            process?.let { running ->
                if (running.isAlive) {
                    running.destroyForcibly()
                    try { running.waitFor(2000, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { }
                }
                try { running.inputStream.close() } catch (_: IOException) { }
                try { running.errorStream.close() } catch (_: IOException) { }
                try { running.outputStream.close() } catch (_: IOException) { }
            }
            try { reader?.join(2000) } catch (_: InterruptedException) { }
        }
    }

    companion object {
        fun environment(home: File): Map<String, String> {
            fun directory(name: String): String = File(home, name).apply {
                check(isDirectory || mkdirs())
            }.absolutePath
            return mapOf(
                "HOME" to home.absolutePath,
                "CODEX_HOME" to directory(".codex"),
                "XDG_CONFIG_HOME" to directory(".config"),
                "XDG_DATA_HOME" to directory(".local/share"),
                "XDG_CACHE_HOME" to directory(".cache"),
                "TMPDIR" to directory(".tmp"),
                "LANG" to "C.UTF-8", "LC_ALL" to "C.UTF-8",
            )
        }
    }
}
