package tech.zseven.rish.tasks

internal object TaskPolicy {
    fun validSchema(value: Any?): Boolean = value is Int && value == 1

    fun allowsAlert(kind: String, enabled: Boolean, muted: Boolean, viewing: Boolean, delivered: Boolean, sameRun: Boolean): Boolean =
        kind in setOf("completed", "failed", "attention") && enabled && !muted && !viewing && !delivered && sameRun

    fun owns(expected: String?, current: String?): Boolean = !expected.isNullOrEmpty() && expected == current
}
