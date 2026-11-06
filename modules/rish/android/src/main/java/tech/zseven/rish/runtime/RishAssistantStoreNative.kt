package tech.zseven.rish.runtime

/** The GPUI Rust library owns the same assistant store used by the Shell. */
internal object RishAssistantStoreNative {
    val available: Boolean by lazy {
        try {
            System.loadLibrary("rish_gpui")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    @JvmStatic external fun call(directory: String, requestJson: String): String
}
