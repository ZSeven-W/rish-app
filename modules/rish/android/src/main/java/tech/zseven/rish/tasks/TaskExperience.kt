package tech.zseven.rish.tasks

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** Main-thread-only display/lifecycle coordinator. A saved display never authorizes work. */
internal object TaskExperience {
    const val ONGOING_ID = 9101
    const val RETIRED_START_ID = 9102
    const val RUNNING_CHANNEL = "rish.task.running.v1"
    private const val ALERT_CHANNEL = "rish.task.alerts.v1"
    const val OPEN = "tech.zseven.rish.OPEN_TASK"
    const val CANCEL = "tech.zseven.rish.CANCEL_TASK"
    // Process-lifetime Application only; never retain an Activity here.
    private lateinit var context: android.app.Application
    private val prefs get() = context.getSharedPreferences("rish.task.experience.v1", Context.MODE_PRIVATE)
    private val notifications get() = context.getSystemService(NotificationManager::class.java)
    var emit: ((String) -> Unit)? = null
    var emitLifecycle: ((Boolean) -> Unit)? = null
    var foreground = false
        private set
    private var visible: String? = null
    private var locale = Locale.getDefault().toLanguageTag()
    private var current: Run? = null
    private val queued = linkedMapOf<String, JSONObject>()
    private val notified = mutableSetOf<String>()
    private var preferences = defaults()
    var backgroundAdmission = "notRequested"
        private set
    data class Run(val id: String, val conversation: String, var phase: String, val backgroundEligible: Boolean = false, val startedAt: Long = System.currentTimeMillis(), var stopRequested: Boolean = false, var interrupted: Boolean = false)
    fun activeRun(): Run? = current

