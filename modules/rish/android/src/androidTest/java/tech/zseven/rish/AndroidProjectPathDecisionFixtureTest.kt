package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidProjectContextPolicy
import tech.zseven.rish.runtime.RishAgentCoreNative

/**
 * The frozen path decisions, replayed through this host.
 *
 * The tables are the core's and cannot differ. Everything before them can:
 * normalization, case folding, how an extension is taken. The non-ASCII cases
 * are what this exists for.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidProjectPathDecisionFixtureTest {
    @Test fun everyFrozenPathIsDecidedTheSameWay() {
        assumeTrue("rish agent core is not staged", RishAgentCoreNative.available)
        val fixture = JSONObject(
            InstrumentationRegistry.getInstrumentation().context.assets
                .open("project-path-decisions.json").bufferedReader().use { it.readText() },
        )
        assertEquals(1, fixture.getInt("schema_version"))
        val cases = fixture.getJSONArray("cases")
        val mismatches = mutableListOf<String>()
        for (index in 0 until cases.length()) {
            val entry = cases.getJSONObject(index)
            val want = entry.getJSONObject("decision")
            val got = AndroidProjectContextPolicy.decisionFor(entry.getString("path"))
            val wantReason = if (want.isNull("omission_reason")) null else want.getString("omission_reason")
            if (got.normalizedPath != want.getString("normalized_path") ||
                got.eligible != want.getBoolean("eligible") ||
                got.omissionReason != wantReason
            ) {
                mismatches += "${entry.getString("name")}: want ${want} got " +
                    "{normalized_path=${got.normalizedPath}, eligible=${got.eligible}, omission_reason=${got.omissionReason}}"
            }
        }
        assertEquals("differs from iOS on:\n" + mismatches.joinToString("\n"), 0, mismatches.size)
    }
}
