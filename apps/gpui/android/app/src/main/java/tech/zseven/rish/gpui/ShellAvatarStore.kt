package tech.zseven.rish.gpui

import android.content.Context
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

/** Pinned private directory descriptors keep intermediate paths out of URI input. */
internal object ShellAvatarStore {
    fun save(context: Context, image: EncodedAvatar, cancelled: () -> Boolean): JSONObject {
        if (image.width !in 1..512 || image.height !in 1..512 || image.bytes.size !in 1..ShellAvatarContract.MAX_PNG_BYTES) {
            throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
        }
        val id = UUID.randomUUID().toString()
        withAvatars(context) { directory, directoryDescriptor ->
            val temporary = "$directory/.$id.tmp"
            val destination = "$directory/$id.png"
            var reserved = false
            try {
                if (cancelled()) throw BridgeFailure("E_ASSISTANT_AVATAR_CANCELLED")
                val descriptor = Os.open(temporary, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0x180)
                FileOutputStream(descriptor).use { output ->
                    Os.fchmod(descriptor, 0x180)
                    val stat = Os.fstat(descriptor)
                    if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_nlink != 1L) throw BridgeFailure("E_ASSISTANT_STORAGE")
                    output.write(image.bytes)
                    output.fd.sync()
                }
                if (cancelled()) throw BridgeFailure("E_ASSISTANT_AVATAR_CANCELLED")
                // Android app storage may reject hard links. Reserve our UUID
                // exclusively, then atomically rename the completed pixels over
                // that private placeholder before exposing any metadata.
                val destinationDescriptor = Os.open(destination, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0x180)
                reserved = true
                Os.close(destinationDescriptor)
                Os.rename(temporary, destination)
                Os.fsync(directoryDescriptor)
                if (cancelled()) throw BridgeFailure("E_ASSISTANT_AVATAR_CANCELLED")
            } catch (error: Throwable) {
                runCatching { Os.remove(temporary) }
                if (reserved) runCatching { Os.remove(destination) }
                throw error
            }
        }
        val sha = MessageDigest.getInstance("SHA-256").digest(image.bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        return JSONObject().put("id", id).put("sha256", sha).put("mime_type", "image/png")
            .put("width", image.width).put("height", image.height).put("byte_length", image.bytes.size)
    }

    /** Only unpublished late results are removed; profile-owned images are retained. */
    fun discardUnpublished(context: Context, avatar: JSONObject) {
        val id = avatar.optString("id")
        if (runCatching { UUID.fromString(id).toString() }.getOrNull() != id) return
        runCatching { withAvatars(context) { path, _ -> Os.remove("$path/$id.png") } }
    }

    private fun openDirectory(path: String): ParcelFileDescriptor {
        val descriptor = Os.open(path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) throw BridgeFailure("E_ASSISTANT_STORAGE")
            return ParcelFileDescriptor.dup(descriptor)
        } finally { Os.close(descriptor) }
    }

    private fun <T> withAvatars(context: Context, body: (String, FileDescriptor) -> T): T {
        val root = ShellAssistantRoutes.storageDirectory(context)
        return openDirectory(root.path).use { rootDescriptor ->
            val pinnedRoot = "/proc/self/fd/${rootDescriptor.fd}"
            val path = "$pinnedRoot/avatars"
            try { Os.mkdir(path, 0x1c0) }
            catch (error: ErrnoException) { if (error.errno != OsConstants.EEXIST) throw error }
            openDirectory(path).use { directory ->
                Os.fchmod(directory.fileDescriptor, 0x1c0)
                body("/proc/self/fd/${directory.fd}", directory.fileDescriptor)
            }
        }
    }
}
