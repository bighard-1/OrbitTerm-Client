package com.orbitterm.android.data.repository

import com.orbitterm.android.data.local.ServerAssetDao
import com.orbitterm.android.data.local.toDomain
import com.orbitterm.android.data.local.toEntity
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.AssetStorageScope
import com.orbitterm.android.domain.assets.LOCAL_ASSET_PARTITION
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
@OptIn(ExperimentalCoroutinesApi::class)
class RoomAssetRepository @Inject constructor(
    private val assetDao: ServerAssetDao,
    private val accountScopeController: ActiveAccountScopeProvider,
) : AssetRepository {
    override fun observeAssets(): Flow<List<ServerAsset>> = accountScopeController.scope.flatMapLatest { scope ->
        scope?.let { assetDao.observeVisible(it.storageId, LOCAL_ASSET_PARTITION) }
            ?: assetDao.observeAll(LOCAL_ASSET_PARTITION)
    }.map { assets ->
        assets.map { it.toDomain() }
    }

    override suspend fun findAsset(id: String): ServerAsset? {
        val account = accountScopeController.scope.value?.storageId
        return if (account == null) {
            assetDao.findById(LOCAL_ASSET_PARTITION, id)?.toDomain()
        } else {
            assetDao.findVisibleById(account, LOCAL_ASSET_PARTITION, id)?.toDomain()
        }
    }

    override suspend fun saveAsset(asset: ServerAsset) {
        assetDao.upsert(asset.toEntity(partitionFor(asset)))
    }

    override suspend fun saveAssetInScope(asset: ServerAsset, accountScope: String) {
        assetDao.upsert(asset.toEntity(accountScope))
    }

    override suspend fun deleteAsset(id: String) {
        val asset = findAsset(id) ?: return
        assetDao.delete(asset.toEntity(partitionFor(asset)))
    }

    private fun requireScope(): String = requireNotNull(accountScopeController.scope.value) { "no active account" }.storageId

    private fun partitionFor(asset: ServerAsset): String = when (asset.storageScope) {
        AssetStorageScope.LOCAL_ONLY -> LOCAL_ASSET_PARTITION
        AssetStorageScope.ACCOUNT_SYNCED -> requireScope()
    }
}
