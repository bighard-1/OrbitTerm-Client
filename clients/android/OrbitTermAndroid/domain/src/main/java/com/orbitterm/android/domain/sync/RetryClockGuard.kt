package com.orbitterm.android.domain.sync

import kotlin.math.abs

/**
 * Converts wall-clock samples into a process-local trusted clock. Persisted
 * retry deadlines still survive restart/reboot, while changing the device
 * clock during the current process cannot expire a server delay early.
 */
class RetryClockGuard(
    private val toleratedWallClockDriftSeconds: Long = 2,
) {
    private var lastElapsedRealtimeSeconds: Long? = null
    private var lastTrustedUnixSeconds: Long? = null

    @Synchronized
    fun trustedNowUnix(
        wallClockUnixSeconds: Long,
        elapsedRealtimeSeconds: Long,
    ): Long {
        val previousElapsed = lastElapsedRealtimeSeconds
        val previousTrusted = lastTrustedUnixSeconds
        if (previousElapsed == null || previousTrusted == null) {
            lastElapsedRealtimeSeconds = elapsedRealtimeSeconds
            lastTrustedUnixSeconds = wallClockUnixSeconds
            return wallClockUnixSeconds
        }

        val elapsedDelta = elapsedRealtimeSeconds - previousElapsed
        if (elapsedDelta < 0) {
            // A new boot/process uses the persisted wall-clock deadline again.
            lastElapsedRealtimeSeconds = elapsedRealtimeSeconds
            lastTrustedUnixSeconds = wallClockUnixSeconds
            return wallClockUnixSeconds
        }

        val monotonicCandidate = previousTrusted + elapsedDelta
        val wallDrift = wallClockUnixSeconds - monotonicCandidate
        val trusted = if (abs(wallDrift) <= toleratedWallClockDriftSeconds.coerceAtLeast(0)) {
            maxOf(previousTrusted, wallClockUnixSeconds)
        } else {
            monotonicCandidate
        }
        lastElapsedRealtimeSeconds = elapsedRealtimeSeconds
        lastTrustedUnixSeconds = trusted
        return trusted
    }
}
