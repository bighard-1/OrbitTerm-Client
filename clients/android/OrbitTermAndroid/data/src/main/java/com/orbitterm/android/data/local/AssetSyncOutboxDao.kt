package com.orbitterm.android.data.local

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert

@Dao
interface AssetSyncOutboxDao {
    @Query("SELECT * FROM asset_sync_outbox WHERE accountScope = :accountScope ORDER BY enqueuedAtUnix ASC")
    suspend fun list(accountScope: String): List<AssetSyncOutboxEntity>

    @Upsert
    suspend fun upsert(operation: AssetSyncOutboxEntity)

    @Query("DELETE FROM asset_sync_outbox WHERE accountScope = :accountScope AND assetId COLLATE NOCASE = :assetId")
    suspend fun delete(accountScope: String, assetId: String)
}
