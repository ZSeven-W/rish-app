package tech.zseven.rish

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import tech.zseven.rish.runtime.AndroidSubscriptionAuthManager
import tech.zseven.rish.runtime.SubscriptionAuthProcessFactory
import tech.zseven.rish.runtime.SubscriptionAuthVault
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the production manager with injectable process and vault adapters. */
@RunWith(AndroidJUnit4::class)
class AndroidSubscriptionAuthManagerLifecycleTest {
    private val context = ApplicationProvider.getApplicationContext<android.app.Application>()

    @Test fun statusDuringProcessExitWaitsForVerification() {
        val factory = FakeFactory(loginOutput = "https://auth.openai.com/codex/device Code: ABCD-1234")
        val vault = FakeVault()
        val manager = manager(factory, vault)
        try {
            val started = manager.start("codex")
            assertEquals("authorizing", started.getString("status"))
            assertEquals("subscription", started.getString("auth_method"))
            assertTrue(started.getJSONObject("login").has("session_id"))
            assertEquals("authorizing", manager.status("codex").getString("status"))
            await { factory.pendingStatus != null }
            factory.pendingStatus!!.finish("{\"loggedIn\":true,\"authMethod\":\"chatgpt\",\"email\":\"account@example.invalid\"}", 0)
            eventually { manager.status("codex").getString("status") == "signed_in" }
            assertEquals(1, vault.captureCount)
        } finally { manager.shutdown() }
    }

    @Test fun logoutRacingLateSuccessCannotCommitOldLogin() {
        val factory = FakeFactory(loginOutput = "https://auth.openai.com/codex/device Code: ABCD-1234")
        val vault = FakeVault()
        val manager = manager(factory, vault)
        try {
            manager.start("codex")
            val result = manager.logout("codex")
            assertEquals("signed_out", result.getString("status"))
            factory.pendingStatus?.finish("{\"loggedIn\":true,\"authMethod\":\"chatgpt\"}", 0)
            Thread.sleep(100)
            assertEquals(0, vault.captureCount)
            assertEquals(1, vault.clearCount)
        } finally { manager.shutdown() }
    }

    @Test fun staleCancelCannotTouchNewerLogin() {
        val factory = FakeFactory(loginOutput = "https://auth.openai.com/codex/device Code: ABCD-1234")
        val vault = FakeVault()
        val manager = manager(factory, vault)
        try {
            val old = manager.start("codex").getJSONObject("login").getString("session_id")
            manager.cancel("codex", old)
            val newer = manager.start("codex").getJSONObject("login").getString("session_id")
            val stale = manager.cancel("codex", old)
            assertEquals("authorizing", stale.getString("status"))
            assertTrue(newer != old)
            assertTrue(factory.loginCount >= 2)
        } finally { manager.shutdown() }
    }

    @Test fun failedLoginPreservesPreviousVault() {
        val factory = FakeFactory(loginOutput = "login failed", loginExit = 2)
        val vault = FakeVault()
        val manager = manager(factory, vault)
        try {
            val started = manager.start("codex")
            eventually { manager.status("codex").getString("status") == "error" }
            assertEquals("login_failed", manager.status("codex").getString("error_code"))
            assertEquals("old", vault.snapshot)
            assertEquals("authorizing", started.getString("status"))
            assertEquals(0, vault.captureCount)
        } finally { manager.shutdown() }
    }

    @Test fun canceledCallbackDoesNotRestartStatusSubprocess() {
        val factory = FakeFactory(loginOutput = "", loginHeld = true)
        val vault = FakeVault()
        val manager = manager(factory, vault)
        try {
            val session = manager.start("codex").getJSONObject("login").getString("session_id")
            assertEquals("signed_out", manager.cancel("codex", session).getString("status"))
            Thread.sleep(100)
            assertEquals(0, factory.statusCount)
            assertEquals("cancelled", manager.status("codex").getString("error_code"))
        } finally { manager.shutdown() }
    }

    @Test fun terminalErrorRemainsStableUntilNewLogin() {
        val factory = FakeFactory(loginOutput = "login failed", loginExit = 2)
        val manager = manager(factory, FakeVault())
        try {
            manager.start("codex")
            eventually { manager.status("codex").getString("status") == "error" }
            assertEquals("error", manager.status("codex").getString("status"))
            assertEquals("login_failed", manager.status("codex").getString("error_code"))
        } finally { manager.shutdown() }
    }

