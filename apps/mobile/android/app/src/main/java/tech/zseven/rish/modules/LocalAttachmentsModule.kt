package tech.zseven.rish.modules

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableArray
import org.json.JSONArray
import org.json.JSONObject
import tech.zseven.rish.runtime.AndroidAttachmentStore
import tech.zseven.rish.runtime.AndroidRuntimeState
import tech.zseven.rish.runtime.RuntimeJson
import java.io.File
import java.util.UUID

/**
 * LocalAttachments on Android: picking a file, and keeping it.
 *
 * The rules for what may become an attachment live in
 * [AndroidAttachmentStore]; this is the part that needs an activity. A
 * picker is asynchronous in a way the rest of the bridge is not -- the
 * promise is answered by an activity result that arrives much later, or
 * never -- so exactly one request is in flight at a time and the one that
 * came first is the one that gets the answer.
 *
 * Documents and photographs go through the storage access framework, which
 * needs no permission and no manifest queries. The camera writes into a file
 * this app owns and hands it over through the same `FileProvider` a preview
 * uses, so nothing here ever asks for storage access it does not need.
 */
class LocalAttachmentsModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext), ActivityEventListener {

    private val runtime = AndroidRuntimeState.get(reactContext)

    /** The request this module is waiting on, if any. */
    private class Pending(
        val code: Int,
        val kind: Kind,
        val promise: Promise,
        val capture: File? = null,
        val captureUri: Uri? = null,
    ) {
        enum class Kind { PICK, PREVIEW }
    }

    @Volatile private var pending: Pending? = null

    init {
        reactContext.addActivityEventListener(this)
    }

    /**
     * `model_delivery` lists the attachment kinds this platform can actually
     * put in front of a model. An image becomes a content part and text is
     * folded into the message, both in `AndroidAttachmentContent`; a PDF is
     * not here because Android has no text extractor in this app and sending
     * the words around a PDF while dropping the PDF would answer a question
     * about a document the model never saw.
     *
     * JavaScript reads this to stop a send before a turn starts, with the
     * draft and the attachment kept, rather than letting the person watch a
     * round fail for a reason nothing explains. iOS exports no such key, and
     * an absent key means every kind.
     */
    override fun getConstants(): MutableMap<String, Any> = mutableMapOf(
        "implemented" to true,
        "model_delivery" to listOf("image", "text"),
    )

    override fun getName(): String = "LocalAttachments"

    override fun invalidate() {
        reactApplicationContext.removeActivityEventListener(this)
        super.invalidate()
    }

    @ReactMethod
    fun present(source: String?, promise: Promise) {
        val activity = reactApplicationContext.currentActivity
        if (activity == null) {
            promise.reject("E_ATTACHMENT_UNAVAILABLE", "There is no screen to present a picker on")
            return
        }
        // Two pickers at once would leave one promise unanswered for good.
        synchronized(this) {
            if (pending != null) {
                promise.reject("E_ATTACHMENT_BUSY", "A picker is already open")
                return
            }
            val code = nextRequestCode()
            val captureFile = if (source == "camera") captureFile() else null
            val captureUri = captureFile?.let { file ->
                try {
                    FileProvider.getUriForFile(reactApplicationContext, authority(), file)
                } catch (failure: Exception) {
                    Log.w(TAG, "A capture target could not be shared", failure)
                    null
                }
            }
            if (source == "camera" && captureUri == null) {
                promise.reject("E_ATTACHMENT_UNAVAILABLE", "The camera is not available")
                return
            }
            val intent = when (source) {
                "camera" -> Intent(MediaStore.ACTION_IMAGE_CAPTURE)
                    .putExtra(MediaStore.EXTRA_OUTPUT, captureUri)
                    .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                "photos" -> documents("image/*")
                "files" -> documents("*/*")
                else -> {
                    promise.reject("E_ATTACHMENT_INVALID", "That attachment source is unknown")
                    return
                }
            }
            // Whether anything can answer is decided by starting it, not by
            // asking first: package visibility on modern Android hides most
            // targets from `resolveActivity`, so the pre-check refuses
            // pickers that would have opened perfectly well.
            pending = Pending(code, Pending.Kind.PICK, promise, captureFile, captureUri)
            try {
                activity.startActivityForResult(intent, code)
            } catch (failure: android.content.ActivityNotFoundException) {
                Log.w(TAG, "No app can answer that picker", failure)
                pending = null
                captureFile?.delete()
                promise.reject("E_ATTACHMENT_UNAVAILABLE", "No app can answer that picker")
            } catch (failure: Exception) {
                Log.w(TAG, "A picker could not be opened", failure)
                pending = null
                captureFile?.delete()
                promise.reject("E_ATTACHMENT_UNAVAILABLE", "The picker could not be opened")
            }
        }
    }

    @ReactMethod
    fun discard(ids: ReadableArray?, promise: Promise) =
        answer("discard", promise) { runtime.attachments.discard(strings(ids)) }

    @ReactMethod
    fun prune(referencedIds: ReadableArray?, promise: Promise) =
        answer("prune", promise) { runtime.attachments.prune(strings(referencedIds)) }

    @ReactMethod
    fun preview(id: String?, promise: Promise) =
        answer("preview", promise) {
            runtime.attachments.preview(id ?: throw AndroidAttachmentStore.Refused(
                "E_ATTACHMENT_INVALID", "Attachment id is missing",
            ))
        }

