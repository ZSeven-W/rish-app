package tech.zseven.rish.guest

/**
 * JNI binding for the rish guest session ABI (see src/main/cpp/rish_guest_jni.cpp).
 *
 * The runtime library is only present in builds that staged it through
 * scripts/prepare-rish-android.sh. [available] answers whether both native
 * libraries loaded; a lite build reports false and LocalGuestModule keeps
 * rejecting with E_GUEST_NATIVE exactly as before.
 */
internal object RishGuestNative : GuestSessionBackend {
    val available: Boolean by lazy {
        try {
            System.loadLibrary("rish_ffi")
            System.loadLibrary("rish_guest_jni")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    @JvmStatic external fun protocolVersion(): Int

    /** Boots a guest and returns its session handle, or 0 on failure. Blocks for the whole boot. */
    @JvmStatic external fun bootSession(requestJson: String): Long

    /** Runs one command in a live session; null when the bridge produced no usable reply. */
    @JvmStatic external fun sessionExecJson(handle: Long, requestJson: String): String?

    /** Shuts the guest down and releases the handle. Safe to call with 0. */
    @JvmStatic external fun sessionFree(handle: Long)

    override fun boot(requestJson: String): Long = bootSession(requestJson)
    override fun exec(handle: Long, requestJson: String): String? = sessionExecJson(handle, requestJson)
    override fun free(handle: Long) = sessionFree(handle)
}
