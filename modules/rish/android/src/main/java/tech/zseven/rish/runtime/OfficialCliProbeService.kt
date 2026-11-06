package tech.zseven.rish.runtime

import android.app.Service
import android.content.Intent
import android.os.IBinder
import tech.zseven.rish.BuildConfig
import org.json.JSONObject
import java.io.File
import java.io.BufferedReader
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit
import java.util.regex.Pattern

/** Internal test-only service used to prove ProcessBuilder under the app UID. */
internal class OfficialCliProbeService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION) return START_NOT_STICKY
        Thread {
            val result = JSONObject().put("uid", android.os.Process.myUid())
            if (BuildConfig.RISH_OFFICIAL_CLI_ENABLED) {
                val nativeDir = File(applicationInfo.nativeLibraryDir)
                val codex = File(nativeDir, "libcodex.so").absolutePath
                val claude = File(nativeDir, "libclaude_code.so").absolutePath
                val loader = File(nativeDir, "libmusl_loader.so").absolutePath
                result.put("codex", runVersion(listOf(codex, "--version")))
                result.put("claude", runVersion(listOf(
                    File(nativeDir, "libmusl_loader.so").absolutePath, "--library-path", nativeDir.absolutePath,
                    File(nativeDir, "libclaude_code.so").absolutePath, "--version"
                )))
                val home = File(cacheDir, "cli-probe-home-${System.nanoTime()}").apply { mkdirs() }
                try {
                    // Exercise the production manager once before the command
                    // matrix; only its safe status/error fields are retained.
                    val manager = AndroidSubscriptionAuthManager(applicationContext)
                    try {
                        val managerStatus = manager.status("claude-code")
                        result.put("manager_claude_status", managerStatus.optString("status"))
                            .put("manager_claude_error", managerStatus.optString("error_code"))
                    } finally { manager.shutdown() }
                    val codexHelp = runCommand(listOf(codex, "login", "--help"), home)
                    val codexStatusHelp = runCommand(listOf(codex, "login", "status", "--help"), home)
                    val codexStatus = runCommand(listOf(codex, "login", "status"), home)
                    val codexStatusJson = runCommand(listOf(codex, "login", "status", "--json"), home)
                    result.put("codex_login_help_device_auth", codexHelp.output.contains("--device-auth", ignoreCase = true))
                        .put("codex_status_help_exit", codexStatusHelp.exitCode)
                        .put("codex_status_exit", codexStatus.exitCode)
                        .put("codex_status_json_exit", codexStatusJson.exitCode)
                        .put("codex_status_class", AndroidSubscriptionAuthStatusParser.parse("codex", codexStatus.output, codexStatus.exitCode).status)
                        .put("codex_status_tls_error", hasTlsError(codexStatus.output))
                    val claudeHelp = runCommand(listOf(loader, "--library-path", nativeDir.absolutePath, claude, "auth", "login", "--help"), home)
                    val claudeStatusHelp = runCommand(listOf(loader, "--library-path", nativeDir.absolutePath, claude, "auth", "status", "--help"), home)
                    val claudeStatusJson = runCommand(listOf(loader, "--library-path", nativeDir.absolutePath, claude, "auth", "status", "--json"), home)
                    result.put("claude_login_help_stdin_code", claudeHelp.output.contains("stdin", ignoreCase = true) && claudeHelp.output.contains("code", ignoreCase = true))
                        .put("claude_status_help_exit", claudeStatusHelp.exitCode)
                        .put("claude_status_json_exit", claudeStatusJson.exitCode)
                        .put("claude_status_class", AndroidSubscriptionAuthStatusParser.parse("claude-code", claudeStatusJson.output, claudeStatusJson.exitCode).status)
                        .put("claude_status_tls_error", hasTlsError(claudeStatusJson.output))
                    val codexChallenge = runCommand(listOf(codex, "login", "--device-auth"), home, 10_000)
                    val claudeChallenge = runCommand(listOf(loader, "--library-path", nativeDir.absolutePath, claude, "auth", "login"), home, 10_000)
                    result.put("codex_challenge_url_present", hasProviderUrl(codexChallenge.output, "codex"))
                        .put("codex_challenge_code_present", hasDeviceCode(codexChallenge.output))
                        .put("codex_challenge_tls_error", hasTlsError(codexChallenge.output))
                        .put("claude_challenge_url_present", hasProviderUrl(claudeChallenge.output, "claude-code"))
                        .put("claude_challenge_code_present", hasDeviceCode(claudeChallenge.output))
                        .put("claude_challenge_tls_error", hasTlsError(claudeChallenge.output))
                } finally { AndroidSubscriptionAuthStore.clearDirectory(home) }
            } else result.put("error", "cli_probe_disabled")
            File(cacheDir, RESULT_FILE).writeText(result.toString())
            stopSelf(startId)
        }.start()
        return START_NOT_STICKY
    }

    private data class CommandResult(val exitCode: Int, val output: String)

    private fun runCommand(command: List<String>, home: File, timeoutMs: Long = 15_000): CommandResult {
        return try {
            val environment = hashMapOf("HOME" to home.absolutePath, "XDG_CONFIG_HOME" to File(home, ".config").absolutePath,
                "XDG_DATA_HOME" to File(home, ".local/share").absolutePath, "XDG_CACHE_HOME" to File(home, ".cache").absolutePath,
                "TMPDIR" to File(home, ".tmp").apply { mkdirs() }.absolutePath, "LANG" to "C.UTF-8", "LC_ALL" to "C.UTF-8")
            val process = ProcessBuilder(command).directory(home).redirectErrorStream(true).apply {
                environment().clear(); environment().putAll(environment)
            }.start()
            val output = StringBuilder()
            val reader = Thread {
                BufferedReader(InputStreamReader(process.inputStream, StandardCharsets.UTF_8)).use { stream ->
                    val buffer = CharArray(1024)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        if (output.length < 8192) output.append(buffer, 0, minOf(count, 8192 - output.length))
                    }
                }
            }
            reader.start()
            val completed = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!completed) {
                process.destroyForcibly()
                process.waitFor(2, TimeUnit.SECONDS)
            }
            reader.join(2000)
            CommandResult(if (completed) process.exitValue() else -1, output.toString())
        } catch (_: Exception) { CommandResult(-1, "") }
    }

    private fun runVersion(command: List<String>): String {
        val home = File(cacheDir, "cli-probe-version-home-${System.nanoTime()}").apply { mkdirs() }
        return try {
            val result = runCommand(command, home)
            if (result.exitCode == 0) Regex("\\d+\\.\\d+\\.\\d+").find(result.output)?.value ?: "error" else "error"
        } finally { AndroidSubscriptionAuthStore.clearDirectory(home) }
    }

    private fun hasTlsError(output: String): Boolean = listOf("certificate", "tls", "ssl", "x509")
        .any { output.contains(it, ignoreCase = true) }

    private fun hasProviderUrl(output: String, harnessId: String): Boolean {
        val matcher = Pattern.compile("https://[^\\s\\\"'<>]{1,2048}").matcher(output)
        while (matcher.find()) {
            val host = try { java.net.URI(matcher.group()).host?.lowercase() } catch (_: Exception) { null }
            if (harnessId == "codex" && (host == "auth.openai.com" || host == "chatgpt.com")) return true
            if (harnessId == "claude-code" && (host == "claude.ai" || host == "auth.anthropic.com" || host == "console.anthropic.com")) return true
        }
        return false
    }

    private fun hasDeviceCode(output: String): Boolean =
        Regex("(?i)(?:code|device code|verification code)\\s*[:：]?\\s*[A-Z0-9][A-Z0-9-]{3,31}").containsMatchIn(output)

    companion object {
        const val ACTION = "tech.zseven.rish.action.OFFICIAL_CLI_PROBE"
        const val RESULT_FILE = "official-cli-probe-result.json"
    }
}
