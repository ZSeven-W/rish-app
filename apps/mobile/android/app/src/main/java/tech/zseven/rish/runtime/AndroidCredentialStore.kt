package tech.zseven.rish.runtime

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keys never leave native code. SharedPreferences contains authenticated ciphertext only. */
internal class AndroidCredentialStore(
    context: Context,
    namespace: String = "rish.credentials.v1",
    /** Accounts this store accepts besides the provider slots; a git credential store names its own. */
    private val extraAccounts: Regex? = null,
) {
    private val preferences = context.applicationContext.getSharedPreferences(namespace, Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val alias = if(namespace == "rish.credentials.v1") "rish.credentials.aes.v1" else "$namespace.aes"
    companion object {
        val slots = setOf("DEEPSEEK_API_KEY", "BIGMODEL_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY")
    }
    private fun validAccount(slot: String) = slot in slots || Regex("CUSTOM_PROVIDER_(codex|claude-code)_[a-f0-9]{64}").matches(slot) ||
        (extraAccounts?.matches(slot) ?: false)
    @Synchronized private fun encryptionKey(): SecretKey {
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }
    @Synchronized fun put(slot: String, secret: String) {
        require(validAccount(slot) && secret.length in 1..8192 && secret.none { it == '\r' || it == '\n' || it == '\u0000' })
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey()); cipher.updateAAD(slot.toByteArray(Charsets.UTF_8))
        val plain = secret.toByteArray(Charsets.UTF_8)
        try {
            val combined = cipher.iv + cipher.doFinal(plain)
            check(preferences.edit().putString(slot, Base64.encodeToString(combined, Base64.NO_WRAP)).commit())
        } finally { plain.fill(0) }
    }
    @Synchronized fun get(slot: String): String? {
        require(validAccount(slot))
        val stored = preferences.getString(slot, null) ?: return null
        val combined = Base64.decode(stored, Base64.NO_WRAP)
        require(combined.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, encryptionKey(), GCMParameterSpec(128, combined.copyOfRange(0, 12)))
        cipher.updateAAD(slot.toByteArray(Charsets.UTF_8))
        val plain = cipher.doFinal(combined.copyOfRange(12, combined.size))
        return try { String(plain, Charsets.UTF_8) } finally { plain.fill(0) }
    }
    fun configured(slot: String): Boolean = get(slot) != null
    @Synchronized fun clear(slot: String) = clearAccounts(slot)
    @Synchronized fun clearAccounts(vararg accounts: String) {
        val editor = preferences.edit()
        accounts.forEach { require(validAccount(it)); editor.remove(it) }
        check(editor.commit())
    }
    @Synchronized fun migrateAccount(previous: String, current: String) {
        require(validAccount(previous) && validAccount(current))
        if(previous == current || !preferences.contains(previous)) return
        val editor = preferences.edit()
        if(!preferences.contains(current)) {
            val secret = requireNotNull(get(previous))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, encryptionKey()); cipher.updateAAD(current.toByteArray(Charsets.UTF_8))
            val plain = secret.toByteArray(Charsets.UTF_8)
            try { editor.putString(current, Base64.encodeToString(cipher.iv + cipher.doFinal(plain), Base64.NO_WRAP)) }
            finally { plain.fill(0) }
        }
        check(editor.remove(previous).commit())
    }
}
