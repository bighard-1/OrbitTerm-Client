package com.orbitterm.android.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.orbitterm.android.domain.performance.PerformanceAcceptanceBaseline
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TerminalPerformanceInstrumentationTest {
    @Test(timeout = PerformanceAcceptanceBaseline.MAX_OPERATION_MILLIS)
    fun largeTerminalBurstRemainsBoundedAndNonBlocking() = runBlocking {
        val pipeline = TerminalOutputBackpressurePipeline(
            queueCapacity = RuntimeResourceBudget.TERMINAL_OUTPUT_QUEUE_CAPACITY,
            maxChunkBytes = RuntimeResourceBudget.TERMINAL_OUTPUT_MAX_CHUNK_BYTES,
        )
        val chunk = ByteArray(RuntimeResourceBudget.TERMINAL_OUTPUT_MAX_CHUNK_BYTES) { 0x41 }

        repeat(PerformanceAcceptanceBaseline.TERMINAL_OUTPUT_STRESS_CHUNKS) {
            pipeline.submit(terminalChannelId = 7, bytes = chunk)
        }

        val metrics = pipeline.metrics()
        assertTrue(metrics.acceptedBytes <= RuntimeResourceBudget.TERMINAL_OUTPUT_MAX_BUFFERED_BYTES)
        assertTrue(metrics.droppedQueueFullChunks > 0)
    }
}
