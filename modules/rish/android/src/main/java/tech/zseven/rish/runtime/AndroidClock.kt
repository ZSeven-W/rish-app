package tech.zseven.rish.runtime

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The timestamps the stores hand the core as host facts, in the same shape
 * iOS produces: ISO-8601 in UTC with milliseconds.
 */
internal object AndroidClock {
    private val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        .apply { timeZone = TimeZone.getTimeZone("UTC") }

    @Synchronized fun now(): String = format.format(Date())

    @Synchronized fun nowAdding(seconds: Long): String =
        format.format(Date(System.currentTimeMillis() + seconds * 1000))
}
