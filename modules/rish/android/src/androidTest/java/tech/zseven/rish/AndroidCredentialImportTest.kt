package tech.zseven.rish

import android.os.Bundle
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.AndroidProviderConfiguration
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.security.KeyPairGenerator
import java.security.interfaces.RSAPublicKey
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

/** Explicit local acceptance import only. Never part of the shipped application. */
@RunWith(AndroidJUnit4::class)
class AndroidCredentialImportTest {
    @Test fun importEncryptedTestCredentials() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("rishCredentialImport") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val runtime = AndroidRuntimeState.get(instrumentation.targetContext)
        val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val public = pair.public as RSAPublicKey
        val challenge = java.util.UUID.randomUUID().toString() + java.util.UUID.randomUUID().toString()
        ServerSocket().use { server ->
            server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 18764))
            server.soTimeout = 180_000
            instrumentation.sendStatus(2, Bundle().apply { putString("stream", "SECURE_IMPORT_READY\n") })
            server.accept().use { socket ->
                socket.soTimeout = 30_000
                val out = socket.getOutputStream()
                val hello = JSONObject().put("protocol", "rish-credential-import-v1").put("challenge", challenge)
                    .put("modulus", Base64.encodeToString(public.modulus.toByteArray(), Base64.NO_WRAP))
                    .put("exponent", Base64.encodeToString(public.publicExponent.toByteArray(), Base64.NO_WRAP))
                out.write((hello.toString() + "\n").toByteArray()); out.flush()
                val input = socket.getInputStream(); val bytes = java.io.ByteArrayOutputStream()
                while(bytes.size() < 32768) { val next = input.read(); require(next >= 0); if(next == 10) break; bytes.write(next) }
                require(bytes.size() < 32768)
                val envelope = JSONObject(bytes.toString("UTF-8")); require(envelope.getString("challenge") == challenge)
                val rsa = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
                rsa.init(Cipher.DECRYPT_MODE, pair.private, OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT))
                val aesKey = rsa.doFinal(Base64.decode(envelope.getString("wrapped_key"), Base64.NO_WRAP))
                val payload = Base64.decode(envelope.getString("payload"), Base64.NO_WRAP)
                val aes = Cipher.getInstance("AES/GCM/NoPadding")
                aes.init(Cipher.DECRYPT_MODE, SecretKeySpec(aesKey, "AES"), GCMParameterSpec(128, payload.copyOfRange(0, 12)))
                aes.updateAAD(challenge.toByteArray())
                val plain = aes.doFinal(payload.copyOfRange(12, payload.size))
                try {
                    val values = JSONObject(String(plain, Charsets.UTF_8))
                    require(values.keys().asSequence().toSet() == setOf("DEEPSEEK_API_KEY", "BIGMODEL_API_KEY"))
                    runtime.transport.mutate {
                        for(harness in listOf("codex", "claude-code")) {
                            val mappings = JSONObject()
                            AndroidProviderConfiguration.legacyModelIds.getValue(harness).forEach { mappings.put(it, "GLM-5.3") }
                            runtime.configurations.save(JSONObject().put("schema_version", 1).put("harness_id", harness).put("name", "GLM Coding Plan")
                                .put("endpoint_url", if(harness == "codex") "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions" else "https://open.bigmodel.cn/api/anthropic/v1/messages")
                                .put("protocol", if(harness == "codex") "chat-completions" else "messages").put("auth_type", if(harness == "codex") "bearer" else "x-api-key")
                                .put("model_mappings", mappings).put("send_reasoning", false).put("full_url", true))
                        }
                    }
                    for(slot in listOf("DEEPSEEK_API_KEY", "BIGMODEL_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY")) {
                        val source = if(slot == "DEEPSEEK_API_KEY") slot else "BIGMODEL_API_KEY"
                        runtime.transport.put(slot, runtime.transport.account(slot), values.getString(source))
                    }
                    out.write("{\"ok\":true}\n".toByteArray()); out.flush()
                } finally { plain.fill(0); aesKey.fill(0) }
            }
        }
    }
}
