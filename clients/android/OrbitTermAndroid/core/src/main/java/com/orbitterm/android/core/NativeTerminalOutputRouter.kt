package com.orbitterm.android.core

import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.receiveAsFlow

data class TerminalOutputChunk(
    val terminalChannelId: Long,
    val bytes: ByteArray,
)

/** Aggregate-only diagnostics: never contains terminal content or server identity. */
data class TerminalOutputBackpressureMetrics(
    val acceptedChunks: Long,
    val acceptedBytes: Long,
    val droppedQueueFullChunks: Long,
    val droppedQueueFullBytes: Long,
    val truncatedChunks: Long,
    val truncatedBytes: Long,
    val ignoredRetiredChunks: Long,
    val ignoredRetiredBytes: Long,
)

/**
 * A bounded, non-blocking boundary between JNI and the UI collector.
 *
 * The native worker never waits for a consumer. When the queue is full, the
 * newest chunk is discarded so previously accepted bytes retain their order.
 * Chunks are capped before enqueuing, making the queue's memory limit explicit.
 */
internal class TerminalOutputBackpressurePipeline(
    private val queueCapacity: Int = RuntimeResourceBudget.TERMINAL_OUTPUT_QUEUE_CAPACITY,
    private val maxChunkBytes: Int = RuntimeResourceBudget.TERMINAL_OUTPUT_MAX_CHUNK_BYTES,
) {
    private val incoming = Channel<TerminalOutputChunk>(capacity = queueCapacity)
    private val queuedChunks = AtomicInteger()
    private val retiredChannels = ConcurrentHashMap<Long, Unit>()
    private val retirementOrder = ConcurrentLinkedQueue<Long>()
    private val acceptedChunks = AtomicLong()
    private val acceptedBytes = AtomicLong()
    private val droppedQueueFullChunks = AtomicLong()
    private val droppedQueueFullBytes = AtomicLong()
    private val truncatedChunks = AtomicLong()
    private val truncatedBytes = AtomicLong()
    private val ignoredRetiredChunks = AtomicLong()
    private val ignoredRetiredBytes = AtomicLong()

    // Check retirement again at delivery time: a callback can win the tiny race
    // between its first retirement check and the queue insertion.
    val output: Flow<TerminalOutputChunk> = incoming
        .receiveAsFlow()
        .onEach { queuedChunks.decrementAndGet() }
        .filter(::deliverable)

    fun submit(terminalChannelId: Long, bytes: ByteArray) {
        if (bytes.isEmpty()) return
        if (retiredChannels.containsKey(terminalChannelId)) return recordRetired(bytes.size)
        val acceptedSize = bytes.size.coerceAtMost(maxChunkBytes)
        if (acceptedSize != bytes.size) {
            truncatedChunks.incrementAndGet()
            truncatedBytes.addAndGet((bytes.size - acceptedSize).toLong())
        }
        if (!reserveQueueSlot()) {
            droppedQueueFullChunks.incrementAndGet()
            droppedQueueFullBytes.addAndGet(bytes.size.toLong())
            return
        }
        val chunk = TerminalOutputChunk(terminalChannelId, bytes.copyOf(acceptedSize))
        if (incoming.trySend(chunk).isSuccess) {
            acceptedChunks.incrementAndGet()
            acceptedBytes.addAndGet(chunk.bytes.size.toLong())
        } else {
            queuedChunks.decrementAndGet()
            droppedQueueFullChunks.incrementAndGet()
            droppedQueueFullBytes.addAndGet(bytes.size.toLong())
        }
    }

    /** Rejects late native callbacks without closing the process-wide callback pipe. */
    fun retire(terminalChannelId: Long) {
        if (retiredChannels.putIfAbsent(terminalChannelId, Unit) == null) {
            retirementOrder.add(terminalChannelId)
            while (retiredChannels.size > MAX_RETIRED_CHANNELS) {
                retirementOrder.poll()?.let(retiredChannels::remove) ?: break
            }
        }
    }

    /** A newly opened channel may receive output immediately after the JNI call returns. */
    fun activate(terminalChannelId: Long) {
        retiredChannels.remove(terminalChannelId)
    }

    private fun deliverable(chunk: TerminalOutputChunk): Boolean {
        if (!retiredChannels.containsKey(chunk.terminalChannelId)) return true
        recordRetired(chunk.bytes.size)
        return false
    }

    private fun recordRetired(byteCount: Int) {
        ignoredRetiredChunks.incrementAndGet()
        ignoredRetiredBytes.addAndGet(byteCount.toLong())
    }

    private fun reserveQueueSlot(): Boolean {
        while (true) {
            val current = queuedChunks.get()
            if (current >= queueCapacity) return false
            if (queuedChunks.compareAndSet(current, current + 1)) return true
        }
    }

    fun metrics(): TerminalOutputBackpressureMetrics = TerminalOutputBackpressureMetrics(
        acceptedChunks = acceptedChunks.get(),
        acceptedBytes = acceptedBytes.get(),
        droppedQueueFullChunks = droppedQueueFullChunks.get(),
        droppedQueueFullBytes = droppedQueueFullBytes.get(),
        truncatedChunks = truncatedChunks.get(),
        truncatedBytes = truncatedBytes.get(),
        ignoredRetiredChunks = ignoredRetiredChunks.get(),
        ignoredRetiredBytes = ignoredRetiredBytes.get(),
    )

    private companion object {
        const val MAX_RETIRED_CHANNELS = 256
    }
}

/** JNI invokes this object from a native worker thread. It must never block that thread. */
object NativeTerminalOutputRouter {
    private val pipeline = TerminalOutputBackpressurePipeline()

    val output: Flow<TerminalOutputChunk> = pipeline.output

    fun onTerminalData(terminalChannelId: Long, bytes: ByteArray) = pipeline.submit(terminalChannelId, bytes)

    fun activate(terminalChannelId: Long) = pipeline.activate(terminalChannelId)

    fun retire(terminalChannelId: Long) = pipeline.retire(terminalChannelId)

    fun metrics(): TerminalOutputBackpressureMetrics = pipeline.metrics()
}
