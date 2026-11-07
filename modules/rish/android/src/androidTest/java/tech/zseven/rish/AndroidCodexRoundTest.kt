package tech.zseven.rish

import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** Real Android checkpoint, round journal and transcript, with scripted stdio. */
@RunWith(AndroidJUnit4::class)
class AndroidCodexRoundTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun correlatedTerminalAnswerUsesTheNativeCompletionReceipt() {
        val server = Server { process ->
            process.delta("stale", turn = "other-turn")
            process.delta("preview only")
            process.ack()
            process.answer()
        }
        val previews = mutableListOf<JSONObject>()
        withRound(server, previews::add) { service, request, wal ->
            val result = service.completeRound(request)
            assertEquals(result.toString(), "completed", result.optString("status"))
            val outcome = result.getJSONObject("outcome")
            assertEquals("final", outcome.getString("kind"))
            assertEquals("Authoritative answer", outcome.getString("text"))
            val receipt = outcome.getJSONObject("completion_receipt")
            assertEquals(request.getString("operation_id"), receipt.getString("provider_request_id"))
            assertEquals("test-turn", receipt.getString("provider_response_id"))
            assertEquals("completed", row(wal).getString("state"))
            assertEquals(1, result.getJSONObject("transcript").getInt("generation"))
            val cache = AndroidAgentRoundPresentations(wal.root)
            val displayed = cache.read(request.getString("conversation_id"), request.getString("attempt_id"), JSONObject())
            assertEquals("Authoritative answer", displayed.getJSONArray("rounds").getJSONObject(0).getString("text"))
            assertEquals(listOf("delta", "end"), previews.map { it.getString("kind") })
            assertEquals("preview only", previews.first().getString("text"))
            assertEquals(request.getString("round_id"), previews.first().getString("round_id"))
            assertEquals("validated", previews.last().getString("status"))
            assertEquals(listOf("initialize", "initialized", "thread/start", "turn/start"), server.methods)
        }
    }

    @Test fun disconnectAfterPreviewLeavesAnAmbiguousRoundWithoutReplay() {
        val server = Server { process ->
            process.ack()
            process.delta("incomplete")
            process.disconnect()
        }
        withRound(server) { service, request, wal ->
            val result = service.completeRound(request)
            assertEquals(result.toString(), "ambiguous", result.optString("status"))
            assertTrue(row(wal).isNull("completion_receipt"))
            val recovered = service.recoverRound(selector(request, row(wal)))
            assertEquals(recovered.toString(), "ambiguous", recovered.optString("status"))
            assertEquals(1, server.methods.count { it == "turn/start" })
        }
    }

    @Test fun cancellationWinsAgainstAQueuedTerminalReply() {
        val previewed = CountDownLatch(1)
        val releasePreview = CountDownLatch(1)
        val server = Server { process ->
            process.ack()
            process.delta("preview")
        }
        withRound(server, { event ->
            if (event.optString("kind") == "delta") {
                previewed.countDown()
                check(releasePreview.await(5, TimeUnit.SECONDS))
            }
        }) { service, request, wal ->
            val worker = FutureTask { service.completeRound(request) }
            Thread(worker, "codex-round-test").start()
            try {
                assertTrue("The live turn did not reach preview", previewed.await(5, TimeUnit.SECONDS))
                service.cancelRound(selector(request, row(wal)).put("cancel_token", uuid()))
                assertEquals("cancel_requested", row(wal).getString("state"))
                server.answer()
            } finally {
                releasePreview.countDown()
            }
            val result = worker.get(8, TimeUnit.SECONDS)
            assertEquals(result.toString(), "ambiguous", result.optString("status"))
            assertTrue(row(wal).isNull("completion_receipt"))
            assertTrue(row(wal).isNull("transcript_after"))
            assertFalse(server.isAlive)
        }
    }

    @Test fun toolItemCannotSettleAsATextAnswer() {
        val server = Server { process ->
            process.ack()
            process.event("item/started", JSONObject().put("turnId", "test-turn").put(
                "item", JSONObject().put("type", "commandExecution").put("id", "tool"),
            ))
            process.answer()
        }
        withRound(server) { service, request, wal ->
            assertEquals("ambiguous", service.completeRound(request).optString("status"))
            assertTrue(row(wal).isNull("completion_receipt"))
        }
    }

    @Test fun packagedAppServerCompletesThroughTheRoundJournalWithALoopbackProvider() {
        assumeTrue("Requires the dedicated Codex probe build", BuildConfig.RISH_CODEX_PROBE_BUNDLED)
        assertOffline()
        val binary = File(context.applicationInfo.nativeLibraryDir, "libcodex.so")
        assertTrue(binary.canExecute())
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { socket ->
            socket.soTimeout = 25_000
            val response = FutureTask { replyToCodex(socket) }
            val worker = Thread(response, "codex-loopback-fixture").apply { isDaemon = true; start() }
            try {
                val server = BoundedCodexAppServerProbeRunner(timeoutMs = 30_000, startProcess = { argv, home, env ->
                    File(env.getValue("CODEX_HOME"), "config.toml").writeText(
                        """
                        model_provider = "rish_loopback"
                        [model_providers.rish_loopback]
                        name = "Rish loopback fixture"
                        base_url = "http://127.0.0.1:${socket.localPort}/v1"
                        wire_api = "responses"
                        requires_openai_auth = false
                        request_max_retries = 0
                        stream_max_retries = 0
                        """.trimIndent(),
                    )
                    ProcessBuilder(argv).directory(home).apply {
                        environment().clear()
                        environment().putAll(env)
                    }.start()
                })
                val previews = mutableListOf<JSONObject>()
                withRound(binary, server, previews::add) { service, request, wal ->
                    val result = service.completeRound(request)
                    assertEquals(result.toString(), "completed", result.optString("status"))
                    assertEquals("Loopback answer", result.getJSONObject("outcome").getString("text"))
                    assertEquals("completed", row(wal).getString("state"))
                    assertEquals("Loopback answer", previews.joinToString("") { it.optString("text") })
                    assertEquals("validated", previews.last().getString("status"))
                }
                response.get(2, TimeUnit.SECONDS)
                assertOffline()
            } finally {
                socket.close()
                worker.join(2_000)
            }
        }
    }

    private fun withRound(
        server: Server,
        preview: ((JSONObject) -> Unit)? = null,
        body: (AndroidAgentProviderRoundService, JSONObject, AndroidAgentWal) -> Unit,
    ) {
        try {
            withRound(File("fixture-codex"), BoundedCodexAppServerProbeRunner(
                timeoutMs = 8_000, startProcess = { _, _, _ -> server },
            ), preview, body)
        } finally { server.destroy() }
    }

    private fun withRound(
        executable: File,
        server: BoundedCodexAppServerProbeRunner,
        preview: ((JSONObject) -> Unit)?,
        body: (AndroidAgentProviderRoundService, JSONObject, AndroidAgentWal) -> Unit,
    ) {
        assertTrue("rish agent core must be staged", RishAgentCoreNative.available)
        AndroidDshModelCatalog.initialize(context)
        val namespace = "codex-round-${uuid()}"
        val home = File(context.noBackupFilesDir, namespace).apply { check(mkdir()) }
        val sessions = AndroidSessionStore(context, "$namespace.db")
        val previousRegistry = AndroidProviderConfiguration.registry
        try {
            val configuration = AndroidProviderConfiguration(context, "$namespace.providers") { JSONObject.NULL }
            configuration.providerModels.save(JSONObject().put("schema_version", 1).put("expected_revision", 0)
                .put("harness_id", "codex").put("models", JSONArray().put(JSONObject()
                    .put("id", MODEL).put("name", MODEL).put("supports_images", false))))
            val wal = AndroidAgentWal(File(home, "wal").apply { check(mkdir()) })
            val workspaces = AndroidWorkspaceRegistry(File(home, "workspaces").apply { check(mkdir()) })
            val workspace = workspaces.create("Codex fixture").getString("workspace_id")
            val roots = AndroidAgentRootResolver(workspaces)
            val prepared = AndroidPreparedAttemptStore(sessions, wal, roots)
            val ids = AgentSessionFixture.Ids()
            val history = JSONArray().put(JSONObject().put("role", "user").put("content", "hello").put("attachments", JSONArray()))
            val digest = RishAgentCoreNative.hash("visible-history", JSONObject().put("messages", history))
            val first = AgentSessionFixture.commit(sessions, ids, workspace = workspace, model = MODEL)
            val common = JSONObject().put("schema_version", 2)
                .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                .put("transport_schema_version", 2).put("harness_id", "codex").put("model", MODEL)
                .put("thinking_mode", "off").put("visible_history_sha256", digest).put("visible_message_count", 1)
                .put("project_context_sha256", JSONObject.NULL).put("registry_version", 4)
            val preparation = prepared.prepareAgentAttempt(JSONObject(common.toString())
                .put("operation_id", ids.operation).put("controller_cas", cas(ids, first, 0))
                .put("committed_checkpoint", AgentSessionFixture.checkpoint(first, 0))
                .put("workspace_id", workspace).put("project_id", JSONObject.NULL).put("workspace_binding_revision", 1)
                .put("visible_message_ids", JSONArray().put(ids.message))
                .put("expected_policy_version", JSONObject.NULL).put("expected_transcript", JSONObject.NULL))
            assertEquals(preparation.toString(), "prepared", preparation.optString("status"))
            val authority = prepared.authorityFor(ids.task, ids.attempt)!!
            val root = authority.getJSONObject("root")
            val roundId = uuid()
            val journal = AgentSessionFixture.agentJournal(workspace, "round_in_flight")
                .put("root", root).put("policy", authority.get("policy")).put("tool_registry_version", 4)
                .put("toolset_sha256", authority.getJSONObject("registry").get("toolset_sha256"))
                .put("transcript", authority.get("transcript"))
                .put("round_lineage", JSONObject().put("schema_version", 2).put("round_id", roundId).put("round_index", 0)
                    .put("launch_attempt", 1).put("status", "active").put("native_row_revision", JSONObject.NULL))
            val session = AgentSessionFixture.session(ids, workspace = workspace, agent = journal, model = MODEL)
            session.getJSONArray("conversations").getJSONObject(0).getJSONArray("attempts").getJSONObject(0)
                .put("status", "sending").put("active_round", JSONObject().put("round_id", roundId).put("round_index", 0))
                .put("visible_history_sha256", digest)
            val persisted = sessions.persist(JSONObject().put("schema_version", 1).put("operation_id", uuid())
                .put("expected", AgentSessionFixture.expecting(first))
                .put("candidate_json", RishAgentCoreNative.canonical(session.toString())!!))
            assertEquals(persisted.toString(), "committed", persisted.optString("status"))
            val snapshot = persisted.getJSONObject("snapshot")
            val request = JSONObject(common.toString()).put("operation_id", uuid())
                .put("controller_cas", cas(ids, snapshot, 1)).put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                .put("round_id", roundId).put("round_index", 0).put("launch_attempt", 1).put("expected_round_revision", 0)
                .put("transcript", authority.get("transcript")).put("root", root)
                .put("toolset_sha256", authority.getJSONObject("registry").get("toolset_sha256"))
            val http = AndroidModelTransport(
                AndroidCredentialStore(context, namespace), configuration,
            )
            val tasks = AndroidLiveTasks()
            val cli = AndroidCodexRoundTransport(executable, home, server)
            val service = AndroidAgentProviderRoundService(
                sessions, prepared, AndroidAgentRoundJournal(wal, tasks), roots, AndroidAgentToolRegistry,
                http, wal, AndroidAgentOperations(wal), tasks, AndroidAgentTranscriptStore(wal),
                codexRounds = cli, previewPublisher = { preview },
            )
            body(service, request, wal)
            assertEquals(0, http.sentRequestCount)
            assertTrue(home.listFiles()!!.none { it.name.startsWith("codex-round-") })
        } finally {
            sessions.close()
            context.deleteDatabase("$namespace.db")
            AndroidProviderConfiguration.registry = previousRegistry
            context.getSharedPreferences("$namespace.providers.models", 0).edit().clear().commit()
            home.deleteRecursively()
        }
    }

    private fun assertOffline() {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("dumpsys connectivity")
        val report = ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
        assertTrue("The loopback fixture requires an offline device",
            Regex("(?m)^\\s*Active default network:\\s*none\\s*$").containsMatchIn(report))
    }

    private fun replyToCodex(socket: ServerSocket) {
        socket.accept().use { connection ->
            connection.soTimeout = 8_000
            val input = connection.getInputStream().buffered()
            check(readLine(input).startsWith("POST /v1/responses "))
            val headers = generateSequence { readLine(input).takeIf(String::isNotEmpty) }.take(64).toList()
            check(headers.none { it.startsWith("authorization:", ignoreCase = true) })
            val length = headers.single { it.startsWith("content-length:", ignoreCase = true) }
                .substringAfter(':').trim().toInt()
            check(length in 1..1_048_576)
            val body = ByteArray(length)
            var read = 0
            while (read < length) {
                val count = input.read(body, read, length - read)
                check(count > 0)
                read += count
            }
            val request = JSONObject(body.toString(Charsets.UTF_8))
            check(request.getString("model") == MODEL && request.getJSONArray("input").toString().contains("hello"))
            val item = JSONObject().put("id", "msg_loopback").put("type", "message").put("role", "assistant")
                .put("phase", "final_answer").put("status", "completed").put("content", JSONArray()
                    .put(JSONObject().put("type", "output_text").put("text", "Loopback answer").put("annotations", JSONArray())))
            val completed = JSONObject().put("id", "resp_loopback").put("model", MODEL).put("status", "completed")
                .put("output", JSONArray().put(item))
            val stream = listOf(
                "response.created" to JSONObject().put("response", JSONObject().put("id", "resp_loopback")),
                "response.output_item.added" to JSONObject().put("item", JSONObject(item.toString()).put("content", JSONArray())),
                "response.output_text.delta" to JSONObject().put("item_id", "msg_loopback").put("output_index", 0)
                    .put("content_index", 0).put("delta", "Loopback answer"),
                "response.output_item.done" to JSONObject().put("item", item),
                "response.completed" to JSONObject().put("response", completed),
            ).joinToString("") { (type, data) -> "event: $type\ndata: ${data.put("type", type)}\n\n" }
            val payload = stream.toByteArray(Charsets.UTF_8)
            connection.getOutputStream().buffered().use {
                it.write(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" +
                    "Content-Length: ${payload.size}\r\nConnection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
                it.write(payload)
            }
        }
    }

    private fun readLine(input: InputStream): String {
        val line = ByteArrayOutputStream()
        repeat(8192) {
            val byte = input.read()
            check(byte >= 0)
            if (byte == '\n'.code) return line.toString("US-ASCII").trimEnd('\r')
            line.write(byte)
        }
        error("HTTP fixture line too large")
    }

    private fun cas(ids: AgentSessionFixture.Ids, snapshot: JSONObject, revision: Int) = JSONObject()
        .put("schema_version", 1).put("conversation_id", ids.conversation).put("task_id", ids.task)
        .put("attempt_id", ids.attempt).put("expected_controller_generation", revision)
        .put("expected_journal_revision", revision).put("expected_session_generation", snapshot.get("generation"))
        .put("expected_session_sha256", snapshot.get("session_sha256"))

    private fun selector(request: JSONObject, row: JSONObject) = JSONObject().put("schema_version", 2)
        .put("expected_round_revision", row.get("row_revision")).also { out ->
            for (key in listOf("task_id", "attempt_id", "round_id", "round_index", "root", "transcript")) {
                out.put(key, request.get(key))
            }
        }

    private fun row(wal: AndroidAgentWal) = wal.snapshot().getJSONArray("rounds").getJSONObject(0)
    private fun uuid() = UUID.randomUUID().toString()

    private class Server(private val onTurn: (Server) -> Unit) : Process() {
        val methods = mutableListOf<String>()
        private val ended = CountDownLatch(1)
        private val stdout = PipedInputStream(16 * 1024)
        private val output = PipedOutputStream(stdout)
        private val stdin = object : ByteArrayOutputStream() {
            override fun flush() {
                val message = JSONObject(toString("UTF-8"))
                reset()
                val method = message.getString("method")
                methods += method
                when (method) {
                    "initialize" -> response(1, JSONObject().put("userAgent", "fixture"))
                    "initialized" -> Unit
                    "thread/start" -> {
                        val params = message.getJSONObject("params")
                        check(params.getString("sandbox") == "read-only" && params.getString("approvalPolicy") == "never")
                        response(2, JSONObject().put("model", MODEL)
                            .put("thread", JSONObject().put("id", "test-thread").put("ephemeral", true)))
                    }
                    "turn/start" -> {
                        val params = message.getJSONObject("params")
                        check(params.getString("threadId") == "test-thread")
                        check(params.getJSONArray("input").getJSONObject(0).getString("text") == "hello")
                        onTurn(this@Server)
                    }
                    else -> error("Unexpected stdio method")
                }
            }
            override fun close() = disconnect()
        }
        private fun emit(json: JSONObject) = output.write((json.toString() + "\n").toByteArray(Charsets.UTF_8))
        private fun response(id: Int, value: JSONObject) = emit(JSONObject().put("id", id).put("result", value))
        fun event(method: String, params: JSONObject) =
            emit(JSONObject().put("method", method).put("params", params.put("threadId", "test-thread")))
        private fun turn(status: String) = JSONObject().put("turn", JSONObject().put("id", "test-turn").put("status", status))
        fun ack() = response(3, turn("inProgress"))
        fun delta(text: String, turn: String = "test-turn") = event("item/agentMessage/delta",
            JSONObject().put("turnId", turn).put("itemId", "message").put("delta", text))
        fun answer() {
            event("item/completed", JSONObject().put("turnId", "test-turn").put("item", JSONObject()
                .put("id", "message").put("type", "agentMessage").put("phase", "final_answer").put("text", "Authoritative answer")))
            event("turn/completed", turn("completed"))
        }
        fun disconnect() {
            output.close()
            ended.countDown()
        }
        override fun getOutputStream() = stdin
        override fun getInputStream() = stdout
        override fun getErrorStream() = ByteArrayInputStream(byteArrayOf())
        override fun isAlive() = ended.count != 0L
        override fun waitFor(): Int { ended.await(); return 0 }
        override fun waitFor(timeout: Long, unit: TimeUnit) = ended.await(timeout, unit)
        override fun exitValue(): Int = if (isAlive) throw IllegalThreadStateException() else 0
        override fun destroy() = disconnect()
        override fun destroyForcibly(): Process { destroy(); return this }
    }

    private companion object {
        const val MODEL = "gpt-5.6"
    }
}
