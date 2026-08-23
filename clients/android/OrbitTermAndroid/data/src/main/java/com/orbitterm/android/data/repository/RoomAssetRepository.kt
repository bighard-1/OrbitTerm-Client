package com.orbitterm.android.data.repository

import com.orbitterm.android.data.local.ServerAssetDao
import com.orbitterm.android.data.local.toDomain
import com.orbitterm.android.data.local.toEntity
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
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
        scope?.let { assetDao.observeAll(it.storageId) } ?: flowOf(emptyList())
    }.map { assets ->
        assets.map { it.toDomain() }
    }

    override suspend fun findAsset(id: String): ServerAsset? = assetDao.findById(requireScope(), id)?.toDomain()

    override suspend fun saveAsset(asset: ServerAsset) {
        assetDao.upsert(asset.toEntity(requireScope()))
    }

    override suspend fun saveAssetInScope(asset: ServerAsset, accountScope: String) {
        assetDao.upsert(asset.toEntity(accountScope))
    }

    override suspend fun deleteAsset(id: String) {
        val asset = assetDao.findById(requireScope(), id) ?: return
        assetDao.delete(asset)
    }

    private fun requireScope(): String = requireNotNull(accountScopeController.scope.value) { "no active account" }.storageId
}
