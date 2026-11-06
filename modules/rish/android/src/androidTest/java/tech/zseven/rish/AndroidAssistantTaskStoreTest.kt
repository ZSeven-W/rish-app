package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidAssistantTaskExecutor
import tech.zseven.rish.runtime.AndroidWorkspaceToolExecutor
import tech.zseven.rish.runtime.RishAgentCoreNative
import tech.zseven.rish.runtime.RishAssistantStoreNative
import java.io.File
import java.util.UUID

/** Real GPUI JNI and Rust store in a disposable directory, never the person's store. */
@RunWith(AndroidJUnit4::class)
class AndroidAssistantTaskStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun uuid() = UUID.randomUUID().toString()

    private inner class Fixture : AutoCloseable {
        val directory = File(context.noBackupFilesDir, "assistant-tools-test-${uuid()}").apply { mkdirs() }.canonicalFile
        val file = File(directory, "assistant-v1.json")
        val chat = uuid()
        val workspace = uuid()
        val conversation = JSONObject().put("id", chat).put("model_id", "deepseek-v4-flash")
            .put("workspace_binding", JSONObject().put("schema_version", 1).put("workspace_id", workspace)
                .put("binding_revision", 1).put("project_id", JSONObject.NULL))
        val descriptor = JSONObject().put("schema_version", 2).put("workspace_id", workspace)
            .put("binding_revision", 1).put("status", "ok").put("display_name", "Native test")
            .put("capabilities", JSONObject().put("read", true).put("write", true))
        val authority = JSONObject().put("conversation_id", chat).put("registry", JSONObject().put("registry_version", 5))
            .put("root", JSONObject().put("workspace_id", workspace).put("workspace_binding_revision", 1)
                .put("project_id", JSONObject.NULL).put("capabilities", JSONArray().put("file_read")))
        var applyCalls = 0
        var loseReply = false
        init {
            assertTrue("Shared agent library must be staged", RishAgentCoreNative.available)
            assertTrue("GPUI Rust library must be staged", RishAssistantStoreNative.available)
            // Test fixture only. Production allocates this identity through
            // AssistantStore.ensure_conversation, never through model tools.
            file.writeText(JSONObject().put("schema_version", 1).put("revision", 1)
                .put("profile", JSONObject().put("name", "Rish").put("notes", ""))
                .put("conversation_id", chat).put("tasks", JSONArray()).put("clock_high_water_ms", 0).toString())
        }
        fun executor() = AndroidAssistantTaskExecutor({ request ->
            val reply = JSONObject(RishAssistantStoreNative.call(directory.path, request.toString()))
            if (request.optString("action") == "apply") {
                applyCalls++
                if (loseReply) { loseReply = false; throw IllegalStateException("injected reply loss") }
            }
            reply
        }) { descriptor }
        fun snapshot() = JSONObject(file.readText())
        fun call(name: String, args: JSONObject) = JSONObject().put("name", name).put("arguments", args)
            .put("arguments_sha256", RishAgentCoreNative.hash("tool-arguments", JSONObject().put("name", name).put("arguments", args)))
        fun row(call: JSONObject, precondition: JSONObject): JSONObject {
            val locator = JSONObject().put("schema_version", 2).put("task_id", uuid()).put("attempt_id", uuid())
                .put("round_id", uuid()).put("round_index", 0).put("call_index", 0).put("call_id", "call-test")
                .put("idempotency_key", RishAgentCoreNative.hash("test-idempotency", JSONObject().put("id", uuid())))
            return JSONObject().put("locator", locator).put("name", call.get("name"))
                .put("arguments_sha256", call.get("arguments_sha256")).put("precondition", precondition)
        }
        fun request(row: JSONObject) = JSONObject(row.getJSONObject("locator").toString()).put("conversation_id", chat)
            .put("name", row.get("name")).put("arguments_sha256", row.get("arguments_sha256"))
        override fun close() { directory.deleteRecursively() }
    }

    @Test fun privateScopeAndPrepareCannotCreateTasks() {
        Fixture().use { fixture ->
            val executor = fixture.executor()
            val before = fixture.file.readText()
            assertTrue(executor.scopeAllowed(5, fixture.conversation))
            assertEquals("Rish", executor.assistantContext(fixture.conversation)!!.getString("name"))
            assertFalse(executor.scopeAllowed(5, JSONObject(fixture.conversation.toString()).put("id", uuid())))
            val call = fixture.call("create_assistant_task", JSONObject().put("title", "Review build").put("instructions", "Check the build"))
            val ordinary = JSONObject(fixture.authority.toString()).put("registry", JSONObject().put("registry_version", 4))
            assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) { executor.prepare(call, fixture.conversation, ordinary) }
            val prepared = executor.prepare(call, fixture.conversation, fixture.authority)
            assertEquals(1, prepared.getJSONObject("precondition").getLong("expected_store_revision"))
            assertEquals(before, fixture.file.readText())
            assertEquals(0, fixture.applyCalls)
        }
    }

    @Test fun lostCreateReplyAndRestartReuseTheAtomicReceipt() {
        Fixture().use { fixture ->
            val executor = fixture.executor()
            val call = fixture.call("create_assistant_task", JSONObject().put("title", "Review build").put("instructions", "Check the build")
                .put("follow_up_minutes", 30))
            val precondition = executor.prepare(call, fixture.conversation, fixture.authority).getJSONObject("precondition")
            val row = fixture.row(call, precondition)
            val request = fixture.request(row)
            fixture.loseReply = true
            val effect = executor.execute(request, call.getJSONObject("arguments"), row, fixture.conversation, fixture.authority)
            val after = fixture.file.readText()
            assertEquals(1, fixture.applyCalls)
            val saved = fixture.snapshot()
            assertEquals(1, saved.getJSONArray("tasks").length())
            assertEquals(1, saved.getJSONArray("tool_receipts").length())
            assertEquals("deepseek-v4-flash", saved.getJSONArray("tasks").getJSONObject(0).getString("model_id"))
            assertEquals(30, saved.getJSONArray("tasks").getJSONObject(0).getInt("interval_minutes"))
            val restarted = fixture.executor()
            val recovered = restarted.recover(request, call.getJSONObject("arguments"), row, fixture.conversation, fixture.authority)
            assertEquals("settled", recovered.getString("status"))
            assertEquals(effect.toString(), recovered.getJSONObject("effect").toString())
            assertEquals(effect.toString(), restarted.execute(request, call.getJSONObject("arguments"), row, fixture.conversation, fixture.authority).toString())
            assertEquals(after, fixture.file.readText())
        }
    }

    @Test fun createListUpdateUseNativeContextAndRejectForgedReceiptIdentity() {
        Fixture().use { fixture ->
            val executor = fixture.executor()
            fun apply(name: String, arguments: JSONObject): JSONObject {
                val call = fixture.call(name, arguments)
                val row = fixture.row(call, executor.prepare(call, fixture.conversation, fixture.authority).getJSONObject("precondition"))
                return executor.execute(fixture.request(row), arguments, row, fixture.conversation, fixture.authority)
            }
            val created = apply("create_assistant_task", JSONObject().put("title", "Review build").put("instructions", "Check the build"))
            val taskId = JSONObject(created.getString("feedback")).getJSONObject("payload").getString("task_id")
            val listed = apply("list_assistant_tasks", JSONObject())
            assertEquals(taskId, JSONObject(listed.getString("feedback")).getJSONObject("payload").getJSONArray("tasks").getJSONObject(0).getString("task_id"))
            val args = JSONObject().put("task_id", taskId).put("title", "Updated build").put("paused", true)
            val update = fixture.call("update_assistant_task", args)
            val row = fixture.row(update, executor.prepare(update, fixture.conversation, fixture.authority).getJSONObject("precondition"))
            val request = fixture.request(row)
            val changed = executor.execute(request, args, row, fixture.conversation, fixture.authority)
            val after = fixture.file.readText()
            assertEquals("Updated build", fixture.snapshot().getJSONArray("tasks").getJSONObject(0).getString("title"))
            assertFalse(fixture.snapshot().getJSONArray("tasks").getJSONObject(0).getBoolean("enabled"))
            assertEquals(changed.toString(), fixture.executor().execute(request, args, row, fixture.conversation, fixture.authority).toString())
            assertEquals(after, fixture.file.readText())
            assertThrows(AndroidWorkspaceToolExecutor.Refused::class.java) {
                fixture.executor().recover(JSONObject(request.toString()).put("call_id", "forged"), args, row, fixture.conversation, fixture.authority)
            }
            assertEquals(after, fixture.file.readText())
        }
    }

    @Test fun memoryRememberSearchForgetStayLocalAndReplayTheirReceipts() {
        Fixture().use { fixture ->
            val executor = fixture.executor()
            fun apply(name: String, args: JSONObject): JSONObject {
                val call = fixture.call(name, args)
                val row = fixture.row(call, executor.prepare(call, fixture.conversation, fixture.authority).getJSONObject("precondition"))
                val request = fixture.request(row)
                val effect = executor.execute(request, args, row, fixture.conversation, fixture.authority)
                val committed = fixture.file.readText()
                assertEquals(effect.toString(), fixture.executor().execute(request, args, row, fixture.conversation, fixture.authority).toString())
                assertEquals(committed, fixture.file.readText())
                return JSONObject(effect.getString("feedback")).getJSONObject("payload")
            }
            val remembered = apply("remember_assistant_memory", JSONObject().put("title", "Language")
                .put("content", "Use Chinese").put("kind", "preference"))
            val memoryId = remembered.getString("memory_id")
            val memory = fixture.snapshot().getJSONArray("memories").getJSONObject(0)
            assertEquals(fixture.chat, memory.getString("source_conversation_id"))
            val found = apply("search_assistant_memory", JSONObject().put("query", "Chinese").put("limit", 5))
            assertEquals(memoryId, found.getJSONArray("memories").getJSONObject(0).getString("memory_id"))
            assertFalse(found.getBoolean("truncated"))
            apply("forget_assistant_memory", JSONObject().put("memory_id", memoryId))
            assertEquals(0, fixture.snapshot().optJSONArray("memories")?.length() ?: 0)
            assertEquals(2, fixture.snapshot().getJSONArray("tool_receipts").length())
        }
    }
}
