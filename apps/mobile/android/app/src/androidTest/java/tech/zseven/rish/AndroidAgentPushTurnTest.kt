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
import tech.zseven.rish.runtime.AndroidAgentApprovalService
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
import tech.zseven.rish.runtime.RuntimeJson
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit


/**
 * The agent's `git_push` as one turn through the ledger: the model asks for
 * it, the batch prepares it against what the bare origin advertises, the
 * person allows it once, the approval is bound, and the call runs and
 * settles with the origin holding the commit. The same steps the controller
 * takes, minus the controller.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentPushTurnTest {
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
    fun aPushTurnIsPreparedApprovedBoundExecutedAndSettled() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        val scratch = File(context.noBackupFilesDir, "push-turn-${UUID.randomUUID()}").apply { mkdirs() }
        val databaseName = "push-turn-${UUID.randomUUID()}.db"
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
            val gitDir = projects.gitDirectory(workspaceId, projectId).absolutePath
            // A commit to push, and a bare origin beside the fixture reached as
            // an absolute path: the native transport that needs no credential.
            File(workDir, "README.md").writeText("# the project\n")
            assertEquals("ok", RishLibgit2Native.stagePath(gitDir, workDir.absolutePath, "README.md"))
            val committed = JSONObject(String(RishLibgit2Native.commit(gitDir, workDir.absolutePath, "first", "Rish", "rish@example.invalid", null), Charsets.UTF_8))
            assertTrue(committed.toString(), committed.getBoolean("ok"))
            val headOid = committed.getString("oid")
            val bare = File(scratch, "origin.git")
            assertEquals("ok", RishLibgit2Native.initSplitRepository(bare.absolutePath, File(scratch, "unused").apply { mkdirs() }.absolutePath))
            assertEquals("ok", RishLibgit2Native.setRemote(gitDir, workDir.absolutePath, bare.absolutePath))

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

            // The provider asks for one push.
            val provider = Provider(
                """{"id":"resp-push","model":"$MODEL","choices":[{"message":{"role":"assistant","content":"",""" +
                    """"tool_calls":[{"id":"call_1","type":"function","function":{"name":"git_push","arguments":"{}"}}]},""" +
                    """"finish_reason":"tool_calls"}]}""",
            )
            provider.start()
            val namespace = "push-turn-${UUID.randomUUID()}"
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
            assertEquals(1, outcome.getJSONArray("calls").length())
            val roundRevision = round.get("result_round_revision")

            // The batch: the push is prepared against what the origin advertises now (nothing).
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
            val projection = receipt.getJSONArray("calls").getJSONObject(0)
            assertEquals(projection.toString(), "git_push", projection.getString("name"))
            assertEquals(projection.toString(), "conversation_confirm", projection.getString("access"))
            val token = projection.optJSONObject("approval_token") ?: throw AssertionError("no approval token minted: $projection")
            val tokenId = token.getString("token")
            val rows = wal.snapshot().getJSONArray("ledger")
            assertEquals(rows.toString(), 1, rows.length())
            val intent = rows.getJSONObject(0).getJSONObject("precondition")
            assertEquals(intent.toString(), "git_push", intent.getString("kind"))
            assertTrue(intent.toString(), intent.isNull("pre_remote_oid"))
            assertEquals(headOid, intent.getString("target_oid"))

            // The journal the controller commits from that receipt: the call waits for the person.
            fun journalCall(decision: String, reference: Any, settled: JSONObject?, revision: Any): JSONObject = JSONObject()
                .put("schema_version", 3).put("call_id", projection.getString("call_id")).put("call_index", projection.getInt("call_index"))
                .put("name", projection.getString("name")).put("arguments_sha256", projection.getString("arguments_sha256"))
                .put("safe_summary_key", projection.getString("safe_summary_key")).put("access", projection.getString("access"))
                .put("approval_token", tokenId).put("approval_decision", decision).put("approval_reference", reference)
                .put("idempotency_key", projection.get("idempotency_key")).put("native_row_revision", revision)
                .put("receipt", settled ?: JSONObject.NULL)
            var transcript = receipt.getJSONObject("transcript")
            generation += 1
            snapshot = AgentSessionFixture.commit(
                sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspaceId,
                agent = journal("approval_pending", transcript, "completed", roundRevision, JSONArray().put(journalCall("pending", JSONObject.NULL, null, 1)), 0),
                model = MODEL, attemptContext = attemptContext,
            )

            // The person allows this once: the decision is committed to the
            // session as an approval event before native is asked to bind it.
            val approvalId = UUID.randomUUID().toString()
            val approvalEvent = JSONObject().put("schema_version", 2).put("event_id", approvalId)
                .put("attempt_id", ids.attempt).put("seq", 1).put("kind", "approval")
                .put("round_index", 0).put("call_id", projection.getString("call_id")).put("status", "approval")
                .put("safe_summary_key", projection.getString("safe_summary_key"))
                .put("arguments_sha256", projection.getString("arguments_sha256"))
                .put("result_sha256", JSONObject.NULL).put("approval_reference", approvalId)
                .put("failure_code", JSONObject.NULL).put("created_at", RuntimeJson.now())
            val allowed = JSONArray().put(journalCall("allow_once", approvalId, null, 1))
            generation += 1
            snapshot = AgentSessionFixture.commit(
                sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspaceId,
                agent = journal("batch_frozen", transcript, "completed", roundRevision, allowed, 0),
                events = JSONArray().put(approvalEvent), model = MODEL, attemptContext = attemptContext,
            )
            val approvals = AndroidAgentApprovalService(wal, sessions, ledger, operations, roots)
            val bound = approvals.bind(bridged(
                JSONObject().put("schema_version", 2).put("operation_id", approvalId)
                    .put("controller_cas", controllerCas(ids, snapshot, generation, 1))
                    .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                    .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                    .put("round_id", roundId).put("round_index", 0)
                    .put("manifest_sha256", receipt.get("manifest_sha256")).put("batch_revision", receipt.get("batch_revision"))
                    .put("call_index", 0).put("call_id", projection.getString("call_id"))
                    .put("token", token).put("decision", "allow_once").put("deny_message", JSONObject.NULL),
            ))
            assertEquals(bound.toString(), "bound", bound.optString("status"))
            assertEquals(bound.toString(), approvalId, bound.optString("approval_reference"))

            // Executed with the bound approval, the push lands on the origin.
            val executions = AndroidAgentToolExecutionService(wal, sessions, prepared, ledger, roots, workspaceTools, liveTasks, transcripts, operations, gitTools)
            generation += 1
            snapshot = AgentSessionFixture.commit(
                sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspaceId,
                agent = journal("execution_intent", transcript, "completed", roundRevision, allowed, 0), model = MODEL, attemptContext = attemptContext,
            )
            val result = executions.execute(bridged(
                JSONObject().put("schema_version", 2).put("operation_id", UUID.randomUUID().toString())
                    .put("controller_cas", controllerCas(ids, snapshot, generation, 1))
                    .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                    .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                    .put("round_id", roundId).put("round_index", 0)
                    .put("batch_kind", receipt.getString("batch_kind")).put("manifest_sha256", receipt.get("manifest_sha256"))
                    .put("expected_batch_revision", receipt.get("batch_revision"))
                    .put("call_index", 0).put("call_id", projection.getString("call_id")).put("name", "git_push")
                    .put("arguments_sha256", projection.getString("arguments_sha256")).put("idempotency_key", projection.get("idempotency_key"))
                    .put("expected_execution_revision", 1)
                    .put("transcript", transcript).put("root", root).put("approval_reference", approvalId),
            ))
            assertEquals(result.toString(), "completed", result.optString("status"))
            val settled = result.getJSONObject("receipt")
            assertEquals("ok", settled.getString("outcome"))
            transcript = result.getJSONObject("transcript")
            assertEquals(headOid, File(bare, "refs/heads/main").readText().trim())
            assertEquals(headOid, File(gitDir, "refs/remotes/origin/main").readText().trim())
            val settledRows = wal.snapshot().getJSONArray("ledger")
            assertEquals(settledRows.toString(), 1, settledRows.length())
            assertEquals("settled", settledRows.getJSONObject(0).getString("state"))
            assertEquals(headOid, settledRows.getJSONObject(0).getJSONObject("settled_facts").getString("actual_remote_oid"))
            val messages = transcripts.nativeMessages(
                JSONObject().put("schema_version", 1).put("attempt_id", ids.attempt).put("root", root).put("transcript", transcript),
            )!!
            val tool = (0 until messages.length()).map { messages.getJSONObject(it) }.last { it.optString("role") == "tool" }
            assertEquals("call_1", tool.optString("call_id"))
            assertTrue(tool.toString(), tool.optString("content").contains("\"pushed_oid\":\"$headOid\""))
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
