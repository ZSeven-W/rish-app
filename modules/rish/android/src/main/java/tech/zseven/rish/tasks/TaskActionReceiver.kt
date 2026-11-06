package tech.zseven.rish.tasks

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class TaskActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TaskExperience.CANCEL) return
        val run = intent.getStringExtra("runId") ?: return
        val conversation = intent.getStringExtra("conversationId") ?: return
        TaskExperience.requestCancel(run, conversation)
    }
}
