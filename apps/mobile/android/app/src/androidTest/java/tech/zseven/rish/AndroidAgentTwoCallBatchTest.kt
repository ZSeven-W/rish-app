package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentOperations
import tech.zseven.rish.runtime.AndroidAgentExecutionLedger
import tech.zseven.rish.runtime.AndroidAgentGitToolExecutor
import tech.zseven.rish.runtime.AndroidAgentToolBatchService
import tech.zseven.rish.runtime.AndroidAgentToolExecutionService
import tech.zseven.rish.runtime.AndroidWorkspaceToolExecutor
import tech.zseven.rish.runtime.AndroidAgentProviderRoundService
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidAgentRoundJournal
import tech.zseven.rish.runtime.AndroidAgentToolRegistry
import tech.zseven.rish.runtime.AndroidAgentTranscriptStore
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.AndroidCredentialStore
import tech.zseven.rish.runtime.AndroidLiveTasks
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidPreparedAttemptStore
import tech.zseven.rish.runtime.AndroidProjectContextSnapshots
import tech.zseven.rish.runtime.AndroidProjectContextStore
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit


/**
 * One round that asks for two tools, and the batch that runs them: the
 * evidence the device gave once, made repeatable. `git_status` settles first
 * and `list_dir` after it, and the second call reads its arguments under the
 * transcript the *request* names -- the generation the first settlement
 * produced -- not the batch's `transcript_before`. Reading under the latter
 * was the defect that stopped every second call on the beta build with
 * E_AGENT_STORE_3, and no test here reached it.
 *
 * The journal is written between steps the way the controller writes it,
 * because the core relates every execute request to the committed session:
 * batch_frozen after the batch receipt, execution_intent before each call,
 * the settled receipt folded in after it.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentTwoCallBatchTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** A provider that records one request and answers a fixed chat-completions stream. */
    private class Provider(private val reply: String) {
        val socket: ServerSocket = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0))
        }
        val served = CountDownLatch(1)
        @Volatile var request: String = ""

        fun start() {
            Thread {
                socket.use { server ->
                    server.accept().use { client ->
                        val input = client.getInputStream()
                        val head = StringBuilder()
                        while (!head.endsWith("\r\n\r\n")) {
                            val next = input.read()
                            if (next < 0) return@use
                            head.append(next.toChar())
                        }
                        val length = Regex("(?i)content-length: *(\\d+)").find(head)?.groupValues?.get(1)?.toInt() ?: 0
                        val body = ByteArray(length)
                        var read = 0
                        while (read < length) {
                            val count = input.read(body, read, length - read)
                            if (count < 0) break
                            read += count
                        }
                        request = head.toString() + String(body, Charsets.UTF_8)
                        val out = client.getOutputStream()
                        out.write(
                            ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n" +
                                "Content-Length: ${reply.toByteArray().size}\r\n\r\n").toByteArray(),
                        )
                        out.write(reply.toByteArray(Charsets.UTF_8))
                        out.flush()
                        served.countDown()
                    }
                }
            }.apply { isDaemon = true }.start()
        }
    }

    @Test
    fun bothCallsOfOneBatchSettleAndTheTranscriptCarriesBothResults() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        val scratch = File(context.noBackupFilesDir, "two-call-${UUID.randomUUID()}").apply { mkdirs() }
        val databaseName = "two-call-${UUID.randomUUID()}.db"
        val sessions = AndroidSessionStore(context, databaseName)
        try {
            val wal = AndroidAgentWal(File(scratch, "wal").apply { mkdirs() })
            val workspaces = AndroidWorkspaceRegistry(File(scratch, "registry").apply { mkdirs() })
            val projects = AndroidWorkspaceProjects(workspaces)
            val roots = AndroidAgentRootResolver(workspaces, projects)
            val workspaceId = workspaces.create("Scratch").getString("workspace_id")
            val projectId = projects.attach(
                JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString()).put("mode", "init")
                    .put("root", rootRef(workspaceId, null)),
            ).getJSONObject("project").getString("project_id")
            val workDir = workspaces.rootFor(workspaceId)!!
            File(workDir, "README.md").writeText("# the project\n")
            assertEquals("ok", RishLibgit2Native.stagePath(projects.gitDirectory(workspaceId, projectId).absolutePath, workDir.absolutePath, "README.md"))

            // The attempt carries a confirmed project context, as the round
            // test's does: a project root is only bound through one.
            val snapshots = AndroidProjectContextSnapshots(projects, roots, AndroidProjectContextStore(File(scratch, "project-context")))
            val runtimeContextId = UUID.randomUUID().toString()
            val manifest = snapshots.prepare(
                JSONObject().put("schema_version", 2).put("root", rootRef(workspaceId, projectId))
                    .put("conversation_id", runtimeContextId).put("model_id", MODEL).put("policy", "chat-read-v1")
                    .put("selected_paths", JSONArray().put("README.md")),
            )
            val snapshotId = manifest.getString("snapshot_id")
            val consent = snapshots.confirm(JSONObject().put("schema_version", 2).put("snapshot_id", snapshotId).put("root", rootRef(workspaceId, projectId)))
            val ids = AgentSessionFixture.Ids()
            val attemptContext = JSONObject().put("schema_version", 1).put("runtime_context_id", runtimeContextId)
                .put("project_id", projectId).put("snapshot_id", snapshotId)
                .put("snapshot_sha256", manifest.getString("snapshot_sha256"))
                .put("source_fingerprint", manifest.getString("source_fingerprint"))
                .put("context_bytes", manifest.getInt("context_bytes"))
                .put("consent_receipt_id", consent.getString("consent_receipt_id"))
                .put("provider", "openai").put("policy", "chat-read-v1").put("policy_version", "chat-read-v1.0.0")
            val first = AgentSessionFixture.commit(sessions, ids, workspace = workspaceId, model = MODEL, attemptContext = attemptContext)
            val prepared = AndroidPreparedAttemptStore(sessions, wal, roots)
            val preparation = prepared.prepareAgentAttempt(
                JSONObject().put("schema_version", 2).put("operation_id", ids.operation)
                    .put("controller_cas", controllerCas(ids, first, 0, 0))
                    .put("committed_checkpoint", AgentSessionFixture.checkpoint(first, 0))
                    .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                    .put("workspace_id", workspaceId).put("project_id", projectId).put("workspace_binding_revision", 1)
                    .put("transport_schema_version", 3).put("model", MODEL).put("thinking_mode", THINKING)
                    .put("visible_message_ids", JSONArray().put(ids.message))
                    .put("visible_history_sha256", visibleDigest()).put("visible_message_count", 1)
                    .put("project_context_sha256", manifest.getString("snapshot_sha256"))
                    .put("registry_version", 2).put("expected_policy_version", JSONObject.NULL)
                    .put("expected_transcript", JSONObject.NULL),
            )
            assertEquals(preparation.toString(), "prepared", preparation.optString("status"))
            val authority = prepared.authorityFor(ids.task, ids.attempt)!!
            val root = authority.getJSONObject("root")
            val roundId = UUID.randomUUID().toString()

            var generation = 1
            // A journal in the shape the controller commits at each step. An
            // in-flight round also needs the attempt's `active_round`, which
            // the fixture does not model, so the round is asked for from
            // `ready_for_round` as the round test does.
            fun journal(phase: String, transcript: JSONObject, lineageStatus: String?, roundRevision: Any, batch: JSONArray, callIndex: Any): JSONObject =
                AgentSessionFixture.agentJournal(workspaceId, phase)
                    .put("controller_generation", generation)
                    .put("root", root).put("transcript", transcript)
                    .put("toolset_sha256", authority.getJSONObject("registry").getString("toolset_sha256"))
                    .put("policy", authority.getJSONObject("policy"))
                    .put(
                        "round_lineage",
                        if (lineageStatus == null) JSONObject.NULL
                        else JSONObject().put("schema_version", 2).put("round_id", roundId).put("round_index", 0)
                            .put("launch_attempt", 1).put("status", lineageStatus).put("native_row_revision", roundRevision),
                    )
                    .put("batch", batch).put("call_index", callIndex)
            var snapshot = AgentSessionFixture.commit(
                sessions, ids, expected = AgentSessionFixture.expecting(first), workspace = workspaceId,
                agent = journal("ready_for_round", authority.getJSONObject("transcript"), null, JSONObject.NULL, JSONArray(), JSONObject.NULL),
                model = MODEL, attemptContext = attemptContext,
            )

            // The provider asks for two tools in one turn.
            val provider = Provider(
                """{"id":"resp-two","model":"$MODEL","choices":[{"message":{"role":"assistant","content":"",""" +
                    """"tool_calls":[{"id":"call_1","type":"function","function":{"name":"git_status","arguments":"{}"}},""" +
                    """{"id":"call_2","type":"function","function":{"name":"list_dir","arguments":"{\"path\":\".\"}"}}]},""" +
                    """"finish_reason":"tool_calls"}]}""",
            )
            provider.start()
            val namespace = "two-call-${UUID.randomUUID()}"
            val configurations = AndroidProviderConfiguration(context, "$namespace.providers")
            val transport = AndroidModelTransport(AndroidCredentialStore(context, namespace), configurations)
            configurations.save(
                JSONObject().put("schema_version", 1).put("harness_id", "codex").put("name", "Local")
                    .put("endpoint_url", "http://127.0.0.1:${provider.socket.localPort}/v1/chat/completions")
                    .put("protocol", "chat-completions").put("auth_type", "bearer")
                    .put("model_mappings", JSONObject().put(MODEL, MODEL))
                    .put("send_reasoning", false).put("full_url", true),
            )
            transport.put("OPENAI_API_KEY", transport.account("OPENAI_API_KEY"), "local-test-key")

            val liveTasks = AndroidLiveTasks()
            val operations = AndroidAgentOperations(wal)
            val transcripts = AndroidAgentTranscriptStore(wal)
            val ledger = AndroidAgentExecutionLedger(wal, liveTasks, operations)
            val workspaceTools = AndroidWorkspaceToolExecutor(workspaces, roots)
            val gitTools = AndroidAgentGitToolExecutor(projects, workspaces, roots)
            val rounds = AndroidAgentProviderRoundService(
                sessions, prepared, AndroidAgentRoundJournal(wal, liveTasks), roots, AndroidAgentToolRegistry, transport, wal,
                operations, liveTasks, transcripts, snapshots,
            )
            val round = rounds.completeRound(bridged(
                JSONObject().put("schema_version", 2).put("operation_id", UUID.randomUUID().toString())
                    .put("controller_cas", controllerCas(ids, snapshot, generation, 1))
                    .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                    .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                    .put("round_id", roundId).put("round_index", 0).put("launch_attempt", 1).put("expected_round_revision", 0)
                    .put("transport_schema_version", 3).put("harness_id", "codex").put("model", MODEL).put("thinking_mode", THINKING)
                    .put("visible_history_sha256", visibleDigest()).put("visible_message_count", 1)
                    .put("project_context_sha256", manifest.getString("snapshot_sha256"))
                    .put("transcript", authority.getJSONObject("transcript"))
                    .put("root", root)
                    .put("registry_version", 2).put("toolset_sha256", AndroidAgentToolRegistry.toolsetSha256()),
            ))
            assertTrue(provider.served.await(20, TimeUnit.SECONDS))
            assertEquals(round.toString(), "completed", round.getString("status"))
            val outcome = round.getJSONObject("outcome")
            assertEquals(round.toString(), "tool_batch", outcome.getString("kind"))
            assertEquals(2, outcome.getJSONArray("calls").length())
            val roundRevision = round.get("result_round_revision")

            // The batch, as the controller asks for it after the round.
            val batches = AndroidAgentToolBatchService(wal, sessions, prepared, ledger, roots, workspaceTools, operations, transcripts, gitTools)
            val batch = batches.prepare(bridged(
                JSONObject().put("schema_version", 2).put("operation_id", UUID.randomUUID().toString())
                    .put("controller_cas", controllerCas(ids, snapshot, generation, 1))
                    .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                    .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                    .put("round_id", roundId).put("round_index", 0).put("expected_round_revision", roundRevision)
                    .put("transcript", outcome.getJSONObject("transcript")).put("root", root)
                    .put("registry_version", 2).put("toolset_sha256", AndroidAgentToolRegistry.toolsetSha256())
                    .put("policy_version", "agent-v1").put("expected_batch_revision", 0).put("expected_reserved_write_bytes", 0),
            ))
            assertEquals(batch.toString(), "prepared", batch.optString("status"))
            val receipt = batch.getJSONObject("receipt")
            val calls = receipt.getJSONArray("calls")
            assertEquals(receipt.toString(), 2, calls.length())

            // The journal the controller commits from that receipt.
            fun journalCall(projection: JSONObject, settled: JSONObject?, revision: Any): JSONObject = JSONObject()
                .put("schema_version", 3).put("call_id", projection.getString("call_id")).put("call_index", projection.getInt("call_index"))
                .put("name", projection.getString("name")).put("arguments_sha256", projection.getString("arguments_sha256"))
                .put("safe_summary_key", projection.getString("safe_summary_key")).put("access", projection.getString("access"))
                .put("approval_token", JSONObject.NULL).put("approval_decision", "pending").put("approval_reference", JSONObject.NULL)
                .put("idempotency_key", projection.get("idempotency_key")).put("native_row_revision", revision)
                .put("receipt", settled ?: JSONObject.NULL)
            val journalBatch = JSONArray().put(journalCall(calls.getJSONObject(0), null, 1)).put(journalCall(calls.getJSONObject(1), null, 1))
            var transcript = receipt.getJSONObject("transcript")
            generation += 1
            snapshot = AgentSessionFixture.commit(
                sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspaceId,
                agent = journal("batch_frozen", transcript, "completed", roundRevision, journalBatch, 0), model = MODEL, attemptContext = attemptContext,
            )

            val executions = AndroidAgentToolExecutionService(wal, sessions, prepared, ledger, roots, workspaceTools, liveTasks, transcripts, operations, gitTools)
            val results = ArrayList<JSONObject>()
            for (index in 0 until 2) {
                val call = journalBatch.getJSONObject(index)
                generation += 1
                snapshot = AgentSessionFixture.commit(
                    sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspaceId,
                    agent = journal("execution_intent", transcript, "completed", roundRevision, journalBatch, index), model = MODEL, attemptContext = attemptContext,
                )
                val result = executions.execute(bridged(
                    JSONObject().put("schema_version", 2).put("operation_id", UUID.randomUUID().toString())
                        .put("controller_cas", controllerCas(ids, snapshot, generation, 1))
                        .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                        .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                        .put("round_id", roundId).put("round_index", 0)
                        .put("batch_kind", receipt.getString("batch_kind")).put("manifest_sha256", receipt.get("manifest_sha256"))
                        .put("expected_batch_revision", receipt.get("batch_revision"))
                        .put("call_index", index).put("call_id", call.getString("call_id")).put("name", call.getString("name"))
                        .put("arguments_sha256", call.getString("arguments_sha256")).put("idempotency_key", call.get("idempotency_key"))
                        .put("expected_execution_revision", call.get("native_row_revision"))
                        .put("transcript", transcript).put("root", root).put("approval_reference", JSONObject.NULL),
                ))
                assertEquals("call $index: $result", "completed", result.optString("status"))
                val settled = result.getJSONObject("receipt")
                assertEquals(call.getString("call_id"), settled.getString("call_id"))
                assertEquals("ok", settled.getString("outcome"))
                results.add(result)
                // What the controller folds back: the receipt, the row's revision, the transcript it produced.
                journalBatch.put(index, journalCall(calls.getJSONObject(index), settled, result.get("result_execution_revision")))
                transcript = result.getJSONObject("transcript")
            }

            // Two settled rows, and the transcript ends with one tool message per call, in order.
            val rows = wal.snapshot().getJSONArray("ledger")
            assertEquals(2, rows.length())
            for (index in 0 until rows.length()) assertEquals(rows.toString(), "settled", rows.getJSONObject(index).getString("state"))
            val messages = transcripts.nativeMessages(
                JSONObject().put("schema_version", 1).put("attempt_id", ids.attempt).put("root", root).put("transcript", transcript),
            )!!
            val tools = (0 until messages.length()).map { messages.getJSONObject(it) }.filter { it.optString("role") == "tool" }
            assertEquals(messages.toString(), listOf("call_1", "call_2"), tools.map { it.optString("call_id") })
        } finally {
            sessions.close()
            context.deleteDatabase(databaseName)
            scratch.deleteRecursively()
        }
    }

    private fun rootRef(workspaceId: String, projectId: String?): JSONObject = JSONObject()
        .put("schema_version", 1).put("workspace_id", workspaceId).put("binding_revision", 1)
        .put("project_id", projectId ?: JSONObject.NULL)

    private fun controllerCas(ids: AgentSessionFixture.Ids, snapshot: JSONObject, generation: Int, journal: Int): JSONObject =
        JSONObject().put("schema_version", 1).put("conversation_id", ids.conversation).put("task_id", ids.task)
            .put("attempt_id", ids.attempt).put("expected_controller_generation", generation)
            .put("expected_journal_revision", journal)
            .put("expected_session_generation", snapshot.getLong("generation"))
            .put("expected_session_sha256", snapshot.getString("session_sha256"))

    private fun visibleDigest(): String = RishAgentCoreNative.hash(
        "visible-history",
        JSONObject().put("messages", JSONArray().put(JSONObject().put("role", "user").put("content", "hello").put("attachments", JSONArray()))),
    )

    /** Numbers as the React Native bridge delivers them: all Double. */
    private fun bridged(value: Any?): Any? = when (value) {
        is JSONObject -> JSONObject().also { out -> for (key in value.keys()) out.put(key, bridged(value.get(key))) }
        is JSONArray -> JSONArray().also { out -> for (index in 0 until value.length()) out.put(bridged(value.get(index))) }
        is Int -> value.toDouble()
        is Long -> value.toDouble()
        else -> value
    }
    private fun bridged(value: JSONObject): JSONObject = bridged(value as Any?) as JSONObject

    private companion object {
        const val MODEL = "gpt-5.6"
        const val THINKING = AgentSessionFixture.THINKING
    }
}
