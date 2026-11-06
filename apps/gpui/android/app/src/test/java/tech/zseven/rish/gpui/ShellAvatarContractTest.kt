package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ShellAvatarContractTest {
    private fun args(schema: Any = 1, initiated: Any = true) = JSONArray().put(
        JSONObject().put("schema_version", schema).put("userInitiated", initiated),
    )

    @Test fun pickerRequiresExplicitUserActionAndExactProtocol() {
        ShellAvatarContract.validate(args())
        for (schema in listOf<Any>(true, "1", 1.0, 2)) {
            assertThrows(IllegalArgumentException::class.java) { ShellAvatarContract.validate(args(schema)) }
        }
        for (initiated in listOf<Any>(false, "true", 1, JSONObject.NULL)) {
            assertThrows(IllegalArgumentException::class.java) { ShellAvatarContract.validate(args(initiated = initiated)) }
        }
        assertThrows(Exception::class.java) { ShellAvatarContract.validate(JSONArray()) }
        assertThrows(Exception::class.java) { ShellAvatarContract.validate(JSONArray().put(1)) }
        val extras = args().apply { getJSONObject(0).put("uri", "content://ambient-image") }
        assertThrows(IllegalArgumentException::class.java) { ShellAvatarContract.validate(extras) }
    }

    @Test fun onePickerOwnsReplyAndCancellationCannotSettleItsReplacement() {
        val lease = AvatarPickLease<String?>()
        val results = mutableListOf<String?>()
        val token = lease.begin(results::add)
        val busy = assertThrows(BridgeFailure::class.java) { lease.begin(results::add) }
        assertEquals("E_ASSISTANT_AVATAR_BUSY", busy.code)
        assertFalse(lease.finish("foreign", "wrong"))
        assertTrue(lease.finish(token, null))
        assertFalse(lease.finish(token, "duplicate"))
        val next = lease.begin(results::add)
        assertFalse(lease.finish(token, "late original"))
        assertTrue(lease.active(next))
        assertTrue(lease.finish(next, "new image"))
        assertEquals(listOf(null, "new image"), results)
    }

    @Test fun bitmapPlanBoundsBothDimensionsAndPreservesAspectRatio() {
        assertEquals(512 to 256, ShellAvatarContract.targetSize(4000, 2000))
        assertEquals(256 to 512, ShellAvatarContract.targetSize(2000, 4000))
        assertEquals(1 to 512, ShellAvatarContract.targetSize(1, 32768))
        assertEquals(24 to 32, ShellAvatarContract.targetSize(24, 32))
        val sample = ShellAvatarContract.sampleSize(20_000, 5000)
        assertTrue(20_000 / sample <= 1024)
        for ((width, height) in listOf(0 to 1, -1 to 2, 2 to 0, 32769 to 1, 10001 to 10000)) {
            assertThrows(BridgeFailure::class.java) { ShellAvatarContract.targetSize(width, height) }
        }
    }
}
