package tech.zseven.rish.runtime

import android.content.Context
import android.system.Os
import android.system.OsConstants
import java.io.File

/** Native-owned location shared by the Shell and task tools; never a model argument. */
internal object AndroidAssistantStorage {
    fun directory(context: Context): File {
        val directory = File(context.filesDir, "assistant-v1")
        if (!directory.exists() && !directory.mkdir()) error("E_ASSISTANT_STORAGE")
        if (!OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) error("E_ASSISTANT_STORAGE")
        Os.chmod(directory.path, 0x1c0)
        return directory.canonicalFile
    }
}
