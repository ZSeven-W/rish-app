package tech.zseven.rish

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Tools reach the provider request, and a tool call is no longer refused.
 *
 * Two lines in `AndroidModelTransport` held the whole agent path shut: one
 * refused any request carrying tools, the other refused any reply containing
 * tool calls. A round could be journalled and settled and still come back with
 * nothing to do, which reads exactly like a model choosing not to act.
 *
 * These cover the request shape, because that is the part this platform
 * decides. Reading a reply is not covered here and should not be: turning
 * untrusted model output into calls is `completion_response`'s rule, and the
 * transport carries the provider's own JSON for it rather than reading fields
 * off it in Kotlin.
 */
@RunWith(AndroidJUnit4::class)
@SmallTest
class AndroidTransportToolsTest {

    private fun transport() = tech.zseven.rish.runtime.AndroidRuntimeState
        .get(ApplicationProvider.getApplicationContext<Application>()).transport

    private fun tool(name: String): JSONObject = JSONObject()
        .put("name", name)
        .put("description", "does $name")
        .put(
            "parameters",
            JSONObject().put("type", "object").put(
                "properties",
                JSONObject().put("path", JSONObject().put("type", "string")),
            ),
        )

    /**
     * The chat-completions wrapper is the only part the transport decides: the
     * name, the description and the schema are the registry's and travel
     * unchanged.
     */
    @Test
    fun aToolIsWrappedForChatCompletionsWithoutChangingWhatItIs() {
        val declared = JSONArray().put(tool("read_file")).put(tool("write_file"))
        val wrapped = transport().functionToolsForTest(declared)
        assertEquals(2, wrapped.length())
        val first = wrapped.getJSONObject(0)
        assertEquals("function", first.getString("type"))
        val function = first.getJSONObject("function")
        assertEquals("read_file", function.getString("name"))
        assertEquals("does read_file", function.getString("description"))
        // The schema is the registry's object, not a re-spelling of it.
        assertEquals(
            declared.getJSONObject(0).getJSONObject("parameters").toString(),
            function.getJSONObject("parameters").toString(),
        )
    }

    /** An empty list is not a list of tools; nothing is added. */
    @Test
    fun noToolsMeansNoToolsField() {
        val wrapped = transport().functionToolsForTest(JSONArray())
        assertEquals(0, wrapped.length())
    }

    /** A malformed entry is skipped rather than sent as a broken tool. */
    @Test
    fun anEntryThatIsNotAToolIsSkipped() {
        val declared = JSONArray().put("not a tool").put(tool("list_dir"))
        val wrapped = transport().functionToolsForTest(declared)
        assertEquals(1, wrapped.length())
        assertTrue(wrapped.getJSONObject(0).getJSONObject("function").getString("name") == "list_dir")
    }
}
