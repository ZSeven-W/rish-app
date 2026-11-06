package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentRootResolver
import tech.zseven.rish.runtime.AndroidProjectContextService
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * `listCandidatesV2` end to end on this platform: a workspace, a project
 * attached to it, files staged through the private gitdir, and the page
 * JavaScript reads back.
 */
@RunWith(AndroidJUnit4::class)
class AndroidProjectContextServiceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(registryRoot: File) {
        val workspaces = AndroidWorkspaceRegistry(registryRoot)
        val projects = AndroidWorkspaceProjects(workspaces)
        val roots = AndroidAgentRootResolver(workspaces, projects)
        val service = AndroidProjectContextService(projects, roots)
        val workspaceId: String = workspaces.create("Scratch").getString("workspace_id")
        val workspaceDir: File = workspaces.rootFor(workspaceId)!!
        val projectId: String = projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("root", root(null)).put("mode", "init"),
        ).getJSONObject("project").getString("project_id")
        val gitDir: File = projects.gitDirectory(workspaceId, projectId)

        fun root(projectId: String?): JSONObject = JSONObject()
            .put("schema_version", 1).put("workspace_id", workspaceId)
            .put("binding_revision", 1).put("project_id", projectId ?: JSONObject.NULL)

        fun request(query: String = "", cursor: String? = null, root: JSONObject = root(projectId)): JSONObject =
            JSONObject().put("schema_version", 1).put("root", root).put("query", query)
                .put("cursor", cursor ?: JSONObject.NULL)

        fun stage(path: String, content: String) {
            File(workspaceDir, path).apply { parentFile?.mkdirs() }.writeText(content)
            assertEquals("ok", RishLibgit2Native.stagePath(gitDir.absolutePath, workspaceDir.absolutePath, path))
        }
    }

    private fun fixture(): Fixture {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        assertTrue("libgit2 is not staged", RishLibgit2Native.available)
        return Fixture(File(context.noBackupFilesDir, "context-test-${UUID.randomUUID()}").apply { mkdirs() })
    }

    private fun refusal(block: () -> Unit): String {
        try {
            block()
        } catch (refused: AndroidProjectContextService.Refused) {
            return refused.code
        }
        fail("expected a refusal")
        throw IllegalStateException()
    }

    /**
     * After the agent's own `git_commit` -- stage everything, commit -- the
     * index still holds every file, and every one of them is a candidate,
     * unchanged. On a device this listing came back empty once, and the
     * question was whether the native page or the JavaScript above it was
     * dropping them.
     */
    @Test
    fun aCommittedIndexStillListsEveryFileAsAnUnchangedCandidate() {
        val f = fixture()
        for ((path, text) in listOf("README.md" to "# Smoke\n", "src/main.kt" to "fun main() {}\n", "secrets.env" to "API_TOKEN=sk-live-abcdefghijklmnopqrstuvwxyz012345\n")) {
            File(f.workspaceDir, path).apply { parentFile?.mkdirs() }.writeText(text)
        }
        val tools = tech.zseven.rish.runtime.AndroidAgentGitToolExecutor(f.projects, f.workspaces, f.roots)
        val root = f.roots.resolve(f.workspaceId, f.projectId, 1)!!
        val precondition = tools.prepare("git_commit", JSONObject().put("message", "initial"), root).getJSONObject("precondition")
        val committed = tools.execute("git_commit", JSONObject().put("message", "initial"), root, precondition)
        assertEquals(committed.toString(), "ok", committed.getString("status"))

        val page = f.service.listCandidates(f.request())
        val candidates = page.getJSONArray("candidates")
        val paths = (0 until candidates.length()).map { candidates.getJSONObject(it).getString("path") }
        assertEquals(listOf("README.md", "secrets.env", "src/main.kt"), paths.sorted())
        for (index in 0 until candidates.length()) {
            val candidate = candidates.getJSONObject(index)
            assertEquals(candidate.toString(), "unchanged", candidate.getString("git_state"))
            if (candidate.getString("path") == "secrets.env") {
                assertFalse(candidate.getBoolean("eligible")); assertEquals("secret_path", candidate.getString("omission_reason"))
            } else {
                assertTrue(candidate.toString(), candidate.getBoolean("eligible"))
            }
        }
    }

    @Test
    fun listsTheAttachedProjectsCandidatesForTheRoot() {
        val f = fixture()
        f.stage("README.md", "# hello\n")
        f.stage("src/main.kt", "fun main() {}\n")
        f.stage("build/out.bin", "\u0000\u0001")

        val page = f.service.listCandidates(f.request())
        assertEquals(2, page.getInt("schema_version"))
        assertEquals(f.projectId, page.getJSONObject("root").getString("project_id"))
        assertEquals(f.workspaceId, page.getJSONObject("root").getString("workspace_id"))
        val project = page.getJSONObject("project")
        assertEquals(f.projectId, project.getString("project_id"))
        assertEquals("private_split_gitdir", project.getString("git_topology"))
        assertTrue(page.isNull("next_cursor"))
        val candidates = page.getJSONArray("candidates")
        val byPath = (0 until candidates.length()).map { candidates.getJSONObject(it) }.associateBy { it.getString("path") }
        assertEquals(listOf("README.md", "build/out.bin", "src/main.kt"), byPath.keys.toList())
        assertTrue(byPath.getValue("README.md").getBoolean("eligible"))
        assertEquals("staged", byPath.getValue("README.md").getString("git_state"))
        assertTrue(byPath.getValue("src/main.kt").getBoolean("eligible"))
        // A build product is the shared policy's to omit, with its reason.
        assertFalse(byPath.getValue("build/out.bin").getBoolean("eligible"))
        assertEquals("generated", byPath.getValue("build/out.bin").getString("omission_reason"))

        // The query narrows by folded substring.
        val narrowed = f.service.listCandidates(f.request(query = "MAIN"))
        assertEquals(1, narrowed.getJSONArray("candidates").length())
        assertEquals("src/main.kt", narrowed.getJSONArray("candidates").getJSONObject(0).getString("path"))
    }

    @Test
    fun aCursorContinuesTheListingAndIsBoundToIt() {
        val f = fixture()
        for (index in 0 until 5) f.stage("file$index.txt", "$index\n")
        val first = f.service.listCandidates(f.request(), limit = 2)
        assertEquals(2, first.getJSONArray("candidates").length())
        val cursor = first.getString("next_cursor")
        assertTrue(cursor, Regex("[A-Za-z0-9_-]{98}").matches(cursor))
        val second = f.service.listCandidates(f.request(cursor = cursor), limit = 2)
        assertEquals("file2.txt", second.getJSONArray("candidates").getJSONObject(0).getString("path"))
        val third = f.service.listCandidates(f.request(cursor = second.getString("next_cursor")), limit = 2)
        assertEquals(1, third.getJSONArray("candidates").length())
        assertTrue(third.isNull("next_cursor"))

        // Under another query the cursor is not this listing's; after the
        // project moves it is a listing that no longer exists.
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.service.listCandidates(f.request(query = "x", cursor = cursor)) })
        f.stage("file5.txt", "5\n")
        assertEquals("E_CONTEXT_CHANGED", refusal { f.service.listCandidates(f.request(cursor = cursor), limit = 2) })
    }

    @Test
    fun refusesRootsWithoutAProjectOrWithAnotherOne() {
        val f = fixture()
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.service.listCandidates(f.request(root = f.root(null))) })
        assertEquals("E_PROJECT_NOT_FOUND", refusal {
            f.service.listCandidates(f.request(root = f.root(UUID.randomUUID().toString())))
        })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.service.listCandidates(f.request().put("extra", true)) })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.service.listCandidates(f.request(query = "a".repeat(257))) })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.service.listCandidates(f.request(query = "tab\there")) })
        assertEquals("E_CONTEXT_REQUEST_INVALID", refusal { f.service.listCandidates(f.request(cursor = "not-a-cursor")) })
        // An empty project lists nothing rather than refusing.
        val empty = f.service.listCandidates(f.request())
        assertEquals(0, empty.getJSONArray("candidates").length())
    }
}
