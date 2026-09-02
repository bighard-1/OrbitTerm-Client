package com.orbitterm.android.domain.sync

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Compile-time allow-list for aggregate, process-local sync diagnostics. */
enum class SyncDiagnosticEvent(val diagnosticCode: String) {
    UnknownResultQueued("unknown_result_queued"),
    DeliveryDeferred("delivery_deferred"),
    DeliveryBlocked("delivery_blocked"),
    ConflictDeferred("conflict_deferred"),
    IdempotentReplayConfirmed("idempotent_replay_confirmed"),
    LateResponseIgnored("late_response_ignored"),
}

/** Never stores timestamps, identities, payloads, endpoints, or error text. */
object PrivacySafeSyncMetrics {
    private val counts = ConcurrentHashMap<SyncDiagnosticEvent, AtomicInteger>()

    fun record(event: SyncDiagnosticEvent) {
        counts.getOrPut(event) { AtomicInteger() }.incrementAndGet()
    }

    fun snapshot(): Map<SyncDiagnosticEvent, Int> = counts.entries
        .associate { (event, count) -> event to count.get() }
        .filterValues { it > 0 }

    fun clear() = counts.clear()
}
