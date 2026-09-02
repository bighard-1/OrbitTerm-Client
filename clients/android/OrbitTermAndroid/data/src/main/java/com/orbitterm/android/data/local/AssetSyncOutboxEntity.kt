package com.orbitterm.android.data.local

import androidx.room.Entity

/** One coalesced, durable sync intent per asset and account. */
@Entity(tableName = "asset_sync_outbox", primaryKeys = ["accountScope", "assetId"])
data class AssetSyncOutboxEntity(
    val accountScope: String,
    val assetId: String,
    val operation: String,
    /** Stable across retries so an accepted mutation is never replayed as a new operation. */
    val operationId: String,
    val enqueuedAtUnix: Long,
    /** Stable machine state; never populated from an exception message. */
    val deliveryDisposition: String = SyncDeliveryDisposition.READY.name,
    /** Allow-listed [com.orbitterm.android.domain.error.OrbitErrorCode] diagnostic code only. */
    val failureCode: String? = null,
    val attemptCount: Int = 0,
    /** Earliest server-authorized retry time; zero means no server delay. */
    val nextAttemptAtUnix: Long = 0,
)

enum class AssetSyncOperation { UPSERT, MOVE_TO_TRASH, RESTORE_FROM_TRASH, PURGE_FROM_TRASH }

enum class SyncDeliveryDisposition {
    READY,
    WAITING_FOR_AUTHENTICATION,
    WAITING_FOR_UNLOCK,
    NEEDS_USER_ACTION,
    BLOCKED,
}
