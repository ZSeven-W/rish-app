package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidCredentialStore
import tech.zseven.rish.runtime.AndroidModelTransport
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import tech.zseven.rish.runtime.RuntimeFailure
import tech.zseven.rish.runtime.RuntimeJson
import java.util.UUID

/**
 * The frozen replies, read back through this host.
 *
 * Reading a reply is where a tool call is quietly lost or a refusal is
 * mislabelled, and the round settles on whatever comes out -- so a case the
 * fixture says must be refused is the more important half.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidProviderResponseFixtureTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun fixture(name: String): JSONObject = JSONObject(
        InstrumentationRegistry.getInstrumentation().context.assets
            .open(name).bufferedReader().use { it.readText() },
    )

    private fun transport(): AndroidModelTransport {
        val namespace = "response-fixture-${UUID.randomUUID()}"
        return AndroidModelTransport(
            AndroidCredentialStore(context, namespace),
            AndroidProviderConfiguration(context, "$namespace.providers"),
        )
    }

    private fun replay(file: String, protocol: String, harness: String) {
        val fixture = fixture(file)
        assertEquals(harness, fixture.getString("harness_id"))
        val cases = fixture.getJSONArray("cases")
        assertTrue("${cases.length()}", cases.length() > 3)
        val transport = transport()
        for (index in 0 until cases.length()) {
            val entry = cases.getJSONObject(index)
            val name = entry.getString("name")
            val hosts = entry.getJSONArray("hosts")
            if ((0 until hosts.length()).none { hosts.getString(it) == "android" }) continue
            val expected = entry.optString("failure_code", "")
            val read = try {
                transport.parseResponse(protocol, entry.getJSONObject("response"))
            } catch (failure: RuntimeFailure) {
                assertEquals("$name refusal", expected, failure.code)
                continue
            }
            assertTrue("$name should have been refused as $expected", expected.isEmpty())
            val want = entry.getJSONObject("parsed")
            assertEquals("$name text", want.getString("text"), read.getString("text"))
            assertEquals(
                "$name reasoning",
                want.getString("reasoning"),
                read.getString("reasoning"),
            )
            assertEquals(
                "$name finish",
                want.getString("finish_reason"),
                read.getString("finish_reason"),
            )
            assertEquals(
                "$name tool_calls",
                RuntimeJson.receiptJson(want.getJSONArray("tool_calls")),
                RuntimeJson.receiptJson(read.getJSONArray("tool_calls")),
            )
        }
    }

    @Test fun anthropicRepliesAreReadTheSameWay() =
        replay("anthropic-response-cases.json", "messages", "claude-code")

    @Test fun responsesRepliesAreReadTheSameWay() =
        replay("openai-response-cases.json", "responses", "codex")
}
