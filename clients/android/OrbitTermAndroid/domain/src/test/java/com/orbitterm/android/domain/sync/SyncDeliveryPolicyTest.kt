package com.orbitterm.android.domain.sync

import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import org.junit.Assert.assertEquals
import org.junit.Test

class SyncDeliveryPolicyTest {
    @Test
    fun `temporary transport failures remain eligible for bounded retry`() {
        listOf(
            OrbitErrorCode.NetworkUnavailable,
            OrbitErrorCode.NetworkTimeout,
        ).forEach { code ->
            assertEquals(SyncDeliveryDisposition.Ready, SyncDeliveryPolicy.disposition(syncError(code)))
        }
        assertEquals(
            SyncDeliveryDisposition.Ready,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.RemoteServiceRejected), attemptCount = 5),
        )
        assertEquals(
            SyncDeliveryDisposition.Blocked,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.RemoteServiceRejected), attemptCount = 6),
        )
        assertEquals(
            SyncDeliveryDisposition.Ready,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.RemoteRateLimited), attemptCount = 1),
        )
        assertEquals(
            SyncDeliveryDisposition.Blocked,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.RemoteRequestRejected), attemptCount = 1),
        )
        assertEquals(
            SyncDeliveryDisposition.Blocked,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.RemoteProtocolViolation), attemptCount = 1),
        )
    }

    @Test
    fun `credentials and unlock failures pause until their recovery boundary`() {
        assertEquals(
            SyncDeliveryDisposition.WaitingForAuthentication,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.AuthenticationExpired)),
        )
        assertEquals(
            SyncDeliveryDisposition.WaitingForUnlock,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.SyncDecryptionFailed)),
        )
    }

    @Test
    fun `unknown and invalid work is isolated instead of spinning`() {
        assertEquals(
            SyncDeliveryDisposition.Blocked,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.InvalidRequest)),
        )
        assertEquals(
            SyncDeliveryDisposition.Blocked,
            SyncDeliveryPolicy.disposition(syncError(OrbitErrorCode.Unknown)),
        )
    }
}
