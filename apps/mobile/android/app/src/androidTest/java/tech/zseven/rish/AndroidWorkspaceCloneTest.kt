package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidWorkspaceClone
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * A public repository cloned into a new workspace, against
 * scripts/git-test-remote.rb on the Mac (see AndroidProjectRemoteTest for
 * the arguments). What a clone that did not finish leaves behind is the
 * point of half of it: nothing.
 */
@RunWith(AndroidJUnit4::class)
class AndroidWorkspaceCloneTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(val scratch: File, context: android.content.Context) {
        val workspaces = AndroidWorkspaceRegistry(File(scratch, "registry").apply { mkdirs() })
        val projects = AndroidWorkspaceProjects(workspaces)
        val clone = AndroidWorkspaceClone(context, workspaces, projects)
        val staging = File(context.noBackupFilesDir, "clone-staging")
    }

    private fun fixture(): Fixture {
        assumeTrue("the agent core is not staged", tech.zseven.rish.runtime.RishAgentCoreNative.available)
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        return Fixture(File(context.noBackupFilesDir, "clone-test-${UUID.randomUUID()}").apply { mkdirs() }, context)
    }

    private fun base(): String {
        val base = InstrumentationRegistry.getArguments().getString("rish_g2_base")
        assumeTrue("no local test remote: pass rish_g2_base", base != null)
        return base!!
    }

    private fun request(url: String, name: String = "Cloned", operationId: String = UUID.randomUUID().toString()): JSONObject =
        JSONObject().put("schema_version", 1).put("operation_id", operationId).put("url", url).put("display_name", name)

    private fun refusal(block: () -> Unit): Int {
        try { block() } catch (refused: AndroidWorkspaceProjects.Refused) { return refused.number }
        throw AssertionError("expected a refusal")
    }

    @Test
    fun aPublicRepositoryBecomesAWorkspaceWithItsProjectAndFiles() {
        val base = base()
        val f = fixture()
        val result = f.clone.clone(request("$base/public.git", "Public"))
        val root = result.getJSONObject("root")
        val workspaceId = root.getString("workspace_id")
        val projectId = root.getString("project_id")
        assertEquals("main", result.getString("branch"))
        assertEquals(projectId, result.getJSONObject("project").getString("project_id"))
        assertEquals("Public", result.getJSONObject("workspace").getString("display_name"))
        // The workspace is listed, the project is attached and reads back clean at the cloned tip.
        assertTrue(f.workspaces.list().any { it.getString("workspace_id") == workspaceId })
        val lookup = f.projects.projectFor(JSONObject(root.toString()).put("project_id", JSONObject.NULL))
        assertEquals("attached", lookup.getString("status"))
        assertEquals(projectId, lookup.getJSONObject("project").getString("project_id"))
        val workDir = f.workspaces.rootFor(workspaceId)!!
        assertEquals("# rish push acceptance seed\n", File(workDir, "README.md").readText())
        assertTrue(File(workDir, "hello.txt").exists())
        assertFalse(File(workDir, ".git").exists())
        val gitDir = f.projects.gitDirectory(workspaceId, projectId)
        assertTrue(File(gitDir, "binding-v2.json").isFile)
        val status = JSONObject(String(RishLibgit2Native.status(gitDir.absolutePath, workDir.absolutePath), Charsets.UTF_8))
        assertTrue(status.getBoolean("clean")); assertEquals("main", status.getString("branch"))
        assertEquals(result.getString("oid"), status.getString("head_oid"))
        assertEquals(0, status.getInt("ahead")); assertEquals(0, status.getInt("behind"))
        assertEquals("$base/public.git", JSONObject(String(RishLibgit2Native.remoteUrl(gitDir.absolutePath, workDir.absolutePath), Charsets.UTF_8)).getString("url"))
        assertFalse(f.staging.listFiles()?.any { it.isDirectory } ?: false)
        f.scratch.deleteRecursively()
    }

    @Test
    fun whatDoesNotFinishLeavesNothingBehind() {
        val base = base()
        val f = fixture()
        val before = f.workspaces.list().size
        assertEquals(3101, refusal { f.clone.clone(request("ftp://example.com/x.git")) })
        assertEquals(3101, refusal { f.clone.clone(request("$base/public.git", "")) })
        // A private repository asks for a credential the clone does not carry.
        assertEquals(3197, refusal { f.clone.clone(request("$base/target.git", "Private")) })
        // A stalled remote, cancelled: refused as cancelled, and no workspace.
        val operationId = UUID.randomUUID().toString()
        var number = -1
        val worker = Thread { number = try { refusal { f.clone.clone(request("$base/slow-public.git", "Slow", operationId)) } } catch (_: Throwable) { -2 } }
        worker.start()
        Thread.sleep(1500)
        assertEquals("cancel_requested", f.clone.cancel(JSONObject().put("schema_version", 1).put("operation_id", operationId)).getString("status"))
        worker.join(60_000)
        assertEquals(3195, number)
        assertEquals(before, f.workspaces.list().size)
        assertFalse(f.staging.listFiles()?.any { it.isDirectory } ?: false)
        f.scratch.deleteRecursively()
    }
}
