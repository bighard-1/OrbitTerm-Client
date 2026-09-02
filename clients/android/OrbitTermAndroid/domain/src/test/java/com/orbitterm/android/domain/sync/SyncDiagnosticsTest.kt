package com.orbitterm.android.domain.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SyncDiagnosticsTest {
    @Before
    fun reset() = PrivacySafeSyncMetrics.clear()

    @Test
    fun `metrics retain only allow-listed event counts`() {
        PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.UnknownResultQueued)
        PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.UnknownResultQueued)
        PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.LateResponseIgnored)
        PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.DeliveryBlocked)

        val snapshot = PrivacySafeSyncMetrics.snapshot()
        assertEquals(2, snapshot[SyncDiagnosticEvent.UnknownResultQueued])
        assertEquals(1, snapshot[SyncDiagnosticEvent.LateResponseIgnored])
        assertEquals(1, snapshot[SyncDiagnosticEvent.DeliveryBlocked])
        assertTrue(snapshot.keys.all { it.diagnosticCode.matches(Regex("[a-z_]+")) })
    }
}
