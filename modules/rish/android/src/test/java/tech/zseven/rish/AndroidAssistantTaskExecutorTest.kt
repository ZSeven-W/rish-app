package tech.zseven.rish.runtime

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class AndroidAssistantTaskExecutorTest {
    private val chat = "11111111-1111-4111-8111-111111111111"
    private val workspace = "22222222-2222-4222-8222-222222222222"
    private val sha = "a".repeat(64)
    private fun conversation(id: String = chat) = JSONObject().put("id", id).put("model_id", "committed-model")
        .put("workspace_binding", JSONObject().put("workspace_id", workspace).put("binding_revision", 7)
            .put("project_id", JSONObject.NULL))
    private fun authority(version: Int = 5) = JSONObject().put("conversation_id", chat)
        .put("registry", JSONObject().put("registry_version", version))
        .put("root", JSONObject().put("workspace_id", workspace).put("workspace_binding_revision", 7)
            .put("project_id", JSONObject.NULL).put("capabilities", JSONArray().put("file_read")))
    private fun descriptor() = JSONObject().put("workspace_id", workspace).put("binding_revision", 7).put("status", "ok")
        .put("capabilities", JSONObject().put("read", true).put("write", false))
    private fun condition() = JSONObject().put("schema_version", 1).put("kind", "create_assistant_task")
        .put("conversation_id", chat).put("arguments_sha256", sha).put("expected_store_revision", 3)
    private fun arguments() = JSONObject().put("title", "Review build").put("instructions", "Check the build")
    private fun call() = JSONObject().put("name", "create_assistant_task").put("arguments_sha256", sha)
        .put("arguments", arguments())
    private fun locator() = JSONObject().put("schema_version", 2).put("task_id", "task")
        .put("attempt_id", "attempt").put("round_id", "round").put("round_index", 0)
        .put("call_index", 1).put("call_id", "call").put("idempotency_key", "key")
    private fun request() = JSONObject(locator().toString()).put("conversation_id", chat)
        .put("name", "create_assistant_task").put("arguments_sha256", sha)
    private fun row() = JSONObject().put("locator", locator()).put("name", "create_assistant_task")
        .put("arguments_sha256", sha).put("precondition", condition())
    private fun ok(value: Any) = JSONObject().put("ok", true).put("result", value)
    private fun effect() = JSONObject().put("schema_version", 1).put("status", "ok")
        .put("feedback", "stable committed receipt").put("settled_facts", JSONObject().put("store_revision", 4))

    private class RecordingBridge(val reply: (JSONObject) -> JSONObject) {
        val calls = mutableListOf<JSONObject>()
        fun call(request: JSONObject): JSONObject {
            calls += JSONObject(request.toString())
            return reply(request)
        }
    }

    @Test fun ordinaryRegistryCannotInvokeAssistantStore() {
        val bridge = RecordingBridge { ok(JSONObject().put("authorized", true)) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        for (name in AndroidAssistantTaskExecutor.TOOLS) {
            assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) { executor.prepare(call().put("name", name), conversation(), authority(4)) }
        }
        assertTrue(bridge.calls.isEmpty())
        assertTrue(executor.scopeAllowed(4, null))
        assertTrue(bridge.calls.isEmpty())
    }

    @Test fun forgedConversationFailsPrivateStoreAuthorization() {
        val bridge = RecordingBridge { q -> ok(JSONObject().put("authorized", q.getString("conversation_id") == chat)) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        assertFalse(executor.scopeAllowed(5, conversation("foreign")))
        assertFalse(executor.scopeAllowed(5, null))
        assertEquals(listOf("authorize"), bridge.calls.map { it.getString("action") })
    }

    @Test fun personaComesFromThePrivateAuthorizeReadAndIsDetached() {
        val persona = JSONObject().put("schema_version", 1).put("conversation_id", chat)
            .put("profile_revision", 9).put("name", "Research assistant").put("notes", "Use Chinese").put("soul", "Think carefully")
        val executor = AndroidAssistantTaskExecutor({ ok(JSONObject().put("authorized", true).put("assistant_context", persona)) }) { descriptor() }
        val frozen = executor.assistantContext(conversation())!!
        persona.put("notes", "new preference")
        assertEquals("Use Chinese", frozen.getString("notes"))
        assertEquals(9, frozen.getInt("profile_revision"))
        assertEquals("Think carefully", frozen.getString("soul"))
    }

    @Test fun unauthorizedOrForeignPersonaIsNeverFrozen() {
        for (authorized in listOf(false, true)) {
            val executor = AndroidAssistantTaskExecutor({ ok(JSONObject().put("authorized", authorized)
                .put("assistant_context", JSONObject().put("conversation_id", "foreign").put("notes", "private"))) }) { descriptor() }
            assertNull(executor.assistantContext(conversation()))
        }
    }

    @Test fun privateAndGroupLanesAlwaysResolveTheirOwnPersonaWithoutCachedSelection() {
        val lanes = listOf(chat, "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555")
        val personas = lanes.mapIndexed { index, id -> id to JSONObject()
            .put("schema_version", 1).put("conversation_id", id).put("profile_revision", 8)
            .put("name", if (index % 2 == 0) "Research Bot" else "Planning Bot")
            .put("notes", "User notes").put("soul", "User personality") }.toMap()
        val bridge = RecordingBridge { q ->
            val persona = personas[q.getString("conversation_id")]
            ok(JSONObject().put("authorized", persona != null).apply {
                if (persona != null) put("assistant_context", persona)
            })
        }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        for (id in lanes + chat) {
            val actual = executor.assistantContext(conversation(id).put("title", "Same title"))!!
            assertEquals(personas[id].toString(), actual.toString())
            assertEquals(id, bridge.calls.last().getString("conversation_id"))
        }
        assertEquals(5, bridge.calls.size)
        assertNull(executor.assistantContext(conversation("foreign").put("title", "Research Bot").put("bot_id", chat)))
    }

    @Test fun anotherGroupMemberCannotReusePreparedLaneForExecutionOrRecovery() {
        val other = "33333333-3333-4333-8333-333333333333"
        val bridge = RecordingBridge { ok(JSONObject().put("authorized", true)) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        val foreignConversation = conversation(other)
        val foreignAuthority = authority().put("conversation_id", other)
        // Even if both persisted lanes are valid Bots, a prepare receipt is
        // bound to its exact lane. UI selection cannot transfer that receipt.
        for (recover in listOf(false, true)) {
            assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) {
                val foreignRequest = request().put("conversation_id", other)
                if (recover) executor.recover(foreignRequest, arguments(), row(), foreignConversation, foreignAuthority)
                else executor.execute(foreignRequest, arguments(), row(), foreignConversation, foreignAuthority)
            }
        }
        assertTrue(bridge.calls.all { it.getString("action") == "authorize" })
    }

    @Test fun lostReplyRetainsGroupLaneIdentityThroughReceiptRecovery() {
        val lane = "44444444-4444-4444-8444-444444444444"
        val bridge = RecordingBridge { q -> when (q.getString("action")) {
            "authorize" -> ok(JSONObject().put("authorized", true))
            "apply" -> throw IllegalStateException("reply lost")
            "recover" -> ok(effect())
            else -> error("unexpected action")
        } }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        val laneRow = row().put("precondition", condition().put("conversation_id", lane))
        executor.execute(request().put("conversation_id", lane), arguments(), laneRow,
            conversation(lane), authority().put("conversation_id", lane))
        assertEquals(listOf("authorize", "apply", "recover"), bridge.calls.map { it.getString("action") })
        assertTrue(bridge.calls.all { it.getString("conversation_id") == lane })
        for (q in bridge.calls.drop(1)) assertEquals(lane, q.getJSONObject("context").getString("conversation_id"))
        assertEquals(bridge.calls[1].getJSONObject("locator").toString(), bridge.calls[2].getJSONObject("locator").toString())
    }

    @Test fun prepareOnlyReadsAndContextComesFromCommittedConversation() {
        val bridge = RecordingBridge { q -> ok(if (q.getString("action") == "authorize") JSONObject().put("authorized", true) else condition()) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        val forged = call().put("model_id", "model-selected-model").put("directory", "/tmp/forged")
            .put("context", JSONObject().put("model_id", "forged"))
        val prepared = executor.prepare(forged, conversation(), authority())
        assertEquals(condition().toString(), prepared.getJSONObject("precondition").toString())
        assertEquals(listOf("authorize", "prepare"), bridge.calls.map { it.getString("action") })
        val sent = bridge.calls.last()
        assertEquals("committed-model", sent.getJSONObject("context").getString("model_id"))
        assertEquals(workspace, sent.getJSONObject("context").getJSONObject("workspace_descriptor").getString("workspace_id"))
        assertFalse(sent.has("directory"))
        assertFalse(sent.has("locator"))
        assertFalse(sent.getJSONObject("context").has("runtime"))
    }

    @Test fun staleNativeDescriptorFailsBeforePreparingOrMutating() {
        val bridge = RecordingBridge { ok(JSONObject().put("authorized", true)) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor().put("binding_revision", 8) }
        assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) { executor.prepare(call(), conversation(), authority()) }
        assertEquals(listOf("authorize"), bridge.calls.map { it.getString("action") })
    }

    @Test fun privateMetadataNeedsReadProofAndNeverWorkspaceWritePermission() {
        val bridge = RecordingBridge { q -> ok(if (q.getString("action") == "authorize") JSONObject().put("authorized", true) else effect()) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        assertEquals("ok", executor.execute(request(), arguments(), row(), conversation(), authority()).getString("status"))
        assertFalse(bridge.calls.last().getJSONObject("context").getJSONObject("workspace_descriptor")
            .getJSONObject("capabilities").getBoolean("write"))
        val noRead = AndroidAssistantTaskExecutor(bridge::call) { descriptor().put("capabilities", JSONObject().put("read", false).put("write", true)) }
        assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) { noRead.prepare(call(), conversation(), authority()) }
        val noRootRead = authority().apply { getJSONObject("root").put("capabilities", JSONArray().put("file_write")) }
        assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) { executor.prepare(call(), conversation(), noRootRead) }
        assertEquals(1, bridge.calls.count { it.getString("action") == "apply" })
    }

    @Test fun executionUsesPersistedLocatorAndPreconditionRevision() {
        val bridge = RecordingBridge { q -> ok(if (q.getString("action") == "authorize") JSONObject().put("authorized", true) else effect()) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        assertEquals(effect().toString(), executor.execute(request(), arguments(), row(), conversation(), authority()).toString())
        val applied = bridge.calls.last()
        assertEquals("apply", applied.getString("action"))
        assertEquals(locator().toString(), applied.getJSONObject("locator").toString())
        assertEquals(3, applied.getLong("expected_revision"))
        assertEquals(sha, applied.getString("arguments_sha256"))
    }

    @Test fun forgedCallIdentityOrDigestNeverReachesMutation() {
        val bridge = RecordingBridge { ok(JSONObject().put("authorized", true)) }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        for (key in listOf("call_id", "idempotency_key", "arguments_sha256", "conversation_id")) {
            assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) {
                executor.execute(request().put(key, "forged"), arguments(), row(), conversation(), authority())
            }
        }
        assertTrue(bridge.calls.all { it.getString("action") == "authorize" })
    }

    @Test fun lostReplyRecoversTheSameReceiptWithoutSecondMutation() {
        val bridge = RecordingBridge { q -> when (q.getString("action")) {
            "authorize" -> ok(JSONObject().put("authorized", true))
            "apply" -> throw IllegalStateException("reply lost after store commit")
            "recover" -> ok(effect())
            else -> error("unexpected action")
        } }
        val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
        assertEquals(effect().toString(), executor.execute(request(), arguments(), row(), conversation(), authority()).toString())
        assertEquals(listOf("authorize", "apply", "recover"), bridge.calls.map { it.getString("action") })
        assertEquals(bridge.calls[1].getJSONObject("locator").toString(), bridge.calls[2].getJSONObject("locator").toString())
        val recovered = executor.recover(request(), arguments(), row(), conversation(), authority())
        assertEquals("settled", recovered.getString("status"))
        assertEquals(effect().toString(), recovered.getJSONObject("effect").toString())
        assertEquals(1, bridge.calls.count { it.getString("action") == "apply" })
    }

    @Test fun missingReceiptDoesNotMutateDuringRecovery() {
        val executor = AndroidAssistantTaskExecutor({ q ->
            ok(if (q.getString("action") == "authorize") JSONObject().put("authorized", true) else JSONObject.NULL)
        }) { descriptor() }
        assertEquals("not_dispatched", executor.recover(request(), arguments(), row(), conversation(), authority()).getString("status"))
    }

    @Test fun uncertainApplyWithoutRecoveredReceiptRemainsAmbiguous() {
        val executor = AndroidAssistantTaskExecutor({ q -> when (q.getString("action")) {
            "authorize" -> ok(JSONObject().put("authorized", true))
            "apply" -> JSONObject().put("ok", false).put("error", "E_AGENT_PERSISTENCE")
            else -> ok(JSONObject.NULL)
        } }) { descriptor() }
        val failure = assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) {
            executor.execute(request(), arguments(), row(), conversation(), authority())
        }
        assertEquals("E_AGENT_EXECUTION_AMBIGUOUS", failure.code)
    }

    @Test fun deterministicApplyRefusalDoesNotProbeOrMutateAgain() {
        for (code in listOf("E_AGENT_CONFLICT", "E_AGENT_BAD_ARGUMENTS", "E_AGENT_NOT_FOUND")) {
            val bridge = RecordingBridge { q -> if (q.getString("action") == "authorize") ok(JSONObject().put("authorized", true))
                else JSONObject().put("ok", false).put("error", code) }
            val executor = AndroidAssistantTaskExecutor(bridge::call) { descriptor() }
            val failure = assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) {
                executor.execute(request(), arguments(), row(), conversation(), authority())
            }
            assertEquals(code, failure.code)
            assertEquals(listOf("authorize", "apply"), bridge.calls.map { it.getString("action") })
        }
    }
}
