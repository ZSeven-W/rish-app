package tech.zseven.rish.runtime

import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/** Descriptor-relative I/O for the app-private Files browser.
 *
 * Android's public Os API has no openat/renameat. The process's own proc-fd
 * directory provides the same pinned-directory lookup without reflection or
 * a path re-resolution through mutable ancestor names. Every user component
 * is opened with O_NOFOLLOW, including directories inside the workspace.
 */
internal object AndroidWorkspaceFileIo {
    private const val CONFLICT = "E_WORKSPACE_CONFLICT"
    private const val NOT_FOUND = "E_WORKSPACE_NOT_FOUND"
    private const val PERSISTENCE = "E_WORKSPACE_PERSISTENCE"
    private const val UNAVAILABLE = "E_WORKSPACE_UNAVAILABLE"
    private const val MAX_TEXT_BYTES = 1024 * 1024

    data class Snapshot(val stat: StructStat, val bytes: ByteArray?) {
        val revision: String get() {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(metadata(stat).toByteArray(Charsets.UTF_8))
            bytes?.let { digest.update(it) }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        // Rename changes ctime. Verify displaced entries by identity and bytes.
        fun sameAfterMove(other: Snapshot?): Boolean = other != null &&
            sameStateAfterMove(stat, other.stat) &&
            if (bytes == null) other.bytes == null else other.bytes?.contentEquals(bytes) == true

        val modifiedMillis: Long get() = stat.st_mtime * 1000 +
            if (Build.VERSION.SDK_INT >= 27) stat.st_mtim.tv_nsec / 1_000_000 else 0
    }

