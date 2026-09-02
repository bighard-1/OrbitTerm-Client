package com.orbitterm.android.domain.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class RetryClockGuardTest {
    @Test
    fun `forward and backward wall clock jumps follow monotonic elapsed time`() {
        val forward = RetryClockGuard(toleratedWallClockDriftSeconds = 2)
        assertEquals(1_000, forward.trustedNowUnix(1_000, 100))
        assertEquals(1_005, forward.trustedNowUnix(4_605, 105))

        val backward = RetryClockGuard(toleratedWallClockDriftSeconds = 2)
        assertEquals(2_000, backward.trustedNowUnix(2_000, 200))
        assertEquals(2_010, backward.trustedNowUnix(1_000, 210))
    }

    @Test
    fun `ordinary drift is accepted and a new uptime epoch resets safely`() {
        val clock = RetryClockGuard(toleratedWallClockDriftSeconds = 2)
        assertEquals(1_000, clock.trustedNowUnix(1_000, 100))
        assertEquals(1_011, clock.trustedNowUnix(1_011, 110))
        assertEquals(3_000, clock.trustedNowUnix(3_000, 5))
    }
}
