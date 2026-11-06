package tech.zseven.rish.gpui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.tasks.TaskExperience
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Main-thread picker lifetime; the worker retains only application context. */
internal object ShellAvatarPicker {
    const val TOKEN = "rish.avatar.token"
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val lease = AvatarPickLease<Result<JSONObject?>>()
    private var owner = WeakReference<Activity>(null)
    private var helper = WeakReference<Activity>(null)
    private var current: String? = null
    private var job: ReadJob? = null
    private var timeout: Runnable? = null

    fun present(activity: Activity?, args: JSONArray, callback: (Result<JSONObject?>) -> Unit) {
        ShellAvatarContract.validate(args)
        val screen = activity?.takeUnless { it.isDestroyed || it.isFinishing }
            ?: throw BridgeFailure("E_ASSISTANT_AVATAR_UNAVAILABLE")
        if (!TaskExperience.foreground) throw BridgeFailure("E_ASSISTANT_AVATAR_UNAVAILABLE")
        val token = lease.begin(callback)
        current = token
        owner = WeakReference(screen)
        try { screen.startActivity(Intent(screen, ShellAvatarPickerActivity::class.java).putExtra(TOKEN, token)) }
        catch (error: Throwable) { complete(token, Result.failure(BridgeFailure("E_ASSISTANT_AVATAR_UNAVAILABLE"))) }
    }

    fun attach(token: String, activity: Activity): Boolean {
        if (!lease.active(token)) return false
        helper = WeakReference(activity)
        return true
    }

    fun cancel(token: String) = complete(token, Result.success(null))
    fun fail(token: String) = complete(token, Result.failure(BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")))
    fun detachOwner(activity: Activity) {
        if (owner.get() === activity) current?.let(::cancel)
    }

    fun selected(token: String, context: Context, uri: Uri) {
        if (!lease.active(token) || job != null) return
        if (uri.scheme != "content") { fail(token); return }
        val application = context.applicationContext
        val request = ReadJob()
        job = request
        val deadline = Runnable {
            complete(token, Result.failure(BridgeFailure("E_ASSISTANT_AVATAR_TIMEOUT")))
        }
        timeout = deadline
        main.postDelayed(deadline, 30_000)
        worker.execute {
            val result = runCatching {
                val source = request.read(application, uri)
                request.check()
                val image = ShellAvatarImage.encode(source)
                request.check()
                ShellAvatarStore.save(application, image) { request.cancelled.get() }
            }.fold(
                onSuccess = { avatar -> Result.success(JSONObject().put("schema_version", 1).put("avatar", avatar)) },
                onFailure = { Result.failure(BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")) },
            )
            main.post {
                if (!complete(token, result)) result.getOrNull()?.optJSONObject("avatar")?.let { avatar ->
                    worker.execute { ShellAvatarStore.discardUnpublished(application, avatar) }
                }
            }
        }
    }

    private fun complete(token: String, value: Result<JSONObject?>): Boolean {
        if (!lease.active(token)) return false
        timeout?.let(main::removeCallbacks)
        timeout = null
        job?.cancel()
        job = null
        current = null
        owner.clear()
        val activity = helper.get()
        helper.clear()
        try { return lease.finish(token, value) }
        finally { if (activity != null && !activity.isFinishing) activity.finish() }
    }

    private class ReadJob {
        val cancelled = AtomicBoolean(false)
        private val cancellation = CancellationSignal()
        private val input = AtomicReference<Closeable?>(null)
        fun check() {
            if (cancelled.get()) throw BridgeFailure("E_ASSISTANT_AVATAR_CANCELLED")
        }
        fun cancel() {
            cancelled.set(true)
            cancellation.cancel()
            runCatching { input.getAndSet(null)?.close() }
        }
        fun read(context: Context, uri: Uri): ByteArray {
            check()
            context.contentResolver.openAssetFileDescriptor(uri, "r", cancellation)?.use { asset ->
                if (asset.length > ShellAvatarContract.MAX_SOURCE_BYTES) throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
                asset.createInputStream().use { stream ->
                    input.set(stream)
                    try {
                        check()
                        val bytes = ByteArrayOutputStream()
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            check()
                            val count = stream.read(buffer)
                            if (count < 0) break
                            if (bytes.size() + count > ShellAvatarContract.MAX_SOURCE_BYTES) throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
                            bytes.write(buffer, 0, count)
                        }
                        return bytes.toByteArray()
                    } finally { input.compareAndSet(stream, null) }
                }
            }
            throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
        }
    }
}
