package tech.zseven.rish.guest

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Rejection codes shared with apps/mobile/src/native/LocalGuest.ts. */
object GuestErrorCodes {
    const val INVALID_REQUEST = "E_GUEST_INVALID_REQUEST"
    const val ASSETS_MISSING = "E_GUEST_ASSETS_MISSING"
    const val ASSET_INTEGRITY = "E_GUEST_ASSET_INTEGRITY"
    const val BOOT_IN_PROGRESS = "E_GUEST_BOOT_IN_PROGRESS"
    const val ALREADY_BOOTED = "E_GUEST_ALREADY_BOOTED"
    const val NOT_BOOTED = "E_GUEST_NOT_BOOTED"
    const val BOOT_FAILED = "E_GUEST_BOOT_FAILED"
    const val BOOT_CANCELLED = "E_GUEST_BOOT_CANCELLED"
    const val EXEC_FAILED = "E_GUEST_EXEC_FAILED"
    const val UNAVAILABLE = "E_GUEST_UNAVAILABLE"
}

/** A fail-closed rejection carrying one of [GuestErrorCodes]. */
class GuestRejection(val code: String, message: String) : Exception(message)

/**
 * Verified, path-addressable copies of the kernel and initramfs, plus the
 * throwaway root disk this app supplies rather than letting the runtime look
 * for a temp directory it may not be allowed to write.
 */
class StagedGuestAssets(
    val kernelPath: String,
    val initramfsPath: String,
    val scratchDiskPath: String,
)

/** Produces [StagedGuestAssets] or throws a [GuestRejection]. */
interface GuestAssetProvider {
    @Throws(GuestRejection::class)
    fun stage(): StagedGuestAssets
}

/** The three session calls the runtime exposes; [RishGuestNative] is the real one. */
interface GuestSessionBackend {
    /** Returns a session handle, or 0 when the boot failed. Blocks for the boot. */
    fun boot(requestJson: String): Long

    /** Returns the runtime's JSON reply, or null when no reply was produced. */
    fun exec(handle: Long, requestJson: String): String?

    fun free(handle: Long)
}

/**
 * Single-session guest state machine behind LocalGuestModule, mirroring
 * modules/rish/ios/Sources/LocalGuestModule.mm.
 *
 * Every state read or write happens on one serial executor. A boot blocks for
 * tens of seconds, so it runs on its own thread and reports back onto the
 * state executor; exec runs on the state executor so shutdown can never free
 * a handle mid-command. Requests are validated fail-closed before anything
 * reaches the runtime, and receipts never carry absolute paths.
 */
