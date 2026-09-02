package com.orbitterm.android.security

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardContentKindPolicyTest {
    @Test
    fun ordinaryTextIsCopyableWithoutAutomaticClear() {
        assertTrue(ClipboardContentKind.ORDINARY_TEXT.canCopy)
        assertNull(ClipboardContentKind.ORDINARY_TEXT.clearAfterMillis)
    }

    @Test
    fun terminalAndFingerprintContentUseTheSameBoundedLifetime() {
        assertTrue(ClipboardContentKind.TERMINAL_OUTPUT.canCopy)
        assertTrue(ClipboardContentKind.HOST_KEY_FINGERPRINT.canCopy)
        assertTrue(ClipboardContentKind.TERMINAL_OUTPUT.clearAfterMillis == 60_000L)
        assertTrue(ClipboardContentKind.HOST_KEY_FINGERPRINT.clearAfterMillis == 60_000L)
    }

    @Test
    fun credentialsAndPrivateKeysCannotEnterTheClipboard() {
        assertFalse(ClipboardContentKind.CREDENTIAL.canCopy)
        assertFalse(ClipboardContentKind.PRIVATE_KEY.canCopy)
        assertNull(ClipboardContentKind.CREDENTIAL.clearAfterMillis)
        assertNull(ClipboardContentKind.PRIVATE_KEY.clearAfterMillis)
    }
}