    class Parent private constructor(
        private val descriptor: ParcelFileDescriptor,
        val leaf: String,
        private val recoveryDirectory: File,
    ) : Closeable {
        private val prefix get() = "/proc/self/fd/${descriptor.fd}"
        val target get() = "$prefix/$leaf"

        fun snapshot(maxBytes: Int = MAX_TEXT_BYTES, requireContent: Boolean = false): Snapshot? =
            snapshotName(leaf, maxBytes, requireContent)

        private fun snapshotName(name: String, maxBytes: Int = MAX_TEXT_BYTES, requireContent: Boolean = false,
            directory: ParcelFileDescriptor = descriptor): Snapshot? = native {
            val location = "/proc/self/fd/${directory.fd}/$name"
            val fd = try {
                // NONBLOCK makes even a concurrently substituted FIFO harmless.
                Os.open(location, OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or
                    OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
            } catch (error: ErrnoException) {
                if (error.errno == OsConstants.ENOENT) return@native null
                throw error
            }
            try {
                val before = Os.fstat(fd)
                if (!OsConstants.S_ISREG(before.st_mode) || before.st_nlink != 1L) {
                    refused(CONFLICT, "That entry is not a regular file with one link")
                }
                if (before.st_size > maxBytes && requireContent) {
                    refused(UNAVAILABLE, "This file is larger than the reader will show")
                }
                val bytes = if (before.st_size <= maxBytes) readBounded(fd, maxBytes) else null
                val after = Os.fstat(fd)
                val atPath = Os.lstat(location)
                if (metadata(before) != metadata(after) || metadata(after) != metadata(atPath)) {
                    refused(CONFLICT, "That file changed while it was read")
                }
                Snapshot(after, bytes)
            } finally {
                Os.close(fd)
            }
        }

        /** Keep the displaced entry until an atomic exchange's identity and bytes prove the CAS. */
        fun write(
            bytes: ByteArray,
            expected: String?,
            createOnly: Boolean,
            beforePublish: (() -> Unit)? = null,
            afterExchange: (() -> Unit)? = null,
        ): Pair<Snapshot, Boolean> = native {
            val prior = snapshot()
            if (prior != null && (createOnly || expected == null)) {
                refused(CONFLICT, "That file already exists")
            }
            if (expected != null && prior == null) refused(NOT_FOUND, "No such file")
            if (expected != null && prior?.revision != expected) {
                refused(CONFLICT, "That file changed since it was read")
            }
            // The app-owned container is outside every workspace root, so
            // neither file tools nor Git stage-all can read a displaced secret
            // under a different name. The same filesystem allows atomic moves.
            val storage = openStorage()
            val stagingName = "rish-edit-${UUID.randomUUID()}"
            val staging = "/proc/self/fd/${storage.fd}/$stagingName"
            val fd = try {
                Os.open(staging, OsConstants.O_WRONLY or OsConstants.O_CREAT or
                    OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0x180)
            } catch (error: Throwable) {
                storage.close()
                throw error
            }
            var published = false
            var replacement: Snapshot? = null
            try {
                var offset = 0
                while (offset < bytes.size) {
                    val count = Os.write(fd, bytes, offset, bytes.size - offset)
                    if (count <= 0) refused(PERSISTENCE, "File could not be written")
                    offset += count
                }
                prior?.let { Os.fchmod(fd, it.stat.st_mode and 0x1ff) }
                Os.fsync(fd)
                Os.fsync(storage.fileDescriptor)
                replacement = Snapshot(Os.fstat(fd), bytes)
                val latest = snapshot()
                if (latest?.revision != prior?.revision) {
                    refused(CONFLICT, "That file changed since it was read")
                }
                // A scoped test seam reproduces an agent write in the former
                // check-to-rename window. Production supplies no hook.
                beforePublish?.invoke()
                if (prior == null) {
                    AndroidWorkspaceFileNative.rename(storage.fd, stagingName, descriptor.fd, leaf, exchange = false)
                    published = true
                    Os.fsync(descriptor.fileDescriptor)
                    Os.fsync(storage.fileDescriptor)
                } else {
                    AndroidWorkspaceFileNative.rename(storage.fd, stagingName, descriptor.fd, leaf, exchange = true)
                    published = true
                    try {
                        afterExchange?.invoke()
                        if (!prior.sameAfterMove(snapshotName(stagingName, directory = storage)) ||
                            !replacement.sameAfterMove(snapshot())
                        ) refused(CONFLICT, "That file changed since it was read")
                        Os.fsync(descriptor.fileDescriptor)
                        Os.fsync(storage.fileDescriptor)
                        if (!prior.sameAfterMove(snapshotName(stagingName, directory = storage)) ||
                            !replacement.sameAfterMove(snapshot())
                        ) refused(CONFLICT, "That file changed while it was saved")
                        Os.remove(staging)
                    } catch (error: Exception) {
                        if (!restoreObservedBackup(storage, stagingName, replacement)) {
                            throw AndroidWorkspaceFiles.Refused(CONFLICT,
                                "File changed concurrently; a recoverable version remains at .rish-file-recovery/$stagingName")
                        }
                        throw error
                    }
                }
                val result = Snapshot(Os.fstat(fd), bytes)
                // The replacement is synced before backup deletion. Failure
                // of this final fsync can only retain a backup after a crash.
                try { Os.fsync(descriptor.fileDescriptor) } catch (_: ErrnoException) { }
                try { Os.fsync(storage.fileDescriptor) } catch (_: ErrnoException) { }
                Pair(result, prior == null)
            } finally {
                try {
                    val remains = Os.lstat(staging)
                    val owned = Os.fstat(fd)
                    if (remains.st_dev == owned.st_dev && remains.st_ino == owned.st_ino &&
                        (!published || replacement?.sameAfterMove(snapshotName(stagingName, directory = storage)) == true)
                    ) Os.remove(staging)
                } catch (_: Exception) { }
                try { Os.close(fd) } finally { storage.close() }
            }
        }

        private fun openStorage(): ParcelFileDescriptor {
            try { Os.mkdir(recoveryDirectory.absolutePath, 0x1c0) } catch (error: ErrnoException) {
                if (error.errno != OsConstants.EEXIST) throw error
            }
            return openDirectory(recoveryDirectory.absolutePath)
        }

        private fun restoreObservedBackup(storage: ParcelFileDescriptor, name: String, replacement: Snapshot): Boolean = try {
            val observed = Os.lstat("/proc/self/fd/${storage.fd}/$name")
            if (!replacement.sameAfterMove(snapshot())) false else {
                AndroidWorkspaceFileNative.rename(storage.fd, name, descriptor.fd, leaf, exchange = true)
                val restored = sameStateAfterMove(observed, Os.lstat(target)) &&
                    replacement.sameAfterMove(snapshotName(name, directory = storage))
                if (restored) {
                    Os.fsync(descriptor.fileDescriptor)
                    Os.fsync(storage.fileDescriptor)
                }
                restored
            }
        } catch (_: Exception) {
            false
        }

        fun createDirectory(): StructStat = native {
            Os.mkdir(target, 0x1c0)
            Os.lstat(target)
        }

        override fun close() = descriptor.close()

        companion object {
            fun open(root: File, path: String): Parent = native {
                val components = path.split('/')
                // The caller already applied the shared path rules. Keep this
                // helper safe even when used without that caller.
                if (components.any { it.isEmpty() || it == "." || it == ".." || it.contains('\u0000') }) {
                    refused(CONFLICT, "Path is invalid")
                }
                var current = openDirectory(root.absolutePath)
                try {
                    for (component in components.dropLast(1)) {
                        val next = openDirectory("/proc/self/fd/${current.fd}/$component")
                        current.close()
                        current = next
                    }
                    val container = root.absoluteFile.parentFile ?: refused(CONFLICT, "Workspace root is invalid")
                    Parent(current, components.last(), File(container, ".rish-file-recovery"))
                } catch (error: Throwable) {
                    current.close()
                    throw error
                }
            }

            private fun openDirectory(path: String): ParcelFileDescriptor {
                // O_DIRECTORY is not exposed by Android's public API. Open
                // without following links or blocking on a FIFO, then prove
                // the descriptor is a directory before using it for lookup.
                val fd = Os.open(path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or
                    OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
                try {
                    if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) {
                        refused(CONFLICT, "No such directory")
                    }
                    return ParcelFileDescriptor.dup(fd)
                } finally {
                    Os.close(fd)
                }
            }
        }
    }

    fun stat(file: File): StructStat? = native {
        try { Os.lstat(file.path) } catch (error: ErrnoException) {
            if (error.errno == OsConstants.ENOENT) null else throw error
        }
    }

    fun safeKind(stat: StructStat): Boolean = OsConstants.S_ISDIR(stat.st_mode) ||
        (OsConstants.S_ISREG(stat.st_mode) && stat.st_nlink == 1L)

    private fun sameStateAfterMove(left: StructStat, right: StructStat): Boolean =
        left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
            left.st_mode == right.st_mode && left.st_nlink == right.st_nlink &&
            left.st_size == right.st_size && left.st_mtime == right.st_mtime &&
            (Build.VERSION.SDK_INT < 27 || left.st_mtim.tv_nsec == right.st_mtim.tv_nsec)

    private fun metadata(stat: StructStat): String = buildString {
        append(stat.st_dev).append(':').append(stat.st_ino).append(':')
        append(stat.st_mode).append(':').append(stat.st_nlink).append(':').append(stat.st_size).append(':')
        append(stat.st_mtime).append(':').append(stat.st_ctime).append(':')
        if (Build.VERSION.SDK_INT >= 27) {
            append(stat.st_mtim.tv_nsec).append(':').append(stat.st_ctim.tv_nsec)
        }
        append('\n')
    }

    private fun readBounded(fd: FileDescriptor, max: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (true) {
            val count = Os.read(fd, chunk, 0, minOf(chunk.size, max - output.size() + 1))
            if (count == 0) break
            output.write(chunk, 0, count)
            if (output.size() > max) refused(UNAVAILABLE, "This file is larger than the reader will show")
        }
        return output.toByteArray()
    }

    private inline fun <T> native(body: () -> T): T = try {
        body()
    } catch (error: ErrnoException) {
        val code = when (error.errno) {
            OsConstants.ENOENT -> NOT_FOUND
            OsConstants.EEXIST, OsConstants.ELOOP, OsConstants.ENOTDIR, OsConstants.EISDIR -> CONFLICT
            else -> PERSISTENCE
        }
        refused(code, "Workspace file operation could not be completed")
    } catch (_: IOException) {
        refused(PERSISTENCE, "Workspace file operation could not be completed")
    }

    private fun refused(code: String, reason: String): Nothing = throw AndroidWorkspaceFiles.Refused(code, reason)
}
