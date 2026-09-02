package com.orbitterm.android.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class AppLockLifecyclePolicyTest {
    @Test
    fun ordinaryBackgroundAlwaysLocksRegardlessOfSessionOwnership() {
        assertEquals(
            BackgroundLockDisposition.LOCK_NOW,
            backgroundLockDisposition(
                isChangingConfigurations = false,
                isDocumentInteractionPending = false,
            ),
        )
    }

    @Test
    fun configurationChangeIsIgnoredAndDocumentInteractionUsesBoundedGrace() {
        assertEquals(
            BackgroundLockDisposition.IGNORE_CONFIGURATION_CHANGE,
            backgroundLockDisposition(true, false),
        )
        assertEquals(
            BackgroundLockDisposition.DEFER_FOR_DOCUMENT_INTERACTION,
            backgroundLockDisposition(false, true),
        )
        assertFalse(documentInteractionRequiresLockOnResume(1_000, 120_999, 120_000))
        assertTrue(documentInteractionRequiresLockOnResume(1_000, 121_000, 120_000))
        assertFalse(documentInteractionRequiresLockOnResume(null, 121_000, 120_000))
    }
}
