package tech.zseven.rish.runtime

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** All subprocesses here are in-memory fakes; no executable or network is used. */
class CodexAppServerProbeTest {
    @Test fun handshakeUsesOnlyTheFixedMethodsAndClosesStdinForNormalExit() {
        val process = ScriptedProcess()
        val result = probe(process) { argv, home, environment ->
            assertEquals(listOf("app-server", "--stdio"), argv.drop(1))
            assertEquals(setOf("HOME", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                "XDG_CACHE_HOME", "TMPDIR", "LANG", "LC_ALL"), environment.keys)
            assertEquals(home.absolutePath, environment["HOME"])
            assertEquals(File(home, ".codex").absolutePath, environment["CODEX_HOME"])
            assertEquals(0, File(environment.getValue("CODEX_HOME")).listFiles()!!.size)
            assertFalse(File(home, ".codex/auth.json").exists())
        }

        assertEquals("available", result.getString("state"))
        assertEquals("stdio_handshake_passed", result.getString("reason_code"))
        assertTrue(result.getBoolean("initialize_acknowledged"))
        assertTrue(result.getBoolean("initialized_sent"))
        assertEquals(0, result.getInt("loaded_thread_count"))
        assertEquals("codex-test/0.153.4", result.getString("user_agent"))
        assertEquals(0, result.getInt("exit_code"))
        assertTrue(result.getBoolean("process_reaped"))
        assertTrue(result.has("protocol_error"))
        assertTrue(result.isNull("protocol_error"))
        assertTrue(process.stdinClosed)
        assertFalse("A normal EOF shutdown does not need a kill", process.destroyed)

        val sent = process.messages()
        assertEquals(listOf("initialize", "initialized", "thread/loaded/list"), sent.map { it.getString("method") })
        assertTrue(sent.none { it.has("jsonrpc") })
        assertEquals(1, sent[0].get("id"))
        val client = sent[0].getJSONObject("params").getJSONObject("clientInfo")
        assertEquals(setOf("name", "title", "version"), client.keys().asSequence().toSet())
        assertEquals("rish_android_probe", client.getString("name"))
        assertEquals("Rish Android Probe", client.getString("title"))
        assertEquals("0.1.0", client.getString("version"))
        assertFalse(sent[1].has("id"))
        assertEquals(2, sent[2].get("id"))
        assertEquals(0, sent[2].getJSONObject("params").length())
    }

    @Test fun stderrIsIndependentOfProtocolAndBounded() {
        val stderr = "{\"id\":1,\"error\":{\"message\":\"diagnostic-only\"}}\n" + "x".repeat(20_000)
        val result = probe(ScriptedProcess(stderr = stderr))
        assertEquals("available", result.getString("state"))
        assertTrue(result.getString("stderr").startsWith("{\"id\":1"))
        assertTrue(result.getString("stderr").length <= 8192)
        assertTrue(result.getBoolean("stderr_truncated"))
    }

