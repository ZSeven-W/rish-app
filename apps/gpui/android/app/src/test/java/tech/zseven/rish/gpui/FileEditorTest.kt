package tech.zseven.rish.gpui

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FileEditorTest {
    private fun options(): JSONObject = JSONObject().put("initial_text", "中文\r\n  value = 1\n")
        .put("title", "notes.txt").put("appearance", "dark").put("save_label", "保存")
        .put("cancel_label", "取消").put("max_bytes", 262144).put("too_long_message", "文件太大")

    @Test fun editorOptionsAreStrictAndByteLimitCannotBeBypassed() {
        val parsed = FileEditorOptions.parse(JSONArray().put(options()))
        assertEquals("中文\r\n  value = 1\n", parsed.initialText)
        assertEquals(262144, parsed.maxBytes)
        assertEquals("保存", parsed.saveLabel)
        assertEquals("dark", parsed.appearance)
        val invalid = mutableListOf(JSONArray(), JSONArray().put("text"), JSONArray().put(options()).put(options()),
            JSONArray().put(options().put("appearance", "system")), JSONArray().put(options().put("title", true)),
            JSONArray().put(options().put("extra", "value")), JSONArray().put(options().apply { remove("cancel_label") }))
        for (limit in listOf(0, -1, 262145, Long.MAX_VALUE, 1.5, 1.0, "262144", true, JSONObject.NULL))
            invalid += JSONArray().put(options().put("max_bytes", limit))
        for (args in invalid) {
            assertEquals("E_BRIDGE_ARGUMENTS",
                assertThrows(BridgeFailure::class.java) { FileEditorOptions.parse(args) }.code)
        }
        assertEquals(1, FileEditorOptions.parse(JSONArray().put(options().put("max_bytes", 1)
            .put("initial_text", ""))).maxBytes)
    }

    @Test fun initialTextMustBeWithinByteLimitAndLosslesslyEncodable() {
        for (text in listOf("中", "aa", "\ud800", "\udc00", "a\ud800b", "\udc00\ud800")) {
            val args = JSONArray().put(options().put("max_bytes", 1).put("initial_text", text))
            assertEquals("E_BRIDGE_ARGUMENTS",
                assertThrows(BridgeFailure::class.java) { FileEditorOptions.parse(args) }.code)
        }
        for (text in listOf("\ud800", "\udc00", "a\ud800b", "\udc00\ud800")) {
            assertFalse(FileEditorValidation.evaluate(text, 262144).canSave)
            assertEquals("E_BRIDGE_ARGUMENTS", assertThrows(BridgeFailure::class.java) {
                FileEditorOptions.parse(JSONArray().put(options().put("initial_text", text)))
            }.code)
        }
        val valid = "\ud83d\ude80 Cafe\u0301\r\n  中文\n"
        assertTrue(FileEditorValidation.evaluate(valid, valid.toByteArray(Charsets.UTF_8).size).canSave)
        assertEquals(valid, FileEditorOptions.parse(JSONArray().put(options().put("initial_text", valid))).initialText)
    }

    @Test fun limitsCountUtf8BytesAndAllowEmptyFiles() {
        for (text in listOf("", "a".repeat(262144), "中".repeat(87381) + "a", "🚀".repeat(65536))) {
            assertTrue(FileEditorValidation.evaluate(text, 262144).canSave)
        }
        for (text in listOf("a".repeat(262145), "中".repeat(87382), "🚀".repeat(65536) + "a")) {
            val state = FileEditorValidation.evaluate(text, 262144)
            assertFalse(state.canSave)
            assertTrue(state.tooLong)
        }
        assertFalse(FileEditorValidation.evaluate("中", 2).canSave)
        assertTrue(FileEditorValidation.evaluate("中", 3).canSave)
    }

    @Test fun markedTextCannotBeSavedOrReportedOversizeUntilCommitted() {
        val composition = "中".repeat(87382)
        val marked = FileEditorValidation.evaluate(composition, 262144, composing = true)
        assertFalse(marked.canSave)
        assertFalse(marked.tooLong)
        assertTrue(FileEditorValidation.evaluate(composition, 262144).tooLong)
        assertFalse(FileEditorValidation.evaluate("中文", 262144, composing = true).canSave)
        assertTrue(FileEditorValidation.evaluate("中文", 262144).canSave)
    }

    @Test fun savedTextIsLosslessAndCompletionCannotBeOverwrittenByDismissal() {
        val text = "  # 中文 👩‍💻\r\n\tCafe\u0301\n\n"
        val replies = mutableListOf<String?>()
        val completion = FileEditorCompletion { replies += it }
        completion.finish(text)
        completion.finish(null)
        completion.finish("late value")
        assertEquals(listOf(text), replies)
        assertTrue(completion.finished)
        assertEquals(text, JSONArray("[${BridgeProtocol.encode(replies.single())}]").getString(0))
        val cancelled = FileEditorCompletion { replies += it }
        cancelled.finish(null)
        cancelled.finish(text)
        assertEquals(listOf(text, null), replies)
    }
}
