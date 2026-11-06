package tech.zseven.rish

import tech.zseven.rish.tasks.TaskPolicy
import org.junit.Assert.*
import org.junit.Test

class TaskPolicyTest {
    @Test fun envelopeVersionRejectsCoercion() {
        assertTrue(TaskPolicy.validSchema(1))
        for (value in listOf(null, true, "1", 1.0, 1.5, 0, 2)) assertFalse(TaskPolicy.validSchema(value))
    }

    @Test fun notificationOptInPrivacyAndDeduplication() {
        for (mask in 0 until 64) {
            val enabled = mask and 1 != 0
            val muted = mask and 2 != 0
            val viewing = mask and 4 != 0
            val delivered = mask and 8 != 0
            val owner = mask and 16 != 0
            val kind = if (mask and 32 != 0) "completed" else "attention"
            assertEquals(enabled && !muted && !viewing && !delivered && owner,
                TaskPolicy.allowsAlert(kind, enabled, muted, viewing, delivered, owner))
        }
        assertFalse(TaskPolicy.allowsAlert("raw_output", true, false, false, false, true))
    }
    @Test fun staleOrAbsentOwnershipCannotCancel() {
        assertFalse(TaskPolicy.owns(null, null))
        assertFalse(TaskPolicy.owns("", ""))
        assertFalse(TaskPolicy.owns("old", "new"))
        assertFalse(TaskPolicy.owns("old", null))
        assertTrue(TaskPolicy.owns("current", "current"))
    }
}
