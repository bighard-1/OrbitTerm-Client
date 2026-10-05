package com.orbitterm.android.data.local

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface ServerAssetDao {
    @Query("SELECT * FROM server_assets WHERE accountScope = :accountScope ORDER BY groupName COLLATE NOCASE, name COLLATE NOCASE")
    fun observeAll(accountScope: String): Flow<List<ServerAssetEntity>>

    @Query(
        "SELECT * FROM server_assets AS visible WHERE accountScope = :localScope OR " +
            "(accountScope = :accountScope AND NOT EXISTS " +
            "(SELECT 1 FROM server_assets AS local WHERE local.accountScope = :localScope " +
            "AND local.id COLLATE NOCASE = visible.id)) " +
            "ORDER BY groupName COLLATE NOCASE, name COLLATE NOCASE",
    )
    fun observeVisible(accountScope: String, localScope: String): Flow<List<ServerAssetEntity>>

    @Query("SELECT * FROM server_assets WHERE accountScope = :accountScope")
    suspend fun listAll(accountScope: String): List<ServerAssetEntity>

    @Query("SELECT * FROM server_assets WHERE accountScope = :accountScope AND id COLLATE NOCASE = :id LIMIT 1")
    suspend fun findById(accountScope: String, id: String): ServerAssetEntity?

    @Query(
        "SELECT * FROM server_assets WHERE accountScope IN (:accountScope, :localScope) " +
            "AND id COLLATE NOCASE = :id ORDER BY CASE WHEN accountScope = :localScope THEN 0 ELSE 1 END LIMIT 1",
    )
    suspend fun findVisibleById(accountScope: String, localScope: String, id: String): ServerAssetEntity?

    @Upsert
    suspend fun upsert(asset: ServerAssetEntity)

    @Delete
    suspend fun delete(asset: ServerAssetEntity)

    @Query("DELETE FROM server_assets WHERE accountScope = :accountScope AND id COLLATE NOCASE = :id")
    suspend fun deleteById(accountScope: String, id: String)
}
