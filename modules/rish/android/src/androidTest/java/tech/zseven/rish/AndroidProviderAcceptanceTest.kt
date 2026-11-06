package tech.zseven.rish

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import tech.zseven.rish.runtime.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Opt-in real requests from the Android process. Never prints credentials or response bodies. */
@RunWith(AndroidJUnit4::class)
class AndroidProviderAcceptanceTest {
    private fun run(harness: String, model: String, marker: String) {
        assumeTrue(InstrumentationRegistry.getArguments().getString("rishRealProviderTest") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val runtime = AndroidRuntimeState.get(context)
        val slot = AndroidProviderConfiguration.slot(harness)
        assertTrue("Test credential is not configured", runtime.transport.configured(slot))
        val request = JSONObject().put("schema_version", 2).put("harness_id", harness)
            .put("turn_id", UUID.randomUUID().toString()).put("attempt_id", UUID.randomUUID().toString()).put("round_id", UUID.randomUUID().toString())
            .put("round_index", 0).put("model", model).put("thinking_mode", "off").put("project_context", JSONObject.NULL)
            .put("visible_history", JSONArray().put(JSONObject().put("role", "user").put("content", "Reply with exactly $marker. No explanation.").put("attachments", JSONArray())))
            .put("round_transcript", JSONArray()).put("tools", JSONArray())
        val receipt = JSONObject().put("schema_version", 1).put("execution", "android-native-api")
            .put("harness", harness).put("logical_model", model).put("at", RuntimeJson.now()).put("process_id", android.os.Process.myPid())
        try {
            val result = runtime.transport.execute(runtime.transport.prepare(request.toString()))
            val matches = result.getString("text").trim() == marker
            receipt.put("ok", matches).put("http_status", 200).put("reply_matched", matches).put("latency_ms", result.getLong("latency_ms"))
                .put("endpoint", runtime.configurations.forModel(model).getString("endpoint_url"))
                .put("provider_response_id", result.getString("provider_response_id"))
            val account = runtime.transport.account(slot)
            val key = requireNotNull(runtime.credentials.get(account))
            val prefs = context.getSharedPreferences("rish.credentials.v1", 0).all.values.joinToString()
            assertFalse("Credential was not encrypted", prefs.contains(key))
            receipt.put("credential_encrypted_at_rest", true)
            assertTrue("Provider returned an unexpected answer", matches)
            assertEquals(model, result.getString("model"))
            assertEquals(request.getString("round_id"), result.getString("round_id"))
        } catch (failure: RuntimeFailure) {
            receipt.put("ok", false).put("error_code", failure.code)
            failure.httpStatus?.let { receipt.put("http_status", it) }
            throw failure
        } finally {
            context.filesDir.resolve("provider-acceptance-$harness.json").writeText(receipt.toString(2))
        }
    }
    @Test fun dshNativeRequest() = run("dsh", "deepseek-v4-flash", "DSH_ANDROID_OK")
    @Test fun glmNativeRequest() = run("glm", "GLM-5.3", "GLM_ANDROID_OK")
    @Test fun codexConfiguredForGlm() = run("codex", "gpt-5.6", "CODEX_GLM_ANDROID_OK")
    @Test fun claudeConfiguredForGlm() = run("claude-code", "claude-sonnet-5", "CC_GLM_ANDROID_OK")
}
