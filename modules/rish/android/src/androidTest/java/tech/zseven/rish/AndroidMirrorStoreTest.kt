package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidMirrorStore
import java.io.File
import java.util.UUID

/**
 * What staging a mirror writes.
 *
 * The receipt and the three files are a contract with `LocalMirrorsModule.mm`,
 * not with this platform: a guest tree assembled from either overlay has to
 * read the same. These hold the bytes, and the refusals that keep a broken
 * preference from reaching them.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidMirrorStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun store(body: (AndroidMirrorStore, File) -> Unit) {
        val home = File(context.cacheDir, "mirrors-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            body(AndroidMirrorStore(home), File(home, "rish-guest-overlay"))
        } finally {
            home.deleteRecursively()
        }
    }

    private fun mirrors(
        alpine: Pair<Boolean, String> = true to "https://mirrors.example.com/alpine",
        pip: Pair<Boolean, String> = true to "https://mirrors.example.com/pypi/simple/",
        npm: Pair<Boolean, String> = true to "https://mirrors.example.com/npm/",
    ): JSONObject = JSONObject()
        .put("alpine", JSONObject().put("enabled", alpine.first).put("baseUrl", alpine.second))
        .put("pip", JSONObject().put("enabled", pip.first).put("baseUrl", pip.second))
        .put("npm", JSONObject().put("enabled", npm.first).put("baseUrl", npm.second))

    private fun refusal(store: AndroidMirrorStore, requested: JSONObject?): String = try {
        "staged: " + store.apply(requested)
        ""
    } catch (refused: AndroidMirrorStore.Refused) {
        refused.code
    }

    /**
     * Three enabled mirrors, three files, and a base URL that gained the
     * trailing slash the paths below it need.
     */
    @Test fun enabledMirrorsAreStagedAsTheGuestWouldReadThem() = store { store, overlay ->
        val receipt = store.apply(mirrors())
        assertEquals("staged", receipt.getString("status"))
        assertEquals("rish-guest-overlay", receipt.getString("root"))
        assertEquals(false, receipt.getBoolean("staged_config_enters_guest"))
        assertEquals(1, receipt.getInt("schema_version"))
        assertEquals(
            "https://mirrors.example.com/alpine/v3.21/main\n" +
                "https://mirrors.example.com/alpine/v3.21/community\n",
            File(overlay, "etc/apk/repositories").readText(),
        )
        assertEquals(
            "[global]\nbreak-system-packages = true\n" +
                "index-url = https://mirrors.example.com/pypi/simple/\n",
            File(overlay, "etc/pip/pip.conf").readText(),
        )
        assertEquals(
            "registry=https://mirrors.example.com/npm/\n",
            File(overlay, "root/.npmrc").readText(),
        )
        val entries = receipt.getJSONArray("entries")
        assertEquals(3, entries.length())
        assertEquals("alpine", entries.getJSONObject(0).getString("category"))
        assertEquals(
            "https://mirrors.example.com/alpine/",
            entries.getJSONObject(0).getString("base_url"),
        )
    }

    /**
     * A disabled mirror is not an absent one: the upstream default is what is
     * staged and what the receipt reports, so the guest always has a source.
     */
    @Test fun aDisabledMirrorStagesTheUpstreamDefault() = store { store, overlay ->
        val receipt = store.apply(mirrors(npm = false to "https://mirrors.example.com/npm/"))
        assertEquals(
            "registry=https://registry.npmjs.org/\n",
            File(overlay, "root/.npmrc").readText(),
        )
        val npm = receipt.getJSONArray("entries").getJSONObject(2)
        assertEquals(false, npm.getBoolean("enabled"))
        assertEquals("https://registry.npmjs.org/", npm.getString("base_url"))
    }

    /** Nothing staged is an answer; a staging is readable afterwards. */
    @Test fun statusIsNullUntilSomethingIsStaged() = store { store, _ ->
        assertNull(store.status())
        val receipt = store.apply(mirrors())
        val read = store.status() ?: throw AssertionError("nothing was staged")
        assertEquals(receipt.getString("staged_at"), read.getString("staged_at"))
        assertEquals(3, read.getJSONArray("entries").length())
    }

    /**
     * The URL rules, which are the whole of the security here: a mirror is a
     * place this device will fetch code from.
     */
    @Test fun onlyACredentialFreeHttpsBaseIsAccepted() = store { store, _ ->
        val rejected = listOf(
            "http://mirrors.example.com/alpine/",
            "https://user:secret@mirrors.example.com/alpine/",
            "https://mirrors.example.com/alpine/?token=1",
            "https://mirrors.example.com/alpine/#fragment",
            "https:///alpine/",
            "not a url",
            "",
        )
        for (url in rejected) {
            assertEquals(url, "E_MIRRORS_INVALID", refusal(store, mirrors(alpine = true to url)))
        }
        // A URL too long to be a base is refused before it is parsed.
        val long = "https://mirrors.example.com/" + "a".repeat(2100)
        assertEquals("E_MIRRORS_INVALID", refusal(store, mirrors(alpine = true to long)))
    }

    /** A request this version does not understand is refused, not ignored. */
    @Test fun aConfigurationOfTheWrongShapeIsRefused() = store { store, _ ->
        assertEquals("E_MIRRORS_INVALID", refusal(store, null))
        assertEquals(
            "E_MIRRORS_INVALID",
            refusal(store, JSONObject(mirrors().toString()).also { it.remove("npm") }),
        )
        assertEquals(
            "E_MIRRORS_INVALID",
            refusal(store, JSONObject(mirrors().toString()).put("extra", JSONObject())),
        )
        // An absent flag is malformed rather than "disabled".
        val missingFlag = JSONObject(mirrors().toString())
        missingFlag.getJSONObject("pip").remove("enabled")
        assertEquals("E_MIRRORS_INVALID", refusal(store, missingFlag))
    }

}
