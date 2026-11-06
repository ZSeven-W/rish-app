package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.io.File
import java.util.UUID

/** Real session, approval, WAL, JNI store and ledger recovery after an interrupted dispatch. */
@RunWith(AndroidJUnit4::class)
class AndroidAssistantLedgerRecoveryTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private class ProcessDeath : Error("simulated death after atomic store commit")

    @Test fun recreatedLedgerSettlesTaskReceiptWithoutDispatchingAgain() = interrupted(
        "create_assistant_task", JSONObject().put("title", "Review project").put("instructions", "Inspect project changes"), "tasks")

    @Test fun recreatedLedgerSettlesMemoryReceiptWithoutDispatchingAgain() = interrupted(
        "remember_assistant_memory", JSONObject().put("title", "Language").put("content", "Use Chinese").put("kind", "preference"), "memories")

    private fun interrupted(name: String, arguments: JSONObject, collection: String) {
        assertTrue(RishAgentCoreNative.available)
        assertTrue(RishAssistantStoreNative.available)
        val scratch = File(context.noBackupFilesDir, "assistant-ledger-${uuid()}").apply { mkdirs() }
        val database = "assistant-ledger-${uuid()}.db"
        val sessions = AndroidSessionStore(context, database)
        try {
            val ids = AgentSessionFixture.Ids()
            val wal = AndroidAgentWal(File(scratch, "wal").apply { mkdirs() })
            val workspaces = AndroidWorkspaceRegistry(File(scratch, "workspaces").apply { mkdirs() })
            val roots = AndroidAgentRootResolver(workspaces)
            val workspace = workspaces.create("Assistant test").getString("workspace_id")
            val directory = File(scratch, "assistant").apply { mkdirs() }.canonicalFile
            val storeFile = File(directory, "assistant-v1.json")
            storeFile.writeText(JSONObject().put("schema_version", 1).put("revision", 1)
                .put("profile", JSONObject().put("name", "Assistant").put("notes", "Native test").put("soul", "Keep concise"))
                .put("conversation_id", ids.conversation).put("tasks", JSONArray()).put("clock_high_water_ms", 0).toString())
            var applies = 0
            var interrupt = false
            val assistant = AndroidAssistantTaskExecutor({ request ->
                val reply = JSONObject(RishAssistantStoreNative.call(directory.path, request.toString()))
                if (request.optString("action") == "apply") {
                    applies++
                    if (interrupt) { interrupt = false; throw ProcessDeath() }
                }
                reply
            }) { workspaces.descriptor(it)?.apply { getJSONObject("capabilities").put("write", false) } }
            val prepared = AndroidPreparedAttemptStore(sessions, wal, roots, assistant)
            val first = AgentSessionFixture.commit(sessions, ids, workspace = workspace)
            val preparation = prepared.prepareAgentAttempt(JSONObject().put("schema_version", 2).put("operation_id", ids.operation)
                .put("controller_cas", cas(ids, first, 0, 0)).put("committed_checkpoint", AgentSessionFixture.checkpoint(first, 0))
                .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                .put("workspace_id", workspace).put("project_id", JSONObject.NULL).put("workspace_binding_revision", 1)
                .put("transport_schema_version", 2).put("model", AgentSessionFixture.MODEL).put("thinking_mode", "off")
                .put("visible_message_ids", JSONArray().put(ids.message)).put("visible_history_sha256", visibleDigest())
                .put("visible_message_count", 1).put("project_context_sha256", JSONObject.NULL)
                .put("registry_version", 5).put("expected_policy_version", JSONObject.NULL).put("expected_transcript", JSONObject.NULL))
            assertEquals(preparation.toString(), "prepared", preparation.optString("status"))
            val authority = prepared.authorityFor(ids.task, ids.attempt)!!
            val root = authority.getJSONObject("root")
            // Narrow the fixture's frozen agent authority to a read-only
            // workspace. Android currently mounts only app-owned workspaces;
            // this exercises the same core proof without widening host grants.
            root.put("capabilities", JSONArray().put("file_read"))
            authority.put("registry", AndroidAgentToolRegistry.registryForRoot(root, 5))
            assertEquals("durable_deny", AndroidAgentToolRegistry.descriptorForTool("write_file", root, 5).getString("access"))
            assertEquals("conversation_confirm", AndroidAgentToolRegistry.descriptorForTool(name, root, 5).getString("access"))
            assertEquals("assistant_metadata", AndroidAgentToolRegistry.nativeDescriptor(name, 5).getString("required_capability"))
            assertEquals("Keep concise", authority.getJSONObject("assistant_context").getString("soul"))
            val before = authority.getJSONObject("transcript")
            val transcriptStore = AndroidAgentTranscriptStore(wal)
            val sha = RishAgentCoreNative.hash("tool-arguments", JSONObject().put("name", name).put("arguments", arguments))
            val raw = JSONObject().put("schema_version", 1).put("call_id", "call-assistant").put("name", name)
                .put("arguments_json", arguments.toString())
            val transcript = transcriptStore.append(JSONObject().put("schema_version", 1).put("attempt_id", ids.attempt)
                .put("root", root).put("expected_transcript", before).put("message", JSONObject().put("schema_version", 1)
                    .put("role", "assistant").put("round_index", 0).put("content", "").put("reasoning_content", "")
                    .put("tool_calls", JSONArray().put(raw))))!!
            val roundId = uuid()
            val descriptor = AndroidAgentToolRegistry.descriptorForTool(name, root, 5)
            val presentation = JSONObject().put("schema_version", 3).put("call_index", 0).put("call_id", "call-assistant")
                .put("name", name).put("arguments_sha256", sha).put("safe_summary_key", descriptor.get("safe_summary_key"))
                .put("access", descriptor.get("access")).put("approval_state", "deferred")
            val locator = JSONObject().put("schema_version", 1).put("task_id", ids.task).put("attempt_id", ids.attempt)
                .put("round_id", roundId).put("round_index", 0)
            val completion = JSONObject().put("schema_version", 1).put("transport_schema_version", 2)
                .put("turn_id", ids.task).put("attempt_id", ids.attempt).put("round_id", roundId).put("round_index", 0)
                .put("provider_request_id", "fixture-request").put("provider_response_id", "fixture-response")
                .put("requested_model", AgentSessionFixture.MODEL).put("model", AgentSessionFixture.MODEL).put("thinking_mode", "off")
                .put("finish_reason", "tool_calls").put("latency_ms", 1).put("visible_history_sha256", visibleDigest())
                .put("model_input_sha256", "b".repeat(64)).put("request_body_sha256", "c".repeat(64)).put("project_context_receipt", JSONObject.NULL)
            val round = JSONObject().put("schema_version", 3).put("locator", locator).put("row_revision", 1)
                .put("root_fingerprint_sha256", root.get("root_fingerprint_sha256")).put("binding_revision", 1)
                .put("request_sha256", "d".repeat(64)).put("transcript_before", before).put("launch_attempt", 1)
                .put("state", "completed").put("owner", JSONObject.NULL).put("failure_code", JSONObject.NULL)
                .put("completion_receipt", completion).put("transcript_after", transcript).put("calls", JSONArray().put(presentation))
                .put("batch_class", "executable").put("executable_call_count", 1).put("denied_call_count", 0)
                .put("terminal_kind", "tool_batch").put("created_at", RuntimeJson.now()).put("updated_at", RuntimeJson.now())
            assertTrue(wal.transaction { state ->
                state.getJSONArray("authorities").put(0, authority.put("transcript", transcript))
                state.getJSONArray("rounds").put(round)
                state.getJSONArray("dispatch").put(JSONObject().put("schema_version", 1).put("kind", "round")
                    .put("locator", locator).put("dispatch_state", "dispatched"))
                true
            })
            var generation = 1
            fun journal(phase: String, calls: JSONArray) = AgentSessionFixture.agentJournal(workspace, phase)
                .put("controller_generation", generation).put("tool_registry_version", 5).put("root", root)
                .put("toolset_sha256", authority.getJSONObject("registry").get("toolset_sha256"))
                .put("policy", authority.get("policy")).put("transcript", transcript)
                .put("round_lineage", if (phase == "ready_for_round") JSONObject.NULL else JSONObject().put("schema_version", 2).put("round_id", roundId).put("round_index", 0)
                    .put("launch_attempt", 1).put("status", "completed").put("native_row_revision", 1))
                .put("batch", calls).put("call_index", if (calls.length() == 0) JSONObject.NULL else 0)
            var snapshot = AgentSessionFixture.commit(sessions, ids, expected = AgentSessionFixture.expecting(first),
                workspace = workspace, agent = journal("ready_for_round", JSONArray()))
            val live = AndroidLiveTasks()
            val operations = AndroidAgentOperations(wal)
            val ledger = AndroidAgentExecutionLedger(wal, live, operations)
            val workspaceTools = AndroidWorkspaceToolExecutor(workspaces, roots)
            val batches = AndroidAgentToolBatchService(wal, sessions, prepared, ledger, roots, workspaceTools, operations,
                transcriptStore, assistantTools = assistant)
            val batch = batches.prepare(JSONObject().put("schema_version", 2).put("operation_id", uuid())
                .put("controller_cas", cas(ids, snapshot, generation)).put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                .put("round_id", roundId).put("round_index", 0).put("expected_round_revision", 1)
                .put("transcript", transcript).put("root", root).put("registry_version", 5)
                .put("toolset_sha256", authority.getJSONObject("registry").get("toolset_sha256"))
                .put("policy_version", "agent-v1").put("expected_batch_revision", 0).put("expected_reserved_write_bytes", 0))
            assertEquals(batch.toString(), "prepared", batch.optString("status"))
            val receipt = batch.getJSONObject("receipt")
            val call = receipt.getJSONArray("calls").getJSONObject(0)
            val token = call.getJSONObject("approval_token")
            fun journalCall(decision: String, reference: Any) = JSONObject().put("schema_version", 3)
                .put("call_id", call.get("call_id")).put("call_index", 0).put("name", name).put("arguments_sha256", sha)
                .put("safe_summary_key", call.get("safe_summary_key")).put("access", call.get("access"))
                .put("approval_token", token.get("token")).put("approval_decision", decision).put("approval_reference", reference)
                .put("idempotency_key", call.get("idempotency_key")).put("native_row_revision", 1).put("receipt", JSONObject.NULL)
            fun executeRequest(reference: Any) = JSONObject().put("schema_version", 2).put("operation_id", uuid())
                .put("controller_cas", cas(ids, snapshot, generation)).put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1))
                .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
                .put("round_id", roundId).put("round_index", 0).put("batch_kind", receipt.get("batch_kind"))
                .put("manifest_sha256", receipt.get("manifest_sha256")).put("expected_batch_revision", receipt.get("batch_revision"))
                .put("call_index", 0).put("call_id", call.get("call_id")).put("name", name).put("arguments_sha256", sha)
                .put("idempotency_key", call.get("idempotency_key")).put("expected_execution_revision", 1)
                .put("transcript", transcript).put("root", root).put("approval_reference", reference)
            generation++
            snapshot = AgentSessionFixture.commit(sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspace,
                agent = journal("approval_pending", JSONArray().put(journalCall("pending", JSONObject.NULL))))
            val execution = AndroidAgentToolExecutionService(wal, sessions, prepared, ledger, roots, workspaceTools, live,
                transcriptStore, operations, assistantTools = assistant)
            val beforeApproval = storeFile.readText()
            val refused = try { execution.execute(executeRequest(JSONObject.NULL)).optString("status") }
                catch (failure: AndroidAgentToolExecutionService.Refused) { failure.code }
            assertTrue(refused, refused in setOf("conflict", "E_AGENT_APPROVAL", "E_AGENT_CONFLICT"))
            assertEquals(0, applies)
            assertEquals(beforeApproval, storeFile.readText())
            val approvalId = uuid()
            val allowed = JSONArray().put(journalCall("allow_once", approvalId))
            val event = JSONObject().put("schema_version", 2).put("event_id", approvalId).put("attempt_id", ids.attempt)
                .put("seq", 1).put("kind", "approval").put("round_index", 0).put("call_id", call.get("call_id"))
                .put("status", "approval").put("safe_summary_key", call.get("safe_summary_key")).put("arguments_sha256", sha)
                .put("result_sha256", JSONObject.NULL).put("approval_reference", approvalId).put("failure_code", JSONObject.NULL)
                .put("created_at", RuntimeJson.now())
            generation++
            snapshot = AgentSessionFixture.commit(sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspace,
                agent = journal("batch_frozen", allowed), events = JSONArray().put(event))
            val bound = AndroidAgentApprovalService(wal, sessions, ledger, operations, roots).bind(JSONObject()
                .put("schema_version", 2).put("operation_id", approvalId).put("controller_cas", cas(ids, snapshot, generation))
                .put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 1)).put("task_id", ids.task)
                .put("conversation_id", ids.conversation).put("attempt_id", ids.attempt).put("round_id", roundId).put("round_index", 0)
                .put("manifest_sha256", receipt.get("manifest_sha256")).put("batch_revision", receipt.get("batch_revision"))
                .put("call_index", 0).put("call_id", call.get("call_id")).put("token", token).put("decision", "allow_once")
                .put("deny_message", JSONObject.NULL))
            assertEquals(bound.toString(), "bound", bound.optString("status"))
            generation++
            snapshot = AgentSessionFixture.commit(sessions, ids, expected = AgentSessionFixture.expecting(snapshot), workspace = workspace,
                agent = journal("execution_intent", allowed))
            val request = executeRequest(approvalId)
            interrupt = true
            assertThrows(ProcessDeath::class.java) { execution.execute(request) }
            assertEquals(1, applies)
            val storeAfter = storeFile.readText()
            assertEquals(1, JSONObject(storeAfter).getJSONArray(collection).length())
            val interrupted = wal.snapshot().getJSONArray("ledger").getJSONObject(0)
            assertEquals("running", interrupted.getString("state"))
            assertTrue(interrupted.isNull("receipt"))
            // A different root forces a fresh Rust resident handle to load the
            // committed file; a new liveness registry makes the saved owner dead.
            val restoredRoot = File(scratch, "restored-wal").apply { mkdirs() }
            File(wal.root, AndroidAgentWal.FILE_NAME).copyTo(File(restoredRoot, AndroidAgentWal.FILE_NAME))
            val restoredWal = AndroidAgentWal(restoredRoot)
            assertEquals(interrupted.toString(), restoredWal.snapshot().getJSONArray("ledger").getJSONObject(0).toString())
            val restoredLive = AndroidLiveTasks()
            val restoredOperations = AndroidAgentOperations(restoredWal)
            val restoredLedger = AndroidAgentExecutionLedger(restoredWal, restoredLive, restoredOperations)
            val restoredTranscript = AndroidAgentTranscriptStore(restoredWal)
            val restoredPrepared = AndroidPreparedAttemptStore(sessions, restoredWal, roots, assistant)
            val restored = AndroidAgentToolExecutionService(restoredWal, sessions, restoredPrepared, restoredLedger, roots,
                workspaceTools, restoredLive, restoredTranscript, restoredOperations, assistantTools = assistant)
            val recovered = restored.recover(request)
            assertEquals(recovered.toString(), "completed", recovered.optString("status"))
            assertEquals("ok", recovered.getJSONObject("receipt").getString("outcome"))
            assertEquals("settled", restoredWal.snapshot().getJSONArray("ledger").getJSONObject(0).getString("state"))
            assertEquals(recovered.toString(), restored.recover(request).toString())
            assertEquals(1, applies)
            assertEquals(storeAfter, storeFile.readText())
        } finally {
            sessions.close()
            context.deleteDatabase(database)
            scratch.deleteRecursively()
        }
    }

    private fun cas(ids: AgentSessionFixture.Ids, snapshot: JSONObject, generation: Int, journal: Int = 1) = JSONObject()
        .put("schema_version", 1).put("conversation_id", ids.conversation).put("task_id", ids.task).put("attempt_id", ids.attempt)
        .put("expected_controller_generation", generation).put("expected_journal_revision", journal)
        .put("expected_session_generation", snapshot.get("generation")).put("expected_session_sha256", snapshot.get("session_sha256"))

    private fun visibleDigest() = RishAgentCoreNative.hash("visible-history", JSONObject().put("messages", JSONArray()
        .put(JSONObject().put("role", "user").put("content", "hello").put("attachments", JSONArray()))))
}
