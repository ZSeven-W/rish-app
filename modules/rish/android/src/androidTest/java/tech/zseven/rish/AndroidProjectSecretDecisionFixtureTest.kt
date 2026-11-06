package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.RishAgentCoreNative

/**
 * The credential scanner, as this platform asks it: the shared core's
 * `secret_decision` over the bytes, held to the decisions iOS recorded.
 *
 * Nothing here is Android's own -- the fixture is read to prove that the
 * core this build ships answers the same way the shipped host does, which
 * is the only reason a file's content may be sent from here at all.
 */
@RunWith(AndroidJUnit4::class)
class AndroidProjectSecretDecisionFixtureTest {
    @Test
    fun everyFrozenTextIsDecidedTheSameWay() {
        assertTrue("the agent core is not staged", RishAgentCoreNative.available)
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val fixture = JSONObject(assets.open("project-secret-decisions.json").bufferedReader().readText())
        assertEquals(1, fixture.getInt("schema_version"))
        val cases = fixture.getJSONArray("cases")
        val mismatches = ArrayList<String>()
        var pending = 0
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val reply = RishAgentCoreNative.projectContextReduce(
                JSONObject().put("op", "secret_decision").toString(),
                case.getString("text").toByteArray(Charsets.UTF_8),
            )?.let { JSONObject(it) } ?: run { fail("no reply for ${case.getString("name")}"); return }
            assertTrue(reply.optBoolean("ok"))
            val actual = JSONObject().put("suspected_secret", reply.getBoolean("suspected_secret"))
                .put("omission_reason", reply.opt("omission_reason") ?: JSONObject.NULL)
            if (case.opt("decision") == "PENDING") {
                pending += 1
                continue
            }
            val expected = case.getJSONObject("decision")
            if (expected.toString() != actual.toString() &&
                !(expected.getBoolean("suspected_secret") == actual.getBoolean("suspected_secret") &&
                    expected.opt("omission_reason").toString() == actual.opt("omission_reason").toString())
            ) {
                mismatches.add("${case.getString("name")}: expected $expected got $actual")
            }
        }
        assertEquals(mismatches.joinToString("\n"), 0, mismatches.size)
        assertEquals("cases still PENDING; record them on iOS first", 0, pending)
    }
}
