package tech.zseven.rish

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceRemoval
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Forgetting a workspace and deleting its owned content, end to end on the
 * native side: the clearance the session store issues against a committed
 * session, the registry mutation under it, the journaled delete, and what
 * the next launch does with a delete that was interrupted.
 *
 * The session candidates are the agent fixture's: a conversation that names
 * the workspace nowhere and carries the request in its authority outbox is
 * what a cleared session looks like, and one whose attempt still names it
 * is what must be refused.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidWorkspaceRemovalTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(root: File, val sessions: AndroidSessionStore) {
        val workspaces = AndroidWorkspaceRegistry(root)
        val projects = AndroidWorkspaceProjects(workspaces)
        val removal = AndroidWorkspaceRemoval(sessions, workspaces, projects)
        val container = File(root, AndroidWorkspaceRegistry.CONTAINER_NAME)
        val gitdirs = File(root, AndroidWorkspaceProjects.GITDIRS_NAME)
        val removals = File(root, "removals")
    }

    private fun fixture(): Fixture {
        assumeTrue("the agent core is not staged", RishAgentCoreNative.available)
        assumeTrue("libgit2 is not staged", RishLibgit2Native.available)
        val root = File(context.noBackupFilesDir, "removal-test-${UUID.randomUUID()}").apply { mkdirs() }
        return Fixture(root, AndroidSessionStore(context, "removal-${UUID.randomUUID()}"))
    }

    private fun operation(workspaceId: String, action: String): JSONObject = JSONObject()
        .put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
        .put("action", action).put("workspace_id", workspaceId).put("binding_revision", 1)
        .put("clearance_receipt_id", UUID.randomUUID().toString())
        .put("created_at", AgentSessionFixture.STAMP)

    /** A committed-shape candidate with the request in its outbox; bound to [workspace] when given. */
    private fun candidate(ids: AgentSessionFixture.Ids, operation: JSONObject, workspace: String? = null): String {
        val session = AgentSessionFixture.session(ids, workspace = workspace)
            .put("workspace_authority_outbox", JSONArray().put(operation))
        return RishAgentCoreNative.canonical(session.toString()) ?: error("not canonicalisable")
    }

    private fun clearance(fixture: Fixture, candidate: String, operation: JSONObject): JSONObject =
        fixture.sessions.persistWithClearance(
            JSONObject().put("schema_version", 1).put("candidate_json", candidate).put("operation", operation),
            fixture.removal,
        )

    private fun fields(operation: JSONObject, confirmationId: String? = null): JSONObject = JSONObject()
        .put("schema_version", 1).put("workspace_id", operation.getString("workspace_id"))
        .put("expected_binding_revision", 1).put("operation_id", operation.getString("operation_id"))
        .put("clearance_receipt_id", operation.getString("clearance_receipt_id"))
        .also { if (confirmationId != null) it.put("confirmation_id", confirmationId) }

    private fun refusedCode(what: String, body: () -> Unit): String {
        try {
            body()
        } catch (refused: AndroidWorkspaceRegistry.Refused) {
            return refused.code
        }
        fail("$what was accepted")
        return ""
    }

    private fun attach(fixture: Fixture, workspaceId: String): String {
        val root = JSONObject().put("schema_version", 1).put("workspace_id", workspaceId)
            .put("binding_revision", 1).put("project_id", JSONObject.NULL)
        val attached = fixture.projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("mode", "init").put("root", root),
        )
        return attached.getJSONObject("project").getString("project_id")
    }

    private fun identity(file: File): Pair<String, String> {
        val stat = Os.stat(file.absolutePath)
        return Pair(stat.st_dev.toString(), stat.st_ino.toString())
    }

    // --- clearance ----------------------------------------------------------

    @Test
    fun aCandidateThatStillNamesTheWorkspaceIsNotCleared() {
        val fixture = fixture()
        val workspaceId = fixture.workspaces.create("Held").getString("workspace_id")
        val operation = operation(workspaceId, "forget")
        val bound = candidate(AgentSessionFixture.Ids(), operation, workspace = workspaceId)
        try {
            clearance(fixture, bound, operation)
            fail("a session whose attempt names the workspace was cleared")
        } catch (_: IllegalStateException) {
            // The core refused the candidate: the attempt still names the workspace.
        }
        assertEquals("not_started", fixture.sessions.queryClearance(
            JSONObject().put("schema_version", 1).put("operation_id", operation.getString("operation_id")),
        ).getString("status"))
    }

    @Test
    fun aClearanceIsIssuedAgainstTheCommittedSessionAndEndsWithTheNextCommit() {
        val fixture = fixture()
        val workspaceId = fixture.workspaces.create("Cleared").getString("workspace_id")
        val operation = operation(workspaceId, "forget")
        val cleared = candidate(AgentSessionFixture.Ids(), operation)
        val reply = clearance(fixture, cleared, operation)
        assertEquals("committed", reply.getString("status"))
        val receipt = reply.getJSONObject("receipt")
        assertEquals(operation.getString("clearance_receipt_id"), receipt.getString("clearance_receipt_id"))
        assertEquals(1L, receipt.getLong("committed_session_generation"))
        assertEquals(64, receipt.getString("committed_session_sha256").length)
        // The same request again answers the same receipt, not a second one.
        assertEquals(receipt.toString(), clearance(fixture, cleared, operation).getJSONObject("receipt").toString())
        val query = JSONObject().put("schema_version", 1).put("operation_id", operation.getString("operation_id"))
        assertEquals("committed", fixture.sessions.queryClearance(query).getString("status"))

        // Any later commit ends the receipt: the session it named is no
        // longer the one committed.
        val snapshot = fixture.sessions.load().getJSONObject("snapshot")
        AgentSessionFixture.commit(fixture.sessions, AgentSessionFixture.Ids(), expected = AgentSessionFixture.expecting(snapshot))
        assertEquals("unknown", fixture.sessions.queryClearance(query).getString("status"))
        assertEquals("E_WORKSPACE_CONFLICT", refusedCode("a forget under an ended clearance") {
            fixture.removal.forget(fields(operation))
        })
        // And the operation cannot be replayed into a fresh receipt either.
        assertEquals("not_committed", clearance(fixture, cleared, operation).getString("status"))
        assertEquals(1, fixture.workspaces.list().size)
    }

    // --- forget --------------------------------------------------------------

    @Test
    fun forgetRemovesTheRegistrationAndLeavesTheDirectoryAlone() {
        val fixture = fixture()
        val record = fixture.workspaces.create("Keep my files")
        val workspaceId = record.getString("workspace_id")
        val directory = File(fixture.container, record.getString("owned_directory_name"))
        File(directory, "notes.txt").writeText("still here")
        val operation = operation(workspaceId, "forget")
        assertEquals("committed", clearance(fixture, candidate(AgentSessionFixture.Ids(), operation), operation).getString("status"))

        val answer = fixture.removal.forget(fields(operation))
        assertEquals("forgotten", answer.getString("status"))
        assertEquals(0, fixture.workspaces.list().size)
        assertNull(fixture.workspaces.rootFor(workspaceId))
        assertEquals(2, fixture.workspaces.registry().getInt("generation"))
        assertTrue("the directory was deleted by a forget", File(directory, "notes.txt").isFile)
        val receipt = fixture.workspaces.queryOperation(operation.getString("operation_id"))
        assertNotNull(receipt)
        assertEquals("forget", receipt!!.getString("operation"))
        assertEquals("committed", receipt.getString("outcome"))
        // Replayed, it answers from the receipt -- the clearance is beside the point now.
        assertEquals("forgotten", fixture.removal.forget(fields(operation)).getString("status"))
        // The same operation id for another request is a reuse, refused.
        val reused = JSONObject(operation.toString()).put("clearance_receipt_id", UUID.randomUUID().toString())
        assertEquals("E_WORKSPACE_CONFLICT", refusedCode("an operation id reused") {
            fixture.removal.forget(fields(reused))
        })
    }

    @Test
    fun forgetRefusesAWorkspaceWhoseProjectIsStillAttached() {
        val fixture = fixture()
        val workspaceId = fixture.workspaces.create("Attached").getString("workspace_id")
        attach(fixture, workspaceId)
        assertEquals(AndroidWorkspaceProjects.Relation.PUBLISHED, fixture.projects.relation(workspaceId))
        val operation = operation(workspaceId, "forget")
        // The host says no before the session commits: nothing is written.
        assertEquals("not_committed", clearance(fixture, candidate(AgentSessionFixture.Ids(), operation), operation).getString("status"))
        assertEquals("missing", fixture.sessions.load().getString("status"))
        assertEquals(1, fixture.workspaces.list().size)
    }

    // --- delete --------------------------------------------------------------

    @Test
    fun deleteRemovesTheContentAndThePrivateGitdirsUnderOneConfirmation() {
        val fixture = fixture()
        val record = fixture.workspaces.create("Gone")
        val workspaceId = record.getString("workspace_id")
        val directory = File(fixture.container, record.getString("owned_directory_name"))
        File(directory, "a.txt").writeText("a")
        File(File(directory, "nested").apply { mkdirs() }, "b.txt").writeText("b")
        val projectId = attach(fixture, workspaceId)
        assertTrue(File(File(File(fixture.gitdirs, workspaceId), projectId), "binding-v2.json").isFile)
        val operation = operation(workspaceId, "delete_owned")
        assertEquals("committed", clearance(fixture, candidate(AgentSessionFixture.Ids(), operation), operation).getString("status"))

        val prepared = fixture.removal.prepareDelete(fields(operation).apply { remove("operation_id") })
        val confirmationId = prepared.getString("confirmation_id")
        assertTrue(prepared.getString("expires_at").endsWith("Z"))
        // A wrong confirmation consumes the prepared one and changes nothing.
        assertEquals("E_WORKSPACE_CONFLICT", refusedCode("a delete with the wrong confirmation") {
            fixture.removal.deleteOwned(fields(operation, UUID.randomUUID().toString()))
        })
        assertEquals("E_WORKSPACE_CONFLICT", refusedCode("a delete with a consumed confirmation") {
            fixture.removal.deleteOwned(fields(operation, confirmationId))
        })
        assertTrue(directory.isDirectory)
        assertEquals(1, fixture.workspaces.list().size)

        val again = fixture.removal.prepareDelete(fields(operation).apply { remove("operation_id") }).getString("confirmation_id")
        val answer = fixture.removal.deleteOwned(fields(operation, again))
        assertEquals("deleted", answer.getString("status"))
        assertFalse("the content is still there", directory.exists())
        assertFalse("the private gitdirs are still there", File(fixture.gitdirs, workspaceId).exists())
        assertEquals(0, fixture.removals.listFiles()?.size ?: 0)
        assertEquals(0, fixture.workspaces.list().size)
        val receipt = fixture.workspaces.queryOperation(operation.getString("operation_id"))!!
        assertEquals("delete_owned", receipt.getString("operation"))
        assertEquals("committed", receipt.getString("outcome"))
        // Replayed without any confirmation: the receipt answers.
        assertEquals("deleted", fixture.removal.deleteOwned(fields(operation, UUID.randomUUID().toString())).getString("status"))
        // Nothing left to prepare.
        assertEquals("E_WORKSPACE_CONFLICT", refusedCode("preparing a delete of a deleted workspace") {
            fixture.removal.prepareDelete(fields(operation).apply { remove("operation_id") })
        })
    }

    /** A delete's journal as the registry writes it, for a crash to be staged around. */
    private fun journal(fixture: Fixture, record: JSONObject, operationId: String, phase: String): JSONObject {
        val workspaceId = record.getString("workspace_id")
        val directoryName = record.getString("owned_directory_name")
        val content = identity(File(fixture.container, directoryName))
        val gitdirs = File(fixture.gitdirs, workspaceId)
        val git = if (gitdirs.isDirectory) identity(gitdirs) else null
        val registry = fixture.workspaces.registry()
        val canonical = RishAgentCoreNative.canonical(registry.toString())!!
        val clearanceReceiptId = UUID.randomUUID().toString()
        val digest = RishAgentCoreNative.hash(
            "workspace_removal_request",
            JSONObject().put("action", "delete_owned").put("workspace_id", workspaceId)
                .put("expected_binding_revision", 1).put("clearance_receipt_id", clearanceReceiptId),
        )
        return JSONObject()
            .put("schema_version", 1).put("operation_id", operationId).put("workspace_id", workspaceId)
            .put("operation", "delete_owned").put("binding_revision", 1)
            .put("clearance_receipt_id", clearanceReceiptId).put("request_sha256", digest)
            .put("directory_name", directoryName)
            .put("content_device_id", content.first).put("content_inode_id", content.second)
            .put("gitdirs_device_id", git?.first ?: JSONObject.NULL).put("gitdirs_inode_id", git?.second ?: JSONObject.NULL)
            .put("previous_registry_generation", registry.getInt("generation"))
            .put("previous_registry_sha256", java.security.MessageDigest.getInstance("SHA-256")
                .digest(canonical.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) })
            .put("phase", phase).put("created_at", AgentSessionFixture.STAMP).put("updated_at", AgentSessionFixture.STAMP)
    }

    @Test
    fun anInterruptedDeleteIsFinishedByTheNextLaunchFromEitherEarlyPhase() {
        for (phase in listOf("prepared", "quarantined")) {
            val fixture = fixture()
            val record = fixture.workspaces.create("Interrupted $phase")
            val workspaceId = record.getString("workspace_id")
            val directory = File(fixture.container, record.getString("owned_directory_name"))
            File(directory, "left.txt").writeText("behind")
            attach(fixture, workspaceId)
            val gitdirs = File(fixture.gitdirs, workspaceId)
            val operationId = UUID.randomUUID().toString()
            val journal = journal(fixture, record, operationId, phase)
            fixture.removals.mkdirs()
            // The crash left the disk in the state the phase describes.
            if (phase == "quarantined") {
                assertTrue(directory.renameTo(File(fixture.removals, "$operationId-content")))
                assertTrue(gitdirs.renameTo(File(fixture.removals, "$operationId-gitdirs")))
            }
            File(fixture.removals, "$operationId.journal.json").writeText(journal.toString())

            val fresh = AndroidWorkspaceRegistry(fixture.workspaces.root)
            assertEquals("phase $phase", 1, fresh.sweepRemovals())
            assertFalse("phase $phase: content survived", directory.exists())
            assertFalse("phase $phase: gitdirs survived", gitdirs.exists())
            assertEquals("phase $phase", 0, fresh.list().size)
            assertEquals("phase $phase", emptyList<String>(), fixture.removals.list()?.toList() ?: emptyList<String>())
            val receipt = fresh.queryOperation(operationId)!!
            assertEquals("phase $phase", "delete_owned", receipt.getString("operation"))
            assertEquals("phase $phase", "committed", receipt.getString("outcome"))
        }
    }

    @Test
    fun aPurgeThatFailsLeavesTheReceiptPendingAndFinishesLater() {
        val fixture = fixture()
        val record = fixture.workspaces.create("Stubborn")
        val workspaceId = record.getString("workspace_id")
        val directory = File(fixture.container, record.getString("owned_directory_name"))
        val nested = File(directory, "nested").apply { mkdirs() }
        File(nested, "pinned.txt").writeText("cannot unlink me")
        val operationId = UUID.randomUUID().toString()
        val journal = journal(fixture, record, operationId, "quarantined")
        fixture.removals.mkdirs()
        val quarantined = File(fixture.removals, "$operationId-content")
        assertTrue(directory.renameTo(quarantined))
        File(fixture.removals, "$operationId.journal.json").writeText(journal.toString())
        // A directory nobody may write to cannot lose its entries.
        val stuck = File(quarantined, "nested")
        assumeTrue("permissions are not enforced here", stuck.setWritable(false, false) && !stuck.canWrite())

        val fresh = AndroidWorkspaceRegistry(fixture.workspaces.root)
        assertEquals(0, fresh.sweepRemovals())
        // The registration is gone and the receipt says so, honestly: pending.
        assertEquals(0, fresh.list().size)
        val pending = fresh.queryOperation(operationId)!!
        assertEquals("purge_pending", pending.getString("outcome"))
        assertTrue(File(fixture.removals, "$operationId.journal.json").isFile)
        assertTrue(quarantined.isDirectory)
        assertEquals("E_WORKSPACE_PERSISTENCE", refusedCode("a delete replayed while its purge still fails") {
            fresh.deleteOwned(workspaceId, 1, operationId, journal.getString("clearance_receipt_id"), null)
        })

        assertTrue(stuck.setWritable(true, false))
        assertEquals(1, fresh.sweepRemovals())
        assertFalse(quarantined.exists())
        assertEquals("committed", fresh.queryOperation(operationId)!!.getString("outcome"))
        assertEquals(emptyList<String>(), fixture.removals.list()?.toList() ?: emptyList<String>())
    }

    @Test
    fun aDeleteWhoseContentWasReplacedSinceTheIntentIsRefused() {
        val fixture = fixture()
        val record = fixture.workspaces.create("Replaced")
        val workspaceId = record.getString("workspace_id")
        val directoryName = record.getString("owned_directory_name")
        val directory = File(fixture.container, directoryName)
        val operationId = UUID.randomUUID().toString()
        val digest = RishAgentCoreNative.hash(
            "workspace_removal_request",
            JSONObject().put("action", "delete_owned").put("workspace_id", workspaceId)
                .put("expected_binding_revision", 1).put("clearance_receipt_id", UUID.randomUUID().toString()),
        )
        val journal = JSONObject()
            .put("schema_version", 1).put("operation_id", operationId).put("workspace_id", workspaceId)
            .put("operation", "delete_owned").put("binding_revision", 1)
            .put("clearance_receipt_id", UUID.randomUUID().toString()).put("request_sha256", digest)
            .put("directory_name", directoryName)
            .put("content_device_id", "1").put("content_inode_id", "424242")
            .put("gitdirs_device_id", JSONObject.NULL).put("gitdirs_inode_id", JSONObject.NULL)
            .put("previous_registry_generation", 1).put("previous_registry_sha256", "0".repeat(64))
            .put("phase", "prepared").put("created_at", AgentSessionFixture.STAMP).put("updated_at", AgentSessionFixture.STAMP)
        fixture.removals.mkdirs()
        File(fixture.removals, "$operationId.journal.json").writeText(journal.toString())
        val fresh = AndroidWorkspaceRegistry(fixture.workspaces.root)
        assertEquals(0, fresh.sweepRemovals())
        assertTrue("a directory the journal does not describe was moved", directory.isDirectory)
        assertEquals(1, fresh.list().size)
        assertTrue(File(fixture.removals, "$operationId.journal.json").isFile)
    }

    // --- exclusion -------------------------------------------------------------

    @Test
    fun workInFlightDelaysARemovalAndWorkThatWillNotFinishRefusesIt() {
        val fixture = fixture()
        val workspaceId = fixture.workspaces.create("Busy").getString("workspace_id")
        val operation = operation(workspaceId, "forget")
        assertEquals("committed", clearance(fixture, candidate(AgentSessionFixture.Ids(), operation), operation).getString("status"))

        // A hold that lets go within the wait: the removal waits and then runs.
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val worker = Thread {
            fixture.workspaces.holding(workspaceId) {
                started.countDown()
                release.await(10, TimeUnit.SECONDS)
            }
        }
        worker.start()
        assertTrue(started.await(5, TimeUnit.SECONDS))
        Thread {
            Thread.sleep(500)
            release.countDown()
        }.start()
        val before = System.currentTimeMillis()
        assertEquals("forgotten", fixture.removal.forget(fields(operation)).getString("status"))
        assertTrue("the removal did not wait for the hold", System.currentTimeMillis() - before >= 400)
        worker.join()

        // A hold that outlives the wait: busy, and nothing changes.
        val other = fixture.workspaces.create("Busier")
        val otherId = other.getString("workspace_id")
        val otherOperation = operation(otherId, "forget")
        assertEquals("committed", clearance(fixture, candidate(AgentSessionFixture.Ids(), otherOperation), otherOperation).getString("status"))
        val holdStarted = CountDownLatch(1)
        val holdRelease = CountDownLatch(1)
        val holder = Thread {
            fixture.workspaces.holding(otherId) {
                holdStarted.countDown()
                holdRelease.await(20, TimeUnit.SECONDS)
            }
        }
        holder.start()
        assertTrue(holdStarted.await(5, TimeUnit.SECONDS))
        assertEquals("E_WORKSPACE_BUSY", refusedCode("a removal under work that will not finish") {
            fixture.removal.forget(fields(otherOperation))
        })
        assertEquals(1, fixture.workspaces.list().size)
        // While a removal runs, new work on the workspace is refused too.
        holdRelease.countDown()
        holder.join()
    }
}
