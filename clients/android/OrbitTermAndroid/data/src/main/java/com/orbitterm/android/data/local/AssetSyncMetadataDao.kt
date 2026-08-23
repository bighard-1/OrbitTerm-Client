package com.orbitterm.android.data.local

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert

@Dao
interface AssetSyncMetadataDao {
    @Query("SELECT * FROM asset_sync_metadata WHERE accountScope = :accountScope AND assetId COLLATE NOCASE = :assetId LIMIT 1")
    suspend fun find(accountScope: String, assetId: String): AssetSyncMetadataEntity?

    @Query("SELECT * FROM asset_sync_metadata WHERE accountScope = :accountScope")
    suspend fun findAll(accountScope: String): List<AssetSyncMetadataEntity>

    @Upsert
    suspend fun upsert(metadata: AssetSyncMetadataEntity)

    @Query("DELETE FROM asset_sync_metadata WHERE accountScope = :accountScope AND assetId COLLATE NOCASE = :assetId")
    suspend fun delete(accountScope: String, assetId: String)
}
