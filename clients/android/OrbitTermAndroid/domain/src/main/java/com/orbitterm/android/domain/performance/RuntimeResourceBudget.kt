package com.orbitterm.android.domain.performance

import java.nio.charset.StandardCharsets
import java.util.LinkedHashMap

/**
 * Explicit mobile-runtime budgets shared by native bridges and UI features.
 * Values constrain retained memory and UI invalidation frequency; they never
 * contain user content or account data.
 */
object RuntimeResourceBudget {
    const val TERMINAL_OUTPUT_QUEUE_CAPACITY = 128
    const val TERMINAL_OUTPUT_MAX_CHUNK_BYTES = 16 * 1024
    const val TERMINAL_OUTPUT_MAX_BUFFERED_BYTES =
        TERMINAL_OUTPUT_QUEUE_CAPACITY * TERMINAL_OUTPUT_MAX_CHUNK_BYTES
    const val TERMINAL_TRANSCRIPT_ROWS = 10_000
    const val TERMINAL_RENDER_FRAME_MILLIS = 16L
    const val TERMINAL_MAX_PENDING_RENDER_CHANNELS = 64
    const val TERMINAL_EARLY_OUTPUT_MAX_CHANNELS = 16
    const val TERMINAL_EARLY_OUTPUT_MAX_BYTES_PER_CHANNEL = 256 * 1024

    const val SFTP_MAX_QUEUED_TRANSFERS = 8
    const val SFTP_PROGRESS_BUFFER_EVENTS = 64
    const val SFTP_PROGRESS_MIN_INTERVAL_MILLIS = 250L
    const val SFTP_PROGRESS_MIN_BYTE_DELTA = 64 * 1024L

    // A single Compose Text layout for a larger log can consume far more heap
    // than its UTF-8 source. Keep the interactive viewport deliberately small.
    const val DOCKER_LOG_MAX_UI_BYTES = 32 * 1024
    const val DOCKER_LOG_REFRESH_INTERVAL_MILLIS = 2_000L

    const val MONITOR_MIN_REFRESH_SECONDS = 2
    const val MONITOR_HISTORY_SAMPLES = 60
}

/** Device-test thresholds for repeatable release smoke tests, not benchmark claims. */
object PerformanceAcceptanceBaseline {
    const val LARGE_ASSET_COUNT = 1_000
    const val TERMINAL_OUTPUT_STRESS_CHUNKS = 4_096
    const val LONG_DOCKER_LOG_SOURCE_BYTES = 512 * 1024
    const val RAPID_SESSION_SWITCH_COUNT = 32
    const val MAX_OPERATION_MILLIS = 8_000L
    const val MAX_PSS_GROWTH_KB = 48 * 1024
    const val MAX_P95_FRAME_MILLIS = 100L
    const val MIN_FRAME_SAMPLES = 5
    const val MAX_ANR_PROCESS_STATES = 0
}

/** Keeps at most one pending redraw marker per channel until the next frame. */
class FrameInvalidationBatcher<K>(private val maxPendingKeys: Int) {
    private val pending = LinkedHashSet<K>()

    init {
        require(maxPendingKeys > 0)
    }

    /** True only when a new key was admitted; false means coalesced or budgeted out. */
    fun offer(key: K): Boolean = when {
        key in pending -> false
        pending.size >= maxPendingKeys -> false
        else -> pending.add(key)
    }

    fun drain(): Set<K> = pending.toSet().also { pending.clear() }

    fun remove(key: K) {
        pending.remove(key)
    }

    fun clear() = pending.clear()

    val size: Int get() = pending.size
}

/** Emits SFTP progress at a bounded rate while preserving start, completion, and large jumps. */
class TransferProgressUpdateGate(
    private val minIntervalMillis: Long = RuntimeResourceBudget.SFTP_PROGRESS_MIN_INTERVAL_MILLIS,
    private val minByteDelta: Long = RuntimeResourceBudget.SFTP_PROGRESS_MIN_BYTE_DELTA,
    private val maxTrackedTransfers: Int = RuntimeResourceBudget.SFTP_MAX_QUEUED_TRANSFERS + 1,
) {
    private data class Sample(val bytes: Long, val emittedAtMillis: Long)
    private val samples = LinkedHashMap<String, Sample>(maxTrackedTransfers, 0.75f, false)

    init {
        require(minIntervalMillis >= 0)
        require(minByteDelta >= 0)
        require(maxTrackedTransfers > 0)
    }

    fun shouldPublish(requestId: String, transferredBytes: Long, totalBytes: Long?, nowMillis: Long): Boolean {
        if (requestId.isBlank() || transferredBytes < 0) return false
        val previous = samples[requestId]
        val completed = totalBytes != null && transferredBytes >= totalBytes
        val shouldPublish = previous == null ||
            transferredBytes < previous.bytes ||
            completed ||
            transferredBytes - previous.bytes >= minByteDelta ||
            nowMillis - previous.emittedAtMillis >= minIntervalMillis
        if (!shouldPublish) return false
        samples[requestId] = Sample(transferredBytes, nowMillis)
        while (samples.size > maxTrackedTransfers) samples.entries.iterator().run {
            if (hasNext()) {
                next()
                remove()
            }
        }
        return true
    }

    fun clear(requestId: String) {
        samples.remove(requestId)
    }

    val trackedTransferCount: Int get() = samples.size
}

data class BoundedUtf8Text(val content: String, val wasTruncated: Boolean)

/** Retains the newest complete UTF-8 suffix rather than retaining unbounded remote output. */
fun String.retainUtf8Tail(maxBytes: Int): BoundedUtf8Text {
    require(maxBytes > 0)
    val bytes = toByteArray(StandardCharsets.UTF_8)
    if (bytes.size <= maxBytes) return BoundedUtf8Text(this, wasTruncated = false)
    var start = bytes.size - maxBytes
    while (start < bytes.size && (bytes[start].toInt() and 0xC0) == 0x80) start += 1
    return BoundedUtf8Text(
        content = String(bytes, start, bytes.size - start, StandardCharsets.UTF_8),
        wasTruncated = true,
    )
}
