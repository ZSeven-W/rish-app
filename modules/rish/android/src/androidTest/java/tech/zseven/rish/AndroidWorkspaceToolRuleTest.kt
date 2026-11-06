package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.RishAgentCoreNative

/**
 * Android can ask the core what a file tool may do.
 *
 * The rules for reading and writing files inside a workspace have been in the
 * shared core all along, in `workspace_tool`; Android had no binding to them,
 * so an agent here could not have been told what it was allowed to do even if
 * everything above it existed. This covers the binding itself: the same
 * envelope iOS sends, answered by the same rule, reaching Kotlin.
 *
 * These are the core's numbers, not this test's. If they change, the change is
 * a decision about what a tool may read, and this goes red where someone can
 * see it.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidWorkspaceToolRuleTest {

    private fun reduce(request: JSONObject): JSONObject? =
        RishAgentCoreNative.workspaceTool(request)

    @Test
    fun theHostReadsItsByteCapsFromTheCore() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val bounds = reduce(JSONObject().put("op", "bounds"))
        assertNotNull("the bounds decision must reach the core", bounds)
        assertEquals(512, bounds!!.getInt("max_path_bytes"))
        assertEquals(60 * 1024, bounds.getInt("max_read_bytes"))
        assertEquals(64 * 1024, bounds.getInt("max_prior_read_bytes"))
        assertEquals(1000, bounds.getInt("max_entries"))
    }

    /**
     * A revision is the file state the host read, spelled by the core. The
     * host stats; how those five numbers become one string is not the host's
     * to invent, or two platforms would disagree about whether a file changed.
     */
    @Test
    fun aRevisionIsSpelledByTheCoreNotTheHost() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val reply = reduce(
            // The names are the core's: dev, ino, size, mtime_sec, mtime_nsec.
            // Guessing them cost a red test, which is what it is for.
            JSONObject().put("op", "revision").put("dev", 1).put("ino", 2)
                .put("size", 255).put("mtime_sec", 16).put("mtime_nsec", 4095),
        )
        assertNotNull(reply)
        assertEquals("1:2:ff:10:fff", reply!!.getString("revision"))
    }

    /** An envelope the rule does not know is refused, not guessed at. */
    @Test
    fun anUnknownDecisionIsRefused() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        assertNull(reduce(JSONObject().put("op", "no_such_decision")))
        assertNull(reduce(JSONObject()))
    }
}
