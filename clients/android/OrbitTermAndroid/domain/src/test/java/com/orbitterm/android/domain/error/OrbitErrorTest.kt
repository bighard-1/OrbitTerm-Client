package com.orbitterm.android.domain.error

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OrbitErrorTest {
    @Before
    fun resetMetrics() {
        PrivacySafeErrorMetrics.clearForTests()
    }

    @Test
    fun knownNativeAuthenticationFailureHasStableRecovery() {
        val error = orbitNativeError("ssh_auth_failed", retryable = true)

        assertEquals(OrbitErrorCode.AuthenticationFailed, error.code)
        assertEquals(OrbitRecoveryAction.CheckCredentials, error.recovery)
        assertEquals("authentication_failed", error.diagnosticCode)
    }

    @Test
    fun untrustedNativeTokenNeverBecomesDiagnosticOrDisplayText() {
        val untrusted = "password=secret host=private.example"
        val error = orbitNativeError(untrusted)

        assertEquals(OrbitErrorCode.Unknown, error.code)
        assertFalse(error.diagnosticCode.contains("secret"))
        assertFalse(error.userMessage().contains("private.example"))
    }

    @Test
    fun syncFailureTracksOnlyAllowListedCodeAndCount() {
        syncError(OrbitErrorCode.SyncDecryptionFailed)
        val metrics = PrivacySafeErrorMetrics.snapshot()

        assertEquals(1, metrics[OrbitErrorCode.SyncDecryptionFailed])
        assertTrue(metrics.keys.all { it.diagnosticCode.matches(Regex("[a-z_]+")) })
    }
}
