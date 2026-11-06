package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidGitCredentials
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
        val credentials = AndroidGitCredentials(context, "rish.git-credentials.clone-test-${UUID.randomUUID()}")
        val clone = AndroidWorkspaceClone(context, workspaces, projects, credentials)
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
        JSONObject().put("schema_version", 1).put("operation_id", operationId).put("url", url).put("display_name", name).put("https_proxy_url", JSONObject.NULL)

    private fun refusal(block: () -> Unit): Int {
        try { block() } catch (refused: AndroidWorkspaceProjects.Refused) { return refused.number }
        throw AssertionError("expected a refusal")
    }

    /**
     * A clone through the person's proxy, counted by scripts/git-test-proxy.py
     * (pass rish_proxy_base=http://10.0.2.2:N). A plain http remote with a
     * proxy is refused: libgit2 would send it straight past the proxy.
     */
    @Test
    fun aCloneGoesThroughTheProxy() {
        val proxy = InstrumentationRegistry.getArguments().getString("rish_proxy_base")
        assumeTrue("no test proxy: pass rish_proxy_base", proxy != null)
        assumeTrue("github.com is not reachable", try {
            java.net.Socket().use { it.connect(java.net.InetSocketAddress("github.com", 443), 5_000) }; true
        } catch (_: Exception) { false })
        assertTrue(tech.zseven.rish.runtime.AndroidGitCertificates.ensure(context) != null)
        val f = fixture()
        fun tunnels(): Int {
            val uri = java.net.URI(proxy)
            java.net.Socket(uri.host, uri.port).use { socket ->
                socket.soTimeout = 10_000
                socket.getOutputStream().write("GET /__rish_stats HTTP/1.1\r\nHost: proxy\r\n\r\n".toByteArray())
                val text = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                return JSONObject(text.substringAfter("\r\n\r\n")).getJSONObject("connects").optInt("github.com:443", 0)
            }
        }
        val before = tunnels()
        val result = f.clone.clone(
            request("https://github.com/octocat/Hello-World.git", "Hello").put("https_proxy_url", proxy),
        )
        assertEquals("master", result.getString("branch"))
        assertTrue("the clone did not go through the proxy", tunnels() > before)
        assertEquals(3101, refusal {
            f.clone.clone(request("http://10.0.2.2:1/demo.git", "Plain").put("https_proxy_url", proxy))
        })
        assertEquals(3101, refusal {
            f.clone.clone(request("https://github.com/octocat/Hello-World.git", "Bad").put("https_proxy_url", "proxy:3128"))
        })
        f.scratch.deleteRecursively()
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

    /**
     * A private repository: anonymous is refused, the credential the person
     * typed for this operation is offered once to the URL's host, and the
     * clone that succeeds keeps it for the new project so fetch and push do
     * not ask again. A wrong credential is refused the same way as none, and
     * an offer is spent by the clone that names it.
     */
    @Test
    fun aPrivateRepositoryClonesWithTheCredentialOfferedForItAndKeepsIt() {
        val base = base()
        val args = InstrumentationRegistry.getArguments()
        val user = args.getString("rish_g2_user")
        val token = args.getString("rish_g2_token")
        assumeTrue("no local test remote credential: pass rish_g2_user and rish_g2_token", user != null && token != null)
        val f = fixture()
        val host = java.net.URI(base).host
        val operationId = UUID.randomUUID().toString()
        // No credential typed: naming one refuses before the network.
        assertEquals(3197, refusal {
            f.clone.clone(request("$base/target.git", "Private", operationId).put("credential_reference", "prompt"))
        })
        // The wrong one is turned away by the remote.
        f.clone.offerCredential(operationId, host, user!!, "not-the-token", 3600)
        assertEquals(3197, refusal {
            f.clone.clone(request("$base/target.git", "Private", operationId).put("credential_reference", "prompt"))
        })
        assertEquals(0, f.workspaces.list().size)
        // An offer for another host is not offered to this one.
        f.clone.offerCredential(operationId, "example.com", user, token!!, 3600)
        assertEquals(3197, refusal {
            f.clone.clone(request("$base/target.git", "Private", operationId).put("credential_reference", "prompt"))
        })
        // The right one clones, and is the project's afterwards.
        f.clone.offerCredential(operationId, host, user, token, 86400)
        val result = f.clone.clone(request("$base/target.git", "Private", operationId).put("credential_reference", "prompt"))
        val root = result.getJSONObject("root")
        val projectId = root.getString("project_id")
        assertEquals("main", result.getString("branch"))
        val stored = f.credentials.read(projectId, host)
        assertNotNull(stored)
        assertEquals(user, stored!!.username); assertEquals(token, stored.token); assertEquals(86400L, stored.expirySeconds)
        // Spent: the same reference again finds nothing offered, before any network.
        assertEquals(3197, refusal {
            f.clone.clone(request("$base/target.git", "Again", operationId).put("credential_reference", "prompt"))
        })
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
