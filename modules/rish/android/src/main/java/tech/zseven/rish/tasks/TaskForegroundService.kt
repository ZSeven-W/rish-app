package tech.zseven.rish.tasks

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Holds OS runtime for an already admitted task; never starts or restores work. */
class TaskForegroundService : Service() {
    private var owner: String? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val run = intent?.getStringExtra("runId")
        if (!TaskExperience.canAdmitBackground(run)) {
            // An obsolete start still owes Android either promotion or stop.
            // Preserve a service already owned by the current run, but stop an
            // unowned instance before the foreground-start deadline can kill us.
            if (!TaskExperience.canAdmitBackground(owner)) {
                // Android can still enforce the promotion deadline even when a
                // just-created service stops itself. A separate cleanup card
                // satisfies the protocol without claiming the current run.
                try {
                    promote(TaskExperience.RETIRED_START_ID, TaskExperience.retiredStartNotification())
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } catch (_: RuntimeException) {
                    // No run was acquired when the system rejects admission.
                } finally { stopSelfResult(startId) }
            }
            return START_NOT_STICKY
        }
        owner = run
        val notification = TaskExperience.progressNotification() ?: kotlin.run {
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        try {
            promote(TaskExperience.ONGOING_ID, notification)
            TaskExperience.backgroundAccepted(run!!)
        } catch (_: RuntimeException) {
            TaskExperience.backgroundLost(run!!); stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }
    private fun promote(id: Int, notification: android.app.Notification) {
        if (Build.VERSION.SDK_INT >= 29) startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(id, notification)
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        expireOwner(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    override fun onTaskRemoved(rootIntent: Intent?) {
        expireOwner(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    override fun onDestroy() {
        owner?.let { TaskExperience.backgroundLost(it) }
        super.onDestroy()
    }
    private fun expireOwner() { owner?.let { TaskExperience.expire(it) } }
}
