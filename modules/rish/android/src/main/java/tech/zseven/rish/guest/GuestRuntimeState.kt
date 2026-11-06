package tech.zseven.rish.guest

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-wide view of whether a rish guest session is currently booted,
 * mirroring DSHGuestRuntimeState on iOS.
 *
 * LocalGuestModule flips the flag when a session commits or is released.
 * A future LocalMirrors implementation reads it so a receipt only reports a
 * mounted guest while one is genuinely live. The flag is strictly in-process:
 * it resets on every app launch and says nothing about staged overlay
 * configuration reaching the guest.
 */
object GuestRuntimeState {
    private val mounted = AtomicBoolean(false)

    val guestRuntimeMounted: Boolean
        get() = mounted.get()

    fun setGuestRuntimeMounted(value: Boolean) {
        mounted.set(value)
    }
}
