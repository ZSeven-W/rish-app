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
        val pushed = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, operation, "", "", "refs/heads/main", oid, "", "", 30, false, null), Charsets.UTF_8))
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
        val again = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, UUID.randomUUID().toString(), "", "", "refs/heads/main", second, "", "", 30, false, null), Charsets.UTF_8))
        assertEquals(again.toString(), "success", again.getString("outcome"))
        assertEquals(oid, again.getString("advertised_oid"))
        assertEquals(second, again.getString("remote_oid"))
        // Malformed arguments never reach the transport.
        val bad = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, "op", "", "", "main", second, "", "", 30, false, null), Charsets.UTF_8))
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
        // Resolvable and reachable on 443, or the probe says nothing about trust:
        // a transport failure with no route looks the same as a rejected chain.
        assumeTrue("github.com is not reachable from this device", try {
            java.net.Socket().use { it.connect(java.net.InetSocketAddress("github.com", 443), 5_000) }; true
        } catch (_: Exception) { false })
        assertTrue("the system roots could not be exported", tech.zseven.rish.runtime.AndroidGitCertificates.ensure(context) != null)
        val oid = f.commit("README.md", "# demo\n", "first")
        val url = "https://github.com/octocat/Hello-World.git"
        assertEquals("ok", RishLibgit2Native.setRemote(f.gitDir.absolutePath, f.workDir.absolutePath, url))
        val reply = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, UUID.randomUUID().toString(), url, "github.com", "refs/heads/main", oid, "", "", 30, false, null), Charsets.UTF_8))
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
        // The receipt says what the push proved, and only that.
        val receipts = f.git.pushReceipts(f.request()).getJSONArray("receipts")
        assertEquals(1, receipts.length())
        val receipt = receipts.getJSONObject(0)
        assertEquals(setOf("schema_version", "remote", "host", "branch", "local_oid", "remote_oid", "pushed_at"), receipt.keys().asSequence().toSet())
        assertEquals(remote.host, receipt.getString("host")); assertEquals(branch, receipt.getString("branch"))
        assertEquals(first, receipt.getString("local_oid")); assertEquals(first, receipt.getString("remote_oid"))
        assertFalse(receipts.toString().contains(remote.token))
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

    // --- fetch and fast-forward -------------------------------------------

    /** A second working repository beside the fixture, sharing nothing but the origin. */
    private class Peer(scratch: File, name: String, copyOf: Peer? = null, fromGitDir: File? = null, fromWorkDir: File? = null) {
        val gitDir: File = File(scratch, "$name.git")
        val workDir: File = File(scratch, "$name-work").apply { mkdirs() }
        init {
            when {
                // The gitdir pairs with whatever working tree it is opened with, so a copy of both is a second peer.
                fromGitDir != null && fromWorkDir != null -> {
                    fromGitDir.copyRecursively(gitDir); fromWorkDir.copyRecursively(workDir, overwrite = true)
                }
                copyOf != null -> { copyOf.gitDir.copyRecursively(gitDir); copyOf.workDir.copyRecursively(workDir) }
                else -> assertEquals("ok", RishLibgit2Native.initSplitRepository(gitDir.absolutePath, workDir.absolutePath))
            }
        }
        companion object {
            fun copyOf(peer: Peer, scratch: File, name: String) = Peer(scratch, name, peer)
            fun fromDirs(scratch: File, name: String, gitDir: File, workDir: File) =
                Peer(scratch, name, null, gitDir, workDir)
        }
        fun commit(path: String, text: String, message: String): String {
            File(workDir, path).apply { parentFile?.mkdirs() }.writeText(text)
            assertEquals("ok", RishLibgit2Native.stagePath(gitDir.absolutePath, workDir.absolutePath, path))
            val head = JSONObject(String(RishLibgit2Native.status(gitDir.absolutePath, workDir.absolutePath), Charsets.UTF_8))
                .opt("head_oid").takeIf { it != JSONObject.NULL } as? String
            val reply = JSONObject(String(RishLibgit2Native.commit(gitDir.absolutePath, workDir.absolutePath, message, "Peer", "peer@example.invalid", head), Charsets.UTF_8))
            assertTrue(reply.toString(), reply.getBoolean("ok"))
            return reply.getString("oid")
        }
        fun head(): String? = JSONObject(String(RishLibgit2Native.status(gitDir.absolutePath, workDir.absolutePath), Charsets.UTF_8))
            .opt("head_oid").takeIf { it != JSONObject.NULL } as? String
        fun push(oid: String): JSONObject = JSONObject(String(RishLibgit2Native.push(gitDir.absolutePath, workDir.absolutePath, UUID.randomUUID().toString(), "", "", "refs/heads/main", oid, "", "", 30, false, null), Charsets.UTF_8))
        fun fetch(): JSONObject = JSONObject(String(RishLibgit2Native.fetch(gitDir.absolutePath, workDir.absolutePath, UUID.randomUUID().toString(), "", "", "main", "", "", 30), Charsets.UTF_8))
        fun fastForward(expected: String): JSONObject = JSONObject(String(RishLibgit2Native.fastForward(gitDir.absolutePath, workDir.absolutePath, expected), Charsets.UTF_8))
    }

    @Test
    fun theFetchAndFastForwardMoveTheBranchOnlyWhenThatIsSafe() {
        val f = fixture()
        val bare = File(f.scratch, "shared.git")
        assertEquals("ok", RishLibgit2Native.initSplitRepository(bare.absolutePath, File(f.scratch, "unused").apply { mkdirs() }.absolutePath))
        val a = Peer(f.scratch, "a"); val b = Peer(f.scratch, "b")
        for (peer in listOf(a, b)) assertEquals("ok", RishLibgit2Native.setRemote(peer.gitDir.absolutePath, peer.workDir.absolutePath, "file://" + bare.absolutePath))
        // Before any fetch there is nothing to fast-forward to.
        val first = a.commit("shared.txt", "one\n", "first")
        assertEquals("no_upstream", a.fastForward(first).getString("outcome"))
        assertEquals("success", a.push(first).getString("outcome"))
        // B starts empty: its fetch sees the branch but has no HEAD to move yet.
        val emptyFetch = b.fetch()
        assertEquals(emptyFetch.toString(), "success", emptyFetch.getString("outcome"))
        assertEquals(first, emptyFetch.getString("remote_oid"))
        // B commits its own first commit on top of nothing? No: B takes A's history by committing after a fetch is not possible
        // without a checkout, so B's first commit is made *from* the fetched tip: it starts as a fast-forward of an unborn branch.
        // That path is not served (unborn HEAD is 3110); B instead gets its history the way a peer does -- a first commit,
        // then a fetch that shows divergence.
        val bFirst = b.commit("other.txt", "b\n", "b first")
        val diverged = b.fetch()
        assertEquals(1, diverged.getInt("ahead")); assertEquals(1, diverged.getInt("behind"))
        assertEquals("diverged", b.fastForward(bFirst).getString("outcome"))
        // A moves the shared branch on; a second commit in A, pushed.
        val second = a.commit("shared.txt", "two\n", "second")
        assertEquals("success", a.push(second).getString("outcome"))
        // A third peer that took the branch by fetching before its first commit can fast-forward.
        val c = Peer(f.scratch, "c")
        assertEquals("ok", RishLibgit2Native.setRemote(c.gitDir.absolutePath, c.workDir.absolutePath, "file://" + bare.absolutePath))
        // C's HEAD is unborn: the fetch lands refs/remotes/origin/main, but a fast-forward needs a born branch (3110).
        assertEquals("success", c.fetch().getString("outcome"))
        assertEquals(3110, c.fastForward(first).optInt("code"))
        // A itself: up to date after its own push once fetched.
        val aFetch = a.fetch()
        assertEquals(second, aFetch.getString("remote_oid")); assertEquals(0, aFetch.getInt("ahead")); assertEquals(0, aFetch.getInt("behind"))
        assertEquals("up_to_date", a.fastForward(second).getString("outcome"))
        // D: a copy of A taken while both stood at `second` (the gitdir and the
        // working tree together, so its index agrees with its HEAD). Then A
        // moves the origin on, and D is one behind.
        val d = Peer.copyOf(a, f.scratch, "d")
        val third = a.commit("shared.txt", "three\n", "third")
        assertEquals("success", a.push(third).getString("outcome"))
        assertEquals(second, d.head())
        val behind = d.fetch()
        assertEquals(behind.toString(), 0, behind.getInt("ahead")); assertEquals(1, behind.getInt("behind"))
        // Changes to a tracked file are the person's: no fast-forward over them.
        File(d.workDir, "shared.txt").writeText("mine\n")
        assertEquals("dirty", d.fastForward(second).getString("outcome"))
        File(d.workDir, "shared.txt").writeText("two\n")
        // An untracked file that the update would not touch is fine.
        File(d.workDir, "notes.txt").writeText("untracked\n")
        assertEquals(3110, d.fastForward(first).optInt("code"))
        val moved = d.fastForward(second)
        assertEquals(moved.toString(), "updated", moved.getString("outcome"))
        assertEquals(third, moved.getString("oid")); assertEquals(second, moved.getString("previous_oid"))
        assertEquals(third, d.head())
        assertEquals("three\n", File(d.workDir, "shared.txt").readText())
        assertTrue(File(d.workDir, "notes.txt").exists())
        assertEquals("up_to_date", d.fastForward(third).getString("outcome"))
        f.scratch.deleteRecursively()
    }

    /**
     * A fast-forward never overwrites a file the person keeps out of Git.
     *
     * `GIT_CHECKOUT_SAFE` protects tracked changes and untracked files, but
     * not ignored ones: if the incoming commit starts tracking a path that is
     * ignored here -- a local config, a secrets file, a build artefact the
     * person keeps -- the checkout writes straight over it. Nothing in the
     * cleanliness check sees it either, because ignored files are not listed
     * by status. So the local file was lost with no refusal at all.
     */
    @Test
    fun aFastForwardNeverOverwritesAnIgnoredLocalFile() {
        val f = fixture()
        val bare = File(f.scratch, "ignored.git")
        assertEquals("ok", RishLibgit2Native.initSplitRepository(bare.absolutePath, File(f.scratch, "unused-ignored").apply { mkdirs() }.absolutePath))
        val a = Peer(f.scratch, "ia")
        assertEquals("ok", RishLibgit2Native.setRemote(a.gitDir.absolutePath, a.workDir.absolutePath, "file://" + bare.absolutePath))
        val ignoring = a.commit(".gitignore", "local.cfg\n", "ignore local.cfg")
        assertEquals("success", a.push(ignoring).getString("outcome"))
        // E is a copy of A at that commit, and keeps its own ignored file.
        val e = Peer.copyOf(a, f.scratch, "ie")
        File(e.workDir, "local.cfg").writeText("mine\n")
        // A starts tracking the very path E ignores.
        val tracking = a.commit("local.cfg", "theirs\n", "track local.cfg")
        assertEquals("success", a.push(tracking).getString("outcome"))
        val fetched = e.fetch()
        assertEquals(fetched.toString(), 1, fetched.getInt("behind"))
        val answer = e.fastForward(ignoring)
        // Refused, and the person's file is exactly as they left it.
        assertEquals(answer.toString(), "dirty", answer.optString("outcome"))
        assertEquals("mine\n", File(e.workDir, "local.cfg").readText())
        assertEquals(ignoring, e.head())
        f.scratch.deleteRecursively()
    }

    // --- merge after divergence ---------------------------------------------

    /**
     * The fixture's project and a peer with one shared commit, each then
     * moving on: the project locally with `mine`, the peer with `theirs`,
     * pushed. The project has fetched, so it is one ahead and one behind.
     */
    private class Diverged(val f: Fixture, val peer: Peer, val ours: String, val theirs: String) {
        fun request(ours: String = this.ours, theirs: String = this.theirs): JSONObject = f.request()
            .put("operation_id", UUID.randomUUID().toString()).put("expected_branch", "main")
            .put("expected_head_oid", ours).put("expected_remote_oid", theirs)
            .put("author_name", "Rish").put("author_email", "rish@example.invalid")
        fun head(): String? = JSONObject(String(RishLibgit2Native.status(f.gitDir.absolutePath, f.workDir.absolutePath), Charsets.UTF_8))
            .opt("head_oid").takeIf { it != JSONObject.NULL } as? String
        fun fetch(): JSONObject = JSONObject(String(RishLibgit2Native.fetch(f.gitDir.absolutePath, f.workDir.absolutePath, UUID.randomUUID().toString(), "", "", "main", "", "", 30), Charsets.UTF_8))
        fun journal(): File = File(f.gitDir, "rish-merge.json")
    }

    private fun diverged(
        shared: Pair<String, String> = "shared.txt" to "base\n",
        mine: Pair<String, String> = "mine.txt" to "mine\n",
        theirs: Pair<String, String> = "theirs.txt" to "theirs\n",
        beforeDiverging: (Fixture, Peer) -> Unit = { _, _ -> },
    ): Diverged {
        val f = fixture()
        val bare = File(f.scratch, "merge-origin.git")
        assertEquals("ok", RishLibgit2Native.initSplitRepository(bare.absolutePath, File(f.scratch, "merge-unused").apply { mkdirs() }.absolutePath))
        assertEquals("ok", RishLibgit2Native.setRemote(f.gitDir.absolutePath, f.workDir.absolutePath, "file://" + bare.absolutePath))
        val base = f.commit(shared.first, shared.second, "base")
        val pushed = JSONObject(String(RishLibgit2Native.push(f.gitDir.absolutePath, f.workDir.absolutePath, UUID.randomUUID().toString(), "", "", "refs/heads/main", base, "", "", 30, false, null), Charsets.UTF_8))
        assertEquals(pushed.toString(), "success", pushed.getString("outcome"))
        val peer = Peer.fromDirs(f.scratch, "merge-peer", f.gitDir, f.workDir)
        beforeDiverging(f, peer)
        val theirsOid = peer.commit(theirs.first, theirs.second, "theirs")
        assertEquals("success", peer.push(theirsOid).getString("outcome"))
        val oursOid = f.commit(mine.first, mine.second, "mine")
        val d = Diverged(f, peer, oursOid, theirsOid)
        val fetched = d.fetch()
        assertEquals(fetched.toString(), 1, fetched.getInt("ahead")); assertEquals(1, fetched.getInt("behind"))
        return d
    }

    /**
     * The one the whole feature is for: two people changed different files,
     * and the person gets both, with history that says so.
     */
    @Test
    fun aCleanDivergenceIsMergedAndTheBranchCarriesBothSides() {
        val d = diverged()
        val merged = d.f.git.mergeRemote(d.request())
        assertEquals(merged.toString(), "merged", merged.getString("outcome"))
        assertEquals(d.ours, merged.getString("previous_oid"))
        val mergeOid = merged.getString("oid")
        assertTrue(mergeOid != d.ours && mergeOid != d.theirs)
        assertEquals(mergeOid, d.head())
        assertEquals("mine\n", File(d.f.workDir, "mine.txt").readText())
        assertEquals("theirs\n", File(d.f.workDir, "theirs.txt").readText())
        // Both parents are real: the upstream is now an ancestor of HEAD and
        // nothing is left behind -- two ahead (mine and the merge), none behind.
        val after = d.fetch()
        assertEquals(after.toString(), 0, after.getInt("behind")); assertEquals(2, after.getInt("ahead"))
        assertTrue("the journal outlived a finished merge", !d.journal().exists())
        d.f.scratch.deleteRecursively()
    }

    /**
     * A conflict is answered with its paths, and nothing about the
     * repository moves: no markers, no MERGE_HEAD, no index change, no ref.
     */
    @Test
    fun aConflictingDivergenceIsRefusedAndWritesNothing() {
        val d = diverged(mine = "shared.txt" to "mine\n", theirs = "shared.txt" to "theirs\n")
        val answer = d.f.git.mergeRemote(d.request())
        assertEquals(answer.toString(), "conflicts", answer.getString("outcome"))
        val conflict = answer.getJSONArray("conflicts").getJSONObject(0)
        assertEquals("shared.txt", conflict.getString("ours"))
        assertEquals("shared.txt", conflict.getString("theirs"))
        assertEquals(d.ours, d.head())
        assertEquals("mine\n", File(d.f.workDir, "shared.txt").readText())
        assertTrue("MERGE_HEAD was written", !File(d.f.gitDir, "MERGE_HEAD").exists())
        val status = JSONObject(String(RishLibgit2Native.status(d.f.gitDir.absolutePath, d.f.workDir.absolutePath), Charsets.UTF_8))
        assertEquals(status.toString(), 0, status.optJSONArray("entries")?.length() ?: 0)
        assertTrue(!d.journal().exists())
        d.f.scratch.deleteRecursively()
    }

    /** An ignored file the merge would write over is reported, not overwritten. */
    @Test
    fun anIgnoredFileInTheWayIsReportedAndKept() {
        val d = diverged(
            shared = ".gitignore" to "local.cfg\n",
            theirs = "local.cfg" to "theirs\n",
            beforeDiverging = { f, _ -> File(f.workDir, "local.cfg").writeText("mine\n") },
        )
        val answer = d.f.git.mergeRemote(d.request())
        assertEquals(answer.toString(), "obstructed", answer.getString("outcome"))
        assertTrue(answer.toString(), answer.getJSONArray("paths").toString().contains("local.cfg"))
        assertEquals("mine\n", File(d.f.workDir, "local.cfg").readText())
        assertEquals(d.ours, d.head())
        assertTrue(!d.journal().exists())
        d.f.scratch.deleteRecursively()
    }

    /**
     * The merge is bound to what the person reviewed: a HEAD that moved or
     * an upstream that is not the one they fetched is refused.
     */
    @Test
    fun aMovedHeadOrAStaleFetchIsRefused() {
        val d = diverged()
        val elsewhere = "0".repeat(40)
        assertEquals(3110, refusal { d.f.git.mergeRemote(d.request(ours = elsewhere)) })
        assertEquals(3112, refusal { d.f.git.mergeRemote(d.request(theirs = elsewhere)) })
        assertEquals(d.ours, d.head())
        d.f.scratch.deleteRecursively()
    }

    /**
     * A crash after the checkout but before the branch moved leaves the
     * files at the merge and the branch at ours. Recovery reads that from
     * the repository and finishes the move -- it never resets.
     */
    @Test
    fun aMergeInterruptedBeforeTheBranchMovedIsFinishedByRecovery() {
        val d = diverged()
        val merged = d.f.git.mergeRemote(d.request())
        val mergeOid = merged.getString("oid")
        // Put the repository back into the state a crash would leave: the
        // branch moved back to ours with a compare-and-swap, the index and
        // files still the merge, and the journal on disk.
        val back = JSONObject(String(RishLibgit2Native.mergeMoveRef(d.f.gitDir.absolutePath, d.f.workDir.absolutePath, "main", mergeOid, d.ours), Charsets.UTF_8))
        assertEquals(back.toString(), "merged", back.getString("outcome"))
        assertEquals(d.ours, d.head())
        d.journal().writeText(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("branch", "main").put("ours", d.ours).put("theirs", d.theirs).put("merge_oid", mergeOid)
                .put("tree_oid", "0".repeat(40)).put("phase", "applying").put("created_at", "2026-09-23T00:00:00.000Z")
                .toString(),
        )
        // The next merge settles the journal first. After recovery the
        // branch is the merge, so the new request -- made against it -- is
        // simply up to date.
        val answer = d.f.git.mergeRemote(d.request(ours = mergeOid))
        assertEquals(answer.toString(), "up_to_date", answer.getString("outcome"))
        assertEquals(mergeOid, d.head())
        assertTrue("recovery left the journal", !d.journal().exists())
        d.f.scratch.deleteRecursively()
    }

    /** A state recovery does not recognise is kept, and refused -- never reset. */
    @Test
    fun anUnrecognisedStateBehindAJournalIsKeptAndRefused() {
        val d = diverged()
        d.journal().writeText(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("branch", "main").put("ours", d.ours).put("theirs", d.theirs).put("merge_oid", d.theirs)
                .put("tree_oid", "0".repeat(40)).put("phase", "applying").put("created_at", "2026-09-23T00:00:00.000Z")
                .toString(),
        )
        // A tracked file changed by hand: nothing recovery may explain away.
        File(d.f.workDir, "mine.txt").writeText("edited\n")
        assertEquals(3181, refusal { d.f.git.mergeRemote(d.request()) })
        assertTrue("the journal was discarded", d.journal().exists())
        assertEquals("edited\n", File(d.f.workDir, "mine.txt").readText())
        assertEquals(d.ours, d.head())
        d.f.scratch.deleteRecursively()
    }

    @Test
    fun theV2FetchAndPullTalkToTheTestRemote() {
        val remote = testRemote()
        val f = fixture()
        // Unrelated `main` histories: the seeded remote and this fresh repository diverge from the start.
        val local = f.commit("android.txt", "local\n", "local first")
        f.git.setRemote(f.request().put("url", "${remote.base}/target.git"))
        assertEquals(3197, refusal { f.git.fetch(f.request().put("operation_id", UUID.randomUUID().toString()).put("remote", "origin")) })
        f.git.storeCredential(f.credential(remote, remote.token))
        val fetched = f.git.fetch(f.request().put("operation_id", UUID.randomUUID().toString()).put("remote", "origin"))
        assertEquals("main", fetched.getString("branch"))
        assertEquals(remote.tip("target.git", "main"), fetched.getString("remote_oid"))
        assertEquals(1, fetched.getInt("ahead")); assertEquals(1, fetched.getInt("behind"))
        assertEquals(3196, refusal { f.git.pullFastForward(f.request().put("expected_head_oid", local)) })
        assertEquals(3110, refusal { f.git.pullFastForward(f.request().put("expected_head_oid", "a".repeat(40))) })
        // A branch of its own: nothing on the remote yet, then pushed, then moved on by the Mac, then pulled.
        f.scratch.deleteRecursively()
        val g = fixture()
        val branch = g.checkoutFresh()
        val first = g.commit("android.txt", "first\n", "first")
        g.git.setRemote(g.request().put("url", "${remote.base}/target.git"))
        g.git.storeCredential(g.credential(remote, remote.token))
        val nothing = g.git.fetch(g.request().put("operation_id", UUID.randomUUID().toString()).put("remote", "origin"))
        assertTrue(nothing.isNull("remote_oid"))
        assertEquals(3112, refusal { g.git.pullFastForward(g.request().put("expected_head_oid", first)) })
        g.git.push(g.pushRequest(first))
        val competing = remote.control("POST", "/g2/compete", JSONObject().put("repo", "target.git").put("branch", branch).toString())
        val behind = g.git.fetch(g.request().put("operation_id", UUID.randomUUID().toString()).put("remote", "origin"))
        assertEquals(competing.getString("oid"), behind.getString("remote_oid"))
        assertEquals(0, behind.getInt("ahead")); assertEquals(1, behind.getInt("behind"))
        val pulled = g.git.pullFastForward(g.request().put("expected_head_oid", first))
        assertTrue(pulled.getBoolean("updated"))
        assertEquals(competing.getString("oid"), pulled.getString("oid")); assertEquals(first, pulled.getString("previous_oid"))
        assertTrue(File(g.workDir, "COMPETING.txt").exists())
        val again = g.git.pullFastForward(g.request().put("expected_head_oid", competing.getString("oid")))
        assertFalse(again.getBoolean("updated"))
        g.scratch.deleteRecursively()
    }

    @Test
    fun theReceiptJournalKeepsTheNewestTwentyFiveAndRefusesACorruptOne() {
        val f = fixture()
        assertEquals(0, f.git.pushReceipts(f.request()).getJSONArray("receipts").length())
        val gitDir = f.gitDir
        for (index in 1..27) {
            tech.zseven.rish.runtime.AndroidGitPushReceipts.record(
                gitDir, f.projectId,
                tech.zseven.rish.runtime.AndroidGitPushReceipts.receipt("example.com", "main", "a".repeat(40), index.toString(16).padStart(40, '0'), "2026-09-21T00:00:${index.toString().padStart(2, '0')}Z"),
            )
        }
        val kept = f.git.pushReceipts(f.request()).getJSONArray("receipts")
        assertEquals(25, kept.length())
        assertEquals(3.toString(16).padStart(40, '0'), kept.getJSONObject(0).getString("remote_oid"))
        assertEquals(27.toString(16).padStart(40, '0'), kept.getJSONObject(24).getString("remote_oid"))
        // A receipt with anything but the seven fields never enters the journal.
        assertEquals(3021, refusal {
            tech.zseven.rish.runtime.AndroidGitPushReceipts.record(gitDir, f.projectId, tech.zseven.rish.runtime.AndroidGitPushReceipts.receipt("example.com", "main", "a".repeat(40), "b".repeat(40), "now").put("token", "x"))
        })
        // A corrupt journal is refused whole rather than read around.
        File(gitDir, tech.zseven.rish.runtime.AndroidGitPushReceipts.FILENAME).writeText("{\"schema_version\":1,\"project_id\":\"other\",\"receipts\":[]}")
        assertEquals(3021, refusal { f.git.pushReceipts(f.request()) })
        f.scratch.deleteRecursively()
    }
}
