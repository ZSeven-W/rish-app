package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentGitToolExecutor
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidGitCredentials
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.AndroidWorkspaceToolExecutor
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * The agent's git_status and git_commit on this device: a commit lands with
 * exactly the id its precondition predicted, a stale precondition is a
 * conflict rather than a second commit, and recovery can tell the two apart.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentGitToolExecutorTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(val scratch: File, context: android.content.Context) {
        val workspaces = AndroidWorkspaceRegistry(File(scratch, "registry").apply { mkdirs() })
        val projects = AndroidWorkspaceProjects(workspaces)
        val roots = AndroidAgentRootResolver(workspaces, projects)
        val credentials = AndroidGitCredentials(context, "rish.git-credentials.test-${UUID.randomUUID()}")
        val tools = AndroidAgentGitToolExecutor(projects, workspaces, roots, credentials)
        val workspaceId: String = workspaces.create("Scratch").getString("workspace_id")
        val workDir: File = workspaces.rootFor(workspaceId)!!
        val projectId: String = projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString()).put("mode", "init")
                .put("root", JSONObject().put("schema_version", 1).put("workspace_id", workspaceId)
                    .put("binding_revision", 1).put("project_id", JSONObject.NULL)),
        ).getJSONObject("project").getString("project_id")
        val root: JSONObject = roots.resolve(workspaceId, projectId, 1)!!
        val workspaceRoot: JSONObject = roots.resolve(workspaceId, null, 1)!!
        val gitDir: File = projects.gitDirectory(workspaceId, projectId)

        /** A commit the way the agent makes one: a file written, then git_commit prepared and executed. */
        fun agentCommit(path: String, text: String, message: String): String {
            File(workDir, path).apply { parentFile?.mkdirs() }.writeText(text)
            val arguments = JSONObject().put("message", message)
            val precondition = tools.prepare("git_commit", arguments, root).getJSONObject("precondition")
            val effect = tools.execute("git_commit", arguments, root, precondition)
            assertEquals(effect.toString(), "ok", effect.getString("status"))
            return JSONObject(effect.getString("feedback")).getJSONObject("payload").getString("commit_oid")
        }

        /** A bare repository beside the fixture, reached as an absolute path: the native test transport. */
        fun bareOrigin(): File {
            val bare = File(scratch, "origin.git")
            assertEquals("ok", RishLibgit2Native.initSplitRepository(bare.absolutePath, File(scratch, "unused").apply { mkdirs() }.absolutePath))
            assertEquals("ok", RishLibgit2Native.setRemote(gitDir.absolutePath, workDir.absolutePath, bare.absolutePath))
            return bare
        }
    }

    private fun fixture(): Fixture {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        assertTrue("libgit2 is not staged", RishLibgit2Native.available)
        return Fixture(File(context.noBackupFilesDir, "git-tools-${UUID.randomUUID()}").apply { mkdirs() }, context)
    }

    private fun refusal(block: () -> Unit): String {
        try { block() } catch (refused: AndroidWorkspaceToolExecutor.Refused) { return refused.code }
        fail("expected a refusal"); throw IllegalStateException()
    }

    private fun payload(effect: JSONObject): JSONObject = JSONObject(effect.getString("feedback")).getJSONObject("payload")

    @Test
    fun aCommitLandsWithThePredictedIdAndAStalePreconditionConflicts() {
        val f = fixture()
        val status = f.tools.execute("git_status", JSONObject(), f.root, f.tools.prepare("git_status", JSONObject(), f.root).getJSONObject("precondition"))
        assertEquals("ok", status.getString("status"))
        assertTrue(payload(status).getBoolean("clean"))
        assertTrue(payload(status).isNull("head_oid"))
        // Exactly what the core's `feedback_payload` rule accepts for
        // git_status, and nothing the native reply added: with `ok` left in,
        // the ledger refused to settle the row on a real device.
        assertEquals(
            setOf("schema_version", "branch", "head_oid", "clean", "has_conflicts", "entry_count"),
            payload(status).keys().asSequence().toSet(),
        )

        File(f.workDir, "notes.md").writeText("first\n")
        val prepared = f.tools.prepare("git_commit", JSONObject().put("message", "first"), f.root)
        val precondition = prepared.getJSONObject("precondition")
        assertEquals("git_commit", precondition.getString("kind"))
        assertTrue(precondition.isNull("pre_head_oid"))
        assertEquals(0, precondition.getJSONArray("ordered_parent_oids").length())
        assertTrue(Regex("[0-9a-f]{40}").matches(precondition.getString("tree_oid")))
        assertTrue(Regex("[0-9a-f]{40}").matches(precondition.getString("expected_commit_oid")))
        assertEquals(5, precondition.getInt("message_bytes"))
        assertEquals("Rish Agent", precondition.getJSONObject("author").getString("name"))

        val committed = f.tools.execute("git_commit", JSONObject().put("message", "first"), f.root, precondition)
        assertEquals(committed.toString(), "ok", committed.getString("status"))
        assertTrue(committed.getBoolean("effect_may_have_occurred"))
        val commitOid = committed.getJSONObject("settled_facts").getString("actual_commit_oid")
        assertEquals(precondition.getString("expected_commit_oid"), commitOid)
        assertEquals(commitOid, payload(committed).getString("commit_oid"))
        assertEquals(setOf("schema_version", "commit_oid", "tree_oid"), payload(committed).keys().asSequence().toSet())
        // HEAD moved to it, the index was written, and status says so.
        val after = f.tools.execute("git_status", JSONObject(), f.root, f.tools.prepare("git_status", JSONObject(), f.root).getJSONObject("precondition"))
        assertEquals(commitOid, payload(after).getString("head_oid"))
        assertTrue(payload(after).getBoolean("clean"))
        assertTrue(File(f.projects.gitDirectory(f.workspaceId, f.projectId), "index").isFile)
        assertEquals("settled", f.tools.recover("git_commit", JSONObject().put("message", "first"), f.root, precondition).getString("status"))

        // The same precondition again: HEAD is no longer where it asserted.
        val stale = f.tools.execute("git_commit", JSONObject().put("message", "first"), f.root, precondition)
        assertEquals("failed", stale.getString("status"))
        assertEquals("E_AGENT_CONFLICT", payload(stale).getString("failure_code"))
        assertEquals(commitOid, payload(f.tools.execute("git_status", JSONObject(), f.root, f.tools.prepare("git_status", JSONObject(), f.root).getJSONObject("precondition"))).getString("head_oid"))

        // A second commit on top, with the first as its parent.
        File(f.workDir, "notes.md").writeText("first\nsecond\n")
        val second = f.tools.prepare("git_commit", JSONObject().put("message", "second"), f.root).getJSONObject("precondition")
        assertEquals(commitOid, second.getString("pre_head_oid"))
        assertEquals(commitOid, second.getJSONArray("ordered_parent_oids").getString(0))
        // Not dispatched yet: everything the commit would be made from is still as prepared.
        assertEquals("not_dispatched", f.tools.recover("git_commit", JSONObject().put("message", "second"), f.root, second).getString("status"))
        val landed = f.tools.execute("git_commit", JSONObject().put("message", "second"), f.root, second)
        assertEquals("ok", landed.getString("status"))
        assertNotEquals(commitOid, landed.getJSONObject("settled_facts").getString("actual_commit_oid"))
        assertEquals(second.getString("expected_commit_oid"), landed.getJSONObject("settled_facts").getString("actual_commit_oid"))
        // A precondition whose world moved on, with HEAD elsewhere: ambiguous.
        assertEquals("ambiguous", f.tools.recover("git_commit", JSONObject().put("message", "first"), f.root, precondition).getString("status"))
    }

    @Test
    fun theWorkingTreeChangingUnderAPreparedCommitIsAConflict() {
        val f = fixture()
        File(f.workDir, "a.txt").writeText("a\n")
        val precondition = f.tools.prepare("git_commit", JSONObject().put("message", "a"), f.root).getJSONObject("precondition")
        File(f.workDir, "a.txt").writeText("changed\n")
        val effect = f.tools.execute("git_commit", JSONObject().put("message", "a"), f.root, precondition)
        assertEquals("failed", effect.getString("status"))
        assertEquals("E_AGENT_CONFLICT", payload(effect).getString("failure_code"))
        assertTrue(payload(f.tools.execute("git_status", JSONObject(), f.root, f.tools.prepare("git_status", JSONObject(), f.root).getJSONObject("precondition"))).isNull("head_oid"))
        assertEquals("ambiguous", f.tools.recover("git_commit", JSONObject().put("message", "a"), f.root, precondition).getString("status"))
    }

    @Test
    fun requestsAreHeldToTheContract() {
        val f = fixture()
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal { f.tools.prepare("git_status", JSONObject().put("x", 1), f.root) })
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal { f.tools.prepare("git_commit", JSONObject().put("message", ""), f.root) })
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal { f.tools.prepare("git_commit", JSONObject().put("message", "x".repeat(501)), f.root) })
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal { f.tools.prepare("git_commit", JSONObject().put("message", "m").put("extra", 1), f.root) })
        // A workspace root carries no git capability.
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal { f.tools.prepare("git_status", JSONObject(), f.workspaceRoot) })
        // A precondition for another tool never runs this one.
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal {
            f.tools.execute("git_commit", JSONObject().put("message", "m"), f.root, JSONObject().put("kind", "git_status"))
        })
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal { f.tools.prepare("git_push", JSONObject().put("force", true), f.root) })
        // Nothing to push yet: no branch, no precondition.
        assertEquals("E_AGENT_CONFLICT", refusal { f.tools.prepare("git_push", JSONObject(), f.root) })
    }

    private fun prepush(f: Fixture): JSONObject = f.tools.prepare("git_push", JSONObject(), f.root).getJSONObject("precondition")
    private fun push(f: Fixture, precondition: JSONObject): JSONObject = f.tools.execute("git_push", JSONObject(), f.root, precondition)
    private fun recoverPush(f: Fixture, precondition: JSONObject): JSONObject = f.tools.recover("git_push", JSONObject(), f.root, precondition)

    @Test
    fun aPushLandsOnABareOriginAndRecoveryReadsTheRemote() {
        val f = fixture()
        val first = f.agentCommit("a.txt", "one\n", "first")
        val bare = f.bareOrigin()
        val pre = prepush(f)
        assertEquals("git_push", pre.getString("kind"))
        assertEquals("origin", pre.getString("remote"))
        assertEquals("refs/heads/main", pre.getString("remote_ref"))
        assertTrue(pre.isNull("pre_remote_oid"))
        assertEquals(first, pre.getString("target_oid"))

        val effect = push(f, pre)
        assertEquals(effect.toString(), "ok", effect.getString("status"))
        assertTrue(effect.getBoolean("effect_may_have_occurred"))
        assertEquals(setOf("schema_version", "remote", "remote_ref", "pushed_oid", "remote_oid"), payload(effect).keys().asSequence().toSet())
        assertEquals(first, payload(effect).getString("pushed_oid"))
        assertEquals(first, payload(effect).getString("remote_oid"))
        assertEquals(first, effect.getJSONObject("settled_facts").getString("actual_remote_oid"))
        assertEquals(first, File(bare, "refs/heads/main").readText().trim())
        assertEquals(first, File(f.gitDir, "refs/remotes/origin/main").readText().trim())
        // The panel's receipt, with `localhost` standing in for a path origin.
        val receipts = tech.zseven.rish.runtime.AndroidGitPushReceipts.load(f.gitDir, f.projectId)
        assertEquals(1, receipts.length())
        assertEquals("localhost", receipts.getJSONObject(0).getString("host"))
        assertEquals(first, receipts.getJSONObject(0).getString("remote_oid"))
        assertEquals("settled", recoverPush(f, pre).getString("status"))
        assertEquals(first, recoverPush(f, pre).getString("actual_remote_oid"))

        // The next push asserts what the remote advertised when it was prepared.
        val second = f.agentCommit("a.txt", "two\n", "second")
        val stale = prepush(f)
        assertEquals(first, stale.getString("pre_remote_oid"))
        assertEquals(second, stale.getString("target_oid"))
        // The remote moves under it (here: the same commit, pushed by other means).
        val moved = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, UUID.randomUUID().toString(), "", "", "refs/heads/main", second, "", "", 30, false, null), Charsets.UTF_8))
        assertEquals("success", moved.getString("outcome"))
        val conflict = push(f, stale)
        assertEquals("failed", conflict.getString("status"))
        assertEquals("E_AGENT_CONFLICT", payload(conflict).getString("failure_code"))
        assertEquals("remote_moved", payload(conflict).getString("reason"))
        assertEquals(false, conflict.getBoolean("effect_may_have_occurred"))
        // Recovery reads the remote: at the target it settled, whoever put it there.
        assertEquals("settled", recoverPush(f, stale).getString("status"))

        // A push prepared and never dispatched recovers as such; one whose
        // starting point is gone is ambiguous.
        val third = f.agentCommit("a.txt", "three\n", "third")
        val pending = prepush(f)
        assertEquals(second, pending.getString("pre_remote_oid"))
        assertEquals("not_dispatched", recoverPush(f, pending).getString("status"))
        val drifted = JSONObject(pending.toString()).put("pre_remote_oid", first)
        assertEquals("ambiguous", recoverPush(f, drifted).getString("status"))
        // HEAD moving after prepare is a conflict, not a push of something else.
        val fourth = f.agentCommit("a.txt", "four\n", "fourth")
        assertNotEquals(third, fourth)
        val headMoved = push(f, pending)
        assertEquals("E_AGENT_CONFLICT", payload(headMoved).getString("failure_code"))
        assertEquals(second, File(bare, "refs/heads/main").readText().trim())
        f.scratch.deleteRecursively()
    }

    @Test
    fun aNetworkOriginIsRefusedBeforeConnectingWhenItIsUnsafeOrHasNoCredential() {
        val f = fixture()
        val head = f.agentCommit("a.txt", "one\n", "first")
        val precondition = JSONObject().put("schema_version", 1).put("kind", "git_push").put("remote", "origin")
            .put("remote_ref", "refs/heads/main").put("pre_remote_oid", JSONObject.NULL).put("target_oid", head)
        // No origin at all.
        val none = push(f, precondition)
        assertEquals("failed", none.getString("status"))
        assertEquals("origin_unsafe", payload(none).getString("reason"))
        // An origin outside the rule.
        assertEquals("ok", RishLibgit2Native.setRemote(f.gitDir.absolutePath, f.workDir.absolutePath, "ftp://example.com/demo.git"))
        assertEquals("origin_unsafe", payload(push(f, precondition)).getString("reason"))
        // A valid HTTPS origin with nothing stored for its host.
        assertEquals("ok", RishLibgit2Native.setRemote(f.gitDir.absolutePath, f.workDir.absolutePath, "https://github.com/example/demo.git"))
        val missing = push(f, precondition)
        assertEquals("failed", missing.getString("status"))
        assertEquals("E_AGENT_TOOL_FAILED", payload(missing).getString("failure_code"))
        assertEquals("credential_missing", payload(missing).getString("reason"))
        assertEquals(false, missing.getBoolean("effect_may_have_occurred"))
        // Preparing needs the remote's answer; a remote that cannot be asked is not a push to prepare.
        assertEquals("E_AGENT_CONFLICT", refusal { prepush(f) })
        assertEquals("ambiguous", recoverPush(f, precondition).getString("status"))
        f.scratch.deleteRecursively()
    }

    /**
     * Over HTTP, against scripts/git-test-remote.rb on the Mac (see
     * AndroidProjectRemoteTest for the arguments). The credential the panel
     * would have stored is stored here directly.
     */
    @Test
    fun theAgentPushAuthenticatesAndSeesTheRemoteMove() {
        val args = InstrumentationRegistry.getArguments()
        val base = args.getString("rish_g2_base"); val user = args.getString("rish_g2_user"); val token = args.getString("rish_g2_token")
        assumeTrue("no local test remote: pass rish_g2_base, rish_g2_user and rish_g2_token", base != null && user != null && token != null)
        val f = fixture()
        val branch = "rish-agent-" + UUID.randomUUID().toString().substring(0, 8)
        File(f.gitDir, "HEAD").writeText("ref: refs/heads/$branch\n")
        val first = f.agentCommit("agent.txt", "pushed by the agent on the emulator\n", "agent first")
        assertEquals("ok", RishLibgit2Native.setRemote(f.gitDir.absolutePath, f.workDir.absolutePath, "$base/target.git"))
        val host = java.net.URI(base!!).host
        // Nothing stored: refused before any connection, and not preparable either.
        val hand = JSONObject().put("schema_version", 1).put("kind", "git_push").put("remote", "origin")
            .put("remote_ref", "refs/heads/$branch").put("pre_remote_oid", JSONObject.NULL).put("target_oid", first)
        assertEquals("credential_missing", payload(push(f, hand)).getString("reason"))
        f.credentials.store(f.projectId, host, user!!, "not-the-token", 3600)
        assertEquals("E_AGENT_CONFLICT", refusal { prepush(f) })
        assertEquals("auth_failed", payload(push(f, hand)).getString("reason"))
        f.credentials.store(f.projectId, host, user, token!!, 3600)
        val pre = prepush(f)
        assertTrue(pre.isNull("pre_remote_oid"))
        val effect = push(f, pre)
        assertEquals(effect.toString(), "ok", effect.getString("status"))
        assertEquals(first, payload(effect).getString("remote_oid"))
        assertEquals("settled", recoverPush(f, pre).getString("status"))
        // The Mac commits on top; the stale precondition is a moved remote, and recovery sees neither its start nor its target.
        val competing = control(base, user, token, "POST", "/g2/compete", JSONObject().put("repo", "target.git").put("branch", branch).toString())
        assertEquals(first, competing.getString("old_oid"))
        val second = f.agentCommit("agent.txt", "second\n", "agent second")
        val stale = JSONObject(pre.toString()).put("pre_remote_oid", first).put("target_oid", second)
        val movedUnder = push(f, stale)
        assertEquals("remote_moved", payload(movedUnder).getString("reason"))
        assertEquals("ambiguous", recoverPush(f, stale).getString("status"))
        // Prepared afresh, the push is a non-fast-forward the server refuses.
        val fresh = prepush(f)
        assertEquals(competing.getString("oid"), fresh.getString("pre_remote_oid"))
        assertEquals("non_fast_forward", payload(push(f, fresh)).getString("reason"))
        f.scratch.deleteRecursively()
    }

    /** One request to the test server's control endpoints over a raw socket. */
    private fun control(base: String, user: String, token: String, method: String, path: String, body: String?): JSONObject {
        val uri = java.net.URI(base)
        java.net.Socket(uri.host, uri.port).use { socket ->
            socket.soTimeout = 30_000
            val auth = android.util.Base64.encodeToString("$user:$token".toByteArray(), android.util.Base64.NO_WRAP)
            val payload = body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
            val head = "$method $path HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nAuthorization: Basic $auth\r\n" +
                "Content-Type: application/json\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n"
            socket.getOutputStream().apply { write(head.toByteArray(Charsets.US_ASCII)); write(payload); flush() }
            val response = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
            assertEquals(response.take(300), 200, response.substringBefore("\r\n").split(" ").getOrNull(1)?.toIntOrNull())
            return JSONObject(response.substringAfter("\r\n\r\n"))
        }
    }
}
