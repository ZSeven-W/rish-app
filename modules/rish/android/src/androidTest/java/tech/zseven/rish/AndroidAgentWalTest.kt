package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentWal
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * The agent WAL on Android writes the same bytes iOS writes, judged by the
 * same rules, so a state pulled off either device replays through the same
 * harness.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentWalTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun root(): File =
        File(context.noBackupFilesDir, "agent-wal-test-${UUID.randomUUID()}").apply { mkdirs() }

    private fun walFile(root: File) = File(root, AndroidAgentWal.FILE_NAME)

    @Test fun theSharedCoreIsLinkedIntoThisBuild() {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        assertNotNull(RishAgentCoreNative.buildId())
    }

    @Test fun aCommittedTransactionLeavesCanonicalBytesTheCoreAccepts() {
        val root = root()
        try {
            val wal = AndroidAgentWal(root)
            assertEquals(0L, wal.snapshot().optLong("generation"))
            assertTrue(wal.transaction { candidate ->
                candidate.put("cleanup", JSONArray())
                true
            })
            val bytes = walFile(root).readText()
            // Byte-exact canonical JSON is the whole contract: the same file
            // iOS would have written, and the same the core will read back.
            assertEquals(RishAgentCoreNative.canonical(bytes), bytes)
            assertEquals(1L, JSONObject(bytes).getLong("generation"))
            assertEquals(1L, wal.snapshot().getLong("generation"))
            // A second transaction builds on the first.
            assertTrue(wal.transaction { true })
            assertEquals(2L, wal.snapshot().getLong("generation"))
        } finally { root.deleteRecursively() }
    }

    @Test fun anAbandonedTransactionWritesNothing() {
        val root = root()
        try {
            val wal = AndroidAgentWal(root)
            assertTrue(wal.transaction { true })
            assertFalse(wal.transaction { candidate ->
                candidate.put("cleanup", JSONArray().put(JSONObject()))
                false
            })
            assertEquals(1L, wal.snapshot().getLong("generation"))
            assertEquals(1L, JSONObject(walFile(root).readText()).getLong("generation"))
        } finally { root.deleteRecursively() }
    }

    @Test fun aStateTheCoreRefusesIsNeverWritten() {
        val root = root()
        try {
            val wal = AndroidAgentWal(root)
            assertTrue(wal.transaction { true })
            try {
                wal.transaction { candidate ->
                    // Not a dispatch row the shared rules recognise.
                    candidate.put("dispatch", JSONArray().put(JSONObject().put("kind", "round")))
                    true
                }
                fail("a refused candidate was written")
            } catch (_: IllegalStateException) { }
            assertEquals(1L, JSONObject(walFile(root).readText()).getLong("generation"))
        } finally { root.deleteRecursively() }
    }

    @Test fun aTornTransactionIsRefusedRatherThanGuessedAt() {
        val root = root()
        try {
            val wal = AndroidAgentWal(root)
            assertTrue(wal.transaction { true })
            // A leftover staging file is a writer that died between staging
            // and rename. Neither half may be assumed.
            File(root, AndroidAgentWal.FILE_NAME + AndroidAgentWal.TEMPORARY_SUFFIX)
                .writeText("{}")
            try { wal.snapshot(); fail("a torn transaction was read through") }
            catch (_: IllegalStateException) { }
        } finally { root.deleteRecursively() }
    }

    @Test fun committedStateIsRereadWhenTheFileIsReplacedBehindTheStore() {
        val root = root()
        try {
            val wal = AndroidAgentWal(root)
            assertTrue(wal.transaction { true })
            // Replace the file with a state the store has never seen. A stale
            // resident state would keep answering with generation 1 and the
            // next write would overwrite these bytes wholesale.
            val replaced = JSONObject(walFile(root).readText()).put("generation", 42)
            walFile(root).writeText(RishAgentCoreNative.canonical(replaced.toString())!!)
            assertEquals(42L, wal.snapshot().getLong("generation"))
            assertTrue(wal.transaction { true })
            assertEquals(43L, wal.snapshot().getLong("generation"))
        } finally { root.deleteRecursively() }
    }

    @Test fun aSecondInstanceOnOneRootSeesTheFirstsCommits() {
        val root = root()
        try {
            val first = AndroidAgentWal(root)
            val second = AndroidAgentWal(root)
            assertTrue(first.transaction { true })
            // One root, one committed state: a second owner that kept its own
            // would overwrite the first's commit.
            assertEquals(1L, second.snapshot().getLong("generation"))
            assertTrue(second.transaction { true })
            assertEquals(2L, first.snapshot().getLong("generation"))
        } finally { root.deleteRecursively() }
    }
}
