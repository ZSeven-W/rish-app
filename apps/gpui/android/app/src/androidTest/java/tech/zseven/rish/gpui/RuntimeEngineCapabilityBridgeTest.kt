package tech.zseven.rish.gpui

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.BuildConfig
import tech.zseven.rish.runtime.AndroidSubscriptionAuthProcessFactory

/** Exercises the production route without starting authentication or a CLI. */
@RunWith(AndroidJUnit4::class)
class RuntimeEngineCapabilityBridgeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    private fun catalog(context: Context): JSONObject = RishGpuiBridge.routePlatform(
        context, null, "ShellRuntimeEngines", "catalog", JSONArray(),
    ) { error("Catalog must not request permissions") } as JSONObject

    @Test fun disabledAuthenticationMatchesTheProductionCatalogInBothPackageLanes() {
        assertFalse("This lane requires production authentication to remain disabled",
            BuildConfig.RISH_OFFICIAL_CLI_ENABLED)
        val factory = AndroidSubscriptionAuthProcessFactory(context)
        val result = catalog(context)
        assertUnavailableAuthentication(result)
        for (id in listOf("codex", "claude-code")) {
            assertFalse(factory.available(id))
            assertEquals("cli_auth_disabled", factory.unavailableReason(id))
        }
        // Running this same test in the explicit probe package proves that
        // executable presence does not turn on the account capability.
        val codex = File(context.applicationInfo.nativeLibraryDir, "libcodex.so")
        assertEquals(BuildConfig.RISH_CODEX_PROBE_BUNDLED, codex.isFile)
        instrumentation.sendStatus(0, Bundle().apply {
            putBoolean("codex_probe_bundled", BuildConfig.RISH_CODEX_PROBE_BUNDLED)
            putString("runtime_engine_catalog", result.toString())
        })
    }

    @Test fun disabledCatalogDoesNotOpenAuthStorageInspectExecutablesOrLaunchUi() {
        assertFalse(BuildConfig.RISH_OFFICIAL_CLI_ENABLED)
        val touched = mutableListOf<String>()
        fun forbidden(name: String): Nothing {
            touched += name
            error("Catalog must not access $name while authentication is disabled")
        }
        val isolated = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getApplicationInfo(): ApplicationInfo = forbidden("applicationInfo")
            override fun getFilesDir(): File = forbidden("filesDir")
            override fun getCacheDir(): File = forbidden("cacheDir")
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                forbidden("sharedPreferences")
            override fun startActivity(intent: Intent) = forbidden("startActivity")
        }
        assertUnavailableAuthentication(catalog(isolated))
        assertEquals("Capability reads must not initialize auth/runtime services", emptyList<String>(), touched)
    }

    private fun assertUnavailableAuthentication(result: JSONObject) {
        assertEquals(1, result.getInt("schema_version"))
        val engines = result.getJSONArray("engines")
        assertEquals(listOf("pi", "dsh", "claude-code", "codex", "zcode"),
            (0 until engines.length()).map { engines.getJSONObject(it).getString("id") })
        for (index in 0 until engines.length()) {
            val engine = engines.getJSONObject(index)
            val auth = engine.getJSONObject("authentication")
            for (key in listOf("supported", "source_selection", "authorization_browser",
                "native_code_entry", "provider_selection")) {
                assertEquals("${engine.getString("id")} must not advertise $key", false, auth.get(key))
            }
            val builtin = engine.getString("id") == "pi"
            assertEquals(if (builtin) "builtin" else "unavailable",
                engine.getJSONObject("installation").getString("state"))
            assertEquals(if (builtin) "ready" else "unavailable",
                engine.getJSONObject("execution").getString("state"))
        }
    }
}
