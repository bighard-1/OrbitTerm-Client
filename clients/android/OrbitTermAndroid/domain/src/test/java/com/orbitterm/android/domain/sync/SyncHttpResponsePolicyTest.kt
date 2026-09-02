package com.orbitterm.android.domain.sync

import com.orbitterm.android.domain.error.OrbitErrorCode
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncHttpResponsePolicyTest {
    private val now = Instant.parse("2026-09-01T00:00:00Z")

    @Test
    fun `status classes have stable recovery semantics`() {
        assertEquals(OrbitErrorCode.AuthenticationExpired, SyncHttpResponsePolicy.error(401, null, now).code)
        assertEquals(OrbitErrorCode.NetworkTimeout, SyncHttpResponsePolicy.error(408, null, now).code)
        assertEquals(OrbitErrorCode.RemoteRateLimited, SyncHttpResponsePolicy.error(429, null, now).code)
        assertEquals(OrbitErrorCode.RemoteServiceUnavailable, SyncHttpResponsePolicy.error(503, null, now).code)
        assertEquals(OrbitErrorCode.RemoteRequestRejected, SyncHttpResponsePolicy.error(422, null, now).code)
        assertFalse(SyncHttpResponsePolicy.error(409, null, now).retryable)
        assertTrue(SyncHttpResponsePolicy.error(503, null, now).retryable)
    }

    @Test
    fun `credential submission and existing session keep distinct 401 semantics`() {
        assertEquals(
            OrbitErrorCode.AuthenticationFailed,
            SyncHttpResponsePolicy.error(
                401,
                null,
                now,
                authenticationErrorCode = OrbitErrorCode.AuthenticationFailed,
            ).code,
        )
        assertEquals(OrbitErrorCode.AuthenticationExpired, SyncHttpResponsePolicy.error(401, null, now).code)
    }

    @Test
    fun `retry after accepts delta and http date and clamps untrusted values`() {
        assertEquals(120L, SyncHttpResponsePolicy.parseRetryAfter("120", now))
        assertEquals(
            600L,
            SyncHttpResponsePolicy.parseRetryAfter("Tue, 01 Sep 2026 00:10:00 GMT", now),
        )
        assertEquals(3_600L, SyncHttpResponsePolicy.parseRetryAfter("999999", now))
        assertNull(SyncHttpResponsePolicy.parseRetryAfter("0", now))
        assertNull(SyncHttpResponsePolicy.parseRetryAfter("not-a-date", now))
    }
}
