package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NameValidationTest {
    private fun options(): JSONObject = JSONObject()
        .put("kind", "workspace").put("initial_text", "项目")
        .put("title", "创建工作区").put("label", "工作区名称").put("placeholder", "例如：我的项目")
        .put("hint", "为这个工作区起一个名称").put("submit_label", "创建").put("cancel_label", "取消")
        .put("empty_error", "请输入名称").put("invalid_error", "名称无效")
        .put("long_error", "名称过长").put("appearance", "dark")

    @Test fun dialogOptionsAreOneStrictLocalizedDictionary() {
        val parsed = NamePromptOptions.parse(JSONArray().put(options()))
        assertEquals("workspace", parsed.kind)
        assertEquals("项目", parsed.initialText)
        assertEquals("创建", parsed.submitLabel)
        assertEquals("取消", parsed.cancelLabel)
        assertEquals("dark", parsed.appearance)
        for (invalid in listOf(
            JSONArray(), JSONArray().put(options()).put("extra"), JSONArray().put("name"),
            JSONArray().put(options().put("kind", "message")),
            JSONArray().put(options().put("appearance", "system")),
            JSONArray().put(options().put("title", 42)),
            JSONArray().put(options().put("extra", "value")),
            JSONArray().put(options().apply { remove("cancel_label") }),
        )) {
            val error = assertThrows(BridgeFailure::class.java) { NamePromptOptions.parse(invalid) }
            assertEquals("E_BRIDGE_ARGUMENTS", error.code)
        }
    }

    @Test fun malformedUtf16IsRefusedBeforeCrossingTheRustStringBoundary() {
        for (kind in listOf("workspace", "conversation")) {
            for (text in listOf("\ud800", "\udc00", "a\ud800z", "a\udc00z")) {
                val result = NamePromptValidation.evaluate(text, kind)
                assertEquals(NameIssue.INVALID, result.issue)
                assertFalse(result.canSubmit)
                assertEquals(text, result.value)
            }
        }
    }

    @Test fun markedTextIsNeitherNormalizedNorValidatedUntilCommitted() {
        val composingText = " e\u0301" + "中".repeat(121)
        for (kind in listOf("workspace", "conversation")) {
            val result = NamePromptValidation.evaluate(composingText, kind, composing = true)
            assertEquals(NameIssue.COMPOSING, result.issue)
            assertFalse(result.canSubmit)
            assertEquals(composingText, result.value)
            // IMEs may temporarily expose an incomplete UTF-16 pair while composing.
            val incomplete = NamePromptValidation.evaluate("\ud800", kind, composing = true)
            assertEquals(NameIssue.COMPOSING, incomplete.issue)
            assertEquals("\ud800", incomplete.value)
        }
    }

    @Test fun doneCancelAndDismissSettleOnlyOnce() {
        val replies = mutableListOf<String?>()
        val done = NamePromptCompletion { replies += it }
        done.finish("中文 🚀")
        done.finish(null)
        done.finish("duplicate")
        assertTrue(done.finished)
        assertEquals(listOf("中文 🚀"), replies)
        val cancelled = NamePromptCompletion { replies += it }
        cancelled.finish(null)
        cancelled.finish("late Done")
        assertEquals(listOf("中文 🚀", null), replies)
        assertEquals("null", BridgeProtocol.encode(replies.last()))
    }
}