    @Test fun protocolStepsWaitForBothDelayedResponses() {
        val initializeReceived = CountDownLatch(1)
        val releaseAcknowledgement = CountDownLatch(1)
        val listSeen = CountDownLatch(1)
        val releaseListResponse = CountDownLatch(1)
        val prematureAdvance = CountDownLatch(1)
        val acknowledgementSent = AtomicBoolean()
        val cancelled = AtomicBoolean()
        val runnerResult = AtomicReference<JSONObject?>()
        val runnerFailure = AtomicReference<Throwable?>()
        val serverFailure = AtomicReference<Throwable?>()
        val process = ScriptedProcess { p, message ->
            if (message.getString("method") == "initialize") {
                initializeReceived.countDown()
            } else {
                if (!acknowledgementSent.get()) prematureAdvance.countDown()
                if (message.getString("method") == "thread/loaded/list") listSeen.countDown()
                else p.respondNormally(message)
            }
        }
        val server = Thread({
            try {
                check(initializeReceived.await(2, TimeUnit.SECONDS)) { "initialize was not received" }
                check(releaseAcknowledgement.await(2, TimeUnit.SECONDS)) { "test did not release initialize response" }
                acknowledgementSent.set(true)
                process.emit("{\"id\":1,\"result\":{\"userAgent\":\"delayed-server\"}}\n")
                check(listSeen.await(2, TimeUnit.SECONDS)) { "thread/loaded/list was not received" }
                check(releaseListResponse.await(2, TimeUnit.SECONDS)) { "test did not release loaded-thread response" }
                process.emit("{\"id\":2,\"result\":{\"data\":[]}}\n")
            } catch (error: Throwable) { serverFailure.set(error) }
        }, "fake-codex-delayed-server").apply { isDaemon = true }
        val runner = Thread({
            try { runnerResult.set(probe(process, timeoutMs = 4_000, cancelled = cancelled)) }
            catch (error: Throwable) { runnerFailure.set(error) }
        }, "fake-codex-delayed-client").apply { isDaemon = true }
        try {
            server.start()
            runner.start()
            assertTrue("The client did not send initialize", initializeReceived.await(2, TimeUnit.SECONDS))
            assertFalse("The client advanced before initialize was acknowledged",
                prematureAdvance.await(75, TimeUnit.MILLISECONDS))
            assertEquals(listOf("initialize"), process.messages().map { it.getString("method") })

            releaseAcknowledgement.countDown()
            assertTrue("The client did not request loaded threads", listSeen.await(2, TimeUnit.SECONDS))
            assertFalse("The client closed stdin before receiving loaded threads",
                process.stdinClosedSignal.await(75, TimeUnit.MILLISECONDS))
            assertFalse(process.stdinClosed)
            releaseListResponse.countDown()
            server.join(2_000)
            runner.join(5_000)
            assertFalse("The fake server did not finish", server.isAlive)
            assertFalse("The protocol runner did not finish", runner.isAlive)
            assertNull("Fake server failure: ${serverFailure.get()}", serverFailure.get())
            assertNull("Runner failure: ${runnerFailure.get()}", runnerFailure.get())
            val result = requireNotNull(runnerResult.get())
            assertEquals(result.toString(), "available", result.getString("state"))
            assertEquals("delayed-server", result.getString("user_agent"))
            assertEquals(listOf("initialize", "initialized", "thread/loaded/list"),
                process.messages().map { it.getString("method") })
        } finally {
            cancelled.set(true)
            releaseAcknowledgement.countDown()
            releaseListResponse.countDown()
            process.destroyForcibly()
            process.closeTestStreams()
            if (server.isAlive) server.interrupt()
            if (runner.isAlive) runner.interrupt()
            server.join(1_000)
            runner.join(1_000)
            assertFalse("The test leaked its fake server thread", server.isAlive)
            assertFalse("The test leaked its fake runner thread", runner.isAlive)
        }
    }

    @Test fun aValidLoadedThreadResponseDoesNotHideTrailingProtocolFailures() {
        val tails = listOf(
            "not-json\n" to "invalid_json",
            "{\"id\":3,\"result\":{}}\n" to "response_id_mismatch",
            "{\"id\":77,\"method\":\"account/login/start\",\"params\":{}}\n" to "server_request_rejected",
            "{\"id\":3" to "stdout_truncated_frame",
        )
        for ((tail, reason) in tails) {
            val process = ScriptedProcess { p, message ->
                if (message.getString("method") == "thread/loaded/list") {
                    p.emit("{\"id\":2,\"result\":{\"data\":[]}}\n" + tail)
                } else p.respondNormally(message)
            }
            val result = probe(process)
            assertUnavailable(result, reason)
            assertTrue(result.getBoolean("initialize_acknowledged"))
            assertTrue(result.getBoolean("initialized_sent"))
            assertTrue(result.getBoolean("process_reaped"))
            assertTrue(result.getBoolean("readers_stopped"))
        }
    }

    @Test fun anUnrelatedResponseIdCannotAcknowledgeInitialize() {
        val process = ScriptedProcess { p, _ -> p.emit("{\"id\":9,\"result\":{\"userAgent\":\"wrong\"}}\n") }
        val result = probe(process)
        assertUnavailable(result, "response_id_mismatch")
        assertFalse(result.getBoolean("initialize_acknowledged"))
        assertEquals(listOf("initialize"), process.messages().map { it.getString("method") })
    }