    fun initialize(app: Context) {
        if (::context.isInitialized) return
        context = app.applicationContext as android.app.Application
        preferences = try { validatePreferences(JSONObject(prefs.getString("preferences", "{}")!!)) } catch (_: Exception) { defaults() }
        // Cancel only our orphan progress card. Completion alerts remain readable.
        notifications.cancel(ONGOING_ID)
        notifications.cancel(RETIRED_START_ID)
        prefs.edit().remove("activeRun").apply()
        if (Build.VERSION.SDK_INT >= 26) {
            notifications.createNotificationChannel(NotificationChannel(RUNNING_CHANNEL, "Rish task status", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Status of a user-started Rish task"; setShowBadge(false)
            })
            notifications.createNotificationChannel(NotificationChannel(ALERT_CHANNEL, "Rish task alerts", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Opt-in completion, failure and attention alerts"
            })
        }
    }
    private fun defaults() = JSONObject().put("completed", false).put("failed", false).put("attention", false)
        .put("liveActivity", false).put("background", false).put("muted", JSONArray())
    private fun validId(id: String): Boolean = id.isNotEmpty() && id.toByteArray(Charsets.UTF_8).size <= 256 && !id.contains('\u0000')
    private fun validatePreferences(raw: JSONObject): JSONObject {
        val keys = setOf("completed", "failed", "attention", "liveActivity", "background", "muted")
        require(raw.keys().asSequence().toSet() == keys)
        for (key in keys - "muted") require(raw.get(key) is Boolean)
        val muted = raw.getJSONArray("muted")
        require(muted.length() <= 500)
        for (index in 0 until muted.length()) require(muted.get(index) is String && validId(muted.getString(index)))
        return JSONObject(raw.toString())
    }
    private fun enabled(key: String) = preferences.getBoolean(key)
    private fun muted(id: String): Boolean = preferences.getJSONArray("muted").let { list -> (0 until list.length()).any { list.getString(it) == id } }
    fun permissionRequested() { prefs.edit().putBoolean("permissionRequested", true).apply() }
    fun authorization(): String {
        if (notifications.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)) return "authorized"
        return if (Build.VERSION.SDK_INT >= 33 && !prefs.getBoolean("permissionRequested", false)) "notDetermined" else "denied"
    }
    fun settings(): JSONObject = JSONObject().put("available", true).put("notifications", authorization())
        .put("liveActivitiesAvailable", false).put("backgroundAvailable", true)
        .put("backgroundAdmission", backgroundAdmission).put("foreground", foreground)
        .put("preferences", JSONObject(preferences.toString()))

    fun handle(request: JSONObject): Any {
        require(TaskPolicy.validSchema(request.opt("schema_version")))
        return when (request.getString("op")) {
            "settings" -> settings()
            "preferences" -> {
                val next = validatePreferences(request.getJSONObject("preferences"))
                check(prefs.edit().putString("preferences", next.toString()).commit())
                preferences = next
                if (!enabled("background")) {
                    context.stopService(Intent(context, TaskForegroundService::class.java))
                    backgroundAdmission = "notRequested"
                    if (!foreground) current?.let { expire(it.id) }
                }
                refreshProgress(); settings()
            }
            "visible" -> {
                visible = request.opt("conversationId") as? String
                (request.opt("locale") as? String)?.let { if (it in setOf("zh-CN", "en-US")) locale = it }
                true
            }
            "drain" -> JSONArray(queued.values.toList()).also { queued.clear() }
            "begin" -> {
                val runId = request.getString("runId"); val conversation = request.getString("conversationId")
                require(validId(runId) && validId(conversation))
                require(request.opt("backgroundEligible") is Boolean)
                val backgroundEligible = request.opt("backgroundEligible") == true
                require(current == null || (current?.id == runId && current?.conversation == conversation))
                if (current == null) {
                    current = Run(runId, conversation, "preparing", backgroundEligible)
                    prefs.edit().putString("activeRun", runId).apply()
                    notified.clear(); backgroundAdmission = "notRequested"
                    if (backgroundEligible && enabled("background") && foreground) {
                        val intent = Intent(context, TaskForegroundService::class.java).putExtra("runId", runId)
                        try {
                            backgroundAdmission = "submitted"
                            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                        } catch (_: RuntimeException) { backgroundAdmission = "unavailable" }
                    }
                    refreshProgress()
                    if (!foreground && backgroundAdmission != "accepted") requestCancel(runId, conversation, true)
                }
                JSONObject().put("schema_version", 1).put("started", true)
                    .put("backgroundAdmission", backgroundAdmission)
                    .put("backgroundAccepted", backgroundAdmission == "accepted")
            }
            "update" -> {
                val phase = request.getString("phase")
                require(phase in setOf("preparing", "persistence_pending", "starting", "sending", "approval_pending", "executing", "recovering", "cancelling", "finalizing", "retryable", "resume_available", "commit_pending", "blocked"))
                val run = current
                if (run != null && TaskPolicy.owns(request.optString("runId"), run.id) && !run.stopRequested) {
                    if (phase != "approval_pending") notified.remove("attention")
                    run.phase = phase; refreshProgress()
                    if (phase == "approval_pending") alert("attention")
                    true
                } else false
            }
            "end" -> finish(request.getString("runId"), request.getString("status"))
            else -> throw IllegalArgumentException("Unknown task operation")
        }
    }
    fun resume() {
        if (foreground) return
        foreground = true
        emitLifecycle?.invoke(true)
    }
    fun pause() {
        if (!foreground) return
        foreground = false; visible = null
        emitLifecycle?.invoke(false)
        current?.let { if (backgroundAdmission !in setOf("accepted", "submitted")) requestCancel(it.id, it.conversation, true) }
    }
    fun canAdmitBackground(runId: String?): Boolean {
        val run = current ?: return false
        return TaskPolicy.owns(runId, run.id) && run.backgroundEligible && !run.stopRequested &&
            enabled("background") && backgroundAdmission in setOf("submitted", "accepted")
    }
    fun backgroundAccepted(runId: String) {
        if (canAdmitBackground(runId)) backgroundAdmission = "accepted"
    }
    fun backgroundLost(runId: String) {
        val run = current ?: return
        if (!TaskPolicy.owns(runId, run.id)) return
        backgroundAdmission = if (enabled("background") && run.backgroundEligible) "unavailable" else "notRequested"
        if (!foreground) expire(run.id)
    }
    /** OS expiry revokes this display/FGS owner after notifying the process runner. */
    fun expire(runId: String): Boolean {
        val run = current ?: return false
        if (!TaskPolicy.owns(runId, run.id)) return false
        requestCancel(run.id, run.conversation, true)
        return finish(run.id, "cancelled")
    }
    fun requestCancel(runId: String, conversation: String, interrupted: Boolean = false): Boolean {
        val run = current ?: return false
        if (!TaskPolicy.owns(runId, run.id) || run.conversation != conversation || run.stopRequested) return false
        run.stopRequested = true; run.interrupted = interrupted; run.phase = "cancelling"
        queue("cancel", runId, conversation, if (interrupted) "background_expired" else "user_stop")
        refreshProgress()
        return true
    }
    fun open(intent: Intent?) {
        if (intent?.action != OPEN) return
        val run = intent.getStringExtra("runId") ?: return
        val conversation = intent.getStringExtra("conversationId") ?: return
        if (validId(run) && validId(conversation)) queue("open", run, conversation)
    }
    private fun queue(action: String, runId: String, conversation: String, reason: String? = null) {
        val event = JSONObject().put("schema_version", 1).put("action", action).put("runId", runId).put("conversationId", conversation)
        if (reason != null) event.put("reason", reason)
        queued["$action:$runId"] = event
        while (queued.size > 32) queued.remove(queued.keys.first())
        try { emit?.invoke(event.toString()) } catch (_: RuntimeException) {
            // Keep the action queued if the host is being torn down.
        }
    }
    private fun finish(runId: String, status: String): Boolean {
        val run = current ?: return false
        if (!TaskPolicy.owns(runId, run.id)) return false
        if (status == "completed") alert("completed") else if (status != "cancelled" || run.interrupted) alert("failed")
        current = null
        backgroundAdmission = "notRequested"
        prefs.edit().remove("activeRun").apply()
        notifications.cancel(ONGOING_ID)
        context.stopService(Intent(context, TaskForegroundService::class.java))
        return true
    }
    private fun label(en: String, zh: String) = if (locale.startsWith("zh")) zh else en
    private fun stage(phase: String): String = when (phase) {
        "preparing", "starting" -> label("Preparing", "正在准备")
        "sending" -> label("Waiting for model", "等待模型回复")
        "executing" -> label("Running tools", "正在执行工具")
        "approval_pending" -> label("Needs your attention", "需要你处理")
        "finalizing" -> label("Saving result", "正在保存结果")
        "cancelling" -> label("Stopping safely", "正在安全停止")
        else -> label("Return to Rish to continue", "返回 Rish 继续处理")
    }
    private fun openIntent(run: Run): PendingIntent {
        val intent = requireNotNull(context.packageManager.getLaunchIntentForPackage(context.packageName)).setAction(OPEN)
            .setData(Uri.Builder().scheme("rish-task").authority("open").appendPath(run.id).build())
            .putExtra("runId", run.id).putExtra("conversationId", run.conversation)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    fun retiredStartNotification(): Notification = builder(RUNNING_CHANNEL, label("Finishing task", "结束任务")).setOnlyAlertOnce(true).build()
    fun progressNotification(): Notification? {
        val run = current ?: return null
        val cancel = Intent(context, TaskActionReceiver::class.java).setAction(CANCEL)
            .setData(Uri.Builder().scheme("rish-task").authority("cancel").appendPath(run.id).build())
            .putExtra("runId", run.id).putExtra("conversationId", run.conversation)
        val pending = PendingIntent.getBroadcast(context, 0, cancel, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return builder(RUNNING_CHANNEL, stage(run.phase)).setOngoing(true).setOnlyAlertOnce(true)
            .setWhen(run.startedAt).setShowWhen(true).setUsesChronometer(true)
            .setContentIntent(openIntent(run)).addAction(android.R.drawable.ic_menu_close_clear_cancel, label("Stop", "停止"), pending).build()
    }
    private fun builder(channel: String, body: String): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else Notification.Builder(context)
        return builder.setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("Rish").setContentText(body)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_PROGRESS)
            .setShowWhen(false)
    }
    private fun refreshProgress() {
        if (current == null) return
        if ((enabled("liveActivity") || backgroundAdmission in setOf("accepted", "submitted")) && authorization() == "authorized") {
            try { notifications.notify(ONGOING_ID, progressNotification()) } catch (_: SecurityException) { }
        } else if (backgroundAdmission !in setOf("accepted", "submitted")) notifications.cancel(ONGOING_ID)
    }
    private fun alert(kind: String) {
        val run = current ?: return
        if (!TaskPolicy.allowsAlert(kind, enabled(kind), muted(run.conversation), foreground && visible == run.conversation,
                kind in notified, true) || authorization() != "authorized") return
        val body = when (kind) {
            "completed" -> label("Task complete", "任务已完成")
            "attention" -> label("Needs your attention", "需要你处理")
            else -> label("Task needs review", "任务需要检查")
        }
        val notification = builder(ALERT_CHANNEL, body).setCategory(Notification.CATEGORY_STATUS).setAutoCancel(true)
            .setContentIntent(openIntent(run)).build()
        try { notifications.notify(run.id, listOf("completed", "failed", "attention").indexOf(kind) + 1, notification); notified.add(kind) }
        catch (_: SecurityException) { }
    }
}
