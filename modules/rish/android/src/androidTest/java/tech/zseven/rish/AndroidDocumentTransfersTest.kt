package tech.zseven.rish

import android.net.Uri
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidDocumentTransfers
import tech.zseven.rish.runtime.AndroidWorkspaceFiles
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * Importing documents into a workspace.
 *
 * The picker needs an activity and is not exercised here; the staging,
 * commit and recovery it drives are. The point of this design is that the
 * bytes are local before anything is committed, so the interesting test is
 * the one where the process never got to the commit.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidDocumentTransfersTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(
        val transfers: AndroidDocumentTransfers,
        val root: JSONObject,
        val directory: File,
        val staging: File,
    )

    private fun fixture(body: (Fixture) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val home = File(context.cacheDir, "transfers-${UUID.randomUUID()}")
        val outside = File(context.cacheDir, "captures").apply { mkdirs() }
        try {
            val workspaces = AndroidWorkspaceRegistry(File(home, "workspaces"))
            val created = workspaces.create("demo")
            val workspaceId = created.getString("workspace_id")
            val roots = AndroidAgentRootResolver(workspaces)
            body(
                Fixture(
                    AndroidDocumentTransfers(
                        home, AndroidWorkspaceFiles(workspaces, roots), workspaces, roots,
                    ),
                    JSONObject().put("schema_version", 1).put("workspace_id", workspaceId)
                        .put("binding_revision", 1).put("project_id", JSONObject.NULL),
                    workspaces.rootFor(workspaceId)!!,
                    outside,
                ),
            )
        } finally {
            home.deleteRecursively()
            outside.listFiles()?.forEach { it.delete() }
        }
    }

    /** A document offered the way a picker offers one. */
    private fun shared(staging: File, name: String, text: String): Uri {
        val file = File(staging, name)
        file.writeText(text)
        return FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    }

    private fun refusal(body: () -> Unit): String = try {
        body()
        ""
    } catch (refused: AndroidDocumentTransfers.Refused) {
        refused.code
    }

    /** The ordinary path: staged, committed, and reported where it landed. */
    @Test fun documentsAreStagedThenCommitted() = fixture { f ->
        val operation = UUID.randomUUID().toString()
        val staging = f.transfers.begin(operation, "import", "")
        assertEquals("in_progress", statusFor(f, operation, expected = "needs_recovery"))
        f.transfers.stage(context.contentResolver, shared(f.staging, "one.txt", "one\n"), staging)
        f.transfers.stage(context.contentResolver, shared(f.staging, "two.txt", "two\n"), staging)
        f.transfers.commit(operation, f.root, "")

        assertEquals("committed", f.transfers.query(operation).getString("status"))
        assertEquals("one\n", File(f.directory, "one.txt").readText())
        assertEquals("two\n", File(f.directory, "two.txt").readText())
        val entries = f.transfers.entries(operation)
        assertEquals(2, entries.length())
        assertEquals("one.txt", entries.getJSONObject(0).getString("path"))
        assertEquals(4L, entries.getJSONObject(0).getLong("size"))
    }

    /**
     * The case the operation model exists for: the bytes were staged and the
     * commit never happened. The retry needs no picker, because nothing it
     * needs is outside this app any more.
     */
    @Test fun anUnfinishedImportIsFinishedRatherThanRepeated() = fixture { f ->
        val operation = UUID.randomUUID().toString()
        val staging = f.transfers.begin(operation, "import", "")
        f.transfers.stage(context.contentResolver, shared(f.staging, "half.txt", "half\n"), staging)
        // ...and here the process dies.
        assertEquals("needs_recovery", f.transfers.query(operation).getString("status"))
        assertFalse(File(f.directory, "half.txt").exists())

        f.transfers.retry(operation, f.root)
        assertEquals("committed", f.transfers.query(operation).getString("status"))
        assertEquals("half\n", File(f.directory, "half.txt").readText())
    }

    /** Cleaning up forgets the operation and everything it staged. */
    @Test fun cleanupTakesTheStagingWithIt() = fixture { f ->
        val operation = UUID.randomUUID().toString()
        val staging = f.transfers.begin(operation, "import", "")
        f.transfers.stage(context.contentResolver, shared(f.staging, "gone.txt", "gone\n"), staging)
        assertEquals("cleaned", f.transfers.cleanup(operation).getString("status"))
        assertFalse(staging.exists())
        assertFalse(File(f.directory, "gone.txt").exists())
        assertEquals("cleaned", f.transfers.query(operation).getString("status"))
    }

    /** A name already taken is kept beside what is there, never over it. */
    @Test fun anImportNeverOverwrites() = fixture { f ->
        File(f.directory, "notes.txt").writeText("mine\n")
        val operation = UUID.randomUUID().toString()
        val staging = f.transfers.begin(operation, "import", "")
        f.transfers.stage(context.contentResolver, shared(f.staging, "notes.txt", "theirs\n"), staging)
        f.transfers.commit(operation, f.root, "")
        assertEquals("mine\n", File(f.directory, "notes.txt").readText())
        assertEquals("theirs\n", File(f.directory, "notes (2).txt").readText())
        assertEquals(
            "notes (2).txt",
            f.transfers.entries(operation).getJSONObject(0).getString("path"),
        )
    }

    /** A cancelled picker leaves nothing at all. */
    @Test fun anAbandonedImportLeavesNothing() = fixture { f ->
        val operation = UUID.randomUUID().toString()
        f.transfers.begin(operation, "import", "")
        f.transfers.abandon(operation)
        assertEquals("not_started", f.transfers.query(operation).getString("status"))
    }

    /** The refusals that keep a transfer inside a workspace this device holds. */
    @Test fun aTransferOutsideTheWorkspaceIsRefused() = fixture { f ->
        val moved = JSONObject(f.root.toString()).put("binding_revision", 9)
        assertEquals("E_WORKSPACE_ROOT_CHANGED", refusal { f.transfers.directory(moved, "") })
        assertEquals("E_WORKSPACE_NOT_FOUND", refusal { f.transfers.directory(f.root, "nope") })
        // A path that cannot name anything inside the workspace is a bad
        // request, and it says so in this surface's own vocabulary rather
        // than leaking the Files drawer's exception type.
        assertEquals("E_WORKSPACE_INVALID", refusal { f.transfers.directory(f.root, "../..") })
        assertEquals("E_WORKSPACE_INVALID", refusal { f.transfers.query("not-a-uuid") })
        assertEquals("E_WORKSPACE_NOT_FOUND", refusal { f.transfers.file(f.root, "missing.txt") })
    }


    /** An operation that is open reports as needing recovery, not as done. */
    private fun statusFor(f: Fixture, operation: String, expected: String): String {
        assertEquals(expected, f.transfers.query(operation).getString("status"))
        return "in_progress"
    }
}
