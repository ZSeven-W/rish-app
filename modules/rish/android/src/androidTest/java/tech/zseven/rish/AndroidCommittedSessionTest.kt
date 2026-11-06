package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.MediumTest
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidCommittedSession
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.util.UUID

/**
 * Finding the committed session a request was built against.
 *
 * Every agent operation on this platform reads it: the round relates the model
 * call to a conversation, the batch gate refuses without one, and the
 * execution relates a call to the batch the person approved. So a host that
 * cannot find a session that *is* there shuts the whole agent path -- silently,
 * because every layer above reports the same refusal it would report for a
 * genuinely stale one.
 *
 * **These tests assert the session is found.** That is deliberate. The three
 * services were each written against a `load()` reply that has no
 * `conversation` key, so each read null forever and refused every request; the
 * tests around them all asserted that *a refusal happened*, which stayed true.
 * A refusal is only evidence when the same code can also be shown not to
 * refuse.
 */
@RunWith(AndroidJUnit4::class)
@MediumTest
class AndroidCommittedSessionTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun store(): AndroidSessionStore {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        return AndroidSessionStore(context, "committed-session-${UUID.randomUUID()}")
    }

    private fun request(ids: AgentSessionFixture.Ids, checkpoint: JSONObject): JSONObject =
        JSONObject().put("schema_version", 2)
            .put("committed_checkpoint", checkpoint)
            .put("task_id", ids.task)
            .put("conversation_id", ids.conversation)
            .put("attempt_id", ids.attempt)

    /** The whole point: a committed session is found, and so is its conversation. */
    @Test
    fun theCommittedSessionAndItsConversationAreFound() {
        val sessions = store()
        val ids = AgentSessionFixture.Ids()
        val snapshot = AgentSessionFixture.commit(sessions, ids)
        val request = request(ids, AgentSessionFixture.checkpoint(snapshot))

        val session = AndroidCommittedSession.load(sessions, request)
        assertNotNull("the session that was just committed must be readable", session)

        val conversation = AndroidCommittedSession.conversation(session, request)
        assertNotNull("the conversation the request names must be found", conversation)
        assertEquals(ids.conversation, conversation!!.getString("id"))
        assertNotNull(AndroidCommittedSession.events(session))
    }

    /**
     * A checkpoint naming a generation storage has moved past reads as absent.
     * This is the rule the services depend on: they must not decide over a
     * session the caller never saw.
     */
    @Test
    fun aCheckpointStorageHasMovedPastReadsAsAbsent() {
        val sessions = store()
        val ids = AgentSessionFixture.Ids()
        val first = AgentSessionFixture.commit(sessions, ids)
        val stale = request(ids, AgentSessionFixture.checkpoint(first))
        assertNotNull(AndroidCommittedSession.load(sessions, stale))

        // A second commit moves the session on. The first checkpoint is now a
        // description of a session that is no longer stored.
        val second = AgentSessionFixture.commit(
            sessions, ids, epoch = 1, expected = AgentSessionFixture.expecting(first),
        )
        assertNull(
            "a superseded checkpoint must not resolve to the newer session",
            AndroidCommittedSession.load(sessions, stale),
        )
        assertNotNull(
            AndroidCommittedSession.load(sessions, request(ids, AgentSessionFixture.checkpoint(second))),
        )
    }

    /** A digest that does not match the stored bytes is not this session. */
    @Test
    fun aCheckpointWithTheWrongDigestReadsAsAbsent() {
        val sessions = store()
        val ids = AgentSessionFixture.Ids()
        val snapshot = AgentSessionFixture.commit(sessions, ids)
        val forged = AgentSessionFixture.checkpoint(snapshot).put("session_sha256", "0".repeat(64))
        assertNull(AndroidCommittedSession.load(sessions, request(ids, forged)))
    }

    /** A conversation this session does not carry is not invented. */
    @Test
    fun aConversationTheSessionDoesNotCarryIsNotFound() {
        val sessions = store()
        val ids = AgentSessionFixture.Ids()
        val snapshot = AgentSessionFixture.commit(sessions, ids)
        val stranger = request(ids, AgentSessionFixture.checkpoint(snapshot))
            .put("conversation_id", UUID.randomUUID().toString())
        val session = AndroidCommittedSession.load(sessions, stranger)
        assertNotNull(session)
        assertNull(AndroidCommittedSession.conversation(session, stranger))
    }

    /** With nothing committed there is no session, and no exception either. */
    @Test
    fun anEmptyStoreHasNoCommittedSession() {
        val sessions = store()
        val ids = AgentSessionFixture.Ids()
        val checkpoint = JSONObject().put("schema_version", 1)
            .put("session_generation", 1).put("session_sha256", "0".repeat(64))
        assertNull(AndroidCommittedSession.load(sessions, request(ids, checkpoint)))
    }
}
