package tech.zseven.rish.gpui

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.tasks.TaskExperience
import tech.zseven.rish.tasks.TaskPolicy
import java.lang.ref.WeakReference

/** All calls run on the main thread, including permission callbacks. */
internal object TaskExperienceRoutes {
    const val PERMISSION_REQUEST = 9131
    object Pending
    private var permissionOwner = WeakReference<Activity>(null)
    private val permissionReplies = mutableListOf<(JSONObject) -> Unit>()

    fun call(activity: Activity?, method: String, args: JSONArray, reply: (JSONObject) -> Unit): Any {
        if (method != "handle") throw BridgeFailure("E_BRIDGE_UNAVAILABLE")
        require(args.length() == 1)
        val request = args.getJSONObject(0)
        require(TaskPolicy.validSchema(request.opt("schema_version")))
        if (request.optString("op") != "permission") return TaskExperience.handle(request)
        require(request.keys().asSequence().toSet() == setOf("schema_version", "op", "userInitiated"))
        require(request.opt("userInitiated") == true)
        if (Build.VERSION.SDK_INT < 33 || activity == null || activity.isFinishing || activity.isDestroyed ||
            !TaskExperience.foreground || activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            return TaskExperience.settings()
        }
        val owner = permissionOwner.get()
        if (owner != null && owner !== activity) return TaskExperience.settings()
        permissionReplies.add(reply)
        if (owner == null) {
            permissionOwner = WeakReference(activity)
            TaskExperience.permissionRequested()
            try { activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST) }
            catch (_: RuntimeException) { complete(activity) }
        }
        return Pending
    }

    fun permissionResult(activity: Activity, requestCode: Int) {
        if (requestCode == PERMISSION_REQUEST) complete(activity)
    }

    fun detach(activity: Activity) = complete(activity)

    private fun complete(activity: Activity) {
        if (permissionOwner.get() !== activity) return
        permissionOwner.clear()
        val callbacks = permissionReplies.toList()
        permissionReplies.clear()
        val result = TaskExperience.settings()
        callbacks.forEach { it(result) }
    }
}