    @Test fun protocolErrorsRetainOnlyMatchedCodeAndMessageWithoutUnknownPayloads() {
        for ((method, id) in listOf("initialize" to 1, "thread/loaded/list" to 2)) {
            val process = ScriptedProcess { p, request ->
                if (request.getString("method") == method) {
                    p.emit(JSONObject().put("id", id).put("error", JSONObject()
                        .put("code", -32000).put("message", "diagnostic-message")
                        .put("data", JSONObject().put("token", "PRIVATE_ERROR_DATA"))
                        .put("unknown", "PRIVATE_UNKNOWN_FIELD")).toString() + "\n")
                } else p.respondNormally(request)
            }
            val result = probe(process)
            assertUnavailable(result, "server_protocol_error")
            val error = result.getJSONObject("protocol_error")
            assertEquals(setOf("code", "message"), error.keys().asSequence().toSet())
            assertTrue(error.get("code") is Number)
            assertEquals(-32000, error.getInt("code"))
            assertEquals("diagnostic-message", error.getString("message"))
            assertFalse(result.toString().contains("PRIVATE_ERROR_DATA"))
            assertFalse(result.toString().contains("PRIVATE_UNKNOWN_FIELD"))
        }
    }

    @Test fun protocolErrorMessagesAreTruncatedAtUnicodeCodePointBoundaries() {
        val message = "🙂".repeat(513) + "PRIVATE_TRUNCATED_SUFFIX"
        val process = ScriptedProcess { p, _ ->
            p.emit(JSONObject().put("id", 1).put("error", JSONObject()
                .put("code", -32602).put("message", message)).toString() + "\n")
        }
        val result = probe(process)
        assertUnavailable(result, "server_protocol_error")
        val retained = result.getJSONObject("protocol_error").getString("message")
        assertEquals(512, retained.codePointCount(0, retained.length))
        assertEquals("🙂".repeat(512), retained)
        assertFalse(result.toString().contains("PRIVATE_TRUNCATED_SUFFIX"))
    }

    @Test fun errorsForAnUnexpectedResponseIdAreNotCapturedAsProtocolDiagnostics() {
        val process = ScriptedProcess { p, _ ->
            p.emit("{\"id\":9,\"error\":{\"code\":-32000,\"message\":\"PRIVATE_WRONG_ID_MESSAGE\"}}\n")
        }
        val result = probe(process)
        assertUnavailable(result, "response_id_mismatch")
        assertTrue(result.has("protocol_error"))
        assertTrue(result.isNull("protocol_error"))
        assertFalse(result.toString().contains("PRIVATE_WRONG_ID_MESSAGE"))
    }

    @Test fun malformedErrorObjectsAreNotCoercedIntoProtocolDiagnostics() {
        val errors = listOf<Any>(
            JSONObject().put("code", "-32602").put("message", "PRIVATE_NUMERIC_STRING_CODE"),
            JSONObject().put("code", -32602).put("message", 7),
            JSONObject().put("message", "PRIVATE_MISSING_CODE"),
            JSONObject().put("code", -32602),
            "PRIVATE_NON_OBJECT_ERROR",
            JSONObject.NULL,
        )
        for (error in errors) {
            val process = ScriptedProcess { p, _ ->
                p.emit(JSONObject().put("id", 1).put("error", error).toString() + "\n")
            }
            val result = probe(process)
            assertUnavailable(result, "server_protocol_error")
            assertTrue(result.has("protocol_error"))
            assertTrue(result.isNull("protocol_error"))
            assertFalse(result.toString().contains("PRIVATE_"))
        }
    }

    @Test fun malformedJsonAndMissingMessageIdentityFailBeforeAnyFurtherMethod() {
        val malformedFrames = listOf(
            "not-json\n" to "invalid_json",
            "{id:1,\"result\":{\"userAgent\":\"test\"}}\n" to "invalid_json",
            "{\"id\":1,\"result\":{\"userAgent\":\"test\"}}junk\n" to "invalid_json",
            "{\"id\":1,\"id\":1,\"result\":{\"userAgent\":\"test\"}}\n" to "invalid_json",
            "{\"id\":1,\"result\":{\"userAgent\":\"test\"},}\n" to "invalid_json",
            "{\"result\":{}}\n" to "invalid_protocol_frame",
        )
        for ((line, reason) in malformedFrames) {
            val process = ScriptedProcess { p, _ -> p.emit(line) }
            val result = probe(process)
            assertUnavailable(result, reason)
            assertEquals(1, process.messages().size)
        }
    }

