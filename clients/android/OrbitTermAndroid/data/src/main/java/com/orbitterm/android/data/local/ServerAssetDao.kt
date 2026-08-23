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

    @Query("SELECT * FROM server_assets WHERE accountScope = :accountScope")
    suspend fun listAll(accountScope: String): List<ServerAssetEntity>

    @Query("SELECT * FROM server_assets WHERE accountScope = :accountScope AND id COLLATE NOCASE = :id LIMIT 1")
    suspend fun findById(accountScope: String, id: String): ServerAssetEntity?

    @Upsert
    suspend fun upsert(asset: ServerAssetEntity)

    @Delete
    suspend fun delete(asset: ServerAssetEntity)
}
