package tech.zseven.rish.runtime

import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Shared by browser saves, agent file tools and working-tree Git mutations. */
internal object AndroidWorkspaceMutation {
    private val locks = Array(64) { ReentrantLock(true) }
    private val owned = ThreadLocal<String?>()

    private fun key(root: File, workspaceId: String) = "${root.canonicalPath}\n$workspaceId"
    private fun lock(key: String) = locks[(key.hashCode() ushr 1) % locks.size]

    fun <T> run(root: File, workspaceId: String, body: () -> T): T {
        val key = key(root, workspaceId)
        val previous = owned.get()
        // Current endpoints operate on one workspace. Refuse a future nested
        // cross-workspace operation instead of introducing inverse lock order.
        if (previous != null && previous != key) {
            throw AndroidWorkspaceRegistry.Refused("E_WORKSPACE_CONFLICT")
        }
        return lock(key).withLock {
            owned.set(key)
            try { body() } finally {
                if (previous == null) owned.remove() else owned.set(previous)
            }
        }
    }

    /** A deterministic barrier for the native concurrency regression tests. */
    fun waiting(root: File, workspaceId: String, thread: Thread): Boolean =
        lock(key(root, workspaceId)).hasQueuedThread(thread)
}

/** A removal lease is acquired before waiting; readers retain the ordinary lease only. */
internal fun <T> AndroidWorkspaceRegistry.mutating(workspaceId: String, body: () -> T): T =
    holding(workspaceId) { AndroidWorkspaceMutation.run(root, workspaceId, body) }