    @Test fun serverRequestsAreNeverExecutedOrAnswered() {
        val process = ScriptedProcess { p, _ ->
            p.emit("{\"id\":77,\"method\":\"account/login/start\",\"params\":{}}\n")
        }
        val result = probe(process)
        assertUnavailable(result, "server_request_rejected")
        assertEquals(listOf("initialize"), process.messages().map { it.getString("method") })
    }

    @Test fun initializeRequiresANonemptyStringUserAgent() {
        for (value in listOf<Any>("", JSONObject.NULL, 7)) {
            val process = ScriptedProcess { p, _ ->
                p.emit(JSONObject().put("id", 1).put("result", JSONObject().put("userAgent", value)).toString() + "\n")
            }
            assertUnavailable(probe(process), "invalid_initialize_response")
        }
    }

    @Test fun aFreshServerMustHaveNoLoadedThreads() {
        val process = ScriptedProcess { p, message ->
            if (message.getString("method") == "thread/loaded/list") {
                p.emit("{\"id\":2,\"result\":{\"data\":[\"PRIVATE_THREAD_ID\"]}}\n")
            } else p.respondNormally(message)
        }
        val result = probe(process)
        assertUnavailable(result, "loaded_threads_not_empty")
        assertTrue(result.getBoolean("initialize_acknowledged"))
        assertTrue(result.getBoolean("initialized_sent"))
        assertEquals(1, result.getInt("loaded_thread_count"))
        assertFalse(result.toString().contains("PRIVATE_THREAD_ID"))
    }

    @Test fun loadedThreadResultMustContainAnArray() {
        val process = ScriptedProcess { p, message ->
            if (message.getString("method") == "thread/loaded/list") {
                p.emit("{\"id\":2,\"result\":{\"data\":\"not-an-array\"}}\n")
            } else p.respondNormally(message)
        }
        assertUnavailable(probe(process), "invalid_loaded_threads_response")
    }

    @Test fun splitUtf8FramesAndBoundedNotificationsDoNotChangeHandshakeOrder() {
        val process = ScriptedProcess(maxReadChunk = 1) { p, message ->
            if (message.getString("method") == "initialize") {
                p.emit("{\"method\":\"diagnostic\",\"params\":{\"message\":\"ignore\"}}\r\n")
                p.emit("{\"id\":1,\"result\":{\"userAgent\":\"Codex 测试\"}}\r\n")
            } else p.respondNormally(message)
        }
        val result = probe(process)
        assertEquals("available", result.getString("state"))
        assertEquals("Codex 测试", result.getString("user_agent"))
        assertEquals(listOf("initialize", "initialized", "thread/loaded/list"), process.messages().map { it.getString("method") })
    }

    @Test fun anOversizeFrameIsRejectedWithoutBufferingUnboundedOutput() {
        val process = ScriptedProcess { p, _ -> p.emit("{\"userAgent\":\"" + "x".repeat(65_537) + "\"}\n") }
        assertUnavailable(probe(process), "stdout_frame_too_large")
    }

    @Test fun invalidUtf8IsNotSilentlyReplacedInsideProtocolFrames() {
        val process = ScriptedProcess { p, _ -> p.emit(byteArrayOf(0xc3.toByte(), 0x28, 0x0a)) }
        assertUnavailable(probe(process), "stdout_invalid_utf8")
    }

    @Test fun notificationFloodsAreBoundedByFrameByteOrQueueBudgets() {
        val process = ScriptedProcess { p, _ ->
            repeat(70) { p.emit("{\"method\":\"notice\",\"params\":{\"index\":$it}}\n") }
        }
        val result = probe(process)
        assertEquals("unavailable", result.getString("state"))
        assertTrue(result.getString("reason_code"), result.getString("reason_code") in
            setOf("stdout_frame_limit", "stdout_queue_overflow", "stdout_budget_exceeded"))
        assertTrue(result.getBoolean("process_reaped"))
    }

    @Test fun waitingForInitializeHasATotalDeadlineAndTerminatesTheProcess() {
        val process = ScriptedProcess(exitOnStdinClose = false) { _, _ -> }
        val result = probe(process, timeoutMs = 200)
        assertUnavailable(result, "protocol_timeout")
        assertTrue(process.destroyed)
        assertTrue(result.getBoolean("process_reaped"))
    }

