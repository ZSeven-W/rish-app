package tech.zseven.rish.runtime

import org.json.JSONObject

/**
 * The committed session a request was built against, and the conversation
 * inside it.
 *
 * Mirrors `DSHAgentBatchCommittedSession` and `DSHAgentBatchConversation` in
 * modules/rish/ios/Sources/AgentToolBatchService.mm. Every agent operation
 * carries a `committed_checkpoint`: the generation and digest of the session
 * the caller read before it decided anything. Storage may have moved on since.
 * When it has, the answer is *no session*, which the core's rules turn into a
 * conflict the caller recovers from by re-reading -- never a session read
 * anyway because it is the one that happens to be there now.
 *
 * Reading the bytes is the host's job; every decision over what they say is
 * the core's. This file only finds them and parses them.
 */
internal object AndroidCommittedSession {

    /** The stored session exactly when it is the one the request names. */
    fun load(sessions: AndroidSessionStore, request: JSONObject): JSONObject? {
        val expected = request.optJSONObject("committed_checkpoint") ?: return null
        val loaded = sessions.load()
        if (loaded.optString("status") != "present") return null
        val snapshot = loaded.optJSONObject("snapshot") ?: return null
        if (snapshot.optLong("generation", -1L) != expected.optLong("session_generation", -2L) ||
            snapshot.optString("session_sha256") != expected.optString("session_sha256")
        ) {
            return null
        }
        val json = loaded.opt("session_json") as? String ?: return null
        return try {
            JSONObject(json)
        } catch (_: org.json.JSONException) {
            null
        }
    }

    /**
     * The conversation the request names. Sessions written by different
     * versions of the app spell the identity either way round, which is why
     * both are accepted here rather than one being called the real one.
     */
    fun conversation(session: JSONObject?, request: JSONObject): JSONObject? {
        val conversations = session?.optJSONArray("conversations") ?: return null
        for (index in 0 until conversations.length()) {
            val conversation = conversations.optJSONObject(index) ?: continue
            val id = conversation.opt("id") ?: conversation.opt("conversation_id")
            if (AndroidJson.equal(id, request.opt("conversation_id"))) return conversation
        }
        return null
    }

    /** The session's event log, or an empty array when it has none. */
    fun events(session: JSONObject?): org.json.JSONArray =
        session?.optJSONArray("session_events") ?: org.json.JSONArray()
}
