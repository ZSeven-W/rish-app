package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidGitCredentials
import tech.zseven.rish.runtime.AndroidProjectGit
import tech.zseven.rish.runtime.AndroidWorkspaceProjects
import tech.zseven.rish.runtime.AndroidWorkspaceRegistry
import tech.zseven.rish.runtime.RishLibgit2Native
import java.io.File
import java.util.UUID

/**
 * The remote half on this device, without a network: origin set through
 * the V2 request, a credential stored for its host and read back as status
 * only, and the native push driving libgit2's local transport against a
 * bare repository -- the same sequence, callbacks and outcome vocabulary a
 * push over HTTPS goes through, minus the wire.
 *
 * What this does not prove: TLS trust, authentication, non-fast-forward
 * from a competing commit, cancellation mid-transfer. Those need the
 * local HTTP remote (scripts/git-test-remote.rb) through `adb reverse`.
 */
@RunWith(AndroidJUnit4::class)
class AndroidProjectRemoteTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private class Fixture(val scratch: File, context: android.content.Context) {
        val workspaces = AndroidWorkspaceRegistry(File(scratch, "registry").apply { mkdirs() })
        val projects = AndroidWorkspaceProjects(workspaces)
        val credentials = AndroidGitCredentials(context, "rish.git-credentials.test-${UUID.randomUUID()}")
        val git = AndroidProjectGit(projects, workspaces, credentials)
        val workspaceId: String = workspaces.create("Scratch").getString("workspace_id")
        val workDir: File = workspaces.rootFor(workspaceId)!!
        val projectId: String = projects.attach(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString()).put("mode", "init")
                .put("root", root(null)),
        ).getJSONObject("project").getString("project_id")
        val gitDir: File = projects.gitDirectory(workspaceId, projectId)

        fun root(projectId: String?): JSONObject = JSONObject()
            .put("schema_version", 1).put("workspace_id", workspaceId)
            .put("binding_revision", 1).put("project_id", projectId ?: JSONObject.NULL)

        fun request(): JSONObject = JSONObject().put("schema_version", 1).put("root", root(projectId))

        fun commit(path: String, text: String, message: String): String {
            File(workDir, path).apply { parentFile?.mkdirs() }.writeText(text)
            assertEquals("ok", RishLibgit2Native.stagePath(gitDir.absolutePath, workDir.absolutePath, path))
            // The commit asserts the head it was reviewed against: none before the first, the current one after.
            val status = JSONObject(String(RishLibgit2Native.status(gitDir.absolutePath, workDir.absolutePath), Charsets.UTF_8))
            val head = status.opt("head_oid").takeIf { it != JSONObject.NULL } as? String
            val reply = JSONObject(String(RishLibgit2Native.commit(gitDir.absolutePath, workDir.absolutePath, message, "Rish", "rish@example.invalid", head), Charsets.UTF_8))
            assertTrue(reply.toString(), reply.getBoolean("ok"))
            return reply.getString("oid")
        }
    }

    private fun fixture(): Fixture {
        assumeTrue("libgit2 is not staged in this build", RishLibgit2Native.available)
        return Fixture(File(context.noBackupFilesDir, "remote-test-${UUID.randomUUID()}").apply { mkdirs() }, context)
    }

    private fun refusal(block: () -> Unit): Int {
        try { block() } catch (refused: AndroidWorkspaceProjects.Refused) { return refused.number }
        throw AssertionError("expected a refusal")
    }

    @Test
    fun originIsJudgedSetAndReadBack() {
        val f = fixture()
        assertTrue(f.git.remote(f.request()).isNull("url"))
        for (bad in listOf("ftp://example.com/x.git", "https://user:pw@example.com/x.git", "https://example.com/x.git?y=1",
            "http://example.com/x.git", "https://localhost/x.git", "https://example.com:8443/x.git", "https://.local/x")) {
            assertEquals(bad, 3101, refusal { f.git.setRemote(f.request().put("url", bad)) })
        }
        val set = f.git.setRemote(f.request().put("url", "HTTPS://GitHub.com/example/demo.git"))
        assertEquals("https://github.com/example/demo.git", set.getString("url"))
        assertEquals("github.com", set.getString("host"))
        assertEquals("https://github.com/example/demo.git", f.git.remote(f.request()).getString("url"))
        // A private literal over plain http is the test remote on this device.
        assertEquals("http://127.0.0.1:8765/target.git", f.git.setRemote(f.request().put("url", "http://127.0.0.1:8765/target.git")).getString("url"))
        f.scratch.deleteRecursively()
    }

    @Test
    fun aCredentialIsScopedToTheOriginHostAndNeverEchoed() {
        val f = fixture()
        assertEquals(3112, refusal { f.git.credentialStatus(f.request()) })
        f.git.setRemote(f.request().put("url", "https://github.com/example/demo.git"))
        val absent = f.git.credentialStatus(f.request())
        assertFalse(absent.getBoolean("configured")); assertEquals("github.com", absent.getString("host"))
        // The store call names the host it was prompted for; a remote moved elsewhere refuses it.
        assertEquals(3113, refusal { f.git.storeCredential(f.request().put("host", "gitlab.com").put("username", "u").put("token", "t").put("expiry_seconds", 3600)) })
        assertEquals(3101, refusal { f.git.storeCredential(f.request().put("host", "github.com").put("username", "u").put("token", "t").put("expiry_seconds", 60)) })
        val stored = f.git.storeCredential(f.request().put("host", "github.com").put("username", "octocat").put("token", "ghp_secret").put("expiry_seconds", 3600))
        assertTrue(stored.getBoolean("configured"))
        assertEquals(3600L, stored.getLong("expiry_seconds"))
        assertTrue(stored.getLong("expires_at") > System.currentTimeMillis() / 1000)
        assertFalse(stored.toString().contains("ghp_secret"))
        assertFalse(stored.has("username")); assertFalse(stored.has("token"))
        // Read for the push, and for no other host.
        assertEquals("octocat", f.credentials.read(f.projectId, "github.com")!!.username)
        assertNull(f.credentials.read(f.projectId, "gitlab.com"))
        // Expired reads as absent and is gone.
        f.credentials.store(f.projectId, "github.com", "octocat", "ghp_secret", 3600, now = 1L)
        assertNull(f.credentials.read(f.projectId, "github.com"))
        assertFalse(f.git.credentialStatus(f.request()).getBoolean("configured"))
        f.git.storeCredential(f.request().put("host", "github.com").put("username", "octocat").put("token", "ghp_secret").put("expiry_seconds", 3600))
        assertFalse(f.git.clearCredential(f.request()).getBoolean("configured"))
        f.scratch.deleteRecursively()
    }

    @Test
    fun theNativePushLandsOnABareRepositoryAndReportsWhatItVerified() {
        val f = fixture()
        val oid = f.commit("README.md", "# demo\n", "first")
        // A bare repository as the remote, reached through libgit2's local transport.
        val bare = File(f.scratch, "remote.git")
        assertEquals("ok", RishLibgit2Native.initSplitRepository(bare.absolutePath, File(f.scratch, "unused").apply { mkdirs() }.absolutePath))
        val url = "file://" + bare.absolutePath
        assertEquals("ok", RishLibgit2Native.setRemote(f.gitDir.absolutePath, f.workDir.absolutePath, url))
        val operation = UUID.randomUUID().toString()
        // An empty URL pushes to origin as configured; a file remote has no host to bind a credential to.
        val pushed = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, operation, "", "", "refs/heads/main", oid, "", "", 30), Charsets.UTF_8))
        assertTrue(pushed.toString(), pushed.getBoolean("ok"))
        assertEquals(pushed.toString(), "success", pushed.getString("outcome"))
        assertTrue(pushed.isNull("advertised_oid"))
        assertEquals(oid, pushed.getString("remote_oid"))
        assertTrue(pushed.getBoolean("verified"))
        assertEquals(oid, File(bare, "refs/heads/main").readText().trim())
        // Nothing by that id is running any more.
        assertFalse(RishLibgit2Native.cancelPush(operation))
        // A second commit pushes on top: the remote now advertises the first.
        val second = f.commit("README.md", "# demo\n\nmore\n", "second")
        val again = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, UUID.randomUUID().toString(), "", "", "refs/heads/main", second, "", "", 30), Charsets.UTF_8))
        assertEquals(again.toString(), "success", again.getString("outcome"))
        assertEquals(oid, again.getString("advertised_oid"))
        assertEquals(second, again.getString("remote_oid"))
        // Malformed arguments never reach the transport.
        val bad = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, "op", "", "", "main", second, "", "", 30), Charsets.UTF_8))
        assertFalse(bad.getBoolean("ok")); assertEquals(3101, bad.getInt("code"))
        f.scratch.deleteRecursively()
    }

    @Test
    fun theV2PushRefusesWhatItCannotProveBeforeItConnects() {
        val f = fixture()
        val oid = f.commit("README.md", "# demo\n", "first")
        fun push(expected: String = oid) = f.request().put("operation_id", UUID.randomUUID().toString()).put("remote", "origin")
            .put("expected_local_oid", expected).put("credential_reference", "ref").put("https_proxy_url", JSONObject.NULL)
        assertEquals(3112, refusal { f.git.push(push()) })
        f.git.setRemote(f.request().put("url", "https://github.com/example/demo.git"))
        assertEquals(3111, refusal { f.git.push(push()) })
        assertEquals(3110, refusal { f.git.push(push(expected = "0".repeat(40))) })
        assertEquals(3101, refusal { f.git.push(push().put("https_proxy_url", "https://proxy.example.com:8080")) })
        f.scratch.deleteRecursively()
    }

    /**
     * Whether the roots OpenSSL was pointed at let a TLS handshake with a
     * public host succeed. GitHub refuses an anonymous push with an
     * authentication failure *after* the handshake; a trust failure never
     * gets that far and comes back as `failed` with a certificate error.
     * Skipped without a network.
     */
    @Test
    fun theExportedRootsLetTlsReachGitHub() {
        val f = fixture()
        assumeTrue("no network on this device", try { java.net.InetAddress.getByName("github.com"); true } catch (_: Exception) { false })
        assertTrue("the system roots could not be exported", tech.zseven.rish.runtime.AndroidGitCertificates.ensure(context) != null)
        val oid = f.commit("README.md", "# demo\n", "first")
        val url = "https://github.com/octocat/Hello-World.git"
        assertEquals("ok", RishLibgit2Native.setRemote(f.gitDir.absolutePath, f.workDir.absolutePath, url))
        val reply = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, UUID.randomUUID().toString(), url, "github.com", "refs/heads/main", oid, "", "", 30), Charsets.UTF_8))
        assertTrue(reply.toString(), reply.getBoolean("ok"))
        assertEquals(reply.toString(), "auth_failure", reply.getString("outcome"))
        assertFalse(reply.getBoolean("effect_may_have_occurred"))
        f.scratch.deleteRecursively()
    }

    // --- over HTTP, against scripts/git-test-remote.rb served on the Mac ----
    //
    // The emulator reaches the Mac at 10.0.2.2. Run with
    //   ruby scripts/git-test-remote.rb serve --root DIR --port N --user U --token T
    // and pass rish_g2_base=http://10.0.2.2:N, rish_g2_user, rish_g2_token as
    // instrumentation arguments. Without them these tests are skipped.

    private class TestRemote(val base: String, val user: String, val token: String) {
        val host: String = java.net.URI(base).host
        /** One request to the server's control endpoints: a raw socket, so the app's cleartext policy is not in the way. */
        fun control(method: String, path: String, body: String?): JSONObject {
            val uri = java.net.URI(base)
            java.net.Socket(uri.host, uri.port).use { socket ->
                socket.soTimeout = 30_000
                val auth = android.util.Base64.encodeToString("$user:$token".toByteArray(), android.util.Base64.NO_WRAP)
                val payload = body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
                val head = "$method $path HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nAuthorization: Basic $auth\r\n" +
                    "Content-Type: application/json\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n"
                socket.getOutputStream().apply { write(head.toByteArray(Charsets.US_ASCII)); write(payload); flush() }
                val response = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                val status = response.substringBefore("\r\n").split(" ").getOrNull(1)?.toIntOrNull()
                assertEquals(response.take(300), 200, status)
                return JSONObject(response.substringAfter("\r\n\r\n"))
            }
        }
        fun tip(repo: String, branch: String): String? =
            control("GET", "/g2/refs?repo=$repo", null).getJSONObject("refs").optString("refs/heads/$branch").takeIf { it.isNotEmpty() }
    }

    private fun testRemote(): TestRemote {
        val args = InstrumentationRegistry.getArguments()
        val base = args.getString("rish_g2_base"); val user = args.getString("rish_g2_user"); val token = args.getString("rish_g2_token")
        assumeTrue("no local test remote: pass rish_g2_base, rish_g2_user and rish_g2_token", base != null && user != null && token != null)
        return TestRemote(base!!, user!!, token!!)
    }

    /** The first commit lands on a branch of its own, so the seeded `main` on the remote is not in the way. */
    private fun Fixture.checkoutFresh(): String {
        val branch = "rish-android-" + UUID.randomUUID().toString().substring(0, 8)
        File(gitDir, "HEAD").writeText("ref: refs/heads/$branch\n")
        return branch
    }

    private fun Fixture.pushRequest(oid: String, operationId: String = UUID.randomUUID().toString()): JSONObject =
        request().put("operation_id", operationId).put("remote", "origin").put("expected_local_oid", oid)
            .put("credential_reference", "test").put("https_proxy_url", JSONObject.NULL)

    private fun Fixture.credential(remote: TestRemote, token: String): JSONObject =
        request().put("host", remote.host).put("username", remote.user).put("token", token).put("expiry_seconds", 3600L)

    @Test
    fun theHttpPushAuthenticatesLandsAndIsRefusedOnceTheRemoteMovesOn() {
        val remote = testRemote()
        val f = fixture()
        val branch = f.checkoutFresh()
        val first = f.commit("android.txt", "pushed from the emulator\n", "first from android")
        assertEquals("${remote.base}/target.git", f.git.setRemote(f.request().put("url", "${remote.base}/target.git")).getString("url"))
        // Nothing is stored for this host: refused before any connection.
        assertEquals(3111, refusal { f.git.push(f.pushRequest(first)) })
        // The wrong token reaches the server and is turned away there.
        f.git.storeCredential(f.credential(remote, "not-the-token"))
        assertEquals(3197, refusal { f.git.push(f.pushRequest(first)) })
        assertNull(remote.tip("target.git", branch))
        // The right one lands the branch, and the server reads back the same object.
        f.git.storeCredential(f.credential(remote, remote.token))
        val pushed = f.git.push(f.pushRequest(first))
        assertEquals(branch, pushed.getString("branch"))
        assertEquals(first, pushed.getString("oid"))
        assertEquals(first, remote.tip("target.git", branch))
        // The Mac commits on top; the phone's next push is not a fast-forward, and the remote keeps the Mac's tip.
        val competing = remote.control("POST", "/g2/compete", JSONObject().put("repo", "target.git").put("branch", branch).toString())
        assertEquals(first, competing.getString("old_oid"))
        val second = f.commit("android.txt", "second from the emulator\n", "second from android")
        assertEquals(3196, refusal { f.git.push(f.pushRequest(second)) })
        assertEquals(competing.getString("oid"), remote.tip("target.git", branch))
        // A stale expectation never connects.
        assertEquals(3110, refusal { f.git.push(f.pushRequest(first)) })
        f.scratch.deleteRecursively()
    }

    @Test
    fun theHttpPushIsCancelledWhileTheRemoteStalls() {
        val remote = testRemote()
        val f = fixture()
        f.checkoutFresh()
        val oid = f.commit("android.txt", "stalled\n", "stalled from android")
        f.git.setRemote(f.request().put("url", "${remote.base}/stall.git"))
        f.git.storeCredential(f.credential(remote, remote.token))
        val operationId = UUID.randomUUID().toString()
        var number = -1
        val started = System.currentTimeMillis()
        val worker = Thread { number = try { refusal { f.git.push(f.pushRequest(oid, operationId)) } } catch (_: Throwable) { -2 } }
        worker.start()
        Thread.sleep(1500)
        assertEquals("cancel_requested", f.git.cancelPush(f.request().put("operation_id", operationId)).getString("status"))
        worker.join(40_000)
        val elapsed = System.currentTimeMillis() - started
        assertEquals("push outcome after cancel (elapsed $elapsed ms)", 3195, number)
        assertTrue("cancel took $elapsed ms", elapsed < 30_000)
        assertEquals("not_running", f.git.cancelPush(f.request().put("operation_id", operationId)).getString("status"))
        f.scratch.deleteRecursively()
    }
}
