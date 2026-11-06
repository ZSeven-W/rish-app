package tech.zseven.rish.runtime

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.util.AtomicFile
import tech.zseven.rish.BuildConfig
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Registered only in the optional debug host, with android:exported="false". */
internal class CodexOfflineProbeService : Service() {
    private data class Active(
        val requestId: String,
        val cancelled: AtomicBoolean,
        val thread: Thread,
        val owner: CodexOfflineProbeService,
    )
    private var latestStartId = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requestId = intent?.getStringExtra(EXTRA_REQUEST_ID).orEmpty()
        synchronized(lock) { latestStartId = startId }
        if (!CodexOfflineProbe.validRequestId(requestId)) {
            synchronized(lock) { if (active?.owner !== this) stopSelf(startId) }
            return START_NOT_STICKY
        }
        val allowedExtras = setOf(EXTRA_REQUEST_ID, EXTRA_ENGINE_ID)
        if (intent?.getStringExtra(EXTRA_ENGINE_ID) != "codex" ||
            intent.extras?.keySet()?.all { it in allowedExtras } != true ||
            intent.action !in setOf(ACTION, ACTION_CANCEL)) {
            synchronized(lock) {
                // A malformed replay must not race or replace the receipt of
                // the already accepted request with the same identity.
                if (active?.requestId != requestId && !resultFile(this, requestId).exists()) {
                    publishFailure(requestId, "invalid_probe_request")
                }
                if (active?.owner !== this) stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        synchronized(lock) {
            if (intent.action == ACTION_CANCEL) {
                active?.takeIf { it.requestId == requestId }?.let {
                    it.cancelled.set(true)
                    it.thread.interrupt()
                }
                if (active?.owner !== this) stopSelf(startId)
                return START_NOT_STICKY
            }
            // A request UUID is single use. Its terminal atomic receipt is
            // immutable, so a duplicate can safely observe the same result.
            if (resultFile(this, requestId).exists()) {
                if (active?.owner !== this) stopSelf(startId)
                return START_NOT_STICKY
            }
            if (active != null) {
                // A repeated request cannot overwrite its in-flight receipt.
                if (active?.requestId != requestId) publishFailure(requestId, "probe_busy")
                if (active?.owner !== this) stopSelf(startId)
                return START_NOT_STICKY
            }
            val cancelled = AtomicBoolean()
            val thread = Thread({
                try {
                    val probe = CodexOfflineProbe(
                        File(applicationInfo.nativeLibraryDir), File(cacheDir, "codex-offline-probe-homes"),
                        { assets.open(CodexOfflineProbe.MANIFEST_ASSET).bufferedReader().use { it.readText() } },
                        BuildConfig.RISH_CODEX_PROBE_BUNDLED, Build.SUPPORTED_ABIS.toList(),
                        Process.myUid(), Process.myPid(),
                    )
                    publish(requestId, probe.run(requestId, cancelled))
                } catch (_: Exception) {
                    publishFailure(requestId, if (cancelled.get()) "cancelled" else "probe_service_error")
                } finally {
                    synchronized(lock) {
                        if (active?.thread === Thread.currentThread()) active = null
                        stopSelf(latestStartId)
                    }
                }
            }, "codex-offline-probe")
            active = Active(requestId, cancelled, thread, this)
            thread.start()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        synchronized(lock) {
            active?.takeIf { it.owner === this }?.let { it.cancelled.set(true); it.thread.interrupt() }
        }
        super.onDestroy()
    }

    private fun publishFailure(requestId: String, reason: String) = publish(requestId,
        CodexOfflineProbe.fail(CodexOfflineProbe.envelope(requestId, Process.myUid(), Process.myPid()), reason))

    private fun publish(requestId: String, result: JSONObject) = synchronized(lock) {
        val target = resultFile(this, requestId)
        check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs())
        val atomic = AtomicFile(target)
        val stream = atomic.startWrite()
        try {
            stream.write(result.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(stream)
        } catch (error: Exception) {
            atomic.failWrite(stream)
            throw error
        }
    }

    companion object {
        // Cancellation is asynchronous. A replacement Service instance must
        // still observe the old worker until it finishes teardown/publication.
        private val lock = Any()
        private var active: Active? = null
        const val ACTION = "tech.zseven.rish.action.CODEX_OFFLINE_PROBE"
        const val ACTION_CANCEL = "tech.zseven.rish.action.CANCEL_CODEX_OFFLINE_PROBE"
        const val EXTRA_REQUEST_ID = "request_id"
        const val EXTRA_ENGINE_ID = "engine_id"

        /** Includes subprocess teardown, home cleanup, and receipt publication. */
        fun requestIsActive(requestId: String): Boolean {
            require(CodexOfflineProbe.validRequestId(requestId))
            return synchronized(lock) { active?.requestId == requestId }
        }

        fun resultFile(context: Context, requestId: String): File {
            require(CodexOfflineProbe.validRequestId(requestId))
            return File(context.cacheDir, "codex-offline-probe-results/$requestId.json")
        }
    }
}
