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

@RunWith(AndroidJUnit4::class)
class AndroidCustomProviderMutationTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()

    private inner class Fixture {
        val previousRegistry = AndroidProviderConfiguration.registry
        val namespace = "custom-provider-mutation-${uuid()}"
        val directory = File(context.noBackupFilesDir, namespace).apply { mkdirs() }
        val configurations = AndroidProviderConfiguration(context, namespace)
        val credentials = AndroidCredentialStore(context, "$namespace.keys")
        val transport = AndroidModelTransport(credentials, configurations)
        val sessions = AndroidSessionStore(context, "$namespace.db")
        val emptySessions = AndroidSessionStore(context, "$namespace.empty.db")
        val wal = AndroidAgentWal(File(directory, "wal").apply { mkdirs() })
        val emptyWal = AndroidAgentWal(File(directory, "empty-wal").apply { mkdirs() })
        val service = AndroidCustomProviders(configurations, transport, credentials, sessions, wal)
        val id = uuid()
        val modelId = uuid()
        val model = "custom:$id:$modelId"
        init {
            val config = configurations.normalize(JSONObject().put("schema_version", 1).put("harness_id", "custom-$id")
                .put("name", "Test provider").put("endpoint_url", "https://first.example.com/v1")
                .put("protocol", "responses").put("auth_type", "bearer").put("send_reasoning", false)
                .put("model_mappings", JSONObject().put(model, "same-upstream")))
            service.save(JSONObject().put("schema_version", 1).put("expected_revision", 0)
                .put("provider", JSONObject().put("id", id).put("configuration", config).put("active", true)
                    .put("models", JSONArray().put(JSONObject().put("id", modelId).put("name", "Model")
                        .put("wire_model", "same-upstream").put("supports_images", false).put("active", true)))))
        }
        fun prompt() = JSONObject().put("schema_version", 1).put("id", id)
            .put("expected_profile", configurations.custom.provider(id).getJSONObject("configuration"))
        fun remove() = JSONObject().put("schema_version", 1).put("expected_revision", 1).put("id", id)
        fun close() {
            sessions.close(); emptySessions.close()
            context.deleteDatabase("$namespace.db"); context.deleteDatabase("$namespace.empty.db")
            for (name in listOf(namespace, "$namespace.custom", "$namespace.keys")) {
                context.getSharedPreferences(name, 0).edit().clear().commit()
            }
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("$namespace.keys.aes") }
            directory.deleteRecursively()
            AndroidProviderConfiguration.registry = previousRegistry
        }
    }

    private fun refused(code: String, operation: () -> Any?) {
        try { operation(); fail("expected $code") }
        catch (failure: RuntimeFailure) { assertEquals(code, failure.code) }
    }

    @Test fun promptCapturedForAnOldProfileCannotStoreAKeyAfterAnEdit() {
        val fixture = Fixture()
        try {
            val captured = fixture.service.credentialScope(fixture.prompt())
            val edited = JSONObject(fixture.configurations.custom.provider(fixture.id).toString())
            edited.getJSONObject("configuration").put("endpoint_url", "https://second.example.com/v1/responses")
            fixture.service.save(JSONObject().put("schema_version", 1).put("expected_revision", 1).put("provider", edited))
            refused("E_COMPLETION_CREDENTIAL_CHANGED") { fixture.service.put(captured, "fixture-only-secret") }
            assertFalse(fixture.credentials.configured(captured.account!!))
            val current = fixture.service.credentialScope(fixture.prompt())
            assertNotEquals(captured.account, current.account)
            assertFalse(fixture.credentials.configured(current.account!!))
            fixture.service.put(current, "fixture-only-secret")
            assertTrue(fixture.credentials.configured(current.account!!))
        } finally { fixture.close() }
    }

    @Test fun activeTransportReservationBlocksMetadataMutationWithoutCancellation() {
        val fixture = Fixture()
        try {
            val request = JSONObject().put("schema_version", 1).put("request_id", uuid())
                .put("model", fixture.model).put("thinking_mode", "off")
                .put("history", JSONArray().put(JSONObject().put("role", "user").put("content", "fixture").put("attachments", JSONArray())))
            val prepared = fixture.transport.prepare(request.toString())
            try {
                refused("E_COMPLETION_BUSY") { fixture.service.remove(fixture.remove()) }
                val edited = fixture.configurations.custom.provider(fixture.id)
                edited.getJSONObject("configuration").put("name", "Renamed provider")
                refused("E_COMPLETION_BUSY") { fixture.service.save(JSONObject().put("schema_version", 1)
                    .put("expected_revision", 1).put("provider", edited)) }
                assertEquals(1, fixture.transport.activeRequestCount())
                assertFalse(prepared.cancelled)
                assertEquals(1L, fixture.configurations.custom.read().getLong("revision"))
            } finally { fixture.transport.discard(prepared) }
        } finally { fixture.close() }
    }

    private fun digest() = RishAgentCoreNative.hash("visible-history", JSONObject().put("messages", JSONArray()
        .put(JSONObject().put("role", "user").put("content", "hello").put("attachments", JSONArray()))))

    private fun prepare(fixture: Fixture): Triple<AgentSessionFixture.Ids, JSONObject, JSONObject> {
        val workspaces = AndroidWorkspaceRegistry(File(fixture.directory, "workspaces").apply { mkdirs() })
        val workspace = workspaces.create("Mutation guard").getString("workspace_id")
        val ids = AgentSessionFixture.Ids()
        val snapshot = AgentSessionFixture.commit(fixture.sessions, ids, workspace = workspace)
        val cas = JSONObject().put("schema_version", 1).put("conversation_id", ids.conversation).put("task_id", ids.task)
            .put("attempt_id", ids.attempt).put("expected_controller_generation", 0).put("expected_journal_revision", 0)
            .put("expected_session_generation", snapshot.getLong("generation"))
            .put("expected_session_sha256", snapshot.getString("session_sha256"))
        val store = AndroidPreparedAttemptStore(fixture.sessions, fixture.wal, AndroidAgentRootResolver(workspaces))
        val prepared = store.prepareAgentAttempt(JSONObject().put("schema_version", 2).put("operation_id", ids.operation)
            .put("controller_cas", cas).put("committed_checkpoint", AgentSessionFixture.checkpoint(snapshot, 0))
            .put("task_id", ids.task).put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
            .put("workspace_id", workspace).put("project_id", JSONObject.NULL).put("workspace_binding_revision", 1)
            .put("transport_schema_version", 2).put("harness_id", "dsh").put("model", AgentSessionFixture.MODEL)
            .put("thinking_mode", "off").put("visible_message_ids", JSONArray().put(ids.message))
            .put("visible_history_sha256", digest()).put("visible_message_count", 1)
            .put("project_context_sha256", JSONObject.NULL).put("registry_version", 4)
            .put("expected_policy_version", JSONObject.NULL).put("expected_transcript", JSONObject.NULL))
        assertEquals(prepared.toString(), "prepared", prepared.getString("status"))
        return Triple(ids, snapshot, store.authorityFor(ids.task, ids.attempt)!!)
    }

    @Test fun persistedPreparedSessionAndAuthorityEachBlockMetadataRemoval() {
        val fixture = Fixture()
        try {
            prepare(fixture)
            assertEquals(0, fixture.transport.activeRequestCount())
            // Each storage source blocks independently, even after the native
            // HTTP task no longer exists in this process.
            val sessionOnly = AndroidCustomProviders(fixture.configurations, fixture.transport, fixture.credentials,
                fixture.sessions, fixture.emptyWal)
            refused("E_COMPLETION_BUSY") { sessionOnly.remove(fixture.remove()) }
            val authorityOnly = AndroidCustomProviders(fixture.configurations, fixture.transport, fixture.credentials,
                fixture.emptySessions, fixture.wal)
            refused("E_COMPLETION_BUSY") { authorityOnly.remove(fixture.remove()) }
            assertEquals(1L, fixture.configurations.custom.read().getLong("revision"))
            assertNotNull(fixture.configurations.custom.route(fixture.model))
        } finally { fixture.close() }
    }

    @Test fun persistedSendingSessionBlocksMetadataWithoutAnActiveTransport() {
        val fixture = Fixture()
        try {
            val (ids, snapshot, authority) = prepare(fixture)
            val workspace = authority.getJSONObject("root").getString("workspace_id")
            val roundId = uuid()
            val lineage = JSONObject().put("schema_version", 2).put("round_id", roundId).put("round_index", 0)
                .put("launch_attempt", 1).put("status", "active").put("native_row_revision", JSONObject.NULL)
            val journal = AgentSessionFixture.agentJournal(workspace, "round_in_flight")
                .put("root", authority.get("root")).put("policy", authority.get("policy")).put("tool_registry_version", 4)
                .put("toolset_sha256", authority.getJSONObject("registry").get("toolset_sha256"))
                .put("transcript", authority.get("transcript")).put("round_lineage", lineage)
            val session = AgentSessionFixture.session(ids, workspace = workspace, agent = journal)
            session.getJSONArray("conversations").getJSONObject(0).getJSONArray("attempts").getJSONObject(0)
                .put("status", "sending").put("active_round", JSONObject().put("round_id", roundId).put("round_index", 0))
                .put("visible_history_sha256", digest())
            val persisted = fixture.sessions.persist(JSONObject().put("schema_version", 1).put("operation_id", uuid())
                .put("expected", AgentSessionFixture.expecting(snapshot)).put("candidate_json", session.toString()))
            assertEquals(persisted.toString(), "committed", persisted.getString("status"))
            val sessionOnly = AndroidCustomProviders(fixture.configurations, fixture.transport, fixture.credentials,
                fixture.sessions, fixture.emptyWal)
            assertEquals(0, fixture.transport.activeRequestCount())
            refused("E_COMPLETION_BUSY") { sessionOnly.remove(fixture.remove()) }
            refused("E_COMPLETION_BUSY") { sessionOnly.credentialScope(fixture.prompt()) }
            assertEquals(1L, fixture.configurations.custom.read().getLong("revision"))
        } finally { fixture.close() }
    }
}
