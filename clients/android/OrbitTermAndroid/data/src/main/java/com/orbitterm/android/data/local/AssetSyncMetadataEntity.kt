package com.orbitterm.android.data.local

import androidx.room.Entity

/** Remote identity and sync baseline; no credential material is persisted here. */
@Entity(tableName = "asset_sync_metadata", primaryKeys = ["accountScope", "assetId"])
data class AssetSyncMetadataEntity(
    val accountScope: String,
    val assetId: String,
    val remoteConfigId: Long?,
    val vectorClock: String,
    val serverRevision: Long?,
    val remoteState: String,
    val syncedSafeShadow: String,
    val syncedPayloadDigest: String,
    val syncedAtUnix: Long,
)
