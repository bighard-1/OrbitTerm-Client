package com.orbitterm.android.data.repository

import androidx.room.withTransaction
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import com.orbitterm.android.data.local.AssetSyncOperation
import com.orbitterm.android.data.local.AssetSyncOutboxDao
import com.orbitterm.android.data.local.AssetSyncOutboxEntity
import com.orbitterm.android.data.local.OrbitTermDatabase
import com.orbitterm.android.data.local.ServerAssetDao
import com.orbitterm.android.data.local.toDomain
import com.orbitterm.android.data.local.toEntity
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.AssetStorageScope
import com.orbitterm.android.domain.assets.LOCAL_ASSET_PARTITION
import com.orbitterm.android.domain.assets.ServerCredentials
import com.orbitterm.android.domain.assets.CredentialVault
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Coordinates user-originated asset mutations with the durable sync outbox.
 * Remote pulls deliberately bypass this class so received data is never echoed
 * back to the server as a local edit.
 */
@Singleton
class AssetMutationRepository @Inject constructor(
    private val database: OrbitTermDatabase,
    private val assetDao: ServerAssetDao,
    private val outboxDao: AssetSyncOutboxDao,
    private val credentialStore: CredentialVault,
    private val accountScopeController: ActiveAccountScopeProvider,
) {
    suspend fun save(
        asset: ServerAsset,
        credentials: ServerCredentials,
        jumpHostCredentials: ServerCredentials? = null,
    ) {
        // Validate before any Keystore write so an invalid draft cannot leave
        // a new target credential behind without a corresponding asset route.
        asset.jumpHost?.let { jump ->
            jump.validate()
            requireNotNull(jumpHostCredentials) { "jump host credentials are required" }
        }
        val accountScope = accountScopeController.scope.value?.storageId
        val previous = accountScope?.let {
            assetDao.findVisibleById(it, LOCAL_ASSET_PARTITION, asset.id)?.toDomain()
        } ?: assetDao.findById(LOCAL_ASSET_PARTITION, asset.id)?.toDomain()
        credentialStore.save(asset.credentialID, credentials)
        asset.jumpHost?.let { jump ->
            credentialStore.save(jump.credentialID, requireNotNull(jumpHostCredentials))
        }
        saveMetadataAndQueue(asset)
        previous?.jumpHost?.credentialID
            ?.takeIf { it != asset.jumpHost?.credentialID }
            ?.let(credentialStore::delete)
    }

    suspend fun saveMetadataAndQueue(asset: ServerAsset) {
        val accountScope = accountScopeController.scope.value?.storageId
        val targetScope = when (asset.storageScope) {
            AssetStorageScope.LOCAL_ONLY -> LOCAL_ASSET_PARTITION
            AssetStorageScope.ACCOUNT_SYNCED -> requireNotNull(accountScope) {
                "an account is required for synchronized assets"
            }
        }
        database.withTransaction {
            val previousAccountAsset = accountScope?.let { assetDao.findById(it, asset.id) }
            val previousLocalAsset = assetDao.findById(LOCAL_ASSET_PARTITION, asset.id)

            if (targetScope == LOCAL_ASSET_PARTITION) {
                assetDao.upsert(asset.toEntity(LOCAL_ASSET_PARTITION))
                accountScope?.let { scope ->
                    if (previousAccountAsset != null) {
                        assetDao.deleteById(scope, asset.id)
                        queue(scope, asset.id, AssetSyncOperation.MOVE_TO_TRASH)
                    }
                }
            } else {
                assetDao.upsert(asset.toEntity(targetScope))
                if (previousLocalAsset != null) {
                    assetDao.deleteById(LOCAL_ASSET_PARTITION, asset.id)
                }
                queue(targetScope, asset.id, AssetSyncOperation.UPSERT)
            }
        }
    }

    suspend fun delete(asset: ServerAsset) {
        val accountScope = accountScopeController.scope.value?.storageId
        val partition = when (asset.storageScope) {
            AssetStorageScope.LOCAL_ONLY -> LOCAL_ASSET_PARTITION
            AssetStorageScope.ACCOUNT_SYNCED -> requireNotNull(accountScope) {
                "an account is required for synchronized assets"
            }
        }
        database.withTransaction {
            assetDao.deleteById(partition, asset.id)
            if (asset.storageScope == AssetStorageScope.ACCOUNT_SYNCED) {
                queue(partition, asset.id, AssetSyncOperation.MOVE_TO_TRASH)
            } else {
                outboxDao.delete(partition, asset.id)
            }
        }
        // A failed secure-store cleanup leaves only an inaccessible orphan,
        // never a visible asset without credentials.
        credentialStore.delete(asset.credentialID)
        asset.jumpHost?.let { credentialStore.delete(it.credentialID) }
    }

    private suspend fun queue(scope: String, assetId: String, operation: AssetSyncOperation) {
        outboxDao.upsert(
            AssetSyncOutboxEntity(
                accountScope = scope,
                assetId = assetId,
                operation = operation.name,
                operationId = UUID.randomUUID().toString(),
                enqueuedAtUnix = Instant.now().epochSecond,
            ),
        )
    }

    private fun requireScope(): String = requireNotNull(accountScopeController.scope.value) {
        "no active account"
    }.storageId
}
