package tech.zseven.rish.guestprobe

/**
 * Native-side questions the Kotlin layer cannot answer about itself.
 *
 * Loaded separately from the guest runtime: these must still work when the
 * runtime is what failed.
 */
object NativeProbe {
    val available: Boolean by lazy {
        try { System.loadLibrary("guestprobe_jni"); true }
        catch (_: UnsatisfiedLinkError) { false }
        catch (_: SecurityException) { false }
    }

    @JvmStatic external fun readFile(path: String): String
    @JvmStatic external fun mapAnonymous(mib: Int): String
    @JvmStatic external fun mapExecutable(): String
    @JvmStatic external fun tempStatus(): String
}
