package tech.zseven.rish.gpui

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import tech.zseven.rish.runtime.AndroidAssistantStorage

/** App-private storage location only; the Rust assistant owns its persisted records. */
internal object ShellAssistantRoutes {
    fun call(context: Context, method: String, args: JSONArray): JSONObject {
        if (method != "storage") throw BridgeFailure("E_BRIDGE_UNAVAILABLE")
        require(args.length() == 0)
        val directory = storageDirectory(context)
        return JSONObject().put("schema_version", 1).put("directory", directory.path)
            .put("platform", "android")
    }

    fun storageDirectory(context: Context): File {
        return try { AndroidAssistantStorage.directory(context) }
        catch (_: Exception) { throw BridgeFailure("E_ASSISTANT_STORAGE") }
    }
}
