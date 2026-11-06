package tech.zseven.rish

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import tech.zseven.rish.runtime.AndroidSubscriptionAuthManager
import tech.zseven.rish.runtime.AndroidSubscriptionAuthStore
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Test
import org.junit.runner.RunWith

/** Subscription auth stays unavailable and truthful in the normal lite APK. */
@RunWith(AndroidJUnit4::class)
class AndroidSubscriptionAuthTest {
    private val context = ApplicationProvider.getApplicationContext<android.app.Application>()

    @Test
    fun absentOptionalCliIsUnavailableWithoutFakeLogin() {
        assumeFalse("This absence check is for hosts without bundled official CLIs", BuildConfig.RISH_OFFICIAL_CLI_ENABLED)
        val manager = AndroidSubscriptionAuthManager(context)
        try {
            for (harness in listOf("codex", "claude-code")) {
                val result = manager.status(harness)
                assertEquals(1, result.getInt("schema_version"))
                assertEquals(harness, result.getString("harness_id"))
                assertEquals("unavailable", result.getString("status"))
                assertEquals("none", result.getString("auth_method"))
                assertFalse(result.getJSONObject("runtime").getBoolean("available"))
                assertTrue(result.has("error_code"))
            }
        } finally {
            manager.shutdown()
        }
    }

    @Test
    fun encryptedHomesAreSeparatePerHarness() {
        val store = AndroidSubscriptionAuthStore(
            context,
            "rish.subscription.auth.test.${System.nanoTime()}"
        )
        val root = File(context.cacheDir, "subscription-auth-test-${System.nanoTime()}")
        val codexHome = File(root, "codex")
        val claudeHome = File(root, "claude")
        try {
            codexHome.mkdirs()
            File(codexHome, ".codex/auth.json").apply { parentFile?.mkdirs(); writeText("codex-account@example.invalid") }
            claudeHome.mkdirs()
            File(claudeHome, ".claude/.credentials.json").apply { parentFile?.mkdirs(); writeText("claude-account@example.invalid") }
            store.capture("codex", codexHome)
            store.capture("claude-code", claudeHome)
            AndroidSubscriptionAuthStore.clearDirectory(codexHome)
            AndroidSubscriptionAuthStore.clearDirectory(claudeHome)
            store.restore("codex", codexHome)
            store.restore("claude-code", claudeHome)
            assertEquals("codex-account@example.invalid", File(codexHome, ".codex/auth.json").readText())
            assertEquals("claude-account@example.invalid", File(claudeHome, ".claude/.credentials.json").readText())
            assertFalse(File(codexHome, ".claude/.credentials.json").exists())
            assertFalse(File(claudeHome, ".codex/auth.json").exists())
        } finally {
            store.clear("codex")
            store.clear("claude-code")
            AndroidSubscriptionAuthStore.clearDirectory(root)
        }
    }
}
