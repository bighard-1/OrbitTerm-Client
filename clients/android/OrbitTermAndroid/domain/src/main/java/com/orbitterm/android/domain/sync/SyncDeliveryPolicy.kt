package com.orbitterm.android.domain.sync

import com.orbitterm.android.domain.error.OrbitError
import com.orbitterm.android.domain.error.OrbitErrorCode

/** Durable queue disposition. Only [Ready] work is eligible for background delivery. */
enum class SyncDeliveryDisposition {
    Ready,
    WaitingForAuthentication,
    WaitingForUnlock,
    Blocked,
}

/**
 * Classifies only stable, allow-listed error codes. Exception text and remote
 * response bodies must never decide whether a persisted mutation is retried.
 */
object SyncDeliveryPolicy {
    const val MAX_REMOTE_REJECTION_ATTEMPTS = 5

    fun disposition(error: OrbitError, attemptCount: Int = 1): SyncDeliveryDisposition = when (error.code) {
        OrbitErrorCode.NetworkUnavailable,
        OrbitErrorCode.NetworkTimeout,
        -> if (error.retryable) SyncDeliveryDisposition.Ready else SyncDeliveryDisposition.Blocked

        // The API layer intentionally does not inspect untrusted response text.
        // A bounded allowance covers transient 429/5xx responses without
        // letting an ambiguous permanent rejection spin forever.
        OrbitErrorCode.RemoteServiceRejected -> if (
            error.retryable && attemptCount <= MAX_REMOTE_REJECTION_ATTEMPTS
        ) SyncDeliveryDisposition.Ready else SyncDeliveryDisposition.Blocked

        OrbitErrorCode.RemoteRateLimited,
        OrbitErrorCode.RemoteServiceUnavailable,
        -> if (error.retryable && attemptCount <= MAX_REMOTE_REJECTION_ATTEMPTS) {
            SyncDeliveryDisposition.Ready
        } else {
            SyncDeliveryDisposition.Blocked
        }

        OrbitErrorCode.RemoteRequestRejected,
        OrbitErrorCode.RemoteProtocolViolation,
        -> SyncDeliveryDisposition.Blocked

        OrbitErrorCode.AuthenticationExpired,
        OrbitErrorCode.AuthenticationFailed,
        -> SyncDeliveryDisposition.WaitingForAuthentication

        OrbitErrorCode.StorageLocked,
        OrbitErrorCode.SyncDecryptionFailed,
        -> SyncDeliveryDisposition.WaitingForUnlock

        else -> SyncDeliveryDisposition.Blocked
    }
}
