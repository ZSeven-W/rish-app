package tech.zseven.rish

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.*
import java.io.File
import java.security.MessageDigest
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class AndroidAgentRoundPresentationsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()
    private class Fixture(
        val directory: File, val ids: AgentSessionFixture.Ids,
        val sessions: AndroidSessionStore, val presentations: AndroidAgentRoundPresentations,
        val service: AndroidAgentQueryService, val wal: AndroidAgentWal,
    ) {
        fun request() = JSONObject().put("schema_version", 1)
            .put("conversation_id", ids.conversation).put("attempt_id", ids.attempt)
        fun cache(index: Int = 0, text: String = "你好", roundId: String = UUID.randomUUID().toString()) {
            presentations.cache(JSONObject(request().toString()).put("round_index", index).put("round_id", roundId),
                JSONObject().put("content", text).put("reasoning_content", "推理"), "final")
        }
        fun file() = File(directory, "round-presentations-v1/${ids.conversation}_${ids.attempt}.json")
    }
    private fun fixture(body: (Fixture) -> Unit) {
        check(RishAgentCoreNative.available)
        val name = "round-presentations-${uuid()}"
        val directory = File(context.noBackupFilesDir, name).apply { mkdirs() }
        val ids = AgentSessionFixture.Ids()
        val presentations = AndroidAgentRoundPresentations(directory)
        val sessions = AndroidSessionStore(context, name, onCommit = { session ->
            val conversations = session.getJSONArray("conversations")
            presentations.prune((0 until conversations.length()).map { conversations.getJSONObject(it).getString("id") }.toSet())
        })
        val wal = AndroidAgentWal(directory)
        val roots = AndroidAgentRootResolver(AndroidWorkspaceRegistry(File(directory, "workspaces")))
        val service = AndroidAgentQueryService(wal, sessions, AndroidPreparedAttemptStore(sessions, wal, roots),
            AndroidAgentExecutionLedger(wal, AndroidLiveTasks(), AndroidAgentOperations(wal)), AndroidAgentTranscriptStore(wal))
        try { body(Fixture(directory, ids, sessions, presentations, service, wal)) }
        finally { sessions.close(); context.deleteDatabase(name); directory.deleteRecursively() }
    }

    @Test fun committedConversationCanReadOrderedRoundsAfterStoreRecreationWithoutMutatingWal() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        f.cache(2, "第二轮")
        f.cache(0, "第一轮")
        val before = RishAgentCoreNative.canonical(f.wal.snapshot().toString())
        val value = f.service.readRoundPresentations(f.request())
        val rounds = value.getJSONArray("rounds")
        assertEquals(1, value.getInt("schema_version"))
        assertEquals(2, rounds.length())
        assertEquals("第一轮", rounds.getJSONObject(0).getString("text"))
        assertEquals("第二轮", rounds.getJSONObject(1).getString("text"))
        assertEquals("推理", rounds.getJSONObject(0).getString("reasoning"))
        assertEquals(value.toString(), AndroidAgentRoundPresentations(f.directory)
            .read(f.ids.conversation, f.ids.attempt, f.wal.snapshot()).toString())
        assertEquals(before, RishAgentCoreNative.canonical(f.wal.snapshot().toString()))
    }

    @Test fun gpuiRouteReachesThePresentationOwnershipGate() {
        val code = try {
            tech.zseven.rish.gpui.AgentRoutes.agent(AndroidRuntimeState.get(context),
                "read_agent_round_presentations", JSONArray().put(JSONObject().put("schema_version", 99)))
            "accepted"
        } catch (error: AndroidAgentQueryService.Refused) { error.code }
        assertEquals("E_AGENT_BAD_ARGUMENTS", code)
    }

    @Test fun requestShapeAndCommittedOwnershipAreRequired() = fixture { f ->
        f.cache()
        fun refusal(request: JSONObject): String = try { f.service.readRoundPresentations(request); "accepted" }
            catch (error: AndroidAgentQueryService.Refused) { error.code }
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal(f.request().put("schema_version", 2)))
        assertEquals("E_AGENT_BAD_ARGUMENTS", refusal(f.request().put("extra", true)))
        assertEquals("E_AGENT_UNAVAILABLE", refusal(f.request()))
        AgentSessionFixture.commit(f.sessions, f.ids)
        assertEquals("E_AGENT_NOT_FOUND", refusal(f.request().put("attempt_id", uuid())))
        assertEquals("E_AGENT_NOT_FOUND", refusal(f.request().put("conversation_id", uuid())))
        assertEquals(1, f.service.readRoundPresentations(f.request()).getJSONArray("rounds").length())
    }

    @Test fun corruptDigestsDuplicatesAndOversizeCachesAreIgnored() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        f.cache()
        val original = f.file().readText()
        val edited = JSONObject(original)
        edited.getJSONArray("rounds").getJSONObject(0).put("text", "tampered")
        f.file().writeText(edited.toString())
        assertEquals(0, f.service.readRoundPresentations(f.request()).getJSONArray("rounds").length())
        val duplicated = JSONObject(original)
        duplicated.getJSONArray("rounds").put(duplicated.getJSONArray("rounds").getJSONObject(0))
        f.file().writeText(duplicated.toString())
        assertEquals(0, f.service.readRoundPresentations(f.request()).getJSONArray("rounds").length())
        f.file().writeBytes(ByteArray(2 * 1024 * 1024 + 1))
        assertEquals(0, f.service.readRoundPresentations(f.request()).getJSONArray("rounds").length())
    }

    @Test fun rawCacheRejectsDuplicateKeysAndNonIntegerIndicesBeforeHostParsing() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        f.cache()
        val original = f.file().readText()
        val invalid = listOf(
            original.replace("\"schema_version\":1", "\"schema_version\":1,\"schema_version\":1"),
            original.replace("\"round_index\":0", "\"round_index\":0,\"round_index\":0"),
            original.replace("\"round_index\":0", "\"round_index\":0.0"),
            original.replace("\"round_index\":0", "\"round_index\":-0"),
            original.replace("\"round_index\":0", "\"round_index\":false"),
        )
        invalid.forEach { raw ->
            assertNotEquals(original, raw)
            f.file().writeText(raw)
            assertEquals(raw, 0, f.service.readRoundPresentations(f.request()).getJSONArray("rounds").length())
        }
    }

    @Test fun hostNumericTypesCannotBeNormalizedIntoAnAcceptedInteger() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        f.cache(text = "retained")
        val original = f.file().readText()
        for (index in listOf<Any>(1.0, -0.0, true, "1", 8, -1)) {
            f.presentations.cache(f.request().put("round_id", uuid()).put("round_index", index),
                JSONObject().put("content", "invalid").put("reasoning_content", ""), "final")
            assertEquals("index=$index", original, f.file().readText())
        }
    }

    @Test fun rawUtf8CannotBeRepairedIntoTextWithAnOtherwiseValidDigest() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        f.cache(text = "\uFFFD")
        val original = f.file().readText()
        val marker = original.indexOf('\uFFFD')
        assertTrue(marker >= 0)
        f.file().writeBytes(original.substring(0, marker).toByteArray(Charsets.UTF_8) +
            byteArrayOf(0xff.toByte()) + original.substring(marker + 1).toByteArray(Charsets.UTF_8))
        assertEquals(0, f.service.readRoundPresentations(f.request()).getJSONArray("rounds").length())
    }

    @Test fun sharedDigestsKeepUnicodeNulAndWhitespaceExact() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        val text = "  你好🐦\u0000\n尾部  "
        f.cache(text = text)
        val round = f.service.readRoundPresentations(f.request()).getJSONArray("rounds").getJSONObject(0)
        assertEquals(text, round.getString("text"))
        val expected = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        assertEquals(expected, round.getString("assistant_text_sha256"))
    }

    @Test fun upsertRejectsRoundIdentityReuseAndHostKeepsItsEncodedFileBudget() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        val roundId = uuid()
        f.cache(text = "retained", roundId = roundId)
        val original = f.file().readText()
        f.cache(index = 1, text = "reused", roundId = roundId)
        assertEquals(original, f.file().readText())
        // The record fits the core's text limit, but JSON escaping exceeds the host file limit.
        f.cache(text = "\"".repeat(1100 * 1024))
        assertEquals(original, f.file().readText())
        f.cache(text = "x".repeat(2 * 1024 * 1024 + 1))
        assertEquals(original, f.file().readText())
    }

    @Test fun walProjectionOverridesCacheAndSelectsTheLastMatchingAssistant() = fixture { f ->
        val roundId = uuid()
        val reference = uuid()
        f.cache(text = "cached", roundId = roundId)
        val messages = JSONArray()
            .put(JSONObject().put("role", "assistant").put("round_index", 0)
                .put("content", "earlier").put("reasoning_content", ""))
            .put(JSONObject().put("role", "assistant").put("round_index", 0)
                .put("content", "from WAL").put("reasoning_content", "WAL reasoning"))
            .put(JSONObject().put("role", "user").put("round_index", 0).put("content", "ignored"))
        val state = JSONObject().put("rounds", JSONArray().put(JSONObject()
            .put("locator", JSONObject().put("attempt_id", f.ids.attempt)
                .put("round_id", roundId).put("round_index", 0))
            .put("state", "completed").put("terminal_kind", "final")
            .put("transcript_after", JSONObject().put("transcript_ref", reference).put("generation", 1))))
            .put("transcripts", JSONArray().put(JSONObject().put("attempt_id", f.ids.attempt)
                .put("transcript_ref", reference).put("generation", 2).put("messages", messages)))
        val before = RishAgentCoreNative.canonical(state.toString())
        val rounds = f.presentations.read(f.ids.conversation, f.ids.attempt, state).getJSONArray("rounds")
        assertEquals(1, rounds.length())
        assertEquals("from WAL", rounds.getJSONObject(0).getString("text"))
        assertEquals("WAL reasoning", rounds.getJSONObject(0).getString("reasoning"))
        assertEquals(before, RishAgentCoreNative.canonical(state.toString()))
        assertEquals("cached", JSONObject(f.file().readText()).getJSONArray("rounds").getJSONObject(0).getString("text"))
    }

    @Test fun walProjectionDoesNotInheritTheEncodedCacheFileBudget() = fixture { f ->
        val reference = uuid()
        val text = "x".repeat(1100 * 1024)
        val rows = JSONArray()
        val messages = JSONArray()
        for (index in 0..1) {
            rows.put(JSONObject().put("locator", JSONObject().put("attempt_id", f.ids.attempt)
                .put("round_id", uuid()).put("round_index", index))
                .put("state", "completed").put("terminal_kind", "final")
                .put("transcript_after", JSONObject().put("transcript_ref", reference).put("generation", 1)))
            messages.put(JSONObject().put("role", "assistant").put("round_index", index)
                .put("content", text).put("reasoning_content", ""))
        }
        val state = JSONObject().put("rounds", rows).put("transcripts", JSONArray().put(JSONObject()
            .put("attempt_id", f.ids.attempt).put("transcript_ref", reference).put("generation", 1)
            .put("messages", messages)))
        val projected = f.presentations.read(f.ids.conversation, f.ids.attempt, state)
        assertEquals(2, projected.getJSONArray("rounds").length())
        assertEquals(text.length, projected.getJSONArray("rounds").getJSONObject(1).getString("text").length)
        assertTrue(projected.toString().toByteArray(Charsets.UTF_8).size > 2 * 1024 * 1024)
        assertFalse(f.file().exists())
    }

    @Test fun cachedTextCannotEscapeThroughSymlinkOrInvalidIdentifiers() = fixture { f ->
        AgentSessionFixture.commit(f.sessions, f.ids)
        f.cache()
        val outside = File(f.directory, "private.json").apply { writeText(f.file().readText()) }
        f.file().delete()
        Os.symlink(outside.path, f.file().path)
        assertEquals(0, f.service.readRoundPresentations(f.request()).getJSONArray("rounds").length())
        val original = outside.readText()
        f.cache(text = "updated")
        assertEquals(original, outside.readText())
        assertEquals("updated", f.service.readRoundPresentations(f.request()).getJSONArray("rounds").getJSONObject(0).getString("text"))
        f.presentations.cache(f.request().put("attempt_id", "../../private").put("round_id", uuid()).put("round_index", 0),
            JSONObject().put("content", "bad").put("reasoning_content", ""), "final")
        assertEquals(original, outside.readText())
    }

    @Test fun committedConversationDeletionPrunesCacheAndRevokesReads() = fixture { f ->
        val snapshot = AgentSessionFixture.commit(f.sessions, f.ids)
        f.cache()
        val deleted = AgentSessionFixture.session(f.ids).put("conversations", JSONArray())
        val result = f.sessions.persist(JSONObject().put("schema_version", 1).put("operation_id", uuid())
            .put("expected", AgentSessionFixture.expecting(snapshot))
            .put("candidate_json", RishAgentCoreNative.canonical(deleted.toString())))
        assertEquals("committed", result.getString("status"))
        assertFalse(f.file().exists())
        val code = try { f.service.readRoundPresentations(f.request()); "accepted" }
            catch (error: AndroidAgentQueryService.Refused) { error.code }
        assertEquals("E_AGENT_NOT_FOUND", code)
    }

    @Test fun retentionIsBoundedAndPruningPreservesOtherConversations() = fixture { f ->
        for (i in 0..256) f.presentations.cache(JSONObject().put("conversation_id", uuid()).put("attempt_id", uuid())
            .put("round_id", uuid()).put("round_index", 0), JSONObject().put("content", "round $i").put("reasoning_content", ""), "final")
        val directory = File(f.directory, "round-presentations-v1")
        assertEquals(256, directory.listFiles()!!.size)
        f.cache()
        f.presentations.prune(setOf(f.ids.conversation))
        assertEquals(1, directory.listFiles()!!.size)
        assertTrue(f.file().exists())
    }
}
