package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidSessionStore
import tech.zseven.rish.runtime.RishAgentCoreNative
import java.util.UUID

/**
 * The agent's Git proxy is the one the last committed session holds: the
 * executor reads it from there, so a turn's remote traffic goes where the
 * panel's does. Nothing committed, or no proxy, is none.
 */
@RunWith(AndroidJUnit4::class)
class AndroidSessionGitProxyTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun committed(store: AndroidSessionStore, proxy: Any?) {
        val session = AgentSessionFixture.session(AgentSessionFixture.Ids())
        if (proxy != null) session.getJSONObject("preferences").put("git_https_proxy_url", proxy)
        val candidate = RishAgentCoreNative.canonical(session.toString()) ?: error("not canonicalisable")
        val reply = store.persist(
            JSONObject().put("schema_version", 1).put("operation_id", UUID.randomUUID().toString())
                .put("expected", JSONObject().put("schema_version", 1).put("kind", "missing"))
                .put("candidate_json", candidate),
        )
        assertEquals(reply.toString(), "committed", reply.getString("status"))
    }

    @Test
    fun theCommittedSessionsProxyIsTheAgentsProxy() {
        assumeTrue("rish agent core is not staged in this build", RishAgentCoreNative.available)
        val empty = AndroidSessionStore(context, "git-proxy-${UUID.randomUUID()}")
        assertNull(empty.committedGitProxy())
        val none = AndroidSessionStore(context, "git-proxy-${UUID.randomUUID()}")
        committed(none, null)
        assertNull(none.committedGitProxy())
        val set = AndroidSessionStore(context, "git-proxy-${UUID.randomUUID()}")
        committed(set, "http://10.0.2.2:7897")
        assertEquals("http://10.0.2.2:7897/", set.committedGitProxy())
    }
}
