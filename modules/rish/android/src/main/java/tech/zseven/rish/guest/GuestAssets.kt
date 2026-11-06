package tech.zseven.rish.guest

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/**
 * Pinned identity of the bundled guest boot assets. The names and digests
 * must match modules/rish/shared/GuestAssets/SHA256SUMS: the same two files
 * are packaged into the Android APK's assets by app/build.gradle, and
 * scripts/tests/guest-assets.test.mjs checks that this file carries the
 * digests recorded there.
 */
object GuestAssets {
    const val KERNEL_NAME = "vmlinuz-virt-6.18.35"
    const val INITRAMFS_NAME = "rish-container.cpio"
    const val KERNEL_SHA256 = "1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90"
    const val INITRAMFS_SHA256 = "17923f268be4e0b6fbfa6d0410094fb9b9d216e69fd4341ffbb839ec592926b0"

    /** Fixed, known-good kernel command line for the baked container initramfs. */
    const val COMMAND_LINE =
        "console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr cgroup_no_v1=all 8250.nr_uarts=1"

    /** Directory under Context.filesDir where the verified copies live. */
    const val STAGING_DIRECTORY = "rish-guest"

    /**
     * A throwaway root disk this app supplies itself.
     *
     * An initramfs boot never reads a root disk, but VmConfig demands a path,
     * and when the caller omits one the runtime makes a temporary file of its
     * own. Rust's temp_dir() honours TMPDIR and otherwise falls back to /tmp.
     * Stock Android sets TMPDIR to the app's cache directory, so that worked;
     * inside the 卓易通 compatibility layer TMPDIR is unset, /tmp exists and is
     * not writable by the app, and the boot was refused with EACCES in 37ms --
     * before a byte of the guest was read, identically at every memory size.
     * Naming the path here means the runtime never looks for a temp directory.
     */
    const val SCRATCH_DISK_NAME = "scratch-root.img"

    /** What the runtime would have sized its own throwaway disk to. */
    const val SCRATCH_DISK_BYTES = 64L * 1024 * 1024
}

/**
 * Stages the bundled assets as plain files the runtime can open by path.
 *
 * APK assets are not addressable by path, so each file is copied once into
 * the app's private files directory. Every copy is digested while it is
 * written and again on every later boot; a mismatch is reported as
 * E_GUEST_ASSET_INTEGRITY exactly like the iOS bundle preflight, never
 * silently re-copied into a boot.
 */
class AndroidGuestAssets(private val context: Context) : GuestAssetProvider {
    override fun stage(): StagedGuestAssets {
        val directory = File(context.filesDir, GuestAssets.STAGING_DIRECTORY)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw GuestRejection(GuestErrorCodes.ASSETS_MISSING, "Guest asset staging directory is unavailable.")
        }
        val kernel = stageOne(directory, GuestAssets.KERNEL_NAME, GuestAssets.KERNEL_SHA256)
        val initramfs = stageOne(directory, GuestAssets.INITRAMFS_NAME, GuestAssets.INITRAMFS_SHA256)
        val scratch = stageScratchDisk(directory)
        return StagedGuestAssets(kernel.absolutePath, initramfs.absolutePath, scratch.absolutePath)
    }

    /**
     * A sparse file of the size the runtime would have made for itself. It is
     * never read during an initramfs boot; only its path is required. Sizing
     * it costs nothing until something writes, and a file already the right
     * size is left alone so a boot does not rewrite it.
     */
    private fun stageScratchDisk(directory: File): File {
        val target = File(directory, GuestAssets.SCRATCH_DISK_NAME)
        if (target.isFile && target.length() == GuestAssets.SCRATCH_DISK_BYTES) return target
        try {
            java.io.RandomAccessFile(target, "rw").use { it.setLength(GuestAssets.SCRATCH_DISK_BYTES) }
        } catch (_: IOException) {
            target.delete()
            throw GuestRejection(
                GuestErrorCodes.ASSETS_MISSING,
                "The guest scratch root disk could not be created.",
            )
        }
        return target
    }

    private fun stageOne(directory: File, name: String, expectedSha256: String): File {
        val target = File(directory, name)
        if (target.isFile && sha256Of(target) == expectedSha256) return target

        val input: InputStream = try {
            context.assets.open(name)
        } catch (_: IOException) {
            throw GuestRejection(GuestErrorCodes.ASSETS_MISSING, "Guest boot assets are missing from the app package.")
        }
        val staging = File(directory, "$name.staging")
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            input.use { source ->
                FileOutputStream(staging).use { sink ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                        sink.write(buffer, 0, read)
                    }
                    sink.fd.sync()
                }
            }
        } catch (_: IOException) {
            staging.delete()
            throw GuestRejection(GuestErrorCodes.ASSETS_MISSING, "Guest boot assets could not be staged.")
        }
        if (hex(digest.digest()) != expectedSha256) {
            staging.delete()
            throw GuestRejection(GuestErrorCodes.ASSET_INTEGRITY, "Guest boot asset digests do not match the pinned values.")
        }
        if (!staging.renameTo(target)) {
            target.delete()
            if (!staging.renameTo(target)) {
                staging.delete()
                throw GuestRejection(GuestErrorCodes.ASSETS_MISSING, "Guest boot assets could not be staged.")
            }
        }
        return target
    }

    private fun sha256Of(file: File): String? {
        val digest = MessageDigest.getInstance("SHA-256")
        return try {
            file.inputStream().use { source ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val read = source.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            hex(digest.digest())
        } catch (_: IOException) {
            null
        }
    }

    private fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            val value = byte.toInt() and 0xff
            out.append(Character.forDigit(value ushr 4, 16))
            out.append(Character.forDigit(value and 0x0f, 16))
        }
        return out.toString()
    }
}
