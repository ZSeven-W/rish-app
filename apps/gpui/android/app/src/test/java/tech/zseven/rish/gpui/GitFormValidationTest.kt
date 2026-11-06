package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class GitFormValidationTest {
    private fun options(kind: String = "commit"): JSONObject = JSONObject()
        .put("kind", kind).put("appearance", "dark").put("title", "提交更改")
        .put("submit_label", "提交").put("cancel_label", "取消").put("hint", "提交到本机仓库")
        .put("invalid_message", "请检查输入")
        .put("fields", JSONArray().apply {
            val keys = if (kind == "commit") listOf("message", "author_name", "author_email") else listOf("url")
            keys.forEach { put(JSONObject().put("key", it).put("label", it).put("placeholder", "输入 $it").put("value", "")) }
        })

    private fun commit(message: String = "提交修改", name: String = "作者", email: String = "user@example.com") =
        GitFormValidation.evaluate("commit", listOf(message, name, email))

    @Test fun acceptsOnlyOneStrictOptionsObjectAndOrderedFields() {
        val parsed = GitFormOptions.parse(JSONArray().put(options()))
        assertEquals("提交更改", parsed.title)
        assertEquals(listOf("message", "author_name", "author_email"), parsed.fields.map { it.key })
        assertEquals(listOf("url"), GitFormOptions.parse(JSONArray().put(options("remote"))).fields.map { it.key })
        val invalid = listOf(
            JSONArray(), JSONArray().put(options()).put(options()), JSONArray().put("text"),
            JSONArray().put(options().put("kind", "password")),
            JSONArray().put(options().put("appearance", "system")),
            JSONArray().put(options().put("secret", "no")),
            JSONArray().put(options().put("title", 42)),
            JSONArray().put(options().apply { remove("hint") }),
            JSONArray().put(options().put("fields", JSONArray())),
            JSONArray().put(options().apply { getJSONArray("fields").getJSONObject(0).put("key", "author_name") }),
            JSONArray().put(options().apply { getJSONArray("fields").getJSONObject(0).put("value", 7) }),
            JSONArray().put(options().apply { getJSONArray("fields").getJSONObject(0).put("extra", "no") }),
            JSONArray().put(options("remote").apply { getJSONArray("fields").put(JSONObject().put("key", "token")) }),
        )
        invalid.forEach { assertEquals("E_BRIDGE_ARGUMENTS", assertThrows(BridgeFailure::class.java) { GitFormOptions.parse(it) }.code) }
    }

    @Test fun returnsOnlyTrimmedNfcMetadata() {
        val reply = commit("\t Cafe\u0301 更新 \n", "\u0085\u00a0Cafe\u0301\u3000", " user@example.com ")!!
        assertEquals(setOf("message", "author_name", "author_email"), reply.keys().asSequence().toSet())
        assertEquals("Café 更新", reply.getString("message"))
        assertEquals("Café", reply.getString("author_name"))
        assertEquals("user@example.com", reply.getString("author_email"))
        assertNull(commit(message = " \u00a0 "))
        assertNull(commit(name = ""))
        assertNull(commit(email = ""))
    }

    @Test fun commitBoundsCountUtf8BytesAfterNfc() {
        assertNotNull(commit(message = "a".repeat(500)))
        assertNull(commit(message = "a".repeat(501)))
        assertNotNull(commit(message = "🚀".repeat(125)))
        assertNull(commit(message = "🚀".repeat(126)))
        assertNotNull(commit(name = "中".repeat(40)))
        assertNull(commit(name = "中".repeat(41)))
        assertNotNull(commit(name = "e\u0301".repeat(60)))
        assertNotNull(commit(email = "a".repeat(252) + "@b"))
        assertNull(commit(email = "a".repeat(253) + "@b"))
    }

    @Test fun rejectsMultilineAndSignatureInjectionAndMalformedUnicode() {
        for (bad in listOf("a\nb", "a\rb", "a\tb", "a\u0000b", "a\u007fb", "a\u0085b", "a\u2028b", "a\u2029b", "a\u200db", "a\u202eb", "\ud800", "\udc00")) {
            assertNull(bad, commit(message = bad))
            assertNull(bad, commit(name = bad))
            assertNull(bad, commit(email = "$bad@example.com"))
        }
        for (bad in listOf("a<b", "a>b")) assertNull(commit(name = bad))
        for (bad in listOf("a b@c", "a\u00a0b@c", "a<b@c", "a>b@c", "a@@b", "@b", "a@", "abc")) assertNull(commit(email = bad))
    }

    @Test fun malformedRemoteUtf16NeverCrossesTheRustStringBoundary() {
        for (url in listOf("https://github.com/\ud800", "https://github.com/\udc00", "https://github.com/a\ud800z")) {
            assertNull(GitFormValidation.evaluate("remote", listOf(url)))
        }
    }

    @Test fun markedTextCannotSubmitAndCancelSettlesOnce() {
        assertNull(GitFormValidation.evaluate("commit", listOf("更新", "作者", "a@b"), composing = true))
        assertNull(GitFormValidation.evaluate("remote", listOf("https://github.com/org/repo"), composing = true))
        assertNull(GitFormValidation.evaluate("commit", listOf("更新")))
        assertNull(GitFormValidation.evaluate("unknown", listOf("更新")))
        val replies = mutableListOf<JSONObject?>()
        val completion = GitFormCompletion { replies.add(it) }
        val accepted = commit()!!
        completion.finish(accepted)
        completion.finish(null)
        assertTrue(completion.finished)
        assertEquals(listOf(accepted), replies)
        val cancelled = GitFormCompletion { replies.add(it) }
        cancelled.finish(null)
        cancelled.finish(accepted)
        assertEquals(listOf(accepted, null), replies)
    }
}