    @Test fun cancellationDuringHandshakeStopsBeforeInitializedAndReapsTheChild() {
        val cancelled = AtomicBoolean()
        val process = ScriptedProcess(exitOnStdinClose = false) { _, _ -> cancelled.set(true) }
        val result = probe(process, cancelled = cancelled)
        assertUnavailable(result, "cancelled")
        assertEquals(listOf("initialize"), process.messages().map { it.getString("method") })
        assertTrue(process.destroyed)
        assertTrue(result.getBoolean("process_reaped"))
    }

    @Test fun aPreCancelledRequestDoesNotStartAnyProcess() = withHome { executable, home ->
        val runner = BoundedCodexAppServerProbeRunner(100, 50) { _, _, _ ->
            throw AssertionError("A cancelled request must not start a process")
        }
        assertUnavailable(runner.run(executable, home, AtomicBoolean(true)), "cancelled")
    }

    @Test fun eofBeforeInitializeIsNotAHandshake() {
        val process = ScriptedProcess { p, _ -> p.exitWithoutResponse() }
        assertUnavailable(probe(process), "unexpected_eof")
    }

    @Test fun successfulHandshakeStillFailsWhenEofDoesNotStopTheServer() {
        val process = ScriptedProcess(exitOnStdinClose = false)
        val result = probe(process, timeoutMs = 500)
        assertUnavailable(result, "shutdown_timeout")
        assertTrue(result.getBoolean("initialize_acknowledged"))
        assertTrue(process.stdinClosed)
        assertTrue(process.destroyed)
        assertTrue(result.getBoolean("process_reaped"))
    }

    @Test fun abnormalProcessExitCannotBecomeAvailable() {
        val result = probe(ScriptedProcess(normalExitCode = 23))
        assertUnavailable(result, "process_nonzero_exit")
        assertEquals(23, result.getInt("exit_code"))
        assertTrue(result.getBoolean("process_reaped"))
    }

    @Test fun failedKillIsReportedAsUnreapedRatherThanSuccessfulCleanup() {
        val process = ScriptedProcess(exitOnStdinClose = false, killWorks = false) { _, _ -> }
        val result = probe(process, timeoutMs = 100, teardownTimeoutMs = 100)
        assertUnavailable(result, "process_reap_failed")
        assertTrue(process.destroyed)
        assertFalse(result.getBoolean("process_reaped"))
        assertTrue("A process that resists killing must not retain the owned readers",
            result.getBoolean("readers_stopped"))
    }

    private fun assertUnavailable(result: JSONObject, reason: String) {
        assertEquals(result.toString(), "unavailable", result.getString("state"))
        assertEquals(result.toString(), reason, result.getString("reason_code"))
    }

    private fun probe(
        process: ScriptedProcess,
        timeoutMs: Long = 2_000,
        teardownTimeoutMs: Long = 250,
        cancelled: AtomicBoolean = AtomicBoolean(),
        inspectStart: (List<String>, File, Map<String, String>) -> Unit = { _, _, _ -> },
    ): JSONObject {
        var result: JSONObject? = null
        withHome { executable, home ->
            val runner = BoundedCodexAppServerProbeRunner(timeoutMs, teardownTimeoutMs) { argv, cwd, env ->
                assertEquals(executable.absolutePath, argv.first())
                inspectStart(argv, cwd, env)
                process
            }
            try { result = runner.run(executable, home, cancelled) }
            finally { process.closeTestStreams() }
        }
        return requireNotNull(result)
    }

    private fun withHome(block: (File, File) -> Unit) {
        val root = Files.createTempDirectory("codex-app-server-test-").toFile()
        try { block(File(root, "never-executed-codex"), File(root, "home")) }
        finally { root.deleteRecursively() }
    }

