package com.orbitterm.android.domain.assets

import kotlinx.coroutines.flow.Flow

interface AssetRepository {
    fun observeAssets(): Flow<List<ServerAsset>>
    suspend fun findAsset(id: String): ServerAsset?
    suspend fun saveAsset(asset: ServerAsset)
    /** Saves into an explicitly captured account partition for background synchronization. */
    suspend fun saveAssetInScope(asset: ServerAsset, accountScope: String)
    suspend fun deleteAsset(id: String)
}
