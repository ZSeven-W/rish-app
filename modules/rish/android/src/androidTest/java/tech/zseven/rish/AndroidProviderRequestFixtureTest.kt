package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidCredentialStore
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.RuntimeJson
import java.util.UUID

/**
 * The frozen request bodies, replayed through this host's transport.
 *
 * The fixture lives next to the iOS suite that first recorded it and is read
 * from there rather than copied, so there is one truth. Two things it caught
 * the first time it ran here: this host sent one token ceiling where iOS
 * sends four, and it hashed the request with the canonical encoding rather
 * than the one a receipt binds -- which differ on any round whose tool
 * arguments carry a path.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidProviderRequestFixtureTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** The fixture rides in the test apk, not the app's own assets. */
    private fun fixture(name: String): JSONObject = JSONObject(
        InstrumentationRegistry.getInstrumentation().context.assets
            .open(name).bufferedReader().use { it.readText() },
    )

    private fun transport(): AndroidModelTransport {
        val namespace = "request-fixture-${UUID.randomUUID()}"
        return AndroidModelTransport(
            AndroidCredentialStore(context, namespace),
            AndroidProviderConfiguration(context, "$namespace.providers"),
        )
    }

    /**
     * Every frozen body, rebuilt through this host's transport.
     *
     * All three dialects are the shared core's now, so this host claims every
     * case. It used to claim four of twenty-two; the rest closed when the
     * body moved rather than one at a time.
     */
    private fun replay(file: String, dialect: String, harness: String) {
        val fixture = fixture(file)
        assertEquals(1, fixture.getInt("schema_version"))
        assertEquals(harness, fixture.getString("harness_id"))
        val cases = fixture.getJSONArray("cases")
        assertTrue("${cases.length()}", cases.length() > 3)
        val transport = transport()
        for (index in 0 until cases.length()) {
            val entry = cases.getJSONObject(index)
            val name = entry.getString("name")
            val hosts = entry.getJSONArray("hosts")
            assertTrue(
                "$name no longer claims android",
                (0 until hosts.length()).any { hosts.getString(it) == "android" },
            )
            val body = transport.requestBody(
                dialect,
                entry.getString("model"),
                entry.getString("thinking_mode"),
                // The official configurations for these all send reasoning.
                true,
                entry.getBoolean("streaming"),
                entry.getJSONArray("messages"),
                entry.getJSONArray("tools"),
            )
            assertEquals(
                "$name body",
                RuntimeJson.receiptJson(entry.getJSONObject("body")),
                RuntimeJson.receiptJson(body),
            )
            assertEquals(
                "$name digest",
                entry.getString("body_sha256"),
                RuntimeJson.sha(RuntimeJson.receiptJson(body)),
            )
        }
    }

    @Test fun deepSeekRequestBodiesMatchTheFrozenOnes() =
        replay("deepseek-request-cases.json", "chat-completions", "dsh")

    @Test fun anthropicRequestBodiesMatchTheFrozenOnes() =
        replay("anthropic-request-cases.json", "messages", "claude-code")

    @Test fun responsesRequestBodiesMatchTheFrozenOnes() =
        replay("openai-request-cases.json", "responses", "codex")

    @Test fun theReceiptEncodingEscapesWhatTheCanonicalOneDoesNot() {
        val value = JSONObject().put("path", "workspace/notes.txt")
        assertEquals("""{"path":"workspace\/notes.txt"}""", RuntimeJson.receiptJson(value))
        assertEquals("""{"path":"workspace/notes.txt"}""", RuntimeJson.canonical(value))
        // Everything else the two agree on, so nothing else moves with it.
        val plain = JSONObject().put("b", 2).put("a", JSONArray().put(true).put("x"))
        assertEquals(RuntimeJson.canonical(plain), RuntimeJson.receiptJson(plain))
    }
}
