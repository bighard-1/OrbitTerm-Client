package com.orbitterm.android.data.local

import androidx.room.Entity

/** One coalesced, durable sync intent per asset and account. */
@Entity(tableName = "asset_sync_outbox", primaryKeys = ["accountScope", "assetId"])
data class AssetSyncOutboxEntity(
    val accountScope: String,
    val assetId: String,
    val operation: String,
    val enqueuedAtUnix: Long,
)

enum class AssetSyncOperation { UPSERT, MOVE_TO_TRASH, RESTORE_FROM_TRASH, PURGE_FROM_TRASH }
