package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertThrows
import org.junit.Test

class TaskExperienceRoutesTest {
    @Test fun controlRouteRejectsUnknownMethodsAndMalformedArgumentsBeforeTouchingPlatformState() {
        assertThrows(BridgeFailure::class.java) { TaskExperienceRoutes.call(null, "begin", JSONArray()) { } }
        for (args in listOf(JSONArray(), JSONArray().put(1), JSONArray().put(JSONObject()).put(JSONObject()))) {
            assertThrows(Exception::class.java) { TaskExperienceRoutes.call(null, "handle", args) { } }
        }
        for (schema in listOf<Any>(true, "1", 1.0, 2)) {
            val args = JSONArray().put(JSONObject().put("schema_version", schema).put("op", "permission"))
            assertThrows(IllegalArgumentException::class.java) { TaskExperienceRoutes.call(null, "handle", args) { } }
        }
    }
}
