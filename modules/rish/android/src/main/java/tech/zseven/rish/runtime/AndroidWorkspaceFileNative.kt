package tech.zseven.rish.runtime

import android.system.ErrnoException
import android.system.OsConstants

/** Atomic name operations missing from Android's public Os API. */
internal object AndroidWorkspaceFileNative {
    fun rename(sourceDirectory: Int, source: String, destinationDirectory: Int, destination: String, exchange: Boolean) {
        if (!RishAgentCoreNative.available) {
            throw AndroidWorkspaceFiles.Refused("E_WORKSPACE_UNAVAILABLE", "Workspace file operations are unavailable")
        }
        val error = renameAt(sourceDirectory, source.toByteArray(Charsets.UTF_8), destinationDirectory, destination.toByteArray(Charsets.UTF_8), exchange)
        if (error == OsConstants.ENOSYS || error == OsConstants.EOPNOTSUPP || error == OsConstants.EINVAL) {
            throw AndroidWorkspaceFiles.Refused("E_WORKSPACE_UNAVAILABLE", "This filesystem cannot safely replace files")
        }
        if (error != 0) throw ErrnoException("renameat2", error)
    }

    @JvmStatic private external fun renameAt(sourceDirectory: Int, source: ByteArray, destinationDirectory: Int, destination: ByteArray, exchange: Boolean): Int
}
