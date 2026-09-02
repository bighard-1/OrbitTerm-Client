package com.orbitterm.android.core

import com.orbitterm.android.domain.performance.FrameInvalidationBatcher
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.orbitterm.android.domain.performance.SyncOutboxBatchPolicy
import com.orbitterm.android.domain.performance.TransferProgressUpdateGate
import com.orbitterm.android.domain.performance.retainUtf8Tail
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeResourceBudgetTest {
    @Test
    fun `terminal queue has an explicit two mebibyte upper bound`() {
        assertEquals(2 * 1024 * 1024, RuntimeResourceBudget.TERMINAL_OUTPUT_MAX_BUFFERED_BYTES)
        assertEquals(16, RuntimeResourceBudget.TERMINAL_EARLY_OUTPUT_MAX_CHANNELS)
        assertEquals(256 * 1024, RuntimeResourceBudget.TERMINAL_EARLY_OUTPUT_MAX_BYTES_PER_CHANNEL)
    }

    @Test
    fun `render invalidations coalesce per channel and remain bounded`() {
        val batcher = FrameInvalidationBatcher<Long>(maxPendingKeys = 2)

        assertTrue(batcher.offer(1))
        assertFalse(batcher.offer(1))
        assertTrue(batcher.offer(2))
        assertFalse(batcher.offer(3))
        assertEquals(setOf(1L, 2L), batcher.drain())
        assertEquals(0, batcher.size)
    }

    @Test
    fun `sftp progress emits start completion and bounded intermediate updates`() {
        val gate = TransferProgressUpdateGate(minIntervalMillis = 250, minByteDelta = 64, maxTrackedTransfers = 2)

        assertTrue(gate.shouldPublish("request-1", transferredBytes = 0, totalBytes = 1_000, nowMillis = 0))
        assertFalse(gate.shouldPublish("request-1", transferredBytes = 16, totalBytes = 1_000, nowMillis = 100))
        assertTrue(gate.shouldPublish("request-1", transferredBytes = 80, totalBytes = 1_000, nowMillis = 100))
        assertFalse(gate.shouldPublish("request-1", transferredBytes = 96, totalBytes = 1_000, nowMillis = 200))
        assertTrue(gate.shouldPublish("request-1", transferredBytes = 1_000, totalBytes = 1_000, nowMillis = 201))
        gate.clear("request-1")
        assertEquals(0, gate.trackedTransferCount)
    }

    @Test
    fun `interrupted large transfers may resume while progress tracking stays bounded`() {
        val gate = TransferProgressUpdateGate(minIntervalMillis = 250, minByteDelta = 64 * 1024, maxTrackedTransfers = 2)

        assertTrue(gate.shouldPublish("archive", transferredBytes = 1_200L * 1024 * 1024, totalBytes = 2_000L * 1024 * 1024, nowMillis = 0))
        // A resumed request may report a lower durable offset after reconnecting.
        assertTrue(gate.shouldPublish("archive", transferredBytes = 1_152L * 1024 * 1024, totalBytes = 2_000L * 1024 * 1024, nowMillis = 100))
        assertTrue(gate.shouldPublish("backup", transferredBytes = 0, totalBytes = 1_000, nowMillis = 200))
        assertTrue(gate.shouldPublish("report", transferredBytes = 0, totalBytes = 1_000, nowMillis = 300))
        assertEquals(2, gate.trackedTransferCount)
    }

    @Test
    fun `docker log retention keeps a valid utf8 newest suffix`() {
        val text = "旧日志".repeat(300) + "\nLATEST"
        val bounded = text.retainUtf8Tail(maxBytes = 256)

        assertTrue(bounded.wasTruncated)
        assertTrue(bounded.content.endsWith("LATEST"))
        assertTrue(bounded.content.toByteArray(StandardCharsets.UTF_8).size <= 256)
    }

    @Test
    fun `monitor budget never permits sub two second polling`() {
        assertTrue(RuntimeResourceBudget.MONITOR_MIN_REFRESH_SECONDS >= 2)
        assertEquals(60, RuntimeResourceBudget.MONITOR_HISTORY_SAMPLES)
    }

    @Test
    fun `sync outbox distinguishes failures from an unread database backlog`() {
        assertEquals(100, RuntimeResourceBudget.SYNC_OUTBOX_MAX_OPERATIONS_PER_RUN)
        assertFalse(SyncOutboxBatchPolicy.hasUnprocessedBacklog(attempted = 100, delivered = 98, remaining = 2))
        assertTrue(SyncOutboxBatchPolicy.hasUnprocessedBacklog(attempted = 100, delivered = 98, remaining = 3))
        assertFalse(SyncOutboxBatchPolicy.hasUnprocessedBacklog(attempted = 0, delivered = 0, remaining = 0))
    }
}
