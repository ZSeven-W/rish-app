package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidProjectContextSnapshots
import tech.zseven.rish.runtime.AndroidProjectContextStore
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * A project-context snapshot from selection to envelope: prepared, inspected,
 * confirmed, verified for sending, refused once the project moves, discarded.
 *
 * What is asserted is the contract JavaScript's controller and the agent
 * round rely on -- the manifest's shape, the state an inspection reports at
 * each step, the receipt a verified send returns and the bytes it releases.
 */
@RunWith(AndroidJUnit4::class)
class AndroidProjectContextSnapshotsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(scratch: File) {
        val workspaces = AndroidWorkspaceRegistry(File(scratch, "registry").apply { mkdirs() })
        val projects = AndroidWorkspaceProjects(workspaces)
        val roots = AndroidAgentRootResolver(workspaces, projects)
        val store = AndroidProjectContextStore(File(scratch, "project-context"))
        val snapshots = AndroidProjectContextSnapshots(projects, roots, store)
        val workspaceId: String = workspaces.create("Scratch").getString("workspace_id")
        val workspaceDir: File = workspaces.rootFor(workspaceId)!!
        val projectId: String = projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("root", root(null)).put("mode", "init"),
        ).getJSONObject("project").getString("project_id")
        val gitDir: File = projects.gitDirectory(workspaceId, projectId)
        val conversation: String = UUID.randomUUID().toString()

        fun root(projectId: String?): JSONObject = JSONObject()
            .put("schema_version", 1).put("workspace_id", workspaceId)
            .put("binding_revision", 1).put("project_id", projectId ?: JSONObject.NULL)

        fun stage(path: String, content: String) {
            File(workspaceDir, path).apply { parentFile?.mkdirs() }.writeText(content)
            assertEquals("ok", RishLibgit2Native.stagePath(gitDir.absolutePath, workspaceDir.absolutePath, path))
        }

        fun prepareRequest(vararg paths: String): JSONObject = JSONObject().put("schema_version", 2).put("root", root(projectId))
            .put("conversation_id", conversation).put("model_id", "deepseek-v4-flash").put("policy", "chat-read-v1")
            .put("selected_paths", JSONArray(paths.toList()))

        fun snapshotRequest(snapshotId: String): JSONObject =
            JSONObject().put("schema_version", 2).put("snapshot_id", snapshotId).put("root", root(projectId))

        fun sendRequest(snapshotId: String, consentId: String): JSONObject = JSONObject().put("schema_version", 2)
            .put("snapshot_id", snapshotId).put("consent_receipt_id", consentId).put("root", root(projectId))
            .put("conversation_id", conversation).put("model_id", "deepseek-v4-flash").put("policy", "chat-read-v1")
    }

    private fun fixture(): Fixture {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        assertTrue("libgit2 is not staged", RishLibgit2Native.available)
        return Fixture(File(context.noBackupFilesDir, "snapshots-test-${UUID.randomUUID()}").apply { mkdirs() })
    }

    private fun refusal(block: () -> Unit): String {
        try {
            block()
        } catch (refused: AndroidProjectContextSnapshots.Refused) {
            return refused.code
        }
        fail("expected a refusal")
        throw IllegalStateException()
    }

    private fun rows(array: JSONArray): List<JSONObject> = (0 until array.length()).map { array.getJSONObject(it) }

    @Test
    fun aSelectionBecomesASnapshotThatIsConfirmedSentAndDiscarded() {
        val f = fixture()
        f.stage("README.md", "# hello\n")
        f.stage("src/main.kt", "fun main() {}\n")
        f.stage("config/secrets.env", "password = \"correct-horse-battery-staple\"\n")
        f.stage("build/out.bin", "binary-looking but text\n")
        File(f.workspaceDir, "src/main.kt").writeText("fun main() { println(\"hi\") }\n")

        val manifest = f.snapshots.prepare(f.prepareRequest("README.md", "src", "config/secrets.env", "build/out.bin", "missing.txt"))
        assertEquals(2, manifest.getInt("schema_version"))
        val snapshotId = manifest.getString("snapshot_id")
        assertTrue(Regex("[0-9a-f-]{36}").matches(snapshotId))
        assertEquals(f.projectId, manifest.getString("project_id"))
        assertEquals(f.projectId, manifest.getJSONObject("project").getString("project_id"))
        assertEquals(f.conversation, manifest.getString("conversation_id"))
        assertEquals("chat-read-v1.0.0", manifest.getString("policy_version"))
        assertTrue(manifest.isNull("head_oid"))
        assertEquals("main", manifest.getString("branch"))
        assertFalse(manifest.getBoolean("clean"))
        assertFalse(manifest.getBoolean("conflicted"))
        val included = rows(manifest.getJSONArray("included")).associate { "${it.getString("path")}|${it.getString("source")}" to it }
        assertTrue(included.keys.toString(), included.containsKey("README.md|tracked_file"))
        assertTrue(included.keys.toString(), included.containsKey("src/main.kt|tracked_file"))
        // The edited file carries its worktree patch beside its content.
        assertTrue(included.keys.toString(), included.containsKey("src/main.kt|worktree_diff"))
        val omitted = rows(manifest.getJSONArray("omitted")).associate { it.getString("path") to it.getString("reason") }
        assertEquals("secret_path", omitted["config/secrets.env"])
        assertEquals("generated", omitted["build/out.bin"])
        assertEquals("not_tracked", omitted["missing.txt"])
        // The envelope is the blocks plus their frames and the metadata.
        assertTrue(manifest.getInt("context_bytes") > included.values.sumOf { it.getInt("bytes") })
        assertEquals((manifest.getInt("context_bytes") + 3) / 4, manifest.getInt("estimated_tokens"))

        val prepared = f.snapshots.inspect(f.snapshotRequest(snapshotId))
        assertEquals("prepared", prepared.getString("state"))
        assertEquals(snapshotId, prepared.getJSONObject("manifest").getString("snapshot_id"))

        val consent = f.snapshots.confirm(f.snapshotRequest(snapshotId))
        assertEquals(2, consent.getInt("schema_version"))
        assertEquals(snapshotId, consent.getString("snapshot_id"))
        assertEquals(manifest.getString("snapshot_sha256"), consent.getString("snapshot_sha256"))
        assertEquals(f.workspaceId, consent.getString("workspace_id"))
        val consentId = consent.getString("consent_receipt_id")
        assertEquals("confirmed", f.snapshots.inspect(f.snapshotRequest(snapshotId)).getString("state"))

        val (envelope, receipt) = f.snapshots.verifiedEnvelope(f.sendRequest(snapshotId, consentId), requireLiveSource = true)
        val text = String(envelope, Charsets.UTF_8)
        assertTrue(text.take(40), text.startsWith("RISH-PROJECT-CONTEXT/2\nMETA "))
        assertTrue(text.endsWith("END\n"))
        assertTrue(text.contains("# hello"))
        assertTrue(text.contains("+fun main() { println"))
        assertFalse(text.contains("correct-horse"))
        assertEquals(manifest.getInt("context_bytes"), envelope.size)
        assertEquals(manifest.getString("snapshot_sha256"), receipt.getString("snapshot_sha256"))
        assertEquals(manifest.getString("source_fingerprint"), receipt.getString("source_fingerprint"))
        assertEquals(envelope.size, receipt.getInt("context_bytes"))

        // A consent for another snapshot, or a foreign conversation, is not this one's.
        assertEquals("E_CONTEXT_CONSENT_INVALID", refusal {
            f.snapshots.verifiedEnvelope(f.sendRequest(snapshotId, UUID.randomUUID().toString()), true)
        })
        assertEquals("E_CONTEXT_CONSENT_INVALID", refusal {
            f.snapshots.verifiedEnvelope(f.sendRequest(snapshotId, consentId).put("conversation_id", UUID.randomUUID().toString()), true)
        })

        // The project moves: a live send is refused, a frozen one still
        // hands over the bytes the conversation already saw.
        File(f.workspaceDir, "README.md").writeText("# hello again\n")
        assertEquals("E_CONTEXT_CHANGED", refusal { f.snapshots.verifiedEnvelope(f.sendRequest(snapshotId, consentId), true) })
        assertEquals("stale", f.snapshots.inspect(f.snapshotRequest(snapshotId)).getString("state"))
        val (frozen, _) = f.snapshots.verifiedEnvelope(f.sendRequest(snapshotId, consentId), requireLiveSource = false)
        assertTrue(frozen.contentEquals(envelope))
        assertEquals("E_CONTEXT_CHANGED", refusal { f.snapshots.discard(f.snapshotRequest(snapshotId)) })

        // A stale snapshot is replaced by preparing again, not revived. (The
        // file is left different from both earlier versions: stat times are
        // whole seconds here, so putting the exact bytes back within the same
        // second can reproduce the fingerprint, and that is not what this
        // asserts.)
        File(f.workspaceDir, "README.md").writeText("# hello, third time\n")
        assertEquals("stale", f.snapshots.inspect(f.snapshotRequest(snapshotId)).getString("state"))
        val replacement = f.snapshots.prepare(f.prepareRequest("README.md"))
        val replacementId = replacement.getString("snapshot_id")
        assertNotEquals(snapshotId, replacementId)
        // The confirmed one is kept as the rollback target until the new one
        // is confirmed: still inspectable, no longer the active one.
        assertEquals("stale", f.snapshots.inspect(f.snapshotRequest(snapshotId)).getString("state"))
        assertEquals("E_CONTEXT_CHANGED", refusal { f.snapshots.discard(f.snapshotRequest(snapshotId)) })
        assertEquals("prepared", f.snapshots.inspect(f.snapshotRequest(replacementId)).getString("state"))
        f.snapshots.confirm(f.snapshotRequest(replacementId))
        assertEquals("E_CONTEXT_SNAPSHOT_MISSING", refusal { f.snapshots.inspect(f.snapshotRequest(snapshotId)) })
        assertEquals("E_CONTEXT_SNAPSHOT_MISSING", refusal { f.snapshots.verifiedEnvelope(f.sendRequest(snapshotId, consentId), false) })
        assertEquals("confirmed", f.snapshots.inspect(f.snapshotRequest(replacementId)).getString("state"))
        val discarded = f.snapshots.discard(f.snapshotRequest(replacementId))
        assertEquals("discarded", discarded.getString("status"))
        assertEquals(replacementId, discarded.getString("snapshot_id"))
        assertEquals("E_CONTEXT_SNAPSHOT_MISSING", refusal { f.snapshots.inspect(f.snapshotRequest(replacementId)) })
    }

    /**
     * `discardProjectContext(snapshotId)`, the project-id era spelling. The
     * shared lifecycle controller calls it -- and only it -- at the end of an
     * unbind or a rebind, with no root in hand, so Android has to serve it
     * from the snapshot's own record. It was `refuseUnbuilt` until
     * 2026-09-22, which left every workspace switch in a Git chat unable to
     * finish (see the session-store note about the destructive-transition
     * journal).
     */
    @Test
    fun aSnapshotIsDiscardedByItsIdAloneForTheLifecycleController() {
        val f = fixture()
        f.stage("README.md", "# hello\n")
        val snapshotId = f.snapshots.prepare(f.prepareRequest("README.md")).getString("snapshot_id")
        f.snapshots.confirm(f.snapshotRequest(snapshotId))
        assertEquals("confirmed", f.snapshots.inspect(f.snapshotRequest(snapshotId)).getString("state"))

        // The answer is the v1 shape exactly: two keys, no root, no id.
        val discarded = f.snapshots.discardById(snapshotId)
        assertEquals(setOf("schema_version", "status"), discarded.keys().asSequence().toSet())
        assertEquals(1, discarded.getInt("schema_version"))
        assertEquals("discarded", discarded.getString("status"))
        assertEquals("E_CONTEXT_SNAPSHOT_MISSING", refusal { f.snapshots.inspect(f.snapshotRequest(snapshotId)) })

        // An id that is not one, and one nothing was stored under.
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.discardById("not-a-uuid") })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.discardById(null) })
        assertEquals(
            "E_CONTEXT_SNAPSHOT_MISSING",
            refusal { f.snapshots.discardById(UUID.randomUUID().toString()) },
        )
    }

    @Test
    fun preparingAgainReplacesTheEarlierSnapshotForTheConversation() {
        val f = fixture()
        f.stage("a.txt", "a\n")
        val first = f.snapshots.prepare(f.prepareRequest("a.txt"))
        val second = f.snapshots.prepare(f.prepareRequest("a.txt"))
        assertNotEquals(first.getString("snapshot_id"), second.getString("snapshot_id"))
        assertEquals("E_CONTEXT_SNAPSHOT_MISSING", refusal { f.snapshots.inspect(f.snapshotRequest(first.getString("snapshot_id"))) })
        assertEquals("prepared", f.snapshots.inspect(f.snapshotRequest(second.getString("snapshot_id"))).getString("state"))
        // A snapshot that was never confirmed cannot be sent.
        assertEquals("E_CONTEXT_CONSENT_INVALID", refusal {
            f.snapshots.verifiedEnvelope(f.sendRequest(second.getString("snapshot_id"), UUID.randomUUID().toString()), true)
        })
    }

    @Test
    fun requestsAreHeldToTheContract() {
        val f = fixture()
        f.stage("a.txt", "a\n")
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.prepare(f.prepareRequest("a.txt").put("root", f.root(null))) })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.prepare(f.prepareRequest("a.txt").put("policy", "chat-write")) })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.prepare(f.prepareRequest("a.txt").put("model_id", "no-such-model")) })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.prepare(f.prepareRequest("a.txt", "a.txt")) })
        // A path that leaves the tree is a selection iOS accepts and reports
        // as not tracked; refusing it outright would be a different contract.
        val outside = f.snapshots.prepare(f.prepareRequest("../a.txt"))
        assertEquals("not_tracked", rows(outside.getJSONArray("omitted")).single { it.getString("path") == "../a.txt" }.getString("reason"))
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.prepare(f.prepareRequest("")) })
        assertEquals("E_PROJECT_NOT_FOUND", refusal {
            f.snapshots.prepare(f.prepareRequest("a.txt").put("root", f.root(UUID.randomUUID().toString())))
        })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.snapshots.inspect(f.snapshotRequest("not-a-uuid")) })
        assertEquals("E_CONTEXT_SNAPSHOT_MISSING", refusal { f.snapshots.confirm(f.snapshotRequest(UUID.randomUUID().toString())) })
        // An over-budget selection prepares (the overflow is omitted) but cannot be confirmed.
        for (index in 0 until 40) f.stage("many/file$index.txt", "x".repeat(8000) + "\n")
        val manifest = f.snapshots.prepare(f.prepareRequest("many"))
        val reasons = rows(manifest.getJSONArray("omitted")).map { it.getString("reason") }.toSet()
        assertTrue(reasons.toString(), "budget_exceeded" in reasons)
        assertEquals("E_CONTEXT_BUDGET", refusal { f.snapshots.confirm(f.snapshotRequest(manifest.getString("snapshot_id"))) })
    }
}
