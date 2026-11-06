package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.io.File
import java.util.UUID

/** Empty, isolated credential stores: no real account and no network request. */
@RunWith(AndroidJUnit4::class)
class AndroidAgentCredentialPreflightTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private fun cas(ids: AgentSessionFixture.Ids, snapshot: JSONObject, revision: Int) = JSONObject()
        .put("schema_version", 1).put("conversation_id", ids.conversation).put("task_id", ids.task)
        .put("attempt_id", ids.attempt).put("expected_controller_generation", revision)
        .put("expected_journal_revision", revision).put("expected_session_generation", snapshot.get("generation"))
        .put("expected_session_sha256", snapshot.get("session_sha256"))
    private fun digest() = RishAgentCoreNative.hash("visible-history", JSONObject().put("messages", JSONArray()
        .put(JSONObject().put("role", "user").put("content", "hello").put("attachments", JSONArray()))))
    private fun persist(sessions: AndroidSessionStore, session: JSONObject, previous: JSONObject): JSONObject {
        val result = sessions.persist(JSONObject().put("schema_version", 1).put("operation_id", uuid())
            .put("expected", AgentSessionFixture.expecting(previous))
            .put("candidate_json", RishAgentCoreNative.canonical(session.toString())!!))
        assertEquals(result.toString(), "committed", result.optString("status"))
        return result.getJSONObject("snapshot")
    }

    @Test fun missingCredentialFailsBeforeDispatchAndAllowsTerminalCleanup() {
        assumeTrue(RishAgentCoreNative.available)
        AndroidDshModelCatalog.initialize(context)
        val namespace = "credential-preflight-${uuid()}"
        val home = File(context.noBackupFilesDir, namespace).apply { mkdirs() }
        val sessions = AndroidSessionStore(context, "$namespace.db")
        try {
            val wal = AndroidAgentWal(File(home, "wal").apply { mkdirs() })
            val workspaces = AndroidWorkspaceRegistry(File(home, "workspaces").apply { mkdirs() })
            val workspace = workspaces.create("Preflight").getString("workspace_id")
            val roots = AndroidAgentRootResolver(workspaces)
            val prepared = AndroidPreparedAttemptStore(sessions, wal, roots)
            val ids = AgentSessionFixture.Ids()
            val first = AgentSessionFixture.commit(sessions, ids, workspace = workspace)
            val preparation = prepared.prepareAgentAttempt(JSONObject().put("schema_version", 2)
                .put("operation_id", ids.operation).put("controller_cas", cas(ids, first, 0))
                .put("committed_checkpoint", AgentSessionFixture.checkpoint(first, 0))
                .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                .put("workspace_id", workspace).put("project_id", JSONObject.NULL).put("workspace_binding_revision", 1)
                .put("transport_schema_version", 2).put("harness_id", "dsh").put("model", AgentSessionFixture.MODEL)
                .put("thinking_mode", AgentSessionFixture.THINKING).put("visible_message_ids", JSONArray().put(ids.message))
                .put("visible_history_sha256", digest()).put("visible_message_count", 1)
                .put("project_context_sha256", JSONObject.NULL).put("registry_version", 4)
                .put("expected_policy_version", JSONObject.NULL).put("expected_transcript", JSONObject.NULL))
            assertEquals(preparation.toString(), "prepared", preparation.optString("status"))
            val authority = prepared.authorityFor(ids.task, ids.attempt)!!
            val root = authority.getJSONObject("root")
            val roundId = uuid()
            val lineage = JSONObject().put("schema_version", 2).put("round_id", roundId).put("round_index", 0)
                .put("launch_attempt", 1).put("status", "active").put("native_row_revision", JSONObject.NULL)
            val journal = AgentSessionFixture.agentJournal(workspace, "round_in_flight")
                .put("root", root).put("policy", authority.get("policy")).put("tool_registry_version", 4)
                .put("toolset_sha256", authority.getJSONObject("registry").get("toolset_sha256"))
                .put("transcript", authority.get("transcript")).put("round_lineage", lineage)
            val session = AgentSessionFixture.session(ids, workspace = workspace, agent = journal)
            val attempt = session.getJSONArray("conversations").getJSONObject(0).getJSONArray("attempts").getJSONObject(0)
            attempt.put("status", "sending").put("active_round", JSONObject().put("round_id", roundId).put("round_index", 0))
                .put("visible_history_sha256", digest())
            var snapshot = persist(sessions, session, first)
            val credentials = AndroidCredentialStore(context, namespace)
            val configuration = AndroidProviderConfiguration(context, "$namespace.providers")
            val transport = AndroidModelTransport(credentials, configuration)
            val tasks = AndroidLiveTasks()
            val operations = AndroidAgentOperations(wal)
            val rounds = AndroidAgentProviderRoundService(sessions, prepared, AndroidAgentRoundJournal(wal, tasks), roots,
                AndroidAgentToolRegistry, transport, wal, operations, tasks, AndroidAgentTranscriptStore(wal))
            val request = JSONObject().put("schema_version", 2).put("operation_id", uuid())
                .put("controller_cas", cas(ids, snapshot, 1)).put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                .put("round_id", roundId).put("round_index", 0).put("launch_attempt", 1).put("expected_round_revision", 0)
                .put("transport_schema_version", 2).put("harness_id", "dsh").put("model", AgentSessionFixture.MODEL)
                .put("thinking_mode", AgentSessionFixture.THINKING).put("visible_history_sha256", digest())
                .put("visible_message_count", 1).put("project_context_sha256", JSONObject.NULL)
                .put("transcript", authority.get("transcript")).put("root", root).put("registry_version", 4)
                .put("toolset_sha256", authority.getJSONObject("registry").get("toolset_sha256"))
            val result = rounds.completeRound(request)
            assertEquals(result.toString(), "failed_retryable", result.getString("status"))
            assertEquals("E_AGENT_PROVIDER_CREDENTIAL", result.getString("failure_code"))
            assertEquals(0, transport.sentRequestCount)
            assertEquals("not_dispatched", wal.snapshot().getJSONArray("dispatch").getJSONObject(0).getString("dispatch_state"))
            assertEquals("failed_retryable", wal.snapshot().getJSONArray("rounds").getJSONObject(0).getString("state"))

            journal.put("phase", "failed").put("controller_generation", 2).put("transcript", result.get("transcript"))
            lineage.put("status", "failed_retryable").put("native_row_revision", result.get("result_round_revision"))
            attempt.put("status", "failed").put("journal_revision", 2).put("active_round", JSONObject.NULL)
                .put("failure_code", "E_AGENT_PROVIDER_CREDENTIAL")
            val cleanupId = uuid()
            val transcript = result.getJSONObject("transcript")
            session.getJSONArray("agent_transcript_cleanup_outbox").put(JSONObject().put("schema_version", 1)
                .put("cleanup_id", cleanupId).put("conversation_id", ids.conversation).put("task_id", ids.task)
                .put("attempt_id", ids.attempt).put("transcript_ref", transcript.get("transcript_ref"))
                .put("transcript_sha256", transcript.get("transcript_sha256")).put("reason", "failed").put("created_at", AgentSessionFixture.STAMP))
            snapshot = persist(sessions, session, snapshot)
            val lifecycle = AndroidAgentLifecycleService(wal, sessions, operations, roots)
            val finalized = lifecycle.finalize(JSONObject().put("schema_version", 2).put("operation_id", uuid())
                .put("controller_cas", cas(ids, snapshot, 2)).put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 2))
                .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                .put("terminal_reason", "failed").put("cleanup_id", cleanupId).put("transcript", transcript).put("root", root))
            assertEquals(finalized.toString(), "terminal", finalized.optString("status"))
            val discarded = lifecycle.discard(JSONObject().put("schema_version", 2).put("operation_id", uuid())
                .put("cleanup_id", cleanupId).put("task_id", ids.task).put("conversation_id", ids.conversation)
                .put("attempt_id", ids.attempt).put("transcript_ref", transcript.get("transcript_ref"))
                .put("transcript_sha256", transcript.get("transcript_sha256")))
            assertEquals(discarded.toString(), "discarded", discarded.optString("status"))
            assertEquals(0, wal.snapshot().getJSONArray("rounds").length())
            assertEquals(0, wal.snapshot().getJSONArray("ledger").length())
            assertEquals(0, transport.sentRequestCount)
        } finally {
            sessions.close()
            context.deleteDatabase("$namespace.db")
            home.deleteRecursively()
            context.getSharedPreferences(namespace, 0).edit().clear().commit()
            context.getSharedPreferences("$namespace.providers", 0).edit().clear().commit()
        }
    }

    @Test fun failedReadinessReleasesTheSlotAndConfiguredRetryCanPrepare() {
        assumeTrue(RishAgentCoreNative.available)
        AndroidDshModelCatalog.initialize(context)
        val namespace = "credential-readiness-${uuid()}"
        val transport = AndroidModelTransport(AndroidCredentialStore(context, namespace), AndroidProviderConfiguration(context, "$namespace.providers"))
        val requestId = uuid()
        val envelope = JSONObject().put("schema_version", 2).put("harness_id", "dsh").put("model", AgentSessionFixture.MODEL)
            .put("round_id", requestId).put("turn_id", uuid()).put("attempt_id", uuid()).put("round_index", 0)
            .put("thinking_mode", "off").put("visible_history", JSONArray().put(JSONObject().put("role", "user").put("content", "hello").put("attachments", JSONArray())))
            .put("round_transcript", JSONArray()).put("project_context", JSONObject.NULL).put("tools", JSONArray())
        try {
            val first = transport.prepare(envelope.toString())
            try { transport.validate(first, requireCredential = true); fail("missing credential was accepted") }
            catch (failure: RuntimeFailure) { assertEquals("E_COMPLETION_CREDENTIAL_UNAVAILABLE", failure.code) }
            transport.put("DEEPSEEK_API_KEY", transport.account("DEEPSEEK_API_KEY"), "synthetic-never-sent")
            val retry = transport.prepare(envelope.toString())
            transport.validate(retry, requireCredential = true)
            transport.clear("DEEPSEEK_API_KEY")
            try { transport.validate(retry, requireCredential = true); fail("stale credential generation was accepted") }
            catch (failure: RuntimeFailure) { assertEquals("E_COMPLETION_CREDENTIAL_CHANGED", failure.code) }
            assertEquals(0, transport.sentRequestCount)
        } finally {
            transport.clear("DEEPSEEK_API_KEY")
            context.getSharedPreferences(namespace, 0).edit().clear().commit()
            context.getSharedPreferences("$namespace.providers", 0).edit().clear().commit()
        }
    }
}
