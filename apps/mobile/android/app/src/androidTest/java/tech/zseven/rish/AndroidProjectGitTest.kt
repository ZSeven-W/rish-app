package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidProjectGit
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * The git panel's local operations over an attached project, end to end:
 * a file appears, is staged, is committed, and status says so at each step
 * in the words JavaScript's validator accepts.
 */
@RunWith(AndroidJUnit4::class)
class AndroidProjectGitTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(registryRoot: File) {
        val workspaces = AndroidWorkspaceRegistry(registryRoot)
        val projects = AndroidWorkspaceProjects(workspaces)
        val roots = AndroidAgentRootResolver(workspaces, projects)
        val git = AndroidProjectGit(projects, workspaces)
        val workspaceId: String = workspaces.create("Scratch").getString("workspace_id")
        val workspaceDir: File = workspaces.rootFor(workspaceId)!!
        val projectId: String = projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("root", root()).put("mode", "init"),
        ).getJSONObject("project").getString("project_id")

        fun root(projectId: String? = null): JSONObject = JSONObject()
            .put("schema_version", 1).put("workspace_id", workspaceId)
            .put("binding_revision", 1).put("project_id", projectId ?: JSONObject.NULL)
        fun request(): JSONObject = JSONObject().put("schema_version", 1).put("root", root(projectId))
        fun diffRequest(maxBytes: Any = 1024 * 1024, staged: Any = false): JSONObject = request().put("max_bytes", maxBytes).put("staged", staged)
        fun commitRequest(
            message: String = "first\n\nbody",
            name: String = "Rish",
            email: String = "rish@example.invalid",
            expectedHead: String? = null,
        ): JSONObject = request().put("operation_id", UUID.randomUUID().toString())
            .put("message", message).put("author_name", name).put("author_email", email)
            .put("expected_head_oid", expectedHead ?: JSONObject.NULL)
    }

    private fun fixture(): Fixture {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        assertTrue("libgit2 is not staged", RishLibgit2Native.available)
        return Fixture(File(context.noBackupFilesDir, "git-test-${UUID.randomUUID()}").apply { mkdirs() })
    }

    private fun refusal(block: () -> Unit): String {
        try {
            block()
        } catch (refused: AndroidWorkspaceProjects.Refused) {
            return refused.code
        }
        fail("expected a refusal")
        throw IllegalStateException()
    }

    private fun entries(status: JSONObject): Map<String, JSONObject> {
        val rows = status.getJSONArray("entries")
        return (0 until rows.length()).map { rows.getJSONObject(it) }.associateBy { it.getString("path") }
    }

    @Test
    fun aFileIsSeenStagedAndCommitted() {
        val f = fixture()
        val empty = f.git.status(f.request())
        assertEquals(2, empty.getInt("schema_version"))
        assertEquals(f.projectId, empty.getString("project_id"))
        assertEquals(f.projectId, empty.getJSONObject("root").getString("project_id"))
        assertEquals("main", empty.getString("branch"))
        assertTrue(empty.isNull("head_oid"))
        assertTrue(empty.getBoolean("clean"))
        assertFalse(empty.getBoolean("has_conflicts"))
        assertEquals(0, empty.getInt("ahead"))
        assertEquals(0, empty.getInt("behind"))
        assertEquals(0, empty.getJSONArray("entries").length())

        File(f.workspaceDir, "notes.md").writeText("hello\n")
        val untracked = entries(f.git.status(f.request())).getValue("notes.md")
        assertEquals("unmodified", untracked.getString("index_status"))
        assertEquals("added", untracked.getString("worktree_status"))
        assertFalse(untracked.getBoolean("conflicted"))

        val diff = f.git.diff(f.diffRequest())
        assertFalse(diff.getBoolean("staged"))
        assertFalse(diff.getBoolean("truncated"))
        val file = diff.getJSONArray("files").getJSONObject(0)
        assertEquals("notes.md", file.getString("path"))
        assertEquals("added", file.getString("status"))
        assertEquals(1, file.getInt("additions"))
        assertEquals(0, file.getInt("deletions"))
        assertTrue(diff.getString("patch"), diff.getString("patch").contains("+hello"))

        val staged = f.git.stageAll(f.request())
        // Two diffs, two sides: the index against HEAD carries what was
        // staged, the working tree against the index nothing.
        assertTrue(f.git.diff(f.diffRequest(staged = true)).getBoolean("staged"))
        assertTrue(f.git.diff(f.diffRequest(staged = true)).getJSONArray("files").length() > 0)
        assertFalse(f.git.diff(f.diffRequest(staged = false)).getBoolean("staged"))
        assertEquals("added", entries(staged).getValue("notes.md").getString("index_status"))
        assertEquals("unmodified", entries(staged).getValue("notes.md").getString("worktree_status"))
        assertEquals(0, f.git.diff(f.diffRequest()).getJSONArray("files").length())

        val commit = f.git.commit(f.commitRequest())
        assertEquals(2, commit.getInt("schema_version"))
        assertEquals("first", commit.getString("summary"))
        assertTrue(Regex("[0-9a-f]{40}").matches(commit.getString("oid")))
        assertTrue(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z").matches(commit.getString("committed_at")))
        val after = f.git.status(f.request())
        assertEquals(commit.getString("oid"), after.getString("head_oid"))
        assertTrue(after.getBoolean("clean"))
        assertEquals("main", after.getString("branch"))

        // HEAD is no longer unborn, and nothing is staged: both refuse.
        assertEquals("E_PROJECT_CONFLICT", refusal { f.git.commit(f.commitRequest()) })
        assertEquals("E_PROJECT_NATIVE", refusal { f.git.commit(f.commitRequest(expectedHead = commit.getString("oid"))) })

        File(f.workspaceDir, "notes.md").writeText("hello\nworld\n")
        val modified = entries(f.git.status(f.request())).getValue("notes.md")
        assertEquals("modified", modified.getString("worktree_status"))
        f.git.stageAll(f.request())
        val second = f.git.commit(f.commitRequest(message = "second", name = "Rish Bot", expectedHead = commit.getString("oid")))
        assertNotEquals(commit.getString("oid"), second.getString("oid"))
        assertEquals(second.getString("oid"), f.git.status(f.request()).getString("head_oid"))
        // The workspace holds only the person's file; git's state lives beside the registry.
        assertEquals(listOf("notes.md"), f.workspaceDir.list()!!.toList())
    }

    @Test
    fun theDiffIsClippedToWhatTheCallerTakes() {
        val f = fixture()
        File(f.workspaceDir, "big.txt").writeText((1..200).joinToString("\n") { "line $it é" } + "\n")
        val whole = f.git.diff(f.diffRequest())
        assertFalse(whole.getBoolean("truncated"))
        val clipped = f.git.diff(f.diffRequest(maxBytes = 100))
        assertTrue(clipped.getBoolean("truncated"))
        assertTrue(clipped.getString("patch").toByteArray(Charsets.UTF_8).size <= 100)
        assertTrue(whole.getString("patch").startsWith(clipped.getString("patch")))
        assertEquals(200, clipped.getJSONArray("files").getJSONObject(0).getInt("additions"))
    }

    @Test
    fun requestsAreHeldToTheSameShapeAsOnIos() {
        val f = fixture()
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.status(f.request().put("extra", 1)) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.status(f.request().put("root", f.root())) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.diff(f.diffRequest(maxBytes = 0)) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.diff(f.diffRequest(staged = "yes")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.diff(f.diffRequest().also { it.remove("staged") }) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.diff(f.diffRequest(maxBytes = 1024 * 1024 + 1)) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.diff(f.diffRequest(maxBytes = true)) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.commit(f.commitRequest(message = "  \n")) })
        // A person's name has spaces in it; only what a signature cannot carry is refused.
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.commit(f.commitRequest(name = " Rish")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.commit(f.commitRequest(name = "Rish\nBot")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.commit(f.commitRequest(name = "Rish <bot>")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.commit(f.commitRequest(email = "rish")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.commit(f.commitRequest(email = "<rish@x.y>")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.git.commit(f.commitRequest(expectedHead = "abc")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal {
            f.git.commit(f.commitRequest().put("operation_id", "not-a-uuid"))
        })
        // A project this workspace does not hold is not found (3102).
        assertEquals("E_PROJECT_NATIVE", refusal {
            f.git.status(JSONObject().put("schema_version", 1).put("root", f.root(UUID.randomUUID().toString())))
        })
    }
}