class GuestSessionController(
    private val assets: GuestAssetProvider,
    private val backend: GuestSessionBackend,
    private val stateExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "rish-guest-state")
    },
    private val bootThread: (Runnable) -> Thread = { runnable -> Thread(runnable, "rish-guest-boot") },
    private val clock: () -> Long = System::nanoTime,
) {
    private enum class SessionState { IDLE, BOOTING, BOOTED }

    private var state = SessionState.IDLE
    private var session = 0L
    private var shutdownRequested = false

    fun bootGuest(
        request: Any?,
        resolve: (Map<String, Any?>) -> Unit,
        reject: (code: String, message: String) -> Unit,
    ) {
        stateExecutor.execute {
            val memoryMib = validatedBootRequest(request)
            if (memoryMib == null) {
                reject(GuestErrorCodes.INVALID_REQUEST, "Guest boot request is invalid.")
                return@execute
            }
            if (state != SessionState.IDLE) {
                reject(
                    if (state == SessionState.BOOTING) GuestErrorCodes.BOOT_IN_PROGRESS else GuestErrorCodes.ALREADY_BOOTED,
                    "A guest session is already active.",
                )
                return@execute
            }
            // Integrity preflight: the packaged copies must match the pinned
            // digests before anything is booted.
            val staged = try {
                assets.stage()
            } catch (rejection: GuestRejection) {
                reject(rejection.code, rejection.message ?: rejection.code)
                return@execute
            }
            val envelope = try {
                JSONObject()
                    .put("kernel_path", staged.kernelPath)
                    .put("initrd_path", staged.initramfsPath)
                    // Naming a root disk keeps the runtime out of TMPDIR. See
                    // GuestAssets.SCRATCH_DISK_NAME for what that cost.
                    .put("root_disk_path", staged.scratchDiskPath)
                    // The session boot ignores the command field, but the Rust
                    // request struct requires it; an empty argv satisfies it.
                    .put("command", JSONArray())
                    .put("memory_mib", memoryMib)
                    .put("command_line", GuestAssets.COMMAND_LINE)
                    .put("boot_budget_units", BOOT_BUDGET_UNITS)
                    .put("handshake_budget_units", HANDSHAKE_BUDGET_UNITS)
                    .toString()
            } catch (_: JSONException) {
                reject(GuestErrorCodes.INVALID_REQUEST, "Guest boot request could not be encoded.")
                return@execute
            }
            state = SessionState.BOOTING
            shutdownRequested = false

            // The interpreter boots a Linux guest: blocking and slow. It must
            // never run on the state executor or the main thread.
            bootThread(Runnable {
                val started = clock()
                val handle = backend.boot(envelope)
                val bootMs = (clock() - started) / 1_000_000L
                stateExecutor.execute {
                    if (handle == 0L) {
                        state = SessionState.IDLE
                        reject(GuestErrorCodes.BOOT_FAILED, "The guest failed to boot.")
                        return@execute
                    }
                    if (shutdownRequested) {
                        backend.free(handle)
                        state = SessionState.IDLE
                        shutdownRequested = false
                        reject(GuestErrorCodes.BOOT_CANCELLED, "Guest boot was cancelled by shutdown.")
                        return@execute
                    }
                    session = handle
                    state = SessionState.BOOTED
                    GuestRuntimeState.setGuestRuntimeMounted(true)
                    resolve(
                        linkedMapOf(
                            "schema_version" to 1,
                            "status" to "booted",
                            "boot_ms" to bootMs,
                            "memory_mib" to memoryMib,
                            "kernel" to GuestAssets.KERNEL_NAME,
                            "initramfs" to GuestAssets.INITRAMFS_NAME,
                            "kernel_sha256" to GuestAssets.KERNEL_SHA256,
                            "initramfs_sha256" to GuestAssets.INITRAMFS_SHA256,
                        ),
                    )
                }
            }).start()
        }
    }

    fun guestExec(
        request: Any?,
        resolve: (Map<String, Any?>) -> Unit,
        reject: (code: String, message: String) -> Unit,
    ) {
        stateExecutor.execute {
            // Validate before consulting session state: invalid input is
            // rejected fail-closed regardless of what the session is doing.
            val command = validatedExecRequest(request)
            if (command == null) {
                reject(GuestErrorCodes.INVALID_REQUEST, "Guest exec request is invalid.")
                return@execute
            }
            when (state) {
                SessionState.IDLE -> {
                    reject(GuestErrorCodes.NOT_BOOTED, "The guest is not booted.")
                    return@execute
                }
                SessionState.BOOTING -> {
                    reject(GuestErrorCodes.BOOT_IN_PROGRESS, "The guest is still booting.")
                    return@execute
                }
                SessionState.BOOTED -> Unit
            }
            if (session == 0L) {
                reject(GuestErrorCodes.UNAVAILABLE, "The guest session handle is unavailable.")
                return@execute
            }
            val encoded = JSONObject().put("command", JSONArray(command)).toString()
            val raw = backend.exec(session, encoded)
            if (raw == null) {
                reject(GuestErrorCodes.EXEC_FAILED, "The guest exec bridge returned no response.")
                return@execute
            }
            val response = try {
                JSONObject(raw)
            } catch (_: JSONException) {
                reject(GuestErrorCodes.EXEC_FAILED, "The guest exec reply is invalid.")
                return@execute
            }
            val ok = response.optBoolean("ok", false)
            val exitCode = if (response.has("exit_code") && !response.isNull("exit_code")) {
                response.opt("exit_code") as? Number
            } else {
                null
            }
            if (!ok && exitCode == null) {
                val detail = response.optString("error", "")
                reject(GuestErrorCodes.EXEC_FAILED, if (detail.isEmpty()) "The guest command failed." else detail)
                return@execute
            }
            var stdoutText = response.optString("stdout", "")
            var stderrText = response.optString("stderr", "")
            val stdoutTruncated = stdoutText.length > MAXIMUM_STREAM_LENGTH
            val stderrTruncated = stderrText.length > MAXIMUM_STREAM_LENGTH
            if (stdoutTruncated) stdoutText = stdoutText.substring(0, MAXIMUM_STREAM_LENGTH)
            if (stderrTruncated) stderrText = stderrText.substring(0, MAXIMUM_STREAM_LENGTH)
            val receipt = linkedMapOf<String, Any?>(
                "schema_version" to 1,
                "ok" to ok,
                "exit_code" to (exitCode?.toInt() ?: 0),
                "stdout" to stdoutText,
                "stderr" to stderrText,
                "stdout_truncated" to stdoutTruncated,
                "stderr_truncated" to stderrTruncated,
            )
            val bootUnits = response.opt("boot_units")
            if (bootUnits is Number) receipt["boot_units"] = bootUnits.toLong()
            resolve(receipt)
        }
    }

    fun shutdownGuest(resolve: (Map<String, Any?>) -> Unit) {
        stateExecutor.execute {
            when (state) {
                SessionState.IDLE -> resolve(mapOf("schema_version" to 1, "status" to "already_idle"))
                SessionState.BOOTING -> {
                    // The boot worker frees the handle the moment it completes
                    // and the boot promise rejects with E_GUEST_BOOT_CANCELLED.
                    shutdownRequested = true
                    resolve(mapOf("schema_version" to 1, "status" to "shutdown_scheduled"))
                }
                SessionState.BOOTED -> {
                    releaseSessionLocked()
                    state = SessionState.IDLE
                    resolve(mapOf("schema_version" to 1, "status" to "shutdown"))
                }
            }
        }
    }

    /** Releases a live session on bridge teardown; a boot in flight is cancelled on completion. */
    fun close() {
        stateExecutor.execute {
            when (state) {
                SessionState.BOOTED -> {
                    releaseSessionLocked()
                    state = SessionState.IDLE
                }
                SessionState.BOOTING -> shutdownRequested = true
                SessionState.IDLE -> Unit
            }
        }
    }

    // Runs only on the state executor. Releases the live session exactly once
    // and clears the shared mounted flag.
    private fun releaseSessionLocked() {
        if (session != 0L) {
            backend.free(session)
            session = 0L
        }
        if (state == SessionState.BOOTED) GuestRuntimeState.setGuestRuntimeMounted(false)
    }

    companion object {
        const val MAXIMUM_COMMAND_ARGS = 64
        const val MAXIMUM_ARG_BYTES = 4096
        const val MAXIMUM_COMMAND_BYTES = 65536
        const val MAXIMUM_STREAM_LENGTH = 1024 * 1024
        const val MINIMUM_MEMORY_MIB = 256L
        const val MAXIMUM_MEMORY_MIB = 4096L
        const val BOOT_BUDGET_UNITS = 80_000_000_000L
        const val HANDSHAKE_BUDGET_UNITS = 80_000_000_000L

        /** Returns memory_mib for a valid boot request, else null. */
        fun validatedBootRequest(request: Any?): Long? {
            val map = exactKeys(request, setOf("schema_version", "memory_mib")) ?: return null
            if (!schemaVersionIsOne(map["schema_version"])) return null
            return boundedInteger(map["memory_mib"], MINIMUM_MEMORY_MIB, MAXIMUM_MEMORY_MIB)
        }

        /** Returns the validated argv for an exec request, else null. */
        fun validatedExecRequest(request: Any?): List<String>? {
            val map = exactKeys(request, setOf("schema_version", "command")) ?: return null
            if (!schemaVersionIsOne(map["schema_version"])) return null
            return validatedCommand(map["command"])
        }

        // Bridge maps arrive as HashMap<String, Any?> with Double numbers; unit
        // tests pass Kotlin literals. Both shapes are accepted, booleans never.
        private fun exactKeys(value: Any?, keys: Set<String>): Map<*, *>? {
            val map = value as? Map<*, *> ?: return null
            if (map.size != keys.size) return null
            for (key in map.keys) if (key !is String || key !in keys) return null
            return map
        }

        private fun schemaVersionIsOne(value: Any?): Boolean =
            value is Number && value !is Boolean && value.toDouble() == 1.0

        private fun boundedInteger(value: Any?, minimum: Long, maximum: Long): Long? {
            if (value !is Number || value is Boolean) return null
            val floating = value.toDouble()
            if (!floating.isFinite() || floating < 0.0 || floating != Math.floor(floating)) return null
            if (floating > Long.MAX_VALUE.toDouble()) return null
            val integer = floating.toLong()
            if (integer < minimum || integer > maximum) return null
            return integer
        }

        // Bounded count, bounded UTF-8 bytes, strings only, no embedded NULs.
        private fun validatedCommand(value: Any?): List<String>? {
            val entries = value as? List<*> ?: return null
            if (entries.isEmpty() || entries.size > MAXIMUM_COMMAND_ARGS) return null
            val command = ArrayList<String>(entries.size)
            var totalBytes = 0
            for (entry in entries) {
                val argument = entry as? String ?: return null
                if (argument.isEmpty() || argument.indexOf(' ') >= 0) return null
                val bytes = argument.toByteArray(Charsets.UTF_8).size
                if (bytes > MAXIMUM_ARG_BYTES || bytes > MAXIMUM_COMMAND_BYTES - totalBytes) return null
                totalBytes += bytes
                command.add(argument)
            }
            return command
        }
    }
}
