package tech.zseven.rish.runtime

import android.content.Context
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.security.cert.X509Certificate

/**
 * The system's trusted roots as one PEM file for OpenSSL.
 *
 * libgit2 on Android is built against OpenSSL, and OpenSSL's default trust
 * paths are the Mac that built it. Android's own roots are under
 * `/system/etc/security/cacerts`, but under file names hashed the way
 * OpenSSL stopped hashing in 1.0.0, so pointing it at that directory finds
 * nothing. The `AndroidCAStore` KeyStore hands the same roots out through
 * the platform, and they are written once per process to a private file
 * whose path is given to libgit2.
 */
internal object AndroidGitCertificates {
    @Volatile private var configured: File? = null

    @Synchronized fun ensure(context: Context): File? {
        configured?.let { return it }
        val target = File(context.applicationContext.noBackupFilesDir, "git-roots.pem")
        val written = try {
            val store = KeyStore.getInstance("AndroidCAStore").apply { load(null, null) }
            val out = StringBuilder()
            var count = 0
            for (alias in store.aliases()) {
                val certificate = store.getCertificate(alias) as? X509Certificate ?: continue
                out.append("-----BEGIN CERTIFICATE-----\n")
                out.append(Base64.encodeToString(certificate.encoded, Base64.NO_WRAP).chunked(64).joinToString("\n"))
                out.append("\n-----END CERTIFICATE-----\n")
                count += 1
            }
            if (count == 0) return null
            val staging = File(target.parentFile, target.name + ".tmp")
            staging.writeText(out.toString(), Charsets.UTF_8)
            if (!staging.renameTo(target)) { staging.delete(); return null }
            target
        } catch (_: Exception) {
            return null
        }
        if (!RishLibgit2Native.require()) return null
        val answer = RishLibgit2Native.configureCertificates(written.absolutePath)
        if (answer != "ok") {
            android.util.Log.w("RishProjects", "git roots not configured: $answer")
            return null
        }
        configured = written
        return written
    }
}
