package com.orbitterm.android.app

import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import com.orbitterm.android.sync.OrbitServiceFailure
import com.orbitterm.android.sync.isRetryableRecentlyDeletedFailure
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecentlyDeletedRetryPolicyTest {
    @Test
    fun `only typed retryable sync failures enter durable queue`() {
        assertTrue(
            OrbitServiceFailure(syncError(OrbitErrorCode.NetworkUnavailable))
                .isRetryableRecentlyDeletedFailure(),
        )
        assertFalse(
            OrbitServiceFailure(syncError(OrbitErrorCode.AuthenticationExpired))
                .isRetryableRecentlyDeletedFailure(),
        )
        assertFalse(IllegalStateException("arbitrary").isRetryableRecentlyDeletedFailure())
    }
}