    @Test fun browserSnapshotTracksCancellationWithoutStartingAStatusProcess() {
        val factory = FakeFactory(loginOutput = "", loginHeld = true)
        val manager = manager(factory, FakeVault())
        try {
            val session = manager.start("codex").getJSONObject("login").getString("session_id")
            val active = manager.withAuthorizationStatus("codex") { it }
            assertEquals(session, active.getJSONObject("login").getString("session_id"))
            assertEquals("authorizing", active.getString("status"))
            manager.cancel("codex", session)
            assertEquals("signed_out", manager.withAuthorizationStatus("codex") { it.getString("status") })
            assertEquals(0, factory.statusCount)
        } finally { manager.shutdown() }
    }

    @Test fun browserSnapshotNeverWaitsBehindAStatusSubprocess() {
        val factory = FakeFactory(loginOutput = "")
        val manager = manager(factory, FakeVault())
        val statusDone = CountDownLatch(1)
        val snapshotDone = CountDownLatch(1)
        try {
            Thread { try { manager.status("codex") } finally { statusDone.countDown() } }.start()
            await { factory.pendingStatus != null }
            Thread {
                manager.withAuthorizationStatus("codex") { snapshotDone.countDown() }
            }.start()
            assertTrue("A browser ownership check must not wait for CLI status", snapshotDone.await(1, TimeUnit.SECONDS))
        } finally {
            factory.pendingStatus?.finish("Not logged in", 1)
            statusDone.await(2, TimeUnit.SECONDS)
            manager.shutdown()
        }
    }

    private fun manager(factory: FakeFactory, vault: FakeVault) =
        AndroidSubscriptionAuthManager(context, vault, factory)

    private fun eventually(predicate: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 4_000
        var matched = predicate()
        while (!matched && System.currentTimeMillis() < deadline) {
            Thread.sleep(25)
            matched = predicate()
        }
        assertTrue(matched)
    }

    private fun await(predicate: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 4_000
        while (!predicate() && System.currentTimeMillis() < deadline) Thread.sleep(25)
        assertTrue(predicate())
    }

    private class FakeVault : SubscriptionAuthVault {
        var snapshot = "old"
        var captureCount = 0
        var clearCount = 0
        override fun restore(harnessId: String, home: File) {
            if (snapshot == "old") File(home, ".codex/auth.json").apply { parentFile!!.mkdirs(); writeText(snapshot) }
        }
        override fun capture(harnessId: String, home: File) { captureCount++; snapshot = "new" }
        override fun clear(harnessId: String) { clearCount++; snapshot = "" }
    }

    private class FakeFactory(
        private val loginOutput: String,
        private val loginExit: Int = 0,
        private val loginHeld: Boolean = false,
    ) : SubscriptionAuthProcessFactory {
        val loginProcesses = mutableListOf<FakeProcess>()
        @Volatile var pendingStatus: FakeProcess? = null
        var loginCount = 0
        var statusCount = 0
        override fun available(harnessId: String) = true
        override fun start(harnessId: String, args: List<String>, home: File): Process {
            if (args.contains("status")) {
                statusCount++
                return FakeProcess(held = true).also { pendingStatus = it }
            }
            if (args.contains("logout")) return FakeProcess().also { it.finish("", 0) }
            loginCount++
            return FakeProcess(held = loginHeld).also {
                loginProcesses += it
                if (!loginHeld) it.finish(loginOutput, loginExit)
            }
        }
    }

    private class FakeProcess(private val held: Boolean = false) : Process() {
        private var exitCode: Int? = null
        private val output = PipedInputStream()
        private val outputWriter = PipedOutputStream(output)
        private val done = CountDownLatch(1)
        private val stdin = ByteArrayOutputStream()
        fun finish(text: String, code: Int) {
            outputWriter.write(text.toByteArray())
            outputWriter.close()
            exitCode = code
            done.countDown()
        }
        override fun getInputStream(): InputStream = output
        override fun getErrorStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun getOutputStream(): OutputStream = stdin
        override fun waitFor(): Int { done.await(); return exitCode ?: -1 }
        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = done.await(timeout, unit)
        override fun exitValue(): Int = exitCode ?: throw IllegalThreadStateException()
        override fun destroy() { if (exitCode == null) finish("", 143) }
        override fun destroyForcibly(): Process { destroy(); return this }
        override fun isAlive(): Boolean = exitCode == null
    }
}
