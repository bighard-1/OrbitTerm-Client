package com.orbitterm.android.core

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionEventPipelineTest {
    @Test
    fun lossQueuedBeforeCollectorStartsIsDeliveredByBaseSessionId() = runBlocking {
        val pipeline = ConnectionEventPipeline()

        pipeline.submit(42, "ERR_CONNECTION_LOST")

        assertEquals(
            NativeSessionEvent.BaseConnectionLost(42L),
            withTimeout(1_000) { pipeline.events.first() },
        )
    }

    @Test
    fun invalidAndUnrelatedEventsDoNotEnterTheQueue() = runBlocking {
        val pipeline = ConnectionEventPipeline()
        pipeline.submit(0, "ERR_CONNECTION_LOST")
        pipeline.submit(13, "ERR_OTHER")
        pipeline.submit(14, "ERR_CONNECTION_LOST")

        assertEquals(
            NativeSessionEvent.BaseConnectionLost(14L),
            withTimeout(1_000) { pipeline.events.first() },
        )
    }

    @Test
    fun terminalClosureUsesChannelIdAndSurvivesLateCollector() = runBlocking {
        val pipeline = ConnectionEventPipeline()
        pipeline.submit(91, "ERR_TERMINAL_CLOSED")

        assertEquals(
            NativeSessionEvent.TerminalClosed(91L),
            withTimeout(1_000) { pipeline.events.first() },
        )
    }
}