    /** Simulates a live process: stdout stays open until stdin EOF or termination. */
    private class ScriptedProcess(
        stderr: String = "",
        maxReadChunk: Int = Int.MAX_VALUE,
        private val exitOnStdinClose: Boolean = true,
        private val normalExitCode: Int = 0,
        private val killWorks: Boolean = true,
        private val onMessage: ((ScriptedProcess, JSONObject) -> Unit)? = null,
    ) : Process() {
        private val state = Object()
        private val sent = mutableListOf<JSONObject>()
        private val stdout = PushInputStream(maxReadChunk)
        private val stderrStream = ByteArrayInputStream(stderr.toByteArray(Charsets.UTF_8))
        private var alive = true
        private var code = normalExitCode
        val stdinClosedSignal = CountDownLatch(1)
        @Volatile var stdinClosed = false
        @Volatile var destroyed = false
        private val stdin = object : OutputStream() {
            private val line = ByteArrayOutputStream()
            override fun write(value: Int) {
                check(!stdinClosed) { "stdin already closed" }
                if (value == '\n'.code) {
                    val message = JSONObject(line.toString("UTF-8"))
                    line.reset()
                    synchronized(sent) { sent += message }
                    if (onMessage == null) respondNormally(message) else onMessage.invoke(this@ScriptedProcess, message)
                } else line.write(value)
            }
            override fun close() {
                if (stdinClosed) return
                stdinClosed = true
                stdinClosedSignal.countDown()
                if (exitOnStdinClose) finish(normalExitCode)
            }
        }

        fun respondNormally(message: JSONObject) {
            when (message.getString("method")) {
                "initialize" -> emit("{\"id\":1,\"result\":{\"userAgent\":\"codex-test/0.153.4\"}}\n")
                "initialized" -> Unit
                "thread/loaded/list" -> {
                    if (message.optJSONObject("params")?.length() == 0) {
                        emit("{\"id\":2,\"result\":{\"data\":[]}}\n")
                    } else {
                        emit("{\"id\":2,\"error\":{\"code\":-32600,\"message\":\"Invalid request: expected empty params object\"}}\n")
                    }
                }
                else -> throw AssertionError("Unexpected client method: $message")
            }
        }

        fun messages(): List<JSONObject> = synchronized(sent) { sent.toList() }
        fun emit(value: String) = emit(value.toByteArray(Charsets.UTF_8))
        fun emit(value: ByteArray) { stdout.push(value) }
        fun exitWithoutResponse() { finish(0) }
        fun closeTestStreams() { stdout.close(); stderrStream.close() }

        private fun finish(exitCode: Int) {
            synchronized(state) { alive = false; code = exitCode; state.notifyAll() }
            stdout.close()
        }

        override fun getOutputStream(): OutputStream = stdin
        override fun getInputStream(): InputStream = stdout
        override fun getErrorStream(): InputStream = stderrStream
        override fun waitFor(): Int = synchronized(state) {
            while (alive) state.wait()
            code
        }
        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = synchronized(state) {
            val deadline = System.nanoTime() + unit.toNanos(timeout)
            while (alive) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) return@synchronized false
                TimeUnit.NANOSECONDS.timedWait(state, remaining)
            }
            true
        }
        override fun exitValue(): Int = synchronized(state) {
            if (alive) throw IllegalThreadStateException("fake process is alive")
            code
        }
        override fun destroy() { destroyed = true; if (killWorks) finish(137) }
        override fun destroyForcibly(): Process { destroy(); return this }
        override fun isAlive(): Boolean = synchronized(state) { alive }
    }

    /** Blocking byte channel with explicit EOF and configurable read fragmentation. */
    private class PushInputStream(private val maxReadChunk: Int) : InputStream() {
        private val lock = Object()
        private val chunks = ArrayDeque<ByteArray>()
        private var offset = 0
        private var closed = false

        fun push(bytes: ByteArray) = synchronized(lock) {
            if (closed) return@synchronized
            if (bytes.isNotEmpty()) chunks.addLast(bytes.copyOf())
            lock.notifyAll()
        }

        override fun read(): Int {
            val single = ByteArray(1)
            return if (read(single, 0, 1) < 0) -1 else single[0].toInt() and 0xff
        }

        override fun read(target: ByteArray, start: Int, length: Int): Int = synchronized(lock) {
            if (length == 0) return@synchronized 0
            while (chunks.isEmpty() && !closed) lock.wait()
            if (chunks.isEmpty()) return@synchronized -1
            val chunk = chunks.first()
            val count = minOf(length, maxReadChunk, chunk.size - offset)
            chunk.copyInto(target, start, offset, offset + count)
            offset += count
            if (offset == chunk.size) { chunks.removeFirst(); offset = 0 }
            count
        }

        override fun available(): Int = synchronized(lock) { chunks.sumOf { it.size } - offset }

        override fun close() = synchronized(lock) { closed = true; lock.notifyAll() }
    }
}
