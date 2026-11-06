package tech.zseven.rish

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.zseven.rish.runtime.AndroidWorkspaceMutation
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.mutating
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

class AndroidWorkspaceMutationTest {
    private fun withRegistry(body: (AndroidWorkspaceRegistry) -> Unit) {
        val root = Files.createTempDirectory("workspace-mutation-test-").toFile()
        try {
            body(AndroidWorkspaceRegistry(root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun sameWorkspaceMutationsAreReentrant() = withRegistry { registry ->
        val id = UUID.randomUUID().toString()
        val result = registry.mutating(id) {
            registry.mutating(id) { "nested mutation completed" }
        }
        assertEquals("nested mutation completed", result)
        assertEquals("lock released", registry.mutating(id) { "lock released" })
    }

    @Test fun aReadLeaseCanCompleteWhileAnotherThreadOwnsTheMutationLock() = withRegistry { registry ->
        val id = UUID.randomUUID().toString()
        val read = FutureTask<String> { registry.holding(id) { "read completed" } }
        val reader = Thread(read, "workspace-read-lease")
        try {
            registry.mutating(id) {
                reader.start()
                assertEquals("read completed", read.get(5, TimeUnit.SECONDS))
                assertTrue(read.isDone)
            }
        } finally {
            reader.interrupt()
            reader.join(5000)
            assertFalse(reader.isAlive)
        }
    }

    @Test fun nestingAnotherWorkspaceIsRefusedWithoutLosingTheOuterLock() = withRegistry { registry ->
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        AndroidWorkspaceMutation.run(registry.root, first) {
            var refused: AndroidWorkspaceRegistry.Refused? = null
            try {
                AndroidWorkspaceMutation.run(registry.root, second) { error("Nested mutation was accepted") }
            } catch (error: AndroidWorkspaceRegistry.Refused) {
                refused = error
            }
            assertEquals("E_WORKSPACE_CONFLICT", refused?.code)
            assertEquals("outer still held", AndroidWorkspaceMutation.run(registry.root, first) { "outer still held" })
        }
        assertEquals("second released", AndroidWorkspaceMutation.run(registry.root, second) { "second released" })
    }
}
