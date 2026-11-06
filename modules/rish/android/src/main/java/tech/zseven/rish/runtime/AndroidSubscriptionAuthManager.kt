package tech.zseven.rish.runtime

import android.content.Context
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.regex.Pattern
import org.json.JSONObject

/** Native-only subscription authentication through the unmodified official CLIs. */
internal class AndroidSubscriptionAuthManager(
    context: Context,
    private val vault: SubscriptionAuthVault = AndroidSubscriptionAuthStore(context.applicationContext),
    private val processFactory: SubscriptionAuthProcessFactory = AndroidSubscriptionAuthProcessFactory(context.applicationContext),
) {
    private val app = context.applicationContext
    // Two CLI processes plus their bounded stdout readers are enough for the
    // two supported harnesses; this also prevents unbounded auth workers.
    private val worker = Executors.newFixedThreadPool(4)
    private val sessions = ConcurrentHashMap<String, Session>()
    private val generations = ConcurrentHashMap<String, AtomicLong>()

    init { cleanupOrphanHomes() }

    private data class Spec(
        val id: String,
        val label: String,
        val version: String,
        val executable: String,
        val loginArgs: List<String>,
        val statusArgs: List<String>,
        val logoutArgs: List<String>,
        val musl: Boolean,
    )

    private class Session(
        val spec: Spec,
        val id: String,
        val generation: Long,
        val home: File,
        val process: Process,
        val output: StringBuilder = StringBuilder(),
    ) {
        val metadataLock = Object()
        @Volatile var verificationUrl: String? = null
        @Volatile var userCode: String? = null
        @Volatile var expiresAt: Long? = null
        @Volatile var canSubmitCode: Boolean = false
        @Volatile var completed: Boolean = false
        @Volatile var finalStatus: String? = null
        @Volatile var finalError: String? = null
        @Volatile var finalAccount: String? = null
        @Volatile var finalPlan: String? = null
        @Volatile var verificationProcess: Process? = null
    }

    fun status(harnessId: String): JSONObject {
        val spec = spec(harnessId)
        val unavailable = unavailable(spec)
        if (unavailable != null) return unavailable
        synchronized(lockFor(spec.id)) {
            val active = sessions[harnessId]
            // A process that exited may still be in status verification or
            // vault commit. Keep it owned until readLogin reaches terminal.
            if (active != null && !active.completed) return envelope(spec, "authorizing", active)
            if (active != null && active.completed) {
                val terminal = terminalEnvelope(active)
                // Successful terminal state is safe to refresh on a future
                // poll; errors stay observable until a new login is started.
                if (active.finalStatus == "signed_in") sessions.remove(spec.id, active)
                return terminal
            }

            val home = newHome(spec, "status")
            return try {
                vault.restore(spec.id, home)
                val result = run(spec, spec.statusArgs, home, STATUS_TIMEOUT_MS)
                if (result.exitCode == SIGSYS_EXIT_CODE && spec.id == "claude-code") {
                    return envelopeUnavailable(spec, "cli_incompatible_sigsys")
                }
                val parsed = AndroidSubscriptionAuthStatusParser.parse(spec.id, result.output, result.exitCode)
                if (parsed.status == "signed_in") vault.capture(spec.id, home)
                envelope(spec, parsed.status, null, parsed.account ?: parsed.errorCode, parsed.plan)
            } catch (e: Exception) {
                envelope(spec, "error", null, errorCode(e))
            } finally {
                removeHome(home)
            }
        }
    }

    /** No CLI process or disk I/O. This short lock is independent of the status
     * subprocess lock, so the UI never waits for a status command to finish. */
    fun <T> withAuthorizationStatus(harnessId: String, action: (JSONObject) -> T): T {
        val spec = spec(harnessId)
        return synchronized(authorizationLockFor(spec.id)) {
            val session = sessions[spec.id]
            val current = session != null && !session.completed && session.generation == currentGeneration(spec.id)
            action(if (current) envelope(spec, "authorizing", session) else envelope(spec, "signed_out"))
        }
    }

    fun start(harnessId: String): JSONObject {
        val spec = spec(harnessId)
        val unavailable = unavailable(spec)
        if (unavailable != null) return unavailable
        synchronized(lockFor(spec.id)) {
            val old = sessions[spec.id]
            if (old != null && !old.completed) return envelope(spec, "authorizing", old)
            if (old != null) sessions.remove(spec.id, old)
            val generation = nextGeneration(spec.id)
            val home = newHome(spec, "login")
            return try {
                vault.restore(spec.id, home)
                val process = process(spec, spec.loginArgs, home)
                val session = Session(spec, UUID.randomUUID().toString(), generation, home, process)
                sessions[spec.id] = session
                worker.execute { readLogin(session) }
                // Device-code output is normally emitted immediately. Wait a
                // bounded amount so the JS caller can open the URL in one call.
                synchronized(session.metadataLock) {
                    if (session.verificationUrl == null && !session.completed) {
                        session.metadataLock.wait(START_METADATA_WAIT_MS)
                    }
                }
                envelope(spec, "authorizing", session)
            } catch (e: Exception) {
                removeHome(home)
                envelope(spec, "error", null, errorCode(e))
            }
        }
    }

    fun cancel(harnessId: String, sessionId: String): JSONObject {
        val spec = spec(harnessId)
        val unavailable = unavailable(spec)
        if (unavailable != null) return unavailable
        synchronized(lockFor(spec.id)) {
            val session = sessions[spec.id]
            if (session == null || session.id != sessionId || session.generation != currentGeneration(spec.id)) {
                // A stale cancel is read-only: it cannot invalidate a newer
                // login or advance its generation.
                return if (session != null && !session.completed) envelope(spec, "authorizing", session)
                else session?.let(::terminalEnvelope) ?: envelope(spec, "signed_out")
            }
            nextGeneration(spec.id)
            stop(session)
            session.finalStatus = "signed_out"
            session.finalError = "cancelled"
            session.completed = true
            return envelope(spec, "signed_out", null, "cancelled")
        }
    }

    fun submitCode(harnessId: String, sessionId: String, code: String): JSONObject {
        require(code.length in 1..128 && code.none { it == '\r' || it == '\n' || it == '\u0000' })
        val spec = spec(harnessId)
        synchronized(lockFor(spec.id)) {
            val session = sessions[spec.id]
            require(session != null && !session.completed && session.canSubmitCode && session.id == sessionId && session.generation == currentGeneration(spec.id)) {
                "E_AUTH_STALE_SESSION"
            }
            val bytes = code.toByteArray(StandardCharsets.UTF_8)
            try {
                val output = session.process.outputStream
                output.write(bytes)
                output.write('\n'.code)
                output.flush()
            } finally { bytes.fill(0) }
            session.canSubmitCode = false
            return envelope(spec, "authorizing", session)
        }
    }

    fun logout(harnessId: String): JSONObject {
        val spec = spec(harnessId)
        val unavailable = unavailable(spec)
        if (unavailable != null) {
            // Local ownership can still be revoked safely when a build does
            // not package the CLI. Report runtime absence separately.
            synchronized(lockFor(spec.id)) {
                nextGeneration(spec.id)
                sessions.remove(spec.id)?.let { stop(it) }
                vault.clear(spec.id)
            }
            return unavailable
        }
        synchronized(lockFor(spec.id)) {
            nextGeneration(spec.id)
            sessions.remove(spec.id)?.let { stop(it) }
            val home = newHome(spec, "logout")
            return try {
                vault.restore(spec.id, home)
                val result = run(spec, spec.logoutArgs, home, STATUS_TIMEOUT_MS)
                // Only the official logout result can clear the subscription
                // snapshot. A missing command or failed logout is explicit.
                if (result.exitCode == 0) {
                    vault.clear(spec.id)
                    envelope(spec, "signed_out")
                } else envelope(spec, "error", null, "logout_failed")
            } catch (e: Exception) {
                envelope(spec, "error", null, errorCode(e))
            } finally {
                removeHome(home)
            }
        }
    }

    fun shutdown() {
        sessions.values.toList().forEach {
            synchronized(lockFor(it.spec.id)) {
                nextGeneration(it.spec.id)
                sessions.remove(it.spec.id, it)
                stop(it)
            }
        }
        sessions.clear()
    }

    private fun readLogin(session: Session) {
        val result = try {
            readProcess(session)
        } catch (_: Exception) {
            Result("", -1)
        }
        // A login command's success text is not proof of account state. Ask
        // the same official CLI for status and accept subscription auth only
        // when that command reports it.
        val ownsVerification = synchronized(lockFor(session.spec.id)) {
            sessions[session.spec.id] === session &&
                session.generation == currentGeneration(session.spec.id) &&
                !session.completed
        }
        val parsed = if (result.exitCode == 0 && ownsVerification) {
            val status = try {
                val verified = run(session, session.spec.statusArgs, session.home, STATUS_TIMEOUT_MS)
                if (verified.exitCode == SIGSYS_EXIT_CODE && session.spec.id == "claude-code") {
                    AndroidSubscriptionAuthStatusParser.Result("unavailable", errorCode = "cli_incompatible_sigsys")
                } else AndroidSubscriptionAuthStatusParser.parse(session.spec.id, verified.output, verified.exitCode)
            } catch (_: Exception) {
                AndroidSubscriptionAuthStatusParser.Result("error", errorCode = "status_unverified")
            }
            Triple(status.status, status.account ?: session.spec.label, status.plan ?: status.errorCode)
        } else if (!ownsVerification) {
            Triple("signed_out", null, "cancelled")
        } else parseLogin(session.spec, result.output, result.exitCode).let { Triple(it.first, null, it.second) }
        synchronized(lockFor(session.spec.id)) {
            val stillCurrent = sessions[session.spec.id] === session &&
                session.generation == currentGeneration(session.spec.id)
            try {
                if (stillCurrent) {
                    session.finalStatus = parsed.first
                    session.finalError = if (parsed.first == "signed_in") null else parsed.third
                    session.finalAccount = parsed.second
                    session.finalPlan = parsed.third.takeIf { parsed.first == "signed_in" }
                }
                if (stillCurrent && parsed.first == "signed_in") {
                    // Failed or partial login leaves the previous valid vault
                    // untouched. Only official status verified auth is saved.
                    try {
                        vault.capture(session.spec.id, session.home)
                    } catch (_: Exception) {
                        session.finalStatus = "error"
                        session.finalError = "auth_persist_failed"
                    }
                }
                if (stillCurrent) synchronized(authorizationLockFor(session.spec.id)) { session.completed = true }
            } finally {
                removeHome(session.home)
                // Keep the terminal row so the next status poll can expose an
                // error instead of silently converting it to signed_out.
            }
        }
        synchronized(session.metadataLock) { session.metadataLock.notifyAll() }
    }

    private fun readProcess(session: Session): Result {
        val output = StringBuilder()
        val reader = worker.submit {
            BufferedReader(InputStreamReader(session.process.inputStream, StandardCharsets.UTF_8)).use { stream ->
                val buffer = CharArray(2048)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    if (output.length < MAX_OUTPUT_CHARS) {
                        output.append(buffer, 0, minOf(count, MAX_OUTPUT_CHARS - output.length))
                    }
                    updateMetadata(session, output.toString())
                }
            }
        }
        val completed = session.process.waitFor(LOGIN_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (!completed) {
            session.process.destroy()
            session.process.waitFor(1, TimeUnit.SECONDS)
            if (session.process.isAlive) session.process.destroyForcibly()
        }
        try { reader.get(2, TimeUnit.SECONDS) } catch (_: Exception) { reader.cancel(true) }
        return Result(output.toString(), if (completed) session.process.exitValue() else -1)
    }

    private fun updateMetadata(session: Session, output: String) {
        if (session.verificationUrl == null) session.verificationUrl = safeVerificationUrl(session.spec, output)
        if (session.userCode == null) session.userCode = safeUserCode(output)
        // Claude's pinned `auth login` help does not document a stdin code
        // contract. Keep this false until a future pinned CLI proves one;
        // seeing a URL is not sufficient evidence for secure code submission.
        session.canSubmitCode = false
        if (session.expiresAt == null) session.expiresAt = parseExpiry(output)
        synchronized(session.metadataLock) { session.metadataLock.notifyAll() }
    }

    private fun parseLogin(spec: Spec, output: String, exitCode: Int): Pair<String, String?> {
        if (exitCode == SIGSYS_EXIT_CODE && spec.id == "claude-code") return "unavailable" to "cli_incompatible_sigsys"
        if (exitCode != 0) return "error" to "login_failed"
        val status = AndroidSubscriptionAuthStatusParser.parse(spec.id, output, exitCode)
        if (status.status == "signed_in") return "signed_in" to null
        return "signed_out" to "login_incomplete"
    }

    private fun envelope(spec: Spec, status: String, session: Session? = null, label: String? = null, plan: String? = null): JSONObject {
        val runtime = JSONObject().put("kind", "official-cli").put("available", true).put("version", spec.version)
        val result = JSONObject().put("schema_version", 1).put("harness_id", spec.id).put("runtime", runtime)
            .put("status", status).put("auth_method", AndroidSubscriptionAuthProtocol.authMethodForStatus(status))
        if (status == "signed_in") {
            val account = JSONObject().put("label", label ?: spec.label)
            if (plan != null) account.put("plan", plan)
            result.put("account", account)
        }
        if (session != null) {
            val login = JSONObject().put("session_id", session.id)
            session.verificationUrl?.let { login.put("verification_url", it) }
            session.userCode?.let { login.put("user_code", it) }
            session.expiresAt?.let { login.put("expires_at", it) }
            login.put("can_submit_code", session.canSubmitCode)
            result.put("login", login)
        }
        if (label != null && status != "signed_in") result.put("error_code", label)
        return result
    }

    private fun terminalEnvelope(session: Session): JSONObject {
        val status = session.finalStatus ?: "error"
        return if (status == "unavailable") {
            envelopeUnavailable(session.spec, session.finalError ?: "cli_unavailable")
        } else if (status == "signed_in") {
            envelope(session.spec, status, null, session.finalAccount ?: session.spec.label, session.finalPlan)
        } else if (status == "signed_out") {
            envelope(session.spec, status, null, session.finalError)
        } else {
            envelope(session.spec, "error", null, session.finalError ?: "login_failed")
        }
    }

    private fun unavailable(spec: Spec): JSONObject? {
        if (!processFactory.available(spec.id)) return envelopeUnavailable(spec, "cli_not_packaged")
        return null
    }

    private fun envelopeUnavailable(spec: Spec, reason: String) = JSONObject()
        .put("schema_version", 1).put("harness_id", spec.id)
        .put("runtime", JSONObject().put("kind", "official-cli").put("available", false).put("reason", reason))
        .put("status", "unavailable").put("auth_method", "none").put("error_code", reason)

    private fun spec(id: String): Spec = when (id) {
        // 0.153.4 exposes `login status`; its `--json` flag is unsupported
        // (verified by the app-UID command readiness probe), so parse its
        // exact stable human line instead.
        "codex" -> Spec(id, "OpenAI account", "0.153.4", "libcodex.so", listOf("login", "--device-auth"), listOf("login", "status"), listOf("logout"), false)
        "claude-code" -> Spec(id, "Claude account", "2.1.263", "libclaude_code.so", listOf("auth", "login"), listOf("auth", "status", "--json"), listOf("auth", "logout"), true)
        else -> throw IllegalArgumentException("E_AUTH_HARNESS")
    }

    private fun process(spec: Spec, args: List<String>, home: File): Process {
        return processFactory.start(spec.id, args, home)
    }

    private fun run(spec: Spec, args: List<String>, home: File, timeoutMs: Long): Result =
        run(null, spec, args, home, timeoutMs)

    private fun run(session: Session, args: List<String>, home: File, timeoutMs: Long): Result =
        run(session, session.spec, args, home, timeoutMs)

    private fun run(session: Session?, spec: Spec, args: List<String>, home: File, timeoutMs: Long): Result {
        val process = process(spec, args, home)
        if (session != null) synchronized(lockFor(spec.id)) {
            if (sessions[spec.id] !== session || session.completed || session.generation != currentGeneration(spec.id)) {
                process.destroyForcibly()
                return Result("", -1)
            }
            session.verificationProcess = process
        }
        val output = StringBuilder()
        val reader = worker.submit {
            BufferedReader(InputStreamReader(process.inputStream, StandardCharsets.UTF_8)).use { stream ->
                val buffer = CharArray(2048)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    if (output.length < MAX_OUTPUT_CHARS) output.append(buffer, 0, minOf(count, MAX_OUTPUT_CHARS - output.length))
                }
            }
        }
        val completed = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
        if (!completed) {
            process.destroy()
            if (process.isAlive) process.destroyForcibly()
        }
        try { reader.get(2, TimeUnit.SECONDS) } catch (_: Exception) { reader.cancel(true) }
        if (session != null) synchronized(lockFor(spec.id)) {
            if (session.verificationProcess === process) session.verificationProcess = null
        }
        return Result(output.toString(), if (completed) process.exitValue() else -1)
    }

    private data class Result(val output: String, val exitCode: Int)

    private fun newHome(spec: Spec, purpose: String): File = File(
        app.filesDir,
        "subscription-auth/${spec.id}/$purpose-${UUID.randomUUID()}"
    ).apply { mkdirs() }

    private fun removeHome(home: File) = AndroidSubscriptionAuthStore.clearDirectory(home)
    private fun stop(session: Session) {
        stopProcess(session.process)
        session.verificationProcess?.let(::stopProcess)
        removeHome(session.home)
    }

    private fun stopProcess(process: Process) {
        if (!process.isAlive) return
        process.destroy()
        process.waitFor(2, TimeUnit.SECONDS)
        if (process.isAlive) process.destroyForcibly()
        if (process.isAlive) process.waitFor(1, TimeUnit.SECONDS)
    }

    private fun cleanupOrphanHomes() {
        val root = File(app.filesDir, "subscription-auth")
        if (!root.isDirectory || java.nio.file.Files.isSymbolicLink(root.toPath())) return
        root.listFiles()?.filter { it.name == "codex" || it.name == "claude-code" }?.forEach { harness ->
            if (java.nio.file.Files.isSymbolicLink(harness.toPath()) || !harness.isDirectory) return@forEach
            harness.listFiles()?.forEach { operation ->
                if (operation.name.startsWith("login-") || operation.name.startsWith("status-") || operation.name.startsWith("logout-")) {
                    removeHome(operation)
                }
            }
        }
    }

    private fun nextGeneration(id: String) = synchronized(authorizationLockFor(id)) {
        generations.getOrPut(id) { AtomicLong(0) }.incrementAndGet()
    }
    private fun currentGeneration(id: String) = generations.getOrPut(id) { AtomicLong(0) }.get()
    private val locks = ConcurrentHashMap<String, Any>()
    private fun lockFor(id: String) = locks.getOrPut(id) { Any() }
    private val authorizationLocks = ConcurrentHashMap<String, Any>()
    private fun authorizationLockFor(id: String) = authorizationLocks.getOrPut(id) { Any() }

    private fun errorCode(error: Exception): String = when {
        error.message?.contains("E_CLI_LOADER_MISSING") == true -> "cli_loader_missing"
        error.message?.contains("timeout", true) == true -> "cli_timeout"
        error is IllegalArgumentException && error.message?.startsWith("E_AUTH_") == true -> error.message!!
        else -> "auth_runtime_error"
    }

    private fun extractJson(output: String): JSONObject? {
        val starts = output.indexOf('{')
        val ends = output.lastIndexOf('}')
        if (starts < 0 || ends <= starts) return null
        return try { JSONObject(output.substring(starts, ends + 1)) } catch (_: Exception) { null }
    }

    private fun safeLabel(value: String): String? {
        val clean = value.filter { it.code in 0x20..0x7e }.trim()
        return clean.takeIf { it.isNotEmpty() && it.length <= 128 }
    }

    private fun safeVerificationUrl(spec: Spec, output: String): String? {
        val matcher = Pattern.compile("https://[^\\s\\\"'<>]{1,2048}").matcher(output)
        while (matcher.find()) {
            val candidate = matcher.group().trimEnd('.', ',', ')', ']', ';')
            if (AndroidSubscriptionAuthProtocol.isVerificationUrl(spec.id, candidate)) return candidate
        }
        return null
    }

    private fun safeUserCode(output: String): String? {
        val matcher = Pattern.compile("(?i)(?:code|device code|verification code)\\s*[:：]?\\s*([A-Z0-9][A-Z0-9-]{3,31})").matcher(output)
        if (!matcher.find()) return null
        return matcher.group(1)?.uppercase(Locale.US)
    }

    private fun parseExpiry(output: String): Long? {
        val matcher = Pattern.compile("(?i)(?:expires[_ ]?at|expires in)\\D{0,8}(\\d{9,13})").matcher(output)
        if (!matcher.find()) return null
        val value = matcher.group(1)?.toLongOrNull() ?: return null
        // Bridge contract uses Unix milliseconds even when a CLI prints
        // seconds.
        return if (value < 10_000_000_000L) value * 1000 else value
    }

    companion object {
        private const val SIGSYS_EXIT_CODE = 159
        private const val MAX_OUTPUT_CHARS = 64 * 1024
        private const val START_METADATA_WAIT_MS = 2_000L
        private const val LOGIN_TIMEOUT_MS = 10 * 60 * 1000L
        private const val STATUS_TIMEOUT_MS = 20_000L
    }
}
