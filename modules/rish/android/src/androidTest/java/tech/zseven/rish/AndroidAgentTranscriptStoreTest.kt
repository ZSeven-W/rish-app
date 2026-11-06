package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAgentTranscriptStore
import tech.zseven.rish.runtime.AndroidAgentWal
import java.io.File
import java.util.UUID

/**
 * The transcript store on Android decides nothing of its own: it collects the
 * view, calls the shared reducer, and applies the changes it returns. These
 * cases are the ones that would drift if it ever started deciding.
 */
@RunWith(AndroidJUnit4::class)
class AndroidAgentTranscriptStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun root(): File =
        File(context.noBackupFilesDir, "transcript-test-${UUID.randomUUID()}").apply { mkdirs() }

    private fun uuid() = UUID.randomUUID().toString()

    /** A transcript holds assistant and tool turns; user text lives in the
     *  session, not here. */
    private fun assistantMessage(text: String): JSONObject = JSONObject()
        .put("schema_version", 1).put("role", "assistant").put("round_index", 0)
        .put("content", text).put("reasoning_content", "")
        .put("tool_calls", JSONArray())

    private fun workspaceRoot(fingerprint: String = "c".repeat(64)): JSONObject = JSONObject()
        .put("schema_version", 1).put("kind", "workspace")
        .put("workspace_id", uuid()).put("project_id", JSONObject.NULL)
        .put("root_fingerprint_sha256", fingerprint)
        .put("workspace_binding_revision", 1)
        .put("capabilities", JSONArray().put("file_read"))

    @Test fun creatingATranscriptIsIdempotentPerAttemptAndBoundToItsRoot() {
        val directory = root()
        try {
            val store = AndroidAgentTranscriptStore(AndroidAgentWal(directory))
            val attempt = uuid()
            val rootValue = workspaceRoot()
            val request = JSONObject().put("schema_version", 1)
                .put("attempt_id", attempt).put("root", rootValue)
            val created = store.create(request)
            assertNotNull(created)
            assertEquals(0L, created!!.getLong("generation"))
            // The same attempt asks again and gets the same transcript back,
            // without a second row.
            assertEquals(created.toString(), store.create(request).toString())
            // A different root for the same attempt is a conflict, not a
            // rebind: the transcript is bound to the root it was created for.
            try {
                store.create(JSONObject().put("schema_version", 1).put("attempt_id", attempt)
                    .put("root", workspaceRoot("d".repeat(64))))
                fail("a transcript was rebound to a different root")
            } catch (refused: AndroidAgentTranscriptStore.Refused) {
                assertEquals(3, refused.code)
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun appendingAMessageAdvancesTheTranscriptAndItsDigest() {
        val directory = root()
        try {
            val wal = AndroidAgentWal(directory)
            val store = AndroidAgentTranscriptStore(wal)
            val attempt = uuid()
            val rootValue = workspaceRoot()
            val created = store.create(JSONObject().put("schema_version", 1)
                .put("attempt_id", attempt).put("root", rootValue))!!
            val appended = store.append(JSONObject().put("schema_version", 1)
                .put("attempt_id", attempt).put("root", rootValue)
                .put("expected_transcript", created)
                .put("message", assistantMessage("hello")))
            assertNotNull(appended)
            assertEquals(1L, appended!!.getLong("generation"))
            assertTrue(appended.getString("transcript_sha256") != created.getString("transcript_sha256"))
            // The stored state moved with it, and the file is still canonical.
            val stored = wal.snapshot().getJSONArray("transcripts").getJSONObject(0)
            assertEquals(1L, stored.getLong("generation"))
            // The messages read back through the core, not through a local
            // reading of the row.
            val messages = store.nativeMessages(JSONObject().put("schema_version", 1)
                .put("attempt_id", attempt).put("root", rootValue).put("transcript", appended))
            assertNotNull(messages)
            assertEquals(1, messages!!.length())
            assertEquals("hello", messages.getJSONObject(0).getString("content"))
        } finally { directory.deleteRecursively() }
    }

    @Test fun aStaleTranscriptReferenceIsRefusedRatherThanOverwritten() {
        val directory = root()
        try {
            val store = AndroidAgentTranscriptStore(AndroidAgentWal(directory))
            val attempt = uuid()
            val rootValue = workspaceRoot()
            val created = store.create(JSONObject().put("schema_version", 1)
                .put("attempt_id", attempt).put("root", rootValue))!!
            val message = assistantMessage("first")
            store.append(JSONObject().put("schema_version", 1).put("attempt_id", attempt)
                .put("root", rootValue).put("expected_transcript", created).put("message", message))
            // The second writer still holds generation 0. Appending on it must
            // be refused, not silently applied on top of the first.
            try {
                store.append(JSONObject().put("schema_version", 1).put("attempt_id", attempt)
                    .put("root", rootValue).put("expected_transcript", created)
                    .put("message", JSONObject(message.toString()).put("content", "second")))
                fail("a stale transcript reference was accepted")
            } catch (refused: AndroidAgentTranscriptStore.Refused) {
                assertEquals(3, refused.code)
            }
        } finally { directory.deleteRecursively() }
    }
}
