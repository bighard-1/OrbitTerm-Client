package com.orbitterm.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TcpLatencyProbeTest {
    @Test fun failureRateUsesRecentProbeFailures() {
        assertEquals(50.0, tcpProbeFailurePercent(listOf(12.0, null, 15.0, null))!!, 0.001)
    }

    @Test fun emptyWindowHasNoFailureValue() {
        assertNull(tcpProbeFailurePercent(emptyList()))
    }

    @Test fun percentilesUseSuccessfulTcpSamplesOnly() {
        val samples = listOf(10.0, null, 20.0, 30.0, 40.0)
        assertEquals(20.0, tcpLatencyPercentile(samples, 0.50)!!, 0.001)
        assertEquals(40.0, tcpLatencyPercentile(samples, 0.95)!!, 0.001)
    }
}
