package tech.zseven.rish

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import android.app.Application
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceToolExecutor
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.io.File
import java.util.UUID

/**
 * An agent writing a file into a workspace it is bound to, on the device.
 *
 * This is the layer that does the work the whole feature is for. It runs
 * against a real registry, a real directory under the app's files, and the
 * real core: nothing is faked, and the bytes are read back off the filesystem
 * rather than out of the executor's own reply.
 *
 * What it does not cover: `execute_agent_tool`, which wraps this in the ledger,
 * the batch revision and the approval. A tool cannot be reached from a
 * conversation yet; this proves the tool itself is real.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidWorkspaceToolExecutorTest {

    private fun fixture(body: (AndroidWorkspaceToolExecutor, JSONObject, File) -> Unit) {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val app = ApplicationProvider.getApplicationContext<Application>()
        val home = File(app.cacheDir, "tool-executor-${UUID.randomUUID()}")
        val registry = AndroidWorkspaceRegistry(home)
        val record = registry.create(displayName = "executor test")
        val id = record.getString("workspace_id")
        val roots = AndroidAgentRootResolver(registry)
        // The root a request carries is the resolver's own projection -- the
        // one the controller was handed by a previous resolve, spelling its
        // binding `workspace_binding_revision`. Building one by hand here is
        // how a fixture ends up certifying a shape production never sends.
        val root = roots.resolve(id, null, record.getInt("binding_revision"))
            ?: error("the registry did not resolve the workspace it just created")
        val executor = AndroidWorkspaceToolExecutor(registry, roots)
        try {
            body(executor, root, registry.rootFor(id)!!)
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun anAgentWritesAFileAndTheBytesAreOnDisk() = fixture { executor, root, directory ->
        val written = executor.execute(
            "write_file",
            JSONObject().put("path", "notes/todo.md").put("content", "one\ntwo\n"),
            root,
        )
        // What an executed tool returns is an effect the ledger settles, not a
        // reply of this file's own devising: the model-facing feedback as the
        // core's canonical string, the facts the row records, and whether a
        // retry must assume the effect happened.
        assertEquals("ok", written.getString("status"))
        assertTrue(written.getBoolean("effect_may_have_occurred"))
        val writeFacts = written.getJSONObject("settled_facts")
        assertEquals("write_file", writeFacts.getString("kind"))
        val writeFeedback = JSONObject(written.getString("feedback"))
        assertEquals("write_file", writeFeedback.getString("name"))
        assertEquals("ok", writeFeedback.getString("outcome"))
        assertEquals(8, writeFeedback.getJSONObject("payload").getInt("bytes"))

        // The reply is not the evidence. The file is.
        val file = File(directory, "notes/todo.md")
        assertTrue("the agent's file must exist under the workspace root", file.isFile)
        assertEquals("one\ntwo\n", file.readText())

        val read = executor.execute("read_file", JSONObject().put("path", "notes/todo.md"), root)
        assertFalse(read.getBoolean("effect_may_have_occurred"))
        val readPayload = JSONObject(read.getString("feedback")).getJSONObject("payload")
        assertEquals("one\ntwo\n", readPayload.getString("content"))
        assertFalse(readPayload.getBoolean("truncated"))
        // The revision names the state the host read, and a write moves it.
        assertEquals(
            writeFeedback.getJSONObject("payload").getString("revision"),
            readPayload.getString("revision"),
        )
        assertEquals(writeFacts.getString("actual_revision"), readPayload.getString("revision"))
    }

    @Test
    fun aListingShowsWhatTheAgentWrote() = fixture { executor, root, _ ->
        executor.execute("write_file", JSONObject().put("path", "a.txt").put("content", "a"), root)
        executor.execute("write_file", JSONObject().put("path", "b.txt").put("content", "b"), root)
        val listing = executor.execute("list_dir", JSONObject(), root)
        val payload = JSONObject(listing.getString("feedback")).getJSONObject("payload")
        val entries = payload.getJSONArray("entries")
        val names = (0 until entries.length()).map { entries.getJSONObject(it).getString("name") }
        assertTrue("$names", names.containsAll(listOf("a.txt", "b.txt")))
        // The entry shape is the core's contract, not this file's: a feedback
        // whose entries are spelled otherwise is refused when the call settles.
        assertEquals(
            setOf("schema_version", "name", "type", "revision"),
            entries.getJSONObject(0).keys().asSequence().toSet(),
        )
        assertFalse(payload.getBoolean("truncated"))
        // Preparing a listing and running it must agree on the fingerprint, or
        // what the person approved is not what the ledger settles.
        assertEquals(
            executor.prepare("list_dir", JSONObject(), root)
                .getJSONObject("precondition").getString("directory_fingerprint_sha256"),
            listing.getJSONObject("settled_facts").getString("directory_fingerprint_sha256"),
        )
    }

    /**
     * The path rule is the core's, and these are the spellings it refuses. If
     * any of them started being accepted, an agent could address a file outside
     * the directory the person bound.
     */
    @Test
    fun aPathThatWouldLeaveTheRootIsRefused() = fixture { executor, root, _ ->
        for (path in listOf(
            "../escape.txt",
            "/etc/hosts",
            "notes/../../escape.txt",
            "a\\b.txt",
            ".git/config",
            ".trash/x",
            "",
        )) {
            val refused = try {
                executor.execute("read_file", JSONObject().put("path", path), root)
                false
            } catch (_: AndroidWorkspaceToolExecutor.Refused) {
                true
            }
            assertTrue("$path must be refused", refused)
        }
    }

    /** A tool that is not one of the three is not a tool. */
    @Test
    fun anUnknownToolIsRefused() = fixture { executor, root, _ ->
        val refused = try {
            executor.execute("delete_everything", JSONObject(), root)
            false
        } catch (_: AndroidWorkspaceToolExecutor.Refused) {
            true
        }
        assertTrue(refused)
    }

    /** A root naming a workspace this device does not hold has no directory. */
    @Test
    fun aRootThisDeviceDoesNotHoldIsRefused() = fixture { executor, _, _ ->
        val stranger = JSONObject().put("schema_version", 1).put("kind", "workspace")
            .put("workspace_id", UUID.randomUUID().toString())
            .put("workspace_binding_revision", 1).put("project_id", JSONObject.NULL)
            .put("root_fingerprint_sha256", "0".repeat(64))
            .put("capabilities", org.json.JSONArray().put("file_read"))
        val refused = try {
            executor.execute("list_dir", JSONObject(), stranger)
            false
        } catch (_: AndroidWorkspaceToolExecutor.Refused) {
            true
        }
        assertTrue(refused)
    }

    /**
     * The preparation step is what the batch gate needs before any effect: what
     * the call asserts about the world, and what a person would be approving.
     */
    @Test
    fun preparingACallStatesWhatItAsserts() = fixture { executor, root, _ ->
        executor.execute("write_file", JSONObject().put("path", "a.txt").put("content", "a"), root)

        val read = executor.prepare("read_file", JSONObject().put("path", "a.txt"), root)
        val readCondition = read.getJSONObject("precondition")
        assertEquals("read_file", readCondition.getString("kind"))
        assertTrue(readCondition.getString("source_revision").contains(":"))
        // A preview never carries the file's bytes.
        assertTrue(read.getJSONObject("approval_preview").isNull("content_bytes"))

        assertEquals(0, read.getInt("reserved_write_bytes"))

        val list = executor.prepare("list_dir", JSONObject(), root)
        assertEquals(
            64,
            list.getJSONObject("precondition").getString("directory_fingerprint_sha256").length,
        )
        assertEquals(0, list.getInt("reserved_write_bytes"))
    }

    /**
     * A write asserts the prior it expects, and the disk has to agree. This is
     * the check that makes a stale write a conflict now rather than a silent
     * overwrite later, so it has to refuse both ways round.
     */
    @Test
    fun aWriteWhosePriorIsWrongIsRefusedBeforeAnythingHappens() = fixture { executor, root, directory ->
        // Absent is what a write with no expected_revision asserts.
        val fresh = executor.prepare(
            "write_file",
            JSONObject().put("path", "new.txt").put("content", "hello"),
            root,
        )
        val condition = fresh.getJSONObject("precondition")
        assertEquals("write_file", condition.getString("kind"))
        assertEquals("absent", condition.getJSONObject("prior").getString("kind"))
        assertEquals(5, condition.getInt("content_bytes"))
        assertEquals(64, condition.getString("relative_path_sha256").length)
        assertEquals(64, condition.getString("content_sha256").length)
        // A write reserves what it will put on disk. The ledger holds this
        // against the precondition and refuses the whole batch when it is 0.
        assertEquals(5, fresh.getInt("reserved_write_bytes"))
        // The preview's prior is a different shape from the precondition's:
        // exactly {schema_version, kind, bytes}, with no revision. The ledger
        // validates the key set, so the wrong shape loses the batch.
        val previewPrior = fresh.getJSONObject("approval_preview").getJSONObject("prior")
        assertEquals(
            setOf("schema_version", "kind", "bytes"),
            previewPrior.keys().asSequence().toSet(),
        )
        assertEquals("absent", previewPrior.getString("kind"))
        assertTrue(previewPrior.isNull("bytes"))
        // Nothing was written by preparing.
        assertFalse(File(directory, "new.txt").exists())

        // Once the file exists, the same call asserts a prior that is wrong.
        executor.execute("write_file", JSONObject().put("path", "new.txt").put("content", "x"), root)
        val refused = try {
            executor.prepare(
                "write_file",
                JSONObject().put("path", "new.txt").put("content", "hello"),
                root,
            )
            false
        } catch (_: AndroidWorkspaceToolExecutor.Refused) {
            true
        }
        assertTrue("a write asserting absence over an existing file must be refused", refused)
    }
}
