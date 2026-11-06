package tech.zseven.rish.gpui

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DefaultWorkspaceTest {
    private val workspace = "11111111-1111-4111-8111-111111111111"
    private val operation = "22222222-2222-4222-8222-222222222222"
    private val timestamp = "2026-10-15T00:00:00.000Z"
    private fun descriptor(id: String = workspace) = JSONObject().put("schema_version", 2)
        .put("workspace_id", id).put("display_name", "默认工作空间").put("status", "ok")
        .put("binding_revision", 1).put("capabilities", JSONObject().put("read", true).put("write", true))

    private class Store : DefaultWorkspaceStore {
        var state = DefaultWorkspaceState()
        var fail = false
        var failedWritesUpdateMemory = false
        var writes = 0
        override fun read() = state
        override fun write(state: DefaultWorkspaceState): Boolean {
            writes++
            if (!fail || failedWritesUpdateMemory) this.state = state
            return !fail
        }
    }
    private fun coordinator(store: Store, resolve: (String) -> JSONObject?, create: (PendingDefaultWorkspace) -> JSONObject): DefaultWorkspaceCoordinator {
        val ids = ArrayDeque(listOf(workspace, operation))
        return DefaultWorkspaceCoordinator(store, resolve, create, { ids.removeFirst() }, { timestamp })
    }

    @Test fun repeatEnsureResolvesTheSameIdRegardlessOfRequestedDisplayName() {
        val store = Store()
        var record: JSONObject? = null
        var creates = 0
        val service = coordinator(store, { record }) { pending ->
            assertEquals(pending, store.state.pending)
            creates++
            descriptor(pending.workspaceId).also { record = it }
        }
        assertEquals(workspace, service.ensure("默认工作空间").getString("workspace_id"))
        assertEquals(workspace, service.ensure("Default workspace").getString("workspace_id"))
        assertEquals(1, creates)
        assertEquals(DefaultWorkspaceState(workspaceId = workspace), store.state)
    }

    @Test fun interruptedCreationRecoversByPrecommittedIdWithoutRepeatingCreate() {
        val store = Store()
        var record: JSONObject? = null
        var creates = 0
        val first = coordinator(store, { record }) { pending ->
            assertEquals(workspace, store.state.pending?.workspaceId)
            creates++
            record = descriptor(pending.workspaceId)
            throw IllegalStateException("crash after registry publication before receipt")
        }
        assertThrows(IllegalStateException::class.java) { first.ensure("默认工作空间") }
        assertEquals(workspace, store.state.pending?.workspaceId)
        val recovered = coordinator(store, { record }) { error("must resolve the published record") }
        assertEquals(workspace, recovered.ensure("Default workspace").getString("workspace_id"))
        assertEquals(1, creates)
        assertNull(store.state.pending)
    }

    @Test fun failedCreationKeepsTheSameIdsNameAndTimestampForRetry() {
        val store = Store()
        val requests = mutableListOf<PendingDefaultWorkspace>()
        val first = coordinator(store, { null }) { pending ->
            requests.add(pending)
            throw BridgeFailure("E_WORKSPACE_BUSY")
        }
        assertEquals("E_WORKSPACE_BUSY", assertThrows(BridgeFailure::class.java) { first.ensure("默认工作空间") }.code)
        var record: JSONObject? = null
        val retry = coordinator(store, { record }) { pending ->
            requests.add(pending)
            descriptor(pending.workspaceId).also { record = it }
        }
        retry.ensure("Changed locale name")
        assertEquals(requests[0], requests[1])
        assertEquals(PendingDefaultWorkspace(workspace, operation, "默认工作空间", timestamp), requests[0])
    }

    @Test fun failedPendingPersistenceCannotStartNativeCreationEvenWithUpdatedMemory() {
        val store = Store().apply { fail = true; failedWritesUpdateMemory = true }
        var creates = 0
        val service = coordinator(store, { null }) { creates++; descriptor() }
        repeat(2) {
            assertEquals("E_WORKSPACE_PERSISTENCE", assertThrows(BridgeFailure::class.java) {
                service.ensure("默认工作空间")
            }.code)
        }
        assertEquals(0, creates)
        assertEquals(2, store.writes)
        assertEquals(workspace, store.state.pending?.workspaceId)
    }

    @Test fun failedFinalPersistenceRetainsResolvablePendingIdentity() {
        val store = Store()
        var record: JSONObject? = null
        val first = coordinator(store, { record }) { pending ->
            store.fail = true
            descriptor(pending.workspaceId).also { record = it }
        }
        assertEquals("E_WORKSPACE_PERSISTENCE", assertThrows(BridgeFailure::class.java) { first.ensure("默认工作空间") }.code)
        assertEquals(workspace, store.state.pending?.workspaceId)
        store.fail = false
        val recovered = coordinator(store, { record }) { error("must not repeat create") }
        assertEquals(workspace, recovered.ensure("默认工作空间").getString("workspace_id"))
    }

    @Test fun deletedOrUnavailableDefaultNeverSilentlyRebinds() {
        val store = Store().apply { state = DefaultWorkspaceState(workspaceId = workspace) }
        for (record in listOf(null, descriptor().put("status", "root_changed"),
            descriptor().put("capabilities", JSONObject().put("read", true).put("write", false)))) {
            val service = coordinator(store, { record }) { error("must not create replacement") }
            assertEquals("E_WORKSPACE_DEFAULT_UNAVAILABLE", assertThrows(BridgeFailure::class.java) {
                service.ensure("默认工作空间")
            }.code)
        }
        assertEquals(DefaultWorkspaceState(workspaceId = workspace), store.state)
        assertEquals(0, store.writes)
    }

    @Test fun corruptPendingStateIsNotReplacedWithAFreshWorkspace() {
        val store = Store().apply {
            state = DefaultWorkspaceState(pending = PendingDefaultWorkspace("invalid", operation, "默认工作空间", timestamp))
        }
        val service = coordinator(store, { error("must fail before resolve") }) { error("must not create") }
        assertEquals("E_WORKSPACE_CORRUPT", assertThrows(BridgeFailure::class.java) { service.ensure("默认工作空间") }.code)
        assertEquals(0, store.writes)
    }
}
