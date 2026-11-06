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
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * Attaching a git project to an app-private workspace.
 *
 * What these assert is the contract JavaScript's activation flow relies on
 * -- none, then attached, then already_attached under the same operation --
 * and the layout on disk that iOS keeps: the gitdir outside the workspace,
 * the binding beside it, nothing inside the person's folder.
 */
@RunWith(AndroidJUnit4::class)
class AndroidWorkspaceProjectsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(val registryRoot: File) {
        val workspaces = AndroidWorkspaceRegistry(registryRoot)
        val projects = AndroidWorkspaceProjects(workspaces)
        val roots = AndroidAgentRootResolver(workspaces, projects)
        val workspaceId: String = workspaces.create("Scratch").getString("workspace_id")
        fun root(projectId: String? = null): JSONObject = JSONObject()
            .put("schema_version", 1).put("workspace_id", workspaceId)
            .put("binding_revision", 1).put("project_id", projectId ?: JSONObject.NULL)
        fun attach(mode: String = "init", operationId: String = UUID.randomUUID().toString(), root: JSONObject = root()) =
            JSONObject().put("schema_version", 1).put("operation_id", operationId).put("root", root).put("mode", mode)
    }

    private fun fixture(): Fixture {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        assertTrue("libgit2 is not staged", RishLibgit2Native.available)
        return Fixture(File(context.noBackupFilesDir, "projects-test-${UUID.randomUUID()}").apply { mkdirs() })
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

    /** The iOS error number behind a refusal, for the numbers the shared table has no code for. */
    private fun refusalNumber(block: () -> Unit): Int {
        try {
            block()
        } catch (refused: AndroidWorkspaceProjects.Refused) {
            return refused.number
        }
        fail("expected a refusal")
        throw IllegalStateException()
    }

    @Test
    fun aFreshWorkspaceHasNoProjectAndInitAttachesOne() {
        val f = fixture()
        assertEquals("none", f.projects.projectFor(f.root()).getString("status"))

        val operation = UUID.randomUUID().toString()
        val attached = f.projects.attach(f.attach(operationId = operation))
        assertEquals("attached", attached.getString("status"))
        val project = attached.getJSONObject("project")
        val projectId = project.getString("project_id")
        assertEquals(2, project.getInt("schema_version"))
        assertEquals(f.workspaceId, project.getString("workspace_id"))
        assertEquals(1, project.getInt("workspace_binding_revision"))
        // Named after its workspace, as iOS names it; not after itself.
        assertEquals("Scratch", project.getString("display_name"))
        assertEquals("private_split_gitdir", project.getString("git_topology"))

        // The layout iOS keeps: gitdir beside the registry, binding inside
        // it, and nothing in the workspace folder itself.
        val gitDir = File(File(File(f.registryRoot, "workspace-gitdirs"), f.workspaceId), projectId)
        assertTrue(File(gitDir, "HEAD").isFile)
        assertTrue(File(gitDir, "binding-v2.json").isFile)
        val binding = JSONObject(File(gitDir, "binding-v2.json").readText())
        assertEquals("workspace-gitdirs/${f.workspaceId}/$projectId", binding.getString("git_directory_relative"))
        assertEquals(f.workspaces.fingerprintFor(f.workspaceId), binding.getString("root_fingerprint_sha256"))
        val workspaceDir = f.workspaces.rootFor(f.workspaceId)!!
        assertFalse(File(workspaceDir, ".git").exists())
        assertEquals(emptyList<String>(), workspaceDir.list()!!.toList())
        // No staging or journal survives a completed attach.
        assertEquals(listOf(projectId), gitDir.parentFile!!.list()!!.toList())

        // Found again, and under the same operation the answer is the same
        // project, not a second one.
        val found = f.projects.projectFor(f.root())
        assertEquals("attached", found.getString("status"))
        assertEquals(projectId, found.getJSONObject("project").getString("project_id"))
        val repeated = f.projects.attach(f.attach(operationId = operation))
        assertEquals("already_attached", repeated.getString("status"))
        assertEquals(projectId, repeated.getJSONObject("project").getString("project_id"))
        val another = f.projects.attach(f.attach())
        assertEquals("already_attached", another.getString("status"))
        assertEquals(projectId, another.getJSONObject("project").getString("project_id"))
        // With the project named, open answers it too.
        val opened = f.projects.attach(f.attach(mode = "open", root = f.root(projectId)))
        assertEquals("already_attached", opened.getString("status"))
        assertEquals(listOf(projectId), gitDir.parentFile!!.list()!!.toList())
    }

    @Test
    fun openRefusesAWorkspaceWithoutAProjectAndBadRequests() {
        val f = fixture()
        // 3102, "workspace project is unavailable". The shared code table has
        // no entry for it, so JavaScript sees E_PROJECT_NATIVE -- on iOS too,
        // which never reaches it: activation only ever asks for init.
        assertEquals(3102, refusalNumber { f.projects.attach(f.attach(mode = "open")) })
        assertEquals("E_PROJECT_NATIVE", AndroidWorkspaceProjects.codeFor(3102))
        assertEquals("none", f.projects.projectFor(f.root()).getString("status"))
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.projects.attach(f.attach(mode = "clone")) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal {
            f.projects.attach(f.attach(operationId = UUID.randomUUID().toString().uppercase()))
        })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.projects.attach(f.attach().put("extra", 1)) })
        assertEquals("E_PROJECT_REQUEST_INVALID", refusal { f.projects.projectFor(f.root().put("binding_revision", 0)) })
        // A project id the workspace does not hold.
        assertEquals(3102, refusalNumber { f.projects.projectFor(f.root(UUID.randomUUID().toString())) })
        // A workspace that does not exist has no fingerprint to bind to.
        val stranger = f.root().put("workspace_id", UUID.randomUUID().toString())
        assertEquals(3102, refusalNumber { f.projects.attach(f.attach(root = stranger)) })
    }

    @Test
    fun theSameOperationForAnotherRootConflicts() {
        val f = fixture()
        val operation = UUID.randomUUID().toString()
        f.projects.attach(f.attach(operationId = operation))
        val other = f.workspaces.create("Other").getString("workspace_id")
        val otherRoot = f.root().put("workspace_id", other)
        assertEquals("E_PROJECT_BUSY", refusal { f.projects.attach(f.attach(operationId = operation, root = otherRoot)) })
        // The other workspace is untouched by the refusal.
        assertEquals("none", f.projects.projectFor(otherRoot).getString("status"))
    }

    @Test
    fun theProjectReadsTheWorkspaceAsItsWorkingTree() {
        val f = fixture()
        val projectId = f.projects.attach(f.attach()).getJSONObject("project").getString("project_id")
        val workspaceDir = f.workspaces.rootFor(f.workspaceId)!!
        val gitDir = f.projects.gitDirectory(f.workspaceId, projectId)
        File(workspaceDir, "notes.md").writeText("hello\n")

        val before = JSONObject(RishLibgit2Native.readRepositoryState(gitDir.absolutePath, workspaceDir.absolutePath))
        assertTrue(before.toString(), before.getBoolean("ok"))
        assertTrue(before.isNull("head"))
        assertEquals(0, before.getJSONArray("entries").length())

        assertEquals("ok", RishLibgit2Native.stagePath(gitDir.absolutePath, workspaceDir.absolutePath, "notes.md"))
        val after = JSONObject(RishLibgit2Native.readRepositoryState(gitDir.absolutePath, workspaceDir.absolutePath))
        val entry = after.getJSONArray("entries").getJSONObject(0)
        assertEquals("notes.md", entry.getString("path"))
        assertTrue(entry.getBoolean("staged"))
        assertFalse(entry.getBoolean("unstaged"))
        // Staging wrote the index into the private gitdir, not the workspace.
        assertTrue(File(gitDir, "index").isFile)
        assertEquals(listOf("notes.md"), workspaceDir.list()!!.toList())
        assertNotEquals(before.optString("index_checksum"), after.getString("index_checksum"))
    }

    @Test
    fun leftoverStagingIsSweptAndAPublishedJournalIsHonoured() {
        val f = fixture()
        val parent = File(File(f.registryRoot, "workspace-gitdirs"), f.workspaceId).apply { mkdirs() }
        val orphan = File(parent, ".rish-attach-${UUID.randomUUID()}").apply { mkdir() }
        val prepared = UUID.randomUUID().toString()
        File(parent, ".rish-attach-$prepared").mkdir()
        val journal = JSONObject().put("schema_version", 1).put("operation_id", prepared)
            .put("workspace_id", f.workspaceId).put("binding_revision", 1)
            .put("project_id", UUID.randomUUID().toString())
            .put("root_fingerprint_sha256", f.workspaces.fingerprintFor(f.workspaceId))
            .put("staging_name", ".rish-attach-$prepared")
        File(parent, ".rish-attach-$prepared.journal").writeText(
            journal.put("final_name", journal.getString("project_id")).put("phase", "prepared").toString(),
        )

        assertEquals("none", f.projects.projectFor(f.root()).getString("status"))
        assertFalse(orphan.exists())
        assertEquals(emptyList<String>(), parent.list()!!.toList())

        // A journal that says published, beside a project that is really
        // there, is what a crash between publication and cleanup leaves.
        val projectId = f.projects.attach(f.attach()).getJSONObject("project").getString("project_id")
        val operation = UUID.randomUUID().toString()
        File(parent, ".rish-attach-$operation.journal").writeText(
            JSONObject().put("schema_version", 1).put("operation_id", operation)
                .put("workspace_id", f.workspaceId).put("binding_revision", 1).put("project_id", projectId)
                .put("root_fingerprint_sha256", f.workspaces.fingerprintFor(f.workspaceId))
                .put("staging_name", ".rish-attach-$operation").put("final_name", projectId)
                .put("phase", "published").toString(),
        )
        val fresh = AndroidWorkspaceProjects(f.workspaces)
        val found = fresh.projectFor(f.root())
        assertEquals("attached", found.getString("status"))
        assertEquals(projectId, found.getJSONObject("project").getString("project_id"))
        assertEquals(listOf(projectId), parent.list()!!.toList())

        // A journal whose project is missing is not guessed about: the
        // workspace refuses until someone looks, and keeps refusing.
        File(parent, ".rish-attach-$operation.journal").writeText(
            JSONObject().put("schema_version", 1).put("operation_id", operation)
                .put("workspace_id", f.workspaceId).put("binding_revision", 1).put("project_id", projectId)
                .put("root_fingerprint_sha256", "0".repeat(64))
                .put("staging_name", ".rish-attach-$operation").put("final_name", projectId)
                .put("phase", "published").toString(),
        )
        val stuck = AndroidWorkspaceProjects(f.workspaces)
        assertEquals("E_PROJECT_STORAGE_UNSAFE", refusal { stuck.projectFor(f.root()) })
        assertEquals("E_PROJECT_STORAGE_UNSAFE", refusal { stuck.attach(f.attach()) })
    }
}
