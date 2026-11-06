package tech.zseven.rish.runtime

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.security.KeyStore
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts the small credential homes used by the official CLIs.  The CLI
 * needs ordinary files while a command is running, so the manager restores a
 * temporary home and removes it as soon as the command exits.  The persisted
 * value is authenticated ciphertext only.
 */
internal class AndroidSubscriptionAuthStore(
    context: Context,
    private val namespace: String = "rish.subscription.auth.v1",
) : SubscriptionAuthVault {
    private val app = context.applicationContext
    private val preferences = app.getSharedPreferences(
        namespace, Context.MODE_PRIVATE
    )
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    override fun restore(harnessId: String, home: File) {
        val encoded = synchronized(this) { preferences.getString(prefKey(harnessId), null) }
            ?: return
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        require(combined.size >= 28) { "Invalid encrypted auth snapshot" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            encryptionKey(harnessId),
            GCMParameterSpec(128, combined.copyOfRange(0, 12))
        )
        cipher.updateAAD(aad(harnessId))
        val archive = cipher.doFinal(combined.copyOfRange(12, combined.size))
        try {
            clearDirectory(home)
            home.mkdirs()
            unpack(archive, home)
        } finally {
            archive.fill(0)
            combined.fill(0)
        }
    }

    override fun capture(harnessId: String, home: File) {
        val archive = pack(harnessId, home)
        var encrypted = ByteArray(0)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, encryptionKey(harnessId))
            cipher.updateAAD(aad(harnessId))
            encrypted = cipher.iv + cipher.doFinal(archive)
            val encoded = Base64.encodeToString(encrypted, Base64.NO_WRAP)
            check(synchronized(this) {
                preferences.edit().putString(prefKey(harnessId), encoded).commit()
            })
        } finally {
            encrypted.fill(0)
            archive.fill(0)
        }
    }

    override fun clear(harnessId: String) {
        synchronized(this) { check(preferences.edit().remove(prefKey(harnessId)).commit()) }
    }

    private fun prefKey(harnessId: String) = "home_$harnessId"
    private fun aad(harnessId: String) = "$namespace\u0000$harnessId".toByteArray(StandardCharsets.UTF_8)
    private fun alias(harnessId: String): String {
        if (namespace == "rish.subscription.auth.v1") return "rish.subscription.$harnessId.aes.v1"
        val safeNamespace = namespace.replace(Regex("[^A-Za-z0-9_.]"), "_")
        return "rish.subscription.$safeNamespace.$harnessId.aes.v1"
    }

    @Synchronized private fun encryptionKey(harnessId: String): SecretKey {
        (keyStore.getKey(alias(harnessId), null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias(harnessId),
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    private fun pack(harnessId: String, home: File): ByteArray {
        val allowlisted = when (harnessId) {
            "codex" -> setOf(".codex/auth.json")
            "claude-code" -> setOf(".claude/.credentials.json", ".claude.json")
            else -> emptySet()
        }
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            var total = 0L
            allowlisted.forEach { relative ->
                val file = File(home, relative)
                val canonicalHome = home.canonicalFile
                require(file.canonicalPath.startsWith(canonicalHome.path + File.separator)) {
                    "Invalid auth snapshot path"
                }
                if (!file.isFile || Files.isSymbolicLink(file.toPath())) return@forEach
                zip.putNextEntry(ZipEntry(relative))
                FileInputStream(file).use { input ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    var fileBytes = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        fileBytes += count
                        total += count
                        require(fileBytes <= MAX_FILE_BYTES && total <= MAX_ARCHIVE_BYTES) {
                            "Auth snapshot is too large"
                        }
                        zip.write(buffer, 0, count)
                    }
                }
                zip.closeEntry()
            }
        }
        require(output.size() <= MAX_ARCHIVE_BYTES) { "Auth snapshot is too large" }
        return output.toByteArray()
    }

    private fun unpack(archive: ByteArray, home: File) {
        var total = 0L
        ZipInputStream(ByteArrayInputStream(archive)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val name = entry.name
                require(!entry.isDirectory && safeEntry(name)) { "Invalid auth snapshot entry" }
                val destination = File(home, name)
                require(destination.canonicalPath.startsWith(home.canonicalPath + File.separator)) {
                    "Invalid auth snapshot path"
                }
                destination.parentFile?.mkdirs()
                var written = 0L
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    while (true) {
                        val count = zip.read(buffer)
                        if (count <= 0) break
                        written += count
                        total += count
                        require(written <= MAX_FILE_BYTES && total <= MAX_ARCHIVE_BYTES) {
                            "Auth snapshot is too large"
                        }
                        output.write(buffer, 0, count)
                    }
                }
                destination.setReadable(false, false)
                destination.setReadable(true, true)
                zip.closeEntry()
            }
        }
    }

    private fun safeEntry(path: String): Boolean = path.isNotEmpty() &&
        !path.startsWith("/") && !path.contains("\\") &&
        path.split('/').none { it.isEmpty() || it == "." || it == ".." }

    companion object {
        private const val BUFFER_SIZE = 16 * 1024
        private const val MAX_FILE_BYTES = 1024 * 1024L
        private const val MAX_ARCHIVE_BYTES = 8 * 1024 * 1024L

        fun clearDirectory(directory: File) {
            if (!directory.exists()) return
            deleteTree(directory)
        }

        private fun deleteTree(file: File) {
            if (Files.isSymbolicLink(file.toPath())) {
                file.delete()
                return
            }
            if (file.isDirectory) file.listFiles()?.forEach(::deleteTree)
            file.delete()
        }
    }
}
