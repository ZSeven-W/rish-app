package tech.zseven.rish.runtime

import android.content.Context
import java.io.File

internal interface SubscriptionAuthVault {
    fun restore(harnessId: String, home: File)
    fun capture(harnessId: String, home: File)
    fun clear(harnessId: String)
}

internal interface SubscriptionAuthProcessFactory {
    fun available(harnessId: String): Boolean
    fun start(harnessId: String, args: List<String>, home: File): Process
}

/** Real process adapter; tests can replace both adapters without launching a CLI. */
internal class AndroidSubscriptionAuthProcessFactory(context: Context) : SubscriptionAuthProcessFactory {
    private val app = context.applicationContext

    override fun available(harnessId: String): Boolean = executable(harnessId)?.let {
        if (!it.canExecute()) it.setExecutable(true, true)
        true
    } ?: false

    override fun start(harnessId: String, args: List<String>, home: File): Process {
        val executable = requireNotNull(executable(harnessId))
        val command = if (harnessId == "claude-code") {
            val loader = File(requireNotNull(executable.parentFile), "libmusl_loader.so")
            require(loader.isFile) { "E_CLI_LOADER_MISSING" }
            listOf(loader.absolutePath, "--library-path", requireNotNull(executable.parentFile).absolutePath, executable.absolutePath) + args
        } else listOf(executable.absolutePath) + args
        val environment = hashMapOf(
            "HOME" to home.absolutePath,
            "XDG_CONFIG_HOME" to File(home, ".config").absolutePath,
            "XDG_DATA_HOME" to File(home, ".local/share").absolutePath,
            "XDG_CACHE_HOME" to File(home, ".cache").absolutePath,
            "TMPDIR" to File(home, ".tmp").apply { mkdirs() }.absolutePath,
            "LANG" to "C.UTF-8",
            "LC_ALL" to "C.UTF-8",
        )
        return ProcessBuilder(command).directory(home).redirectErrorStream(true).apply {
            environment().clear()
            environment().putAll(environment)
        }.start()
    }

    private fun executable(harnessId: String): File? {
        val name = when (harnessId) {
            "codex" -> "libcodex.so"
            "claude-code" -> "libclaude_code.so"
            else -> return null
        }
        return File(app.applicationInfo.nativeLibraryDir, name).takeIf { it.isFile }
    }
}
