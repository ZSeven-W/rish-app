package tech.zseven.rish.runtime

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Fixed, read-only app-server handshake; this is not an assistant task adapter. */
internal fun interface CodexAppServerProbeRunner {
    fun run(executable: File, home: File, cancelled: AtomicBoolean): JSONObject
}

internal class BoundedCodexAppServerProbeRunner(
    private val timeoutMs: Long = 15_000,
    private val teardownTimeoutMs: Long = 2_000,
    private val startProcess: (List<String>, File, Map<String, String>) -> Process = { argv, home, env ->
        ProcessBuilder(argv).directory(home).redirectErrorStream(false).apply {
            environment().clear()
            environment().putAll(env)
        }.start()
    },
) : CodexAppServerProbeRunner {
    init {
        require(timeoutMs > 0 && teardownTimeoutMs > 0)
    }

    private class Refused(val code: String) : Exception()

    override fun run(executable: File, home: File, cancelled: AtomicBoolean): JSONObject {
        val started = System.nanoTime()
        val deadline = started + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        // Reserve teardown inside the total budget rather than adding an
        // unbounded cleanup tail after a timed-out protocol exchange.
        val cleanupBudgetMs = minOf(teardownTimeoutMs, maxOf(1, timeoutMs / 4))
        val operationDeadline = deadline - TimeUnit.MILLISECONDS.toNanos(cleanupBudgetMs)
        val stopReaders = AtomicBoolean()
        val stdoutEnded = AtomicBoolean()
        val failure = AtomicReference<String?>(null)
        val frames = ArrayBlockingQueue<String>(MAX_QUEUED_FRAMES)
        val stderrBytes = ByteArrayOutputStream()
        val stderrTruncated = AtomicBoolean()
        val readers = mutableListOf<Thread>()
        var process: Process? = null
        var initializeAcknowledged = false
        var initializedSent = false
        var loadedThreadCount: Int? = null
        var userAgent: String? = null
        var exitCode: Int? = null
        var reason = "protocol_incomplete"
        var operationReason: String? = null
        var reaped = true
        var readersStopped = true
        var launched = false
        var launchErrno: Int? = null
        var protocolError: JSONObject? = null

        fun checkOperation(timeoutReason: String = "protocol_timeout") {
            if (cancelled.get() || Thread.currentThread().isInterrupted) throw Refused("cancelled")
            failure.get()?.let { throw Refused(it) }
            if (System.nanoTime() >= operationDeadline) throw Refused(timeoutReason)
        }

        fun parseFrame(frame: String): JSONObject {
            // Android's JSONTokener accepts comments, unquoted keys and
            // trailing junk. Validate strict, depth-bounded JSON first.
            if (!JsonFrameSyntax(frame).validObject()) throw Refused("invalid_json")
            return try { JSONObject(frame) } catch (_: Exception) { throw Refused("invalid_json") }
        }

        fun isNotification(message: JSONObject): Boolean {
            if (!message.has("method")) return false
            if (message.has("id")) throw Refused("server_request_rejected")
            val method = message.opt("method") as? String
            if (method.isNullOrBlank() || message.has("result") || message.has("error")) {
                throw Refused("invalid_protocol_frame")
            }
            return true
        }

        fun awaitResponse(id: Int): JSONObject {
            while (true) {
                checkOperation()
                val frame = frames.poll(20, TimeUnit.MILLISECONDS)
                if (frame == null) {
                    if (stdoutEnded.get() && frames.isEmpty()) {
                        // The reader publishes its specific failure before
                        // ended=true. Recheck after observing that terminal
                        // flag so a failure during poll is not relabeled EOF.
                        checkOperation()
                        throw Refused("unexpected_eof")
                    }
                    continue
                }
                val message = parseFrame(frame)
                if (isNotification(message)) {
                    // Notifications are bounded by the reader's byte/frame
                    // budget. Never execute or retain their unknown payload.
                    continue
                }
                if (!message.has("id")) throw Refused("invalid_protocol_frame")
                val responseId = message.opt("id")
                if ((responseId !is Int && responseId !is Long) || (responseId as Number).toLong() != id.toLong()) {
                    throw Refused("response_id_mismatch")
                }
                if (message.has("error")) {
                    // Keep only bounded diagnostics from the matching
                    // response. Unknown fields (including error.data) may
                    // contain private server state and are never retained.
                    val error = message.opt("error") as? JSONObject
                    val code = error?.opt("code") as? Number
                    val detail = error?.opt("message") as? String
                    if (code != null && code.toDouble().isFinite() && detail != null) {
                        val end = detail.offsetByCodePoints(0,
                            minOf(MAX_PROTOCOL_ERROR_CODE_POINTS, detail.codePointCount(0, detail.length)))
                        protocolError = JSONObject().put("code", code).put("message", detail.substring(0, end))
                    }
                    throw Refused("server_protocol_error")
                }
                return message.opt("result") as? JSONObject ?: throw Refused("invalid_protocol_frame")
            }
        }

        fun drainTrailingNotifications() {
            while (true) {
                val frame = frames.poll() ?: return
                checkOperation("shutdown_timeout")
                val message = parseFrame(frame)
                if (!isNotification(message)) throw Refused("response_id_mismatch")
            }
        }

        fun send(running: Process, message: JSONObject) {
            checkOperation()
            // Only the three small frames below can reach stdin. No caller can
            // supply another method, configuration, account, model, or turn.
            running.outputStream.write((message.toString() + "\n").toByteArray(Charsets.UTF_8))
            running.outputStream.flush()
        }

        try {
            checkOperation()
            val running = startProcess(listOf(executable.absolutePath, "app-server", "--stdio"), home,
                BoundedCodexProbeCommandRunner.environment(home))
            process = running
            launched = true
            reaped = false
            readers += Thread({
                readStdout(running, stopReaders, stdoutEnded, frames, failure)
            }, "codex-app-server-stdout").apply { isDaemon = true; start() }
            readers += Thread({
                readStderr(running, stopReaders, stderrBytes, stderrTruncated, failure)
            }, "codex-app-server-stderr").apply { isDaemon = true; start() }

            send(running, JSONObject().put("id", 1).put("method", "initialize")
                .put("params", JSONObject().put("clientInfo", JSONObject()
                    .put("name", "rish_android_probe").put("title", "Rish Android Probe").put("version", "0.1.0"))))
            val initialized = awaitResponse(1)
            val agent = initialized.opt("userAgent") as? String
            if (agent.isNullOrBlank() || agent.length > MAX_USER_AGENT_CHARS) throw Refused("invalid_initialize_response")
            userAgent = agent
            initializeAcknowledged = true

            send(running, JSONObject().put("method", "initialized").put("params", JSONObject()))
            initializedSent = true
            send(running, JSONObject().put("id", 2).put("method", "thread/loaded/list")
                .put("params", JSONObject()))
            val loaded = awaitResponse(2).optJSONArray("data") ?: throw Refused("invalid_loaded_threads_response")
            loadedThreadCount = loaded.length()
            if (loaded.length() != 0) throw Refused("loaded_threads_not_empty")

            checkOperation()
            running.outputStream.close()
            while (!running.waitFor(20, TimeUnit.MILLISECONDS)) checkOperation("shutdown_timeout")
            reaped = true
            exitCode = running.exitValue()
            if (exitCode != 0) throw Refused("process_nonzero_exit")
            // Drain bytes available after the direct Process exits, consuming
            // bounded notifications. This does not prove that an unknown
            // descendant has closed an inherited FD; device QA checks those
            // separately. A valid id=2 response alone is insufficient.
            while (readers.any { it.isAlive }) {
                checkOperation("shutdown_timeout")
                drainTrailingNotifications()
                readers.forEach { it.join(1) }
            }
            drainTrailingNotifications()
            checkOperation("shutdown_timeout")
            reason = "stdio_handshake_passed"
        } catch (error: Refused) {
            reason = error.code
            if (reason == "cancelled") cancelled.set(true)
        } catch (_: InterruptedException) {
            cancelled.set(true)
            reason = "cancelled"
        } catch (error: IOException) {
            reason = if (launched) "stdio_io_error" else "exec_failed"
            launchErrno = generateSequence<Throwable>(error) { it.cause }
                .mapNotNull { Regex("error=(\\d+)").find(it.message.orEmpty())?.groupValues?.get(1)?.toIntOrNull() }
                .firstOrNull()
        } catch (_: Exception) {
            reason = "process_setup_failed"
        } finally {
            Thread.interrupted()
            operationReason = reason
            val cleanupDeadline = minOf(deadline, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(cleanupBudgetMs))
            stopReaders.set(true)
            readers.forEach { it.interrupt() }
            process?.let { running ->
                // Request the kill promptly, then give owned readers their
                // own join window before a resistant process can consume the
                // remaining reap budget. Interrupt wakes their short polls.
                try { if (running.isAlive) running.destroyForcibly() } catch (_: Exception) { }
                val readerDeadline = minOf(cleanupDeadline,
                    System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(maxOf(1, cleanupBudgetMs / 2)))
                readers.forEach { reader ->
                    val left = readerDeadline - System.nanoTime()
                    if (left > 0) try {
                        val millis = TimeUnit.NANOSECONDS.toMillis(left)
                        val nanos = (left - TimeUnit.MILLISECONDS.toNanos(millis)).toInt()
                        reader.join(millis, nanos)
                    } catch (_: InterruptedException) { Thread.interrupted() }
                }
                try {
                    while (running.isAlive && System.nanoTime() < cleanupDeadline) {
                        val left = maxOf(1, TimeUnit.NANOSECONDS.toMillis(cleanupDeadline - System.nanoTime()))
                        running.waitFor(minOf(20, left), TimeUnit.MILLISECONDS)
                    }
                    reaped = !running.isAlive
                    if (reaped) exitCode = running.exitValue()
                } catch (_: Exception) { reaped = false }
                // Readers poll only currently available pipe bytes; stopping
                // them does not rely on a hung process closing a pipe or on a
                // blocking stream.close() waking a read held under its lock.
                readersStopped = readers.none { it.isAlive }
                if (readersStopped) {
                    for (stream in listOf(running.inputStream, running.errorStream)) {
                        try { stream.close() } catch (_: IOException) { }
                    }
                    try { running.outputStream.close() } catch (_: IOException) { }
                }
                if (!reaped) reason = "process_reap_failed"
                else if (!readersStopped) reason = "reader_teardown_failed"
            }
            // A late malformed frame or reader failure must not be erased by
            // a previously valid response and a clean main-process exit.
            if (reason == "stdio_handshake_passed") failure.get()?.let { reason = it }
            if (reason == "stdio_handshake_passed" && cancelled.get()) reason = "cancelled"
        }

        val stderr = synchronized(stderrBytes) { stderrBytes.toByteArray().toString(Charsets.UTF_8) }
        return JSONObject()
            .put("state", if (reason == "stdio_handshake_passed" && reaped && readersStopped) "available" else "unavailable")
            .put("reason_code", reason)
            .put("initialize_acknowledged", initializeAcknowledged).put("initialized_sent", initializedSent)
            .put("loaded_thread_count", loadedThreadCount ?: JSONObject.NULL).put("user_agent", userAgent ?: JSONObject.NULL)
            .put("exit_code", exitCode ?: JSONObject.NULL).put("stderr", stderr)
            .put("stderr_truncated", stderrTruncated.get()).put("elapsed_ms", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started))
            .put("process_reaped", reaped).put("readers_stopped", readersStopped).put("process_launched", launched)
            .put("launch_errno", launchErrno ?: JSONObject.NULL)
            .put("protocol_error", protocolError ?: JSONObject.NULL)
            .put("operation_reason_code", operationReason ?: reason)
    }

    private fun readStdout(
        process: Process, stop: AtomicBoolean, ended: AtomicBoolean,
        frames: ArrayBlockingQueue<String>, failure: AtomicReference<String?>,
    ) {
        val line = ByteArrayOutputStream()
        var bytesSeen = 0
        var frameCount = 0
        try {
            readAvailable(process.inputStream, process, stop) { bytes, count ->
                bytesSeen += count
                if (bytesSeen > MAX_STDOUT_BYTES) throw Refused("stdout_budget_exceeded")
                for (index in 0 until count) {
                    val byte = bytes[index]
                    if (byte == '\n'.code.toByte()) {
                        if (++frameCount > MAX_FRAMES) throw Refused("stdout_frame_limit")
                        val raw = line.toByteArray()
                        val size = if (raw.lastOrNull() == '\r'.code.toByte()) raw.size - 1 else raw.size
                        val text = try {
                            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(raw, 0, size)).toString()
                        } catch (_: Exception) { throw Refused("stdout_invalid_utf8") }
                        if (!frames.offer(text)) throw Refused("stdout_queue_overflow")
                        line.reset()
                    } else {
                        if (line.size() >= MAX_FRAME_BYTES) throw Refused("stdout_frame_too_large")
                        line.write(byte.toInt())
                    }
                }
            }
            if (!stop.get() && line.size() != 0) throw Refused("stdout_truncated_frame")
        } catch (error: Refused) { failure.compareAndSet(null, error.code) }
        catch (_: Exception) { if (!stop.get()) failure.compareAndSet(null, "stdout_read_failed") }
        finally { ended.set(true) }
    }

    private fun readStderr(
        process: Process, stop: AtomicBoolean, captured: ByteArrayOutputStream,
        truncated: AtomicBoolean, failure: AtomicReference<String?>,
    ) {
        var bytesSeen = 0
        try {
            readAvailable(process.errorStream, process, stop) { bytes, count ->
                bytesSeen += count
                if (bytesSeen > MAX_STDERR_BYTES_SEEN) throw Refused("stderr_budget_exceeded")
                synchronized(captured) {
                    val remaining = MAX_STDERR_CAPTURE_BYTES - captured.size()
                    captured.write(bytes, 0, minOf(remaining, count))
                    if (count > remaining) truncated.set(true)
                }
            }
        } catch (error: Refused) { failure.compareAndSet(null, error.code) }
        catch (_: Exception) { if (!stop.get()) failure.compareAndSet(null, "stderr_read_failed") }
    }

    private fun readAvailable(processStream: InputStream, process: Process, stop: AtomicBoolean, receive: (ByteArray, Int) -> Unit) {
        val buffer = ByteArray(4096)
        while (!stop.get()) {
            val available = processStream.available()
            if (available > 0) {
                val count = processStream.read(buffer, 0, minOf(available, buffer.size))
                if (count < 0) return
                if (count > 0) receive(buffer, count)
            } else if (!process.isAlive) return
            else Thread.sleep(5)
        }
    }

    /** Small syntax gate before the platform's permissive JSONObject parser. */
    private class JsonFrameSyntax(private val text: String) {
        private var index = 0

        fun validObject(): Boolean = try {
            whitespace()
            check(text.getOrNull(index) == '{')
            value(0)
            whitespace()
            index == text.length
        } catch (_: Exception) { false }

        private fun value(depth: Int) {
            check(depth <= 32)
            whitespace()
            when (text.getOrNull(index)) {
                '{' -> {
                    index++; whitespace()
                    if (take('}')) return
                    val keys = hashSetOf<String>()
                    while (true) {
                        val start = index
                        string()
                        val key = org.json.JSONTokener(text.substring(start, index)).nextValue() as String
                        check(keys.add(key))
                        whitespace(); check(take(':')); value(depth + 1); whitespace()
                        if (take('}')) return
                        check(take(',')); whitespace()
                    }
                }
                '[' -> {
                    index++; whitespace()
                    if (take(']')) return
                    while (true) {
                        value(depth + 1); whitespace()
                        if (take(']')) return
                        check(take(','))
                    }
                }
                '"' -> string()
                't' -> literal("true")
                'f' -> literal("false")
                'n' -> literal("null")
                else -> number()
            }
        }

        private fun string() {
            check(take('"'))
            while (true) {
                val character = text[index++]
                if (character == '"') return
                check(character >= ' ')
                if (character == '\\') {
                    when (text[index++]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> Unit
                        'u' -> repeat(4) { check(text[index++] in "0123456789abcdefABCDEF") }
                        else -> error("invalid escape")
                    }
                }
            }
        }

        private fun number() {
            take('-')
            if (!take('0')) {
                check(digit('1')); index++
                digits()
            }
            if (take('.')) { check(digit()); digits() }
            if (take('e') || take('E')) {
                if (!take('+')) take('-')
                check(digit()); digits()
            }
        }

        private fun digit(first: Char = '0'): Boolean = text.getOrNull(index)?.let { it in first..'9' } == true
        private fun digits() { while (digit()) index++ }
        private fun literal(value: String) { check(text.startsWith(value, index)); index += value.length }
        private fun whitespace() { while (text.getOrNull(index) in listOf(' ', '\t', '\r', '\n')) index++ }
        private fun take(character: Char): Boolean = (text.getOrNull(index) == character).also { if (it) index++ }
    }

    companion object {
        const val MAX_FRAME_BYTES = 64 * 1024
        const val MAX_STDOUT_BYTES = 256 * 1024
        const val MAX_FRAMES = 64
        const val MAX_QUEUED_FRAMES = 16
        const val MAX_USER_AGENT_CHARS = 1024
        const val MAX_PROTOCOL_ERROR_CODE_POINTS = 512
        const val MAX_STDERR_CAPTURE_BYTES = 8192
        const val MAX_STDERR_BYTES_SEEN = 256 * 1024
    }
}
