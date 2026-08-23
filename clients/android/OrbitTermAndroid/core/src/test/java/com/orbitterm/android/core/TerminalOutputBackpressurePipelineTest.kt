package com.orbitterm.android.core

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalOutputBackpressurePipelineTest {
    @Test
    fun queueFullDropsNewestChunkWithoutBlockingTheProducer() = runBlocking {
        val pipeline = TerminalOutputBackpressurePipeline(queueCapacity = 1, maxChunkBytes = 16)

        pipeline.submit(7, byteArrayOf(1))
        pipeline.submit(7, byteArrayOf(2))

        assertArrayEquals(byteArrayOf(1), pipeline.output.first().bytes)
        val metrics = pipeline.metrics()
        assertEquals(1, metrics.acceptedChunks)
        assertEquals(1, metrics.droppedQueueFullChunks)
        assertEquals(1, metrics.droppedQueueFullBytes)
    }

    @Test
    fun oversizedChunksAreCappedToTheExplicitMemoryBudget() = runBlocking {
        val pipeline = TerminalOutputBackpressurePipeline(queueCapacity = 1, maxChunkBytes = 3)

        pipeline.submit(4, byteArrayOf(1, 2, 3, 4, 5))

        assertArrayEquals(byteArrayOf(1, 2, 3), pipeline.output.first().bytes)
        val metrics = pipeline.metrics()
        assertEquals(1, metrics.truncatedChunks)
        assertEquals(2, metrics.truncatedBytes)
    }

    @Test
    fun retiredChannelsRejectLateCallbacksBeforeTheyReachTheUi() {
        val pipeline = TerminalOutputBackpressurePipeline(queueCapacity = 1, maxChunkBytes = 16)

        pipeline.retire(9)
        pipeline.submit(9, byteArrayOf(1, 2))

        val metrics = pipeline.metrics()
        assertEquals(0, metrics.acceptedChunks)
        assertEquals(1, metrics.ignoredRetiredChunks)
        assertEquals(2, metrics.ignoredRetiredBytes)
    }
}