    /**
     * Hands the attachment to whatever app can show it, and answers when that
     * app is done. `closed` is the only status this result has, so it must
     * mean the viewer actually closed rather than merely opened.
     */
    @ReactMethod
    fun presentPreview(id: String?, promise: Promise) {
        val activity = reactApplicationContext.currentActivity
        if (activity == null) {
            promise.reject("E_ATTACHMENT_UNAVAILABLE", "There is no screen to present a preview on")
            return
        }
        val descriptor = id?.let { runtime.attachments.descriptor(it) }
        val payload = id?.let { runtime.attachments.payload(it) }
        if (descriptor == null || payload == null) {
            promise.reject("E_ATTACHMENT_NOT_FOUND", "No such attachment")
            return
        }
        synchronized(this) {
            if (pending != null) {
                promise.reject("E_ATTACHMENT_BUSY", "A picker is already open")
                return
            }
            val shared = try {
                FileProvider.getUriForFile(reactApplicationContext, authority(), payload)
            } catch (failure: Exception) {
                Log.w(TAG, "An attachment could not be shared", failure)
                promise.reject("E_ATTACHMENT_UNAVAILABLE", "The attachment could not be opened")
                return
            }
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(shared, descriptor.optString("mime_type"))
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val code = nextRequestCode()
            pending = Pending(code, Pending.Kind.PREVIEW, promise)
            try {
                activity.startActivityForResult(intent, code)
            } catch (failure: android.content.ActivityNotFoundException) {
                Log.w(TAG, "No app can open that attachment", failure)
                pending = null
                promise.reject("E_ATTACHMENT_UNAVAILABLE", "No app can open that attachment")
            } catch (failure: Exception) {
                Log.w(TAG, "An attachment could not be opened", failure)
                pending = null
                promise.reject("E_ATTACHMENT_UNAVAILABLE", "The attachment could not be opened")
            }
        }
    }

    override fun onActivityResult(
        activity: Activity,
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        val waiting = synchronized(this) {
            val current = pending ?: return
            if (current.code != requestCode) return
            pending = null
            current
        }
        runtime.io.execute {
            try {
                waiting.promise.resolve(
                    Arguments.makeNativeMap(RuntimeJson.map(selection(waiting, resultCode, data))),
                )
            } catch (refused: AndroidAttachmentStore.Refused) {
                Log.w(TAG, "An attachment could not be taken: ${refused.code}")
                waiting.promise.reject(refused.code, refused.reason)
            } catch (failure: Exception) {
                Log.w(TAG, "An attachment could not be taken", failure)
                waiting.promise.reject("E_ATTACHMENT_PERSISTENCE", "The attachment could not be stored")
            } finally {
                waiting.capture?.delete()
            }
        }
    }

    override fun onNewIntent(intent: Intent) = Unit

    /** What the activity result actually contains. */
    private fun selection(waiting: Pending, resultCode: Int, data: Intent?): JSONObject {
        // A viewer has only one outcome worth reporting: it is gone.
        if (waiting.kind == Pending.Kind.PREVIEW) {
            return JSONObject().put("schema_version", 1).put("status", "closed")
        }
        if (resultCode != Activity.RESULT_OK) {
            return JSONObject().put("schema_version", 1).put("status", "cancelled")
                .put("attachments", JSONArray())
        }
        val resolver = reactApplicationContext.contentResolver
        val uris = mutableListOf<Uri>()
        waiting.captureUri?.let { uris.add(it) }
        data?.data?.let { uris.add(it) }
        data?.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index)?.uri?.let { uris.add(it) }
            }
        }
        val accepted = JSONArray()
        for (uri in uris.distinct().take(MAX_PER_SELECTION)) {
            runtime.attachments.accept(resolver, uri)?.let { accepted.put(it) }
        }
        return JSONObject()
            .put("schema_version", 1)
            // A selection that contained nothing this app accepts is the same
            // outcome as picking nothing: the composer has nothing to add.
            .put("status", if (accepted.length() == 0) "cancelled" else "selected")
            .put("attachments", accepted)
    }

    private fun documents(type: String): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(type)
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)

    private fun captureFile(): File {
        val directory = File(reactApplicationContext.cacheDir, "captures")
        directory.mkdirs()
        return File(directory, "${UUID.randomUUID()}.jpg")
    }

    private fun authority(): String = "${reactApplicationContext.packageName}.fileprovider"

    private fun strings(value: ReadableArray?): List<String> {
        val array = value ?: return emptyList()
        return (0 until array.size()).mapNotNull { index ->
            try {
                array.getString(index)
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun answer(operation: String, promise: Promise, body: () -> JSONObject) {
        runtime.io.execute {
            try {
                promise.resolve(Arguments.makeNativeMap(RuntimeJson.map(body())))
            } catch (refused: AndroidAttachmentStore.Refused) {
                Log.w(TAG, "$operation refused: ${refused.code}")
                promise.reject(refused.code, refused.reason)
            } catch (failure: Exception) {
                Log.w(TAG, "$operation could not be answered", failure)
                promise.reject("E_ATTACHMENT_PERSISTENCE", "Attachment storage could not be read")
            }
        }
    }

    private fun nextRequestCode(): Int = (nextCode++ and 0xffff) or 0x5000

    private companion object {
        const val TAG = "RishAttachments"
        const val MAX_PER_SELECTION = 6
        var nextCode = 1
    }
}
