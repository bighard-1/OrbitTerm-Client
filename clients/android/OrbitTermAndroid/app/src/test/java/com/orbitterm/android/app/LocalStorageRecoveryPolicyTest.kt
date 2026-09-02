package com.orbitterm.android.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalStorageRecoveryPolicyTest {
    @Test
    fun everyFailurePausesWithoutSuggestingAutomaticDeletion() {
        LocalStorageFailureKind.entries.forEach { kind ->
            val presentation = LocalStorageRecoveryPolicy.presentation(kind)
            assertEquals(kind, presentation.kind)
            assertEquals("重新检查", presentation.actionLabel)
            assertTrue(presentation.message.contains("不") || presentation.message.contains("不会"))
        }
    }

    @Test
    fun migrationFailureHasDedicatedRecoveryState() {
        val kind = LocalStorageRecoveryPolicy.classify(
            IllegalStateException("A migration was required but not found"),
        )
        assertEquals(LocalStorageFailureKind.MIGRATION_INTERRUPTED, kind)
    }

    @Test
    fun unknownSecureReadFailureFailsClosed() {
        val kind = LocalStorageRecoveryPolicy.classify(RuntimeException("redacted"))
        assertEquals(LocalStorageFailureKind.SECURE_STORAGE_UNAVAILABLE, kind)
    }
}
