package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONException
import org.junit.Assert.*
import org.junit.Test
import tech.zseven.rish.runtime.RuntimeFailure
import tech.zseven.rish.runtime.AndroidWorkspaceFiles

class BridgeProtocolTest {
    @Test fun onlyGeneratedRecoveryLocationsCrossTheErrorBoundary() {
        val code = "E_WORKSPACE_CONFLICT"
        val location = ".rish-file-recovery/rish-edit-01234567-89ab-cdef-0123-456789abcdef"
        assertEquals("Recovery copy preserved: $location", BridgeProtocol.failureMessage(
            AndroidWorkspaceFiles.Refused(code,
                "File changed concurrently; a recoverable version remains at $location"), code))
        for (message in listOf("Bearer private-token",
            "File changed concurrently; a recoverable version remains at ../../private",
            "File changed concurrently; a recoverable version remains at $location?token=private")) {
            assertEquals(code, BridgeProtocol.failureMessage(AndroidWorkspaceFiles.Refused(code, message), code))
        }
        assertEquals(code, BridgeProtocol.failureMessage(IllegalStateException("Bearer private-token"), code))
    }

    @Test fun composerTextSurvivesJsonBoundary() {
        val text = "你好\nA \"quoted\" message with \\ paths 🚀"
        val encoded = BridgeProtocol.encode(text)
        assertEquals(text, JSONArray("[$encoded]").getString(0))
        assertEquals("null", BridgeProtocol.encode(null))
    }

    @Test fun onlyPositionalArrayRequestsAreAccepted() {
        val args = BridgeProtocol.arguments("[\"dsh\",{\"schema_version\":1},null]")
        assertEquals("dsh", args.getString(0))
        assertEquals(1, args.getJSONObject(1).getInt("schema_version"))
        assertTrue(args.isNull(2))
        assertThrows(JSONException::class.java) { BridgeProtocol.arguments("{\"token\":\"private\"}") }
    }

    @Test fun nativeFailuresNeverExposeTheirMessage() {
        assertEquals("E_BRIDGE_NATIVE", BridgeProtocol.failureCode(IllegalStateException("Bearer private-token")))
        assertEquals("E_COMPLETION_CANCELLED", BridgeProtocol.failureCode(RuntimeFailure("E_COMPLETION_CANCELLED")))
        assertEquals("E_BRIDGE_NATIVE", BridgeProtocol.failureCode(BridgeFailure("E_BAD token=private-token")))
        assertEquals("E_NATIVE_UNAVAILABLE", BridgeProtocol.failureCode(UnsatisfiedLinkError("/private/path")))
    }
}
