package tech.zseven.rish.gpui

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.RishAgentCoreNative

/** Runs the staged Rust policy and the UI adapter together; no injected acceptance or skips. */
@RunWith(AndroidJUnit4::class)
class SharedNamePolicyTest {
    @Before fun requireSharedNativePolicy() {
        assertTrue("The shared Rust agent core must be packaged for this acceptance gate", RishAgentCoreNative.available)
    }

    private fun check(kind: String, input: String, normalized: String, issue: NameIssue = NameIssue.NONE) {
        val request = JSONObject().put("kind", kind).put("text", input)
        val json = RishAgentCoreNative.namePolicy(request.toString())
        assertNotNull("The JNI name policy must return an envelope", json)
        val reply = JSONObject(json!!)
        assertEquals(setOf("ok", "value"), reply.keys().asSequence().toSet())
        assertEquals(true, reply.get("ok"))
        val value = reply.getJSONObject("value")
        assertEquals(setOf("text", "issue"), value.keys().asSequence().toSet())
        assertEquals(normalized, value.getString("text"))
        val expectedIssue = when (issue) {
            NameIssue.NONE -> JSONObject.NULL
            NameIssue.EMPTY -> "empty"
            NameIssue.INVALID -> "invalid"
            NameIssue.TOO_LONG -> "too_long"
            NameIssue.COMPOSING -> error("Marked text never enters the shared policy")
        }
        assertEquals(expectedIssue, value.get("issue"))
        val adapter = NamePromptValidation.evaluate(input, kind)
        assertEquals(normalized, adapter.value)
        assertEquals(issue, adapter.issue)
        assertEquals(issue == NameIssue.NONE, adapter.canSubmit)
    }

    @Test fun normalizationAndUnicodeWhitespaceComeFromTheSharedPolicy() {
        for (kind in listOf("workspace", "conversation")) {
            check(kind, "\u0085\u00a0 Cafe\u0301 中文 🚀 \u3000", "Café 中文 🚀")
            check(kind, "项目", "项目")
            check(kind, "", "", NameIssue.EMPTY)
            check(kind, " \t\n\u0085\u00a0\u1680\u2000\u2028\u202f\u205f\u3000", "", NameIssue.EMPTY)
        }
        check("conversation", " 👩‍💻 与家人 👨‍👩‍👧‍👦 ", "👩‍💻 与家人 👨‍👩‍👧‍👦")
    }

    @Test fun bothKindsUse120Utf8BytesAfterNfcWithoutTruncation() {
        for (kind in listOf("workspace", "conversation")) {
            for ((accepted, rejected) in listOf(
                "a".repeat(120) to "a".repeat(121),
                "中".repeat(40) to "中".repeat(41),
                "🚀".repeat(30) to "🚀".repeat(31),
                "é".repeat(60) to "é".repeat(61),
            )) {
                check(kind, accepted, accepted)
                check(kind, rejected, rejected, NameIssue.TOO_LONG)
            }
            check(kind, "e\u0301".repeat(60), "é".repeat(60))
            check(kind, "e\u0301".repeat(61), "é".repeat(61), NameIssue.TOO_LONG)
        }
    }

    @Test fun internalControlsAndLineBreaksAreRefusedWithoutBeingTrimmedAway() {
        for (kind in listOf("workspace", "conversation")) {
            for (text in listOf("a\nb", "a\rb", "a\tb", "a\u0000b", "a\u007fb", "a\u0085b", "a\u2028b", "a\u2029b", "\u001cname")) {
                check(kind, text, text, NameIssue.INVALID)
            }
        }
    }

    @Test fun workspaceRestrictionsDoNotAccidentallyApplyToConversationTitles() {
        for (name in listOf(".", "..", ".hidden", "a/b", "a\\b", "a:b", "a\u200bb",
            "Rish Workspaces", "RISH WORKSPACES", "Rísh Wórkspaces", ".rish-owned", "👩‍💻")) {
            check("workspace", name, name, NameIssue.INVALID)
        }
        for (name in listOf(".notes", "a/b", "Rish Workspaces")) check("conversation", name, name)
    }

    @Test fun malformedOrAmbiguousNativeRequestsFailRatherThanSelectingAnotherRule() {
        for (request in listOf("null", "{}", "{", "{\"kind\":\"file\",\"text\":\"name\"}",
            "{\"kind\":\"workspace\",\"text\":null}",
            "{\"kind\":\"workspace\",\"text\":\"name\",\"extra\":true}",
            "{\"kind\":\"workspace\",\"text\":\"first\",\"text\":\"second\"}",
            "{\"kind\":\"workspace\",\"text\":\"\\ud800\"}")) {
            val reply = JSONObject(RishAgentCoreNative.namePolicy(request)!!)
            assertEquals(setOf("ok", "error"), reply.keys().asSequence().toSet())
            assertEquals(false, reply.get("ok"))
            assertEquals("E_NAME_POLICY_ARGUMENTS", reply.getString("error"))
        }
    }
}
