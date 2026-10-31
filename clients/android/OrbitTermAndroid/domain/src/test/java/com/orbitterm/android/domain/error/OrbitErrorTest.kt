package com.orbitterm.android.domain.error

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OrbitErrorTest {
    @Test
    fun remoteUploadCleanupFailureRequiresInspectionRatherThanClaimingCancellation() {
        val error = orbitNativeError("sftp_remote_cleanup_failed", retryable = true)
        assertEquals(OrbitErrorCode.SftpRemoteCleanupFailed, error.code)
        assertEquals(OrbitRecoveryAction.CheckPermission, error.recovery)
        assertFalse(error.retryable)
        assertTrue(error.userMessage().contains("远端临时上传文件清理失败"))
        assertFalse(error.userMessage().contains("已取消"))
        assertEquals(OrbitErrorCode.Unknown, orbitNativeError("sftp_remote_cleanup_failed /private/path").code)
    }

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

    @Test
    fun checkedSftpTransferFailuresHaveStableCategories() {
        assertEquals(OrbitErrorCode.OperationCancelled, orbitNativeError("sftp_transfer_cancelled").code)
        assertEquals(OrbitErrorCode.SftpOperationFailed, orbitNativeError("sftp_download_failed").code)
        assertEquals(OrbitErrorCode.SftpOperationFailed, orbitNativeError("sftp_upload_failed").code)
        assertEquals(OrbitRecoveryAction.ReopenSession, orbitNativeError("sftp_list_failed").recovery)
        assertEquals(OrbitRecoveryAction.ReopenSession, orbitNativeError("subsystem_request_failed").recovery)
        val destination = orbitNativeError("destination_unwritable")
        assertEquals(OrbitErrorCode.DestinationUnwritable, destination.code)
        assertEquals(OrbitRecoveryAction.CheckPermission, destination.recovery)
        assertFalse(destination.userMessage().contains("解锁"))
    }

    @Test
    fun checkedSftpSessionFailuresGuideReconnectWithoutExposingNativeText() {
        for (token in listOf("security_generation_mismatch", "legacy_session_not_allowed")) {
            val error = orbitNativeError(token)
            assertEquals(OrbitErrorCode.SessionUnavailable, error.code)
            assertEquals(OrbitRecoveryAction.ReopenSession, error.recovery)
            assertTrue(error.userMessage().contains("重新连接资产"))
        }
        assertEquals(OrbitErrorCode.InvalidRequest, orbitNativeError("invalid_request").code)
        assertEquals(OrbitErrorCode.NativeProtocolInvalid, orbitNativeError("ffi_internal_error").code)
        assertEquals(OrbitErrorCode.Unknown, orbitNativeError("security_generation_mismatch /private/path").code)
    }
}
