package com.orbitterm.android.sync

import com.orbitterm.android.core.OrbitCoreBridge
import com.orbitterm.android.data.sync.PortableServerConfig
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.ServerAuthMethod
import com.orbitterm.android.domain.assets.ServerCredentials
import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.error.OrbitError
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import com.orbitterm.android.domain.session.CustomQuickCommand
import com.orbitterm.android.domain.session.QuickCommandRepository
import com.orbitterm.android.domain.sync.PrivacySafeSyncMetrics
import com.orbitterm.android.domain.sync.RetryClockGuard
import com.orbitterm.android.domain.sync.SyncDiagnosticEvent
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.orbitterm.android.domain.performance.SyncOutboxBatchPolicy
import com.orbitterm.android.domain.assets.CredentialVault
import com.orbitterm.android.security.SecureCredentialStore
import com.orbitterm.android.data.local.AssetSyncMetadataDao
import com.orbitterm.android.data.local.AssetSyncMetadataEntity
import com.orbitterm.android.data.local.AssetSyncOperation
import com.orbitterm.android.data.local.AssetSyncOutboxDao
import com.orbitterm.android.data.local.SyncDeliveryDisposition as StoredSyncDeliveryDisposition
import com.orbitterm.android.data.local.ServerAssetDao
import com.orbitterm.android.domain.sync.SyncDeliveryDisposition as PolicySyncDeliveryDisposition
import com.orbitterm.android.domain.sync.SyncDeliveryPolicy
import com.orbitterm.android.data.sync.PortableJumpHostConfig
import com.orbitterm.android.data.local.toDomain
import com.orbitterm.android.data.local.toEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.coroutines.flow.first
import android.os.SystemClock
import android.util.Base64
import java.time.Instant
import java.security.MessageDigest
import java.util.UUID
import javax.inject.Inject

/** Carries only a stable code; remote payloads and encrypted data never escape this layer. */
class SyncFailure(val error: OrbitError) : IllegalStateException(error.diagnosticCode)

private fun Throwable.syncDeliveryError(): OrbitError = when (this) {
    is SyncFailure -> error
    is OrbitServiceFailure -> error
    else -> syncError(OrbitErrorCode.Unknown)
}

data class AssetSyncConflict(
    val assetId: String,
    val fields: Set<AssetSyncField>,
    val localSummary: String,
    val remoteSummary: String,
)
data class AssetOutboxResult(
    val delivered: Int = 0,
    /** Temporary failures retained as READY for WorkManager's bounded backoff. */
    val deferred: Int = 0,
    val blocked: Int = 0,
    val waitingForAuthentication: Int = 0,
    val waitingForUnlock: Int = 0,
    val userActionRequired: Int = 0,
    val retryableFailureCode: OrbitErrorCode? = null,
    /** True when WorkManager should apply its ordinary transport backoff. */
    val requiresSystemBackoff: Boolean = false,
    /** Earliest durable Retry-After delay when no immediate READY work remains. */
    val retryAfterSeconds: Long? = null,
    val conflicts: List<AssetSyncConflict> = emptyList(),
    val hasUnprocessedBacklog: Boolean = false,
)
data class RecentlyDeletedAssetSummary(
    val assetId: String,
    val displayName: String,
    val endpoint: String,
    val deletedAt: String?,
    val purgeAfter: String?,
    val canRestore: Boolean,
)

class SyncRepository @Inject constructor(
    private val api: OrbitApi,
    private val credentialStore: CredentialVault,
    private val quickCommandRepository: QuickCommandRepository,
    private val assetDao: ServerAssetDao,
    private val metadataDao: AssetSyncMetadataDao,
    private val outboxDao: AssetSyncOutboxDao,
    private val deviceIdentity: SyncDeviceIdentity,
    private val secureCredentialStore: SecureCredentialStore,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val configCipherSession = ConfigCipherSession()
    private val retryClock = RetryClockGuard()

    /** Security boundary hook: root keys never survive a lock, logout, or account switch. */
    fun clearTransientConfigCrypto() = configCipherSession.clear()

    /** Re-enable only permanent-failure rows after an explicit user action. */
    suspend fun retryBlockedOutbox(accountScope: String): Int = withContext(Dispatchers.IO) {
        outboxDao.resetDisposition(accountScope, StoredSyncDeliveryDisposition.BLOCKED.name)
    }

    /** A confirmed discard never touches retryable, authentication, unlock, or conflict work. */
    suspend fun discardBlockedOutbox(accountScope: String): Int = withContext(Dispatchers.IO) {
        outboxDao.deleteBlocked(accountScope)
    }

    /** Authentication/unlock recovery may resume only the matching paused classes. */
    suspend fun resumeCredentialBlockedOutbox(accountScope: String) = withContext(Dispatchers.IO) {
        outboxDao.resetDisposition(accountScope, StoredSyncDeliveryDisposition.WAITING_FOR_AUTHENTICATION.name)
        outboxDao.resetDisposition(accountScope, StoredSyncDeliveryDisposition.WAITING_FOR_UNLOCK.name)
    }

    /** Existing conflicts are reconsidered only after an explicit retry from the UI. */
    suspend fun resumeUserActionOutbox(accountScope: String): Int = withContext(Dispatchers.IO) {
        outboxDao.resetDisposition(accountScope, StoredSyncDeliveryDisposition.NEEDS_USER_ACTION.name)
    }

    suspend fun loadRecentlyDeleted(
        token: String,
        masterPassword: String,
        accountScope: AccountScope,
    ): List<RecentlyDeletedAssetSummary> = withContext(Dispatchers.IO) {
        api.pullTrash(token, limit = 500, offset = 0).items.mapNotNull { remote ->
            val assetId = RemoteTombstoneMergePolicy.canonicalAssetId(remote.asset_id)
                ?: return@mapNotNull null
            val portable = runCatching {
                val plaintext = configCipherSession.decrypt(masterPassword, accountScope, remote.encrypted_blob_base64)
                json.decodeFromString<PortableServerConfig>(plaintext).validate()
            }.getOrNull()
            RecentlyDeletedAssetSummary(
                assetId = assetId,
                displayName = portable?.name ?: "无法解密的资产",
                endpoint = portable?.let { "${it.username}@${it.host}:${it.port}" } ?: "资产 ID：$assetId",
                deletedAt = remote.deleted_at,
                purgeAfter = remote.purge_after,
                canRestore = portable != null,
            )
        }.sortedByDescending(RecentlyDeletedAssetSummary::deletedAt)
    }

    suspend fun restoreRecentlyDeleted(
        assetId: String,
        token: String,
        masterPassword: String,
        accountScope: AccountScope,
        operationId: String = UUID.randomUUID().toString(),
    ) = withContext(Dispatchers.IO) {
        val canonicalAssetId = RemoteTombstoneMergePolicy.canonicalAssetId(assetId)
            ?: throw SyncFailure(syncError(OrbitErrorCode.RemoteServiceRejected))
        val remote = findTrashAsset(token, canonicalAssetId)
        val plaintext = configCipherSession.decrypt(masterPassword, accountScope, remote.encrypted_blob_base64)
        val portable = json.decodeFromString<PortableServerConfig>(plaintext).validate()
        check(portable.id == canonicalAssetId) { "restored asset identity mismatch" }
        val restored = restore(canonicalAssetId, token, remote.vector_clock, operationId)
        applyRemoteAsset(accountScope.storageId, RemoteAssetCandidate(restored, portable))
    }

    suspend fun purgeRecentlyDeleted(
        assetId: String,
        token: String,
        accountScope: AccountScope,
        operationId: String = UUID.randomUUID().toString(),
    ) = withContext(Dispatchers.IO) {
        val canonicalAssetId = RemoteTombstoneMergePolicy.canonicalAssetId(assetId)
            ?: throw SyncFailure(syncError(OrbitErrorCode.RemoteServiceRejected))
        val remote = findTrashAsset(token, canonicalAssetId)
        UUID.fromString(canonicalAssetId)
        api.purgeAsset(
            token,
            canonicalAssetId,
            AssetMutationRequest(
                device_id = deviceIdentity.value,
                operation_id = operationId,
                vector_clock = SyncVectorClock.bump(remote.vector_clock, "android"),
                confirmation = "CONFIRM",
            ),
        )
        metadataDao.find(accountScope.storageId, canonicalAssetId)?.let {
            metadataDao.delete(accountScope.storageId, canonicalAssetId)
        }
    }

    suspend fun queueRecentlyDeletedMutation(
        assetId: String,
        accountScope: AccountScope,
        purge: Boolean,
        operationId: String = UUID.randomUUID().toString(),
    ) {
        val canonicalAssetId = RemoteTombstoneMergePolicy.canonicalAssetId(assetId)
            ?: throw IllegalArgumentException("asset ID is required")
        UUID.fromString(canonicalAssetId)
        outboxDao.upsert(
            com.orbitterm.android.data.local.AssetSyncOutboxEntity(
                accountScope = accountScope.storageId,
                assetId = canonicalAssetId,
                operation = if (purge) AssetSyncOperation.PURGE_FROM_TRASH.name else AssetSyncOperation.RESTORE_FROM_TRASH.name,
                operationId = operationId,
                enqueuedAtUnix = Instant.now().epochSecond,
            ),
        )
        PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.UnknownResultQueued)
    }

    private suspend fun findTrashAsset(token: String, assetId: String): UploadConfigData {
        val canonicalAssetId = RemoteTombstoneMergePolicy.canonicalAssetId(assetId)
            ?: throw SyncFailure(syncError(OrbitErrorCode.RemoteServiceRejected))
        var offset = 0
        do {
            val page = api.pullTrash(token, limit = 500, offset = offset)
            page.items.firstOrNull {
                RemoteTombstoneMergePolicy.canonicalAssetId(it.asset_id) == canonicalAssetId
            }?.let { return it }
            offset += page.items.size
        } while (page.items.isNotEmpty() && offset < page.total)
        throw SyncFailure(syncError(OrbitErrorCode.RemoteServiceRejected))
    }

    /**
     * Explicit, all-or-nothing V1 → V2 cloud migration. This only prepares
     * opaque replacements locally; the backend compare-and-swap endpoint
     * rejects the complete operation when any source record changed.
     */
    suspend fun migrateRemoteConfigCryptoToV2(
        token: String,
        masterPassword: String,
        accountScope: AccountScope,
    ): Int = withContext(Dispatchers.IO) {
        val remote = completeConfigSnapshot(token)
        val legacy = remote.filterNot { ConfigCipherSession.isV2(it.encrypted_blob_base64) }
        if (legacy.isEmpty()) return@withContext 0
        remote.filter { ConfigCipherSession.isV2(it.encrypted_blob_base64) }.forEach { item ->
            configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
        }
        val replacements = remote.map { item ->
            val v2Ciphertext = if (ConfigCipherSession.isV2(item.encrypted_blob_base64)) {
                item.encrypted_blob_base64
            } else {
                val plaintext = configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
                configCipherSession.encryptV2(masterPassword, accountScope, plaintext)
            }
            check(ConfigCipherSession.isV2(v2Ciphertext)) { "configuration v2 encoding failed" }
            val source = Base64.decode(item.encrypted_blob_base64, Base64.DEFAULT)
            val digest = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(source), Base64.NO_WRAP)
            val nextClock = OrbitCoreBridge.unwrapResult(
                OrbitCoreBridge.orbitVectorClockBump(item.vector_clock, "crypto_v2"),
            )
            ConfigCryptoMigrationItemRequest(
                id = item.id,
                expected_vector_clock = item.vector_clock,
                expected_blob_sha256 = digest,
                encrypted_blob_base64 = v2Ciphertext,
                next_vector_clock = nextClock,
            )
        }
        val response = api.migrateConfigCryptoV2(token, replacements)
        check(response.migrated_count == replacements.size) { "configuration migration count mismatch" }

        // Do not report completion unless the newly committed snapshot is
        // readable under the same account-scoped root key.
        val verified = completeConfigSnapshot(token)
        check(verified.all { item ->
            ConfigCipherSession.isV2(item.encrypted_blob_base64).also { isV2 ->
                if (isV2) configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
            }
        }) { "configuration migration verification failed" }
        configCipherSession.markV2WriteEnabled(accountScope)
        legacy.size
    }

    private suspend fun completeConfigSnapshot(token: String): List<UploadConfigData> {
        val items = api.pullConfigs(token).toMutableList()
        var offset = 0
        while (true) {
            val page = api.pullTrash(token, limit = 500, offset = offset)
            items += page.items
            offset += page.items.size
            if (page.items.isEmpty() || offset >= page.total) break
        }
        check(items.map { it.id }.toSet().size == items.size) { "duplicate configuration snapshot" }
        return items
    }

    suspend fun resolveAssetConflict(
        assetId: String,
        keepLocal: Boolean,
        token: String,
        masterPassword: String,
        accountScope: String,
    ) = withContext(Dispatchers.IO) {
        val remote = activeRemoteAssets(token, masterPassword, AccountScope(accountScope))[assetId]
            ?: throw SyncFailure(syncError(OrbitErrorCode.SyncConflict))
        if (keepLocal) {
            val local = assetDao.findById(accountScope, assetId)?.toDomain() ?: throw SyncFailure(syncError(OrbitErrorCode.SyncConflict))
            val uploaded = uploadAsset(
                token, masterPassword, local, remote.config.vector_clock, remote.config.id, AccountScope(accountScope),
            )
            saveMetadata(accountScope, assetId, uploaded, "active", AssetSyncConflictPolicy.encode(AssetSyncConflictPolicy.shadow(local)))
        } else {
            applyRemoteAsset(accountScope, remote)
        }
        outboxDao.delete(accountScope, assetId)
    }

    suspend fun uploadAsset(
        token: String,
        masterPassword: String,
        asset: ServerAsset,
        vectorClock: String = "{}",
        remoteConfigId: UInt? = null,
        accountScope: AccountScope? = null,
    ): UploadConfigData = withContext(Dispatchers.IO) {
        val credentials = credentialStore.read(asset.credentialID) ?: ServerCredentials()
        val portableJumpHost = asset.jumpHost?.let { jump ->
            val jumpCredentials = credentialStore.read(jump.credentialID)
                ?: throw SyncFailure(syncError(OrbitErrorCode.StorageLocked))
            PortableJumpHostConfig(
                credentialID = jump.credentialID.substringAfterLast(':', jump.credentialID),
                host = jump.host,
                port = jump.port,
                username = jump.username,
                authMethod = jump.authMethod,
                allowPasswordFallback = jump.allowPasswordFallback,
                password = jumpCredentials.password,
                privateKeyContent = jumpCredentials.privateKeyContent,
                privateKeyPassphrase = jumpCredentials.privateKeyPassphrase,
            )
        }
        val portable = PortableServerConfig(
            id = asset.id,
            credentialID = asset.credentialID.substringAfterLast(':', asset.credentialID),
            name = asset.name,
            group = asset.group,
            tags = asset.tags,
            host = asset.host,
            port = asset.port,
            username = asset.username,
            authMethod = asset.authMethod,
            transport = asset.transport,
            networkDeviceProfile = asset.networkDeviceProfile,
            allowPasswordFallback = asset.allowPasswordFallback,
            password = credentials.password,
            privateKeyContent = credentials.privateKeyContent,
            privateKeyPassphrase = credentials.privateKeyPassphrase,
            keyReference = sanitizeKeyReference(credentials.privateKeyContent),
            savedAtUnix = Instant.now().epochSecond,
            jumpHost = portableJumpHost,
        ).validate()
        val plaintext = json.encodeToString(portable)
        val encrypted = if (accountScope != null && configCipherSession.isV2WriteEnabled(accountScope)) {
            configCipherSession.encryptV2(masterPassword, accountScope, plaintext)
        } else {
            OrbitCoreBridge.encryptConfig(masterPassword, plaintext)
        }
        val bumped = runCatching { OrbitCoreBridge.unwrapResult(OrbitCoreBridge.orbitVectorClockBump(vectorClock, "android")) }
            .getOrElse { vectorClock }
        api.uploadConfig(
            token,
            UploadConfigRequest(
                id = remoteConfigId,
                asset_id = asset.id,
                encrypted_blob_base64 = encrypted,
                vector_clock = bumped,
            ),
        )
    }

    /** Delivers persisted local mutations without dropping failures from the outbox. */
    suspend fun processAssetOutbox(token: String, masterPassword: String, accountScope: String): AssetOutboxResult = withContext(Dispatchers.IO) {
        val nowUnix = retryClock.trustedNowUnix(
            wallClockUnixSeconds = Instant.now().epochSecond,
            elapsedRealtimeSeconds = SystemClock.elapsedRealtime() / 1_000,
        )
        val remoteByAssetId = activeRemoteAssets(token, masterPassword, AccountScope(accountScope))
        registerUntrackedLocalAssets(accountScope, remoteByAssetId)
        val queued = outboxDao.listReadyBatch(
            accountScope,
            RuntimeResourceBudget.SYNC_OUTBOX_MAX_OPERATIONS_PER_RUN,
            nowUnix,
        )
        var delivered = 0
        var deferred = 0
        var retryableFailureCode: OrbitErrorCode? = null
        var requiresSystemBackoff = false
        val conflicts = mutableListOf<AssetSyncConflict>()
        queued.forEach { operation ->
            val completed = try {
                when (AssetSyncOperation.entries.firstOrNull { it.name == operation.operation }) {
                    AssetSyncOperation.UPSERT -> deliverUpsert(
                        operation.assetId, token, masterPassword, accountScope, remoteByAssetId, operation.operationId,
                    )
                    AssetSyncOperation.MOVE_TO_TRASH -> deliverDeletion(
                        operation.assetId, token, accountScope, remoteByAssetId, operation.operationId,
                    )
                    AssetSyncOperation.RESTORE_FROM_TRASH -> restoreRecentlyDeleted(
                        operation.assetId, token, masterPassword, AccountScope(accountScope), operation.operationId,
                    )
                    AssetSyncOperation.PURGE_FROM_TRASH -> purgeRecentlyDeleted(
                        operation.assetId, token, AccountScope(accountScope), operation.operationId,
                    )
                    null -> error("unknown_outbox_operation")
                }
                true
            } catch (conflict: DetectedAssetConflict) {
                conflicts += conflict.value
                outboxDao.markFailure(
                    accountScope = accountScope,
                    assetId = operation.assetId,
                    operationId = operation.operationId,
                    disposition = StoredSyncDeliveryDisposition.NEEDS_USER_ACTION.name,
                    failureCode = OrbitErrorCode.SyncConflict.diagnosticCode,
                    nextAttemptAtUnix = 0,
                )
                PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.ConflictDeferred)
                false
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                val orbitError = error.syncDeliveryError()
                val disposition = SyncDeliveryPolicy.disposition(
                    orbitError,
                    attemptCount = operation.attemptCount + 1,
                )
                val storedDisposition = when (disposition) {
                    PolicySyncDeliveryDisposition.Ready -> StoredSyncDeliveryDisposition.READY
                    PolicySyncDeliveryDisposition.WaitingForAuthentication ->
                        StoredSyncDeliveryDisposition.WAITING_FOR_AUTHENTICATION
                    PolicySyncDeliveryDisposition.WaitingForUnlock ->
                        StoredSyncDeliveryDisposition.WAITING_FOR_UNLOCK
                    PolicySyncDeliveryDisposition.Blocked -> StoredSyncDeliveryDisposition.BLOCKED
                }
                outboxDao.markFailure(
                    accountScope = accountScope,
                    assetId = operation.assetId,
                    operationId = operation.operationId,
                    disposition = storedDisposition.name,
                    failureCode = orbitError.diagnosticCode,
                    nextAttemptAtUnix = orbitError.retryAfterSeconds
                        ?.let { nowUnix + it }
                        ?: 0,
                )
                if (storedDisposition == StoredSyncDeliveryDisposition.READY) {
                    deferred += 1
                    retryableFailureCode = retryableFailureCode ?: orbitError.code
                    if (orbitError.retryAfterSeconds == null) requiresSystemBackoff = true
                }
                PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.DeliveryDeferred)
                if (storedDisposition == StoredSyncDeliveryDisposition.BLOCKED) {
                    PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.DeliveryBlocked)
                }
                false
            }
            if (completed) {
                val removed = outboxDao.deleteCompleted(accountScope, operation.assetId, operation.operationId)
                if (removed == 0) PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.LateResponseIgnored)
                delivered += 1
            }
        }
        val eligibleRemaining = outboxDao.countReadyEligible(accountScope, nowUnix)
        val earliestDelayedAttempt = outboxDao.earliestDelayedAttempt(accountScope, nowUnix)
        val delayedFailureCode = outboxDao.earliestDelayedFailureCode(accountScope, nowUnix)
            ?.let { diagnostic -> OrbitErrorCode.entries.firstOrNull { it.diagnosticCode == diagnostic } }
        val blocked = outboxDao.countByDisposition(accountScope, StoredSyncDeliveryDisposition.BLOCKED.name)
        val waitingForAuthentication = outboxDao.countByDisposition(
            accountScope,
            StoredSyncDeliveryDisposition.WAITING_FOR_AUTHENTICATION.name,
        )
        val waitingForUnlock = outboxDao.countByDisposition(
            accountScope,
            StoredSyncDeliveryDisposition.WAITING_FOR_UNLOCK.name,
        )
        val userActionRequired = outboxDao.countByDisposition(
            accountScope,
            StoredSyncDeliveryDisposition.NEEDS_USER_ACTION.name,
        )
        AssetOutboxResult(
            delivered = delivered,
            deferred = deferred,
            blocked = blocked,
            waitingForAuthentication = waitingForAuthentication,
            waitingForUnlock = waitingForUnlock,
            userActionRequired = userActionRequired,
            retryableFailureCode = retryableFailureCode ?: delayedFailureCode,
            requiresSystemBackoff = requiresSystemBackoff,
            retryAfterSeconds = earliestDelayedAttempt?.let { (it - nowUnix).coerceAtLeast(1) },
            conflicts = conflicts,
            hasUnprocessedBacklog = deferred == 0 && conflicts.isEmpty() && SyncOutboxBatchPolicy.hasUnprocessedBacklog(
                attempted = queued.size,
                delivered = delivered,
                remaining = eligibleRemaining,
            ),
        )
    }

    /**
     * Safe upgrade bootstrap: never overwrite a same-ID cloud record for which
     * this client has no baseline. It is registered as the initial baseline;
     * only cloud-missing local assets become upload intents.
     */
    private suspend fun registerUntrackedLocalAssets(
        accountScope: String,
        remoteByAssetId: Map<String, RemoteAssetCandidate>,
    ) {
        val knownIds = metadataDao.findAll(accountScope).mapTo(hashSetOf()) { it.assetId }
        val queuedIds = outboxDao.list(accountScope).mapTo(hashSetOf()) { it.assetId }
        assetDao.listAll(accountScope).forEach { entity ->
            if (entity.id in knownIds || entity.id in queuedIds) return@forEach
            val remote = remoteByAssetId[entity.id]
            if (remote == null) {
                outboxDao.upsert(
                    com.orbitterm.android.data.local.AssetSyncOutboxEntity(
                        accountScope = accountScope,
                        assetId = entity.id,
                        operation = AssetSyncOperation.UPSERT.name,
                        operationId = UUID.randomUUID().toString(),
                        enqueuedAtUnix = Instant.now().epochSecond,
                    ),
                )
            } else {
                saveMetadata(accountScope, entity.id, remote.config, remote.config.state ?: "active")
            }
        }
    }

    private suspend fun deliverUpsert(
        assetId: String,
        token: String,
        masterPassword: String,
        accountScope: String,
        remoteByAssetId: Map<String, RemoteAssetCandidate>,
        operationId: String,
    ) {
        val localAsset = assetDao.findById(accountScope, assetId)?.toDomain() ?: return
        val metadata = metadataDao.find(accountScope, assetId)
        val remote = remoteByAssetId[assetId]
        if (remote != null) {
            val credentials = credentialStore.read(localAsset.credentialID) ?: ServerCredentials()
            val jumpCredentials = localAsset.jumpHost?.let { credentialStore.read(it.credentialID) }
            val matchesLocalState = AssetSyncConflictPolicy.remoteRepresentsLocalState(
                localAsset, credentials, jumpCredentials, remote.portable,
            )
            if (AssetSyncConflictPolicy.isAcceptedUploadEcho(remote.config.state, matchesLocalState)) {
                PrivacySafeSyncMetrics.record(SyncDiagnosticEvent.IdempotentReplayConfirmed)
                saveMetadata(
                    accountScope, assetId, remote.config, remote.config.state ?: "active",
                    AssetSyncConflictPolicy.encode(AssetSyncConflictPolicy.shadow(localAsset)),
                )
                return
            }
        }
        if (shouldAdoptRemote(localAsset, metadata, remote)) {
            applyRemoteAsset(accountScope, requireNotNull(remote))
            return
        }
        val asset = mergeNonConflictingChanges(localAsset, metadata, remote)
        val restored = if (metadata?.remoteState == "deleted") {
            restore(assetId, token, metadata.vectorClock, operationId)
        } else {
            remote?.config
        }
        val base = restored ?: remote?.config
        val response = uploadAsset(
            token = token,
            masterPassword = masterPassword,
            asset = asset,
            vectorClock = SyncVectorClock.bump(base?.vector_clock ?: metadata?.vectorClock ?: "{}", "android"),
            remoteConfigId = base?.id,
            accountScope = AccountScope(accountScope),
        )
        saveMetadata(
            accountScope = accountScope,
            assetId = assetId,
            remote = response,
            remoteState = "active",
            safeShadow = AssetSyncConflictPolicy.encode(AssetSyncConflictPolicy.shadow(asset)),
        )
        if (asset != localAsset) assetDao.upsert(asset.toEntity(accountScope))
    }

    private suspend fun deliverDeletion(
        assetId: String,
        token: String,
        accountScope: String,
        remoteByAssetId: Map<String, RemoteAssetCandidate>,
        operationId: String,
    ) {
        val metadata = metadataDao.find(accountScope, assetId)
        val remote = remoteByAssetId[assetId]
        if (metadata == null && remote == null) return
        val response = moveToTrash(
            assetId, token, metadata?.vectorClock ?: remote?.config?.vector_clock ?: "{}", operationId,
        )
        saveMetadata(
            accountScope = accountScope,
            assetId = assetId,
            remote = response,
            remoteState = "deleted",
            safeShadow = metadata?.syncedSafeShadow.orEmpty(),
        )
    }

    private suspend fun activeRemoteAssets(
        token: String,
        masterPassword: String,
        accountScope: AccountScope,
    ): Map<String, RemoteAssetCandidate> =
        api.pullConfigs(token)
            .filter { it.state == null || it.state == "active" || it.state == "deleted" }
            .mapNotNull { item ->
                runCatching {
                    val plaintext = configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
                    if (isAuxiliaryEnvelope(plaintext)) return@mapNotNull null
                    val portable = json.decodeFromString<PortableServerConfig>(plaintext).validate()
                    portable.id to RemoteAssetCandidate(item, portable)
                }.getOrNull()
            }.toMap()

    private fun mergeNonConflictingChanges(
        local: ServerAsset,
        metadata: AssetSyncMetadataEntity?,
        remote: RemoteAssetCandidate?,
    ): ServerAsset {
        val base = metadata?.syncedSafeShadow?.let(AssetSyncConflictPolicy::decode) ?: return local
        val remoteShadow = remote?.portable?.let(::portableShadow) ?: return local
        val localChanges = AssetSyncConflictPolicy.changedFields(base, AssetSyncConflictPolicy.shadow(local))
        val remoteChanges = AssetSyncConflictPolicy.changedFields(base, remoteShadow)
        val decision = AssetSyncConflictPolicy.decide(localChanges, remoteChanges)
        if (decision is AssetMergeDecision.AutoMerge) {
            return AssetSyncConflictPolicy.mergeRemoteConfiguration(local, remote.portable, decision.localFields)
        }
        if (decision is AssetMergeDecision.RequiresUserChoice && remoteChanges.isNotEmpty()) {
            throw DetectedAssetConflict(
                AssetSyncConflict(
                    assetId = local.id,
                    fields = decision.fields,
                    localSummary = "${local.name} · ${local.username}@${local.host}:${local.port}",
                    remoteSummary = "${remote.portable.name} · ${remote.portable.username}@${remote.portable.host}:${remote.portable.port}",
                ),
            )
        }
        return local
    }

    /** Drops a stale local retry in favour of a newer complete encrypted cloud record. */
    private fun shouldAdoptRemote(
        local: ServerAsset,
        metadata: AssetSyncMetadataEntity?,
        remote: RemoteAssetCandidate?,
    ): Boolean {
        val base = metadata?.syncedSafeShadow?.let(AssetSyncConflictPolicy::decode) ?: return false
        val remoteShadow = remote?.portable?.let(::portableShadow) ?: return false
        val localChanges = AssetSyncConflictPolicy.changedFields(base, AssetSyncConflictPolicy.shadow(local))
        val remoteChanges = AssetSyncConflictPolicy.changedFields(base, remoteShadow)
        return localChanges.isEmpty() && remoteChanges.isNotEmpty()
    }

    /** Applies both configuration and encrypted credential material from one remote record. */
    private suspend fun applyRemoteAsset(accountScope: String, remote: RemoteAssetCandidate) {
        val portable = remote.portable
        val previousEntity = assetDao.findById(accountScope, portable.id)
        val previousJumpCredentialId = previousEntity?.toDomain()?.jumpHost?.credentialID
        val asset = ServerAsset(
            id = portable.id, credentialID = "$accountScope:${portable.credentialID}", name = portable.name,
            group = portable.group, tags = portable.tags, host = portable.host, port = portable.port, username = portable.username,
            authMethod = portable.authMethod, transport = portable.transport,
            networkDeviceProfile = portable.networkDeviceProfile, allowPasswordFallback = portable.allowPasswordFallback,
            jumpHost = portable.jumpHost?.let { jump ->
                jump.toConfiguration().copy(credentialID = "$accountScope:${jump.credentialID}")
            },
            createdAtUnix = portable.savedAtUnix,
        )
        credentialStore.save(asset.credentialID, ServerCredentials(portable.password, portable.privateKeyContent, portable.privateKeyPassphrase))
        portable.jumpHost?.let { jump ->
            credentialStore.save(
                "$accountScope:${jump.credentialID}",
                ServerCredentials(jump.password, jump.privateKeyContent, jump.privateKeyPassphrase),
            )
        }
        // Older Android builds could persist Apple UUID casing verbatim. Room
        // primary keys are binary strings, so remove that legacy spelling
        // before inserting the canonical lower-case identity.
        if (previousEntity != null && previousEntity.id != asset.id) {
            assetDao.delete(previousEntity)
        }
        assetDao.upsert(asset.toEntity(accountScope))
        previousJumpCredentialId
            ?.takeIf { it != asset.jumpHost?.credentialID }
            ?.let(credentialStore::delete)
        saveMetadata(
            accountScope, asset.id, remote.config, remote.config.state ?: "active",
            AssetSyncConflictPolicy.encode(AssetSyncConflictPolicy.shadow(asset)),
        )
    }

    private fun portableShadow(portable: PortableServerConfig) = AssetSyncShadow(
        name = portable.name, group = portable.group, tags = portable.tags, host = portable.host, port = portable.port,
        username = portable.username, authMethod = portable.authMethod, transport = portable.transport,
        networkDeviceProfile = portable.networkDeviceProfile, allowPasswordFallback = portable.allowPasswordFallback,
        jumpHost = portable.jumpHost?.toConfiguration()?.toAssetJumpHostShadow(),
    )

    private data class RemoteAssetCandidate(val config: UploadConfigData, val portable: PortableServerConfig)
    private class DetectedAssetConflict(val value: AssetSyncConflict) : IllegalStateException()

    private suspend fun moveToTrash(
        assetId: String,
        token: String,
        vectorClock: String,
        operationId: String = UUID.randomUUID().toString(),
    ): UploadConfigData {
        UUID.fromString(assetId)
        return api.moveAssetToTrash(
            token,
            assetId,
            AssetMutationRequest(
                device_id = deviceIdentity.value,
                operation_id = operationId,
                vector_clock = SyncVectorClock.bump(vectorClock, "android"),
            ),
        )
    }

    private suspend fun restore(
        assetId: String,
        token: String,
        vectorClock: String,
        operationId: String = UUID.randomUUID().toString(),
    ): UploadConfigData {
        UUID.fromString(assetId)
        return api.restoreAsset(
            token,
            assetId,
            AssetMutationRequest(
                device_id = deviceIdentity.value,
                operation_id = operationId,
                vector_clock = SyncVectorClock.bump(vectorClock, "android"),
            ),
        )
    }

    private suspend fun saveMetadata(
        accountScope: String,
        assetId: String,
        remote: UploadConfigData,
        remoteState: String,
        safeShadow: String = "",
    ) {
        metadataDao.find(accountScope, assetId)
            ?.takeIf { it.assetId != assetId }
            ?.let { metadataDao.delete(accountScope, it.assetId) }
        metadataDao.upsert(
            AssetSyncMetadataEntity(
                accountScope = accountScope,
                assetId = assetId,
                remoteConfigId = remote.id.toLong(),
                vectorClock = remote.vector_clock,
                serverRevision = remote.server_revision?.toLong(),
                remoteState = remoteState,
                syncedSafeShadow = safeShadow,
                syncedPayloadDigest = "",
                syncedAtUnix = Instant.now().epochSecond,
            ),
        )
    }

    suspend fun pullAssets(
        token: String,
        masterPassword: String,
        credentialNamespace: String,
        excludedAssetIds: Set<String> = emptySet(),
    ): List<ServerAsset> = withContext(Dispatchers.IO) {
        val accountScope = AccountScope(credentialNamespace)
        val activeItems = api.pullConfigs(token).filter { it.state == null || it.state == "active" }
        if (activeItems.isNotEmpty() && activeItems.all { ConfigCipherSession.isV2(it.encrypted_blob_base64) }) {
            configCipherSession.markV2WriteEnabled(accountScope)
        }
        var skipped = 0
        val assets = activeItems.mapNotNull { item ->
            runCatching {
                val plaintext = configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
                if (isAuxiliaryEnvelope(plaintext)) return@mapNotNull null
                val portable = json.decodeFromString<PortableServerConfig>(plaintext).validate()
                if (portable.id in excludedAssetIds) return@mapNotNull null
                credentialStore.save(
                    "$credentialNamespace:${portable.credentialID}",
                    ServerCredentials(
                        password = portable.password,
                        privateKeyContent = portable.privateKeyContent,
                        privateKeyPassphrase = portable.privateKeyPassphrase
                    )
                )
                portable.jumpHost?.let { jump ->
                    credentialStore.save(
                        "$credentialNamespace:${jump.credentialID}",
                        ServerCredentials(
                            password = jump.password,
                            privateKeyContent = jump.privateKeyContent,
                            privateKeyPassphrase = jump.privateKeyPassphrase,
                        ),
                    )
                }
                ServerAsset(
                    id = portable.id,
                    credentialID = "$credentialNamespace:${portable.credentialID}",
                    name = portable.name,
                    group = portable.group,
                    tags = portable.tags,
                    host = portable.host,
                    port = portable.port,
                    username = portable.username,
                    authMethod = portable.authMethod,
                    transport = portable.transport,
                    networkDeviceProfile = portable.networkDeviceProfile,
                    allowPasswordFallback = portable.allowPasswordFallback,
                    jumpHost = portable.jumpHost?.let { jump ->
                        jump.toConfiguration().copy(credentialID = "$credentialNamespace:${jump.credentialID}")
                    },
                    createdAtUnix = portable.savedAtUnix
                )
            }.getOrElse {
                skipped += 1
                null
            }
        }
        if (activeItems.isNotEmpty() && assets.isEmpty() && skipped > 0) {
            throw SyncFailure(syncError(OrbitErrorCode.SyncDecryptionFailed))
        }
        // Keep normal synchronization successful when an older server has not
        // deployed the optional migration endpoint. A later successful pull
        // retries from a fresh, complete account snapshot.
        if (activeItems.any { !ConfigCipherSession.isV2(it.encrypted_blob_base64) } &&
            configCipherSession.shouldAttemptV2Migration(accountScope)) {
            configCipherSession.recordV2MigrationAttempt(accountScope)
            try {
                migrateRemoteConfigCryptoToV2(token, masterPassword, accountScope)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // Optional rollout: a missing endpoint or concurrent update
                // never converts a successful normal pull into an error.
            }
        }
        assets
    }

    suspend fun pullAndApplyAssets(token: String, masterPassword: String, credentialNamespace: String, assetRepository: com.orbitterm.android.domain.assets.AssetRepository): Int {
        // Never overwrite a local mutation that is still waiting for delivery.
        val pendingOperations = outboxDao.list(credentialNamespace)
        val pendingAssetIds = pendingOperations.mapNotNullTo(linkedSetOf()) {
            RemoteTombstoneMergePolicy.canonicalAssetId(it.assetId)
        }
        applyRemoteTombstones(token, credentialNamespace, pendingOperations.associateBy {
            RemoteTombstoneMergePolicy.canonicalAssetId(it.assetId) ?: it.assetId
        })
        val assets = pullAssets(token, masterPassword, credentialNamespace, pendingAssetIds)
        for (asset in assets) {
            val previousJumpCredentialId = assetDao.findById(credentialNamespace, asset.id)
                ?.toDomain()
                ?.jumpHost
                ?.credentialID
            assetRepository.saveAssetInScope(asset, credentialNamespace)
            previousJumpCredentialId
                ?.takeIf { it != asset.jumpHost?.credentialID }
                ?.let(credentialStore::delete)
        }
        return assets.size
    }

    /**
     * `pullConfigs` can include soft-deleted records.  Treat those records as
     * authoritative remote deletions before merging active inventory; otherwise
     * a Windows or Apple deletion remains visible on Android forever because
     * `pullAssets` intentionally processes active ciphertext only.
     *
     * A locally queued upsert is not discarded here: delete-versus-edit is a
     * genuine conflict and remains in the outbox for the existing resolver.
     * A queued local delete is already reflected locally, so only its metadata
     * is refreshed.
     */
    private suspend fun applyRemoteTombstones(
        token: String,
        accountScope: String,
        pendingByAssetId: Map<String, com.orbitterm.android.data.local.AssetSyncOutboxEntity>,
    ) {
        // Deployments are allowed to return only active records from the
        // inventory endpoint. Always reconcile the paginated trash feed as
        // well, keyed by asset identity so a tombstone with a newer config
        // record ID still overrides the active representation.
        val inventoryTombstones = api.pullConfigs(token)
            .filter { it.state != null && it.state != "active" }
        val trashItems = mutableListOf<UploadConfigData>()
        var offset = 0
        while (true) {
            val page = api.pullTrash(token, limit = 500, offset = offset)
            trashItems += page.items
            offset += page.items.size
            if (page.items.isEmpty() || offset >= page.total) break
        }

        for (remote in RemoteTombstoneMergePolicy.merge(inventoryTombstones, trashItems)) {
            val assetId = RemoteTombstoneMergePolicy.canonicalAssetId(remote.asset_id) ?: continue
            val pending = pendingByAssetId[assetId]
            val metadata = metadataDao.find(accountScope, assetId)
            saveMetadata(
                accountScope = accountScope,
                assetId = assetId,
                remote = remote,
                remoteState = "deleted",
                safeShadow = metadata?.syncedSafeShadow.orEmpty(),
            )

            if (pending?.operation == AssetSyncOperation.UPSERT.name) {
                continue
            }

            val local = assetDao.findById(accountScope, assetId)?.toDomain() ?: continue
            assetDao.delete(local.toEntity(accountScope))
            credentialStore.delete(local.credentialID)
            local.jumpHost?.let { credentialStore.delete(it.credentialID) }
        }
    }

    /** Synchronizes the encrypted, cross-platform Snippet envelope shared with iOS. */
    suspend fun syncSnippets(token: String, masterPassword: String, accountScope: AccountScope): Int = withContext(Dispatchers.IO) {
        val local = quickCommandRepository.commandsForScope(accountScope).first()
        val remote = latestSnippetEnvelope(api.pullConfigs(token), masterPassword, accountScope)
        val remoteTime = remote?.envelope?.updatedAtUnix ?: Long.MIN_VALUE
        val localTime = local.maxOfOrNull(CustomQuickCommand::updatedAtUnix) ?: Long.MIN_VALUE

        if (remote != null && remoteTime >= localTime) {
            val decoded = remote.envelope.snippets.map(SnippetWireCommand::toDomain)
            quickCommandRepository.saveForScope(decoded, accountScope)
            return@withContext decoded.size
        }
        if (local.isEmpty()) return@withContext 0

        val now = System.currentTimeMillis() / 1_000
        val envelope = SnippetSyncEnvelope(
            updatedAtUnix = maxOf(now, localTime),
            snippets = local.map(SnippetWireCommand::fromDomain),
        )
        val plaintext = json.encodeToString(envelope)
        val encrypted = if (configCipherSession.isV2WriteEnabled(accountScope)) {
            configCipherSession.encryptV2(masterPassword, accountScope, plaintext)
        } else {
            OrbitCoreBridge.encryptConfig(masterPassword, plaintext)
        }
        val baseClock = remote?.vectorClock ?: "{}"
        val nextClock = runCatching {
            OrbitCoreBridge.unwrapResult(OrbitCoreBridge.orbitVectorClockBump(baseClock, "snippet_client"))
        }.getOrElse { baseClock }
        api.uploadConfig(
            token = token,
            payload = UploadConfigRequest(
                id = remote?.configId,
                encrypted_blob_base64 = encrypted,
                vector_clock = nextClock,
            ),
        )
        local.size
    }

    /**
     * Mobile preserves and merges desktop-created profiles but never starts a
     * tunnel. The whole local document is Android-Keystore encrypted and keyed
     * by the opaque account scope; switching accounts cannot expose profiles.
     */
    suspend fun syncPortForwardProfiles(token: String, masterPassword: String, accountScope: AccountScope): Int = withContext(Dispatchers.IO) {
        val scope = accountScope.storageId
        var local = secureCredentialStore.readPortForwardProfileDocument(scope)
            ?.let { runCatching { json.decodeFromString<PortForwardProfileVaultDocument>(it) }.getOrNull() }
            ?: PortForwardProfileVaultDocument()
        val remote = api.pullConfigs(token).asSequence()
            .filter { it.state == null || it.state == "active" }
            .mapNotNull { item ->
                runCatching {
                    val plaintext = configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
                    PortForwardProfileSyncContract.decode(plaintext)?.let { Triple(it, item.id, item.vector_clock) }
                }.getOrNull()
            }.maxByOrNull { it.first.updatedAtUnix }

        val tombstones = local.tombstones.toMutableMap()
        remote?.first?.tombstones?.forEach { tombstones[it.id] = maxOf(tombstones[it.id] ?: 0, it.deletedAtUnix) }
        val merged = local.profiles.associateBy { it.id }.toMutableMap()
        remote?.first?.profiles?.sortedBy { it.updatedAtUnix }?.forEach { profile ->
            if ((tombstones[profile.id] ?: 0) >= profile.updatedAtUnix) merged.remove(profile.id)
            else if ((merged[profile.id]?.updatedAtUnix ?: Long.MIN_VALUE) <= profile.updatedAtUnix &&
                local.localOnlyProfiles.none { it.id == profile.id }) merged[profile.id] = profile
        }
        tombstones.forEach { (id, deletedAt) -> if ((merged[id]?.updatedAtUnix ?: Long.MAX_VALUE) <= deletedAt) merged.remove(id) }
        val now = System.currentTimeMillis() / 1_000
        val envelope = PortForwardProfileSyncEnvelope(
            kind = PortForwardProfileSyncContract.MARKER,
            version = PortForwardProfileSyncContract.VERSION,
            updatedAtUnix = maxOf(now, merged.values.maxOfOrNull { it.updatedAtUnix } ?: 0, tombstones.values.maxOrNull() ?: 0),
            profiles = merged.values.sortedBy { it.id },
            tombstones = tombstones.map { PortForwardProfileTombstoneWire(it.key, it.value) }.sortedBy { it.id },
        )
        val plaintext = PortForwardProfileSyncContract.encode(envelope)
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(plaintext.toByteArray()).joinToString("") { "%02X".format(it) }
        var remoteId = remote?.second ?: local.remoteConfigId
        var vectorClock = remote?.third ?: local.vectorClock
        if (fingerprint != local.payloadFingerprint || remoteId == null) {
            val encrypted = if (configCipherSession.isV2WriteEnabled(accountScope))
                configCipherSession.encryptV2(masterPassword, accountScope, plaintext)
            else OrbitCoreBridge.encryptConfig(masterPassword, plaintext)
            vectorClock = runCatching {
                OrbitCoreBridge.unwrapResult(OrbitCoreBridge.orbitVectorClockBump(vectorClock, "port_forward_client"))
            }.getOrElse { vectorClock }
            val uploaded = api.uploadConfig(token, UploadConfigRequest(
                id = remoteId,
                encrypted_blob_base64 = encrypted,
                vector_clock = vectorClock,
            ))
            remoteId = uploaded.id
            vectorClock = uploaded.vector_clock
        }
        local = local.copy(profiles = merged.values.toList(), tombstones = tombstones,
            remoteConfigId = remoteId, vectorClock = vectorClock, payloadFingerprint = fingerprint)
        secureCredentialStore.savePortForwardProfileDocument(scope, json.encodeToString(local))
        merged.size
    }

    /** Imports the reusable SSH-key envelope into the account's Keystore-backed library and restores explicit asset assignments. */
    suspend fun syncSshKeys(token: String, masterPassword: String, accountScope: AccountScope): Int = withContext(Dispatchers.IO) {
        val scope = accountScope.storageId
        val savedDocument = secureCredentialStore.readSshKeyLibraryDocument(scope)
        var local = if (savedDocument == null) {
            SshKeyVaultDocument()
        } else {
            // A damaged local secure document must never be treated as an
            // empty library and uploaded over recoverable cloud state.
            json.decodeFromString<SshKeyVaultDocument>(savedDocument)
        }
        val remote = api.pullConfigs(token).asSequence()
            .filter { it.state == null || it.state == "active" }
            .mapNotNull { item ->
                runCatching {
                    val plaintext = configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
                    SshKeySyncContract.decode(plaintext)?.let { Triple(it, item.id, item.vector_clock) }
                }.getOrNull()
            }.maxByOrNull { it.first.updatedAtUnix }

        val tombstones = local.tombstones.toMutableMap()
        remote?.first?.tombstones?.forEach { tombstones[it.id] = maxOf(tombstones[it.id] ?: 0, it.deletedAtUnix) }
        val merged = local.keys.associateBy { it.id }.toMutableMap()
        val localOnlyIds = local.localOnlyKeys.mapTo(mutableSetOf()) { it.id }
        val localOnlyFingerprints = local.localOnlyKeys.mapTo(mutableSetOf()) { it.materialFingerprint }
        remote?.first?.keys?.sortedBy { it.updatedAtUnix }?.forEach { key ->
            if (key.id in localOnlyIds || key.materialFingerprint in localOnlyFingerprints ||
                (tombstones[key.id] ?: 0) >= key.updatedAtUnix) return@forEach
            if ((merged[key.id]?.updatedAtUnix ?: Long.MIN_VALUE) > key.updatedAtUnix) return@forEach
            if (merged.values.any { it.id != key.id && it.materialFingerprint == key.materialFingerprint }) return@forEach
            merged[key.id] = key
        }
        tombstones.forEach { (id, deletedAt) -> if ((merged[id]?.updatedAtUnix ?: Long.MAX_VALUE) <= deletedAt) merged.remove(id) }

        // Assignment is account-scoped and writes only the credential vault;
        // Room continues to contain no private key material.
        merged.values.forEach { key ->
            key.assignedAssetIds.forEach assignment@{ assetId ->
                val asset = assetDao.findById(scope, assetId)?.toDomain() ?: return@assignment
                val previous = credentialStore.read(asset.credentialID) ?: ServerCredentials()
                if (previous.privateKeyContent != key.privateKey || previous.privateKeyPassphrase != key.passphrase) {
                    credentialStore.save(asset.credentialID, previous.copy(
                        privateKeyContent = key.privateKey,
                        privateKeyPassphrase = key.passphrase,
                    ))
                }
                // The reusable-key assignment is authoritative for the local
                // connection path. Persist only the non-sensitive auth mode in
                // Room so the restored private key is actually selected by the
                // Android SSH client; key material remains Keystore-only.
                if (asset.authMethod != ServerAuthMethod.key.name) {
                    assetDao.upsert(asset.copy(authMethod = ServerAuthMethod.key.name).toEntity(scope))
                }
            }
        }

        val now = System.currentTimeMillis() / 1_000
        val envelope = SshKeySyncEnvelope(
            kind = SshKeySyncContract.MARKER,
            version = 1,
            updatedAtUnix = maxOf(now, merged.values.maxOfOrNull { it.updatedAtUnix } ?: 0, tombstones.values.maxOrNull() ?: 0),
            keys = merged.values.sortedBy { it.id },
            tombstones = tombstones.map { SshKeyTombstoneWire(it.key, it.value) }.sortedBy { it.id },
        )
        if (envelope.keys.isEmpty() && envelope.tombstones.isEmpty() && remote == null) return@withContext 0
        val plaintext = SshKeySyncContract.encode(envelope)
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(plaintext.toByteArray()).joinToString("") { "%02X".format(it) }
        var remoteId = remote?.second ?: local.remoteConfigId
        var vectorClock = remote?.third ?: local.vectorClock
        if (fingerprint != local.payloadFingerprint || remoteId == null) {
            val encrypted = if (configCipherSession.isV2WriteEnabled(accountScope))
                configCipherSession.encryptV2(masterPassword, accountScope, plaintext)
            else OrbitCoreBridge.encryptConfig(masterPassword, plaintext)
            vectorClock = runCatching {
                OrbitCoreBridge.unwrapResult(OrbitCoreBridge.orbitVectorClockBump(vectorClock, "ssh_key_client"))
            }.getOrElse { vectorClock }
            val uploaded = api.uploadConfig(token, UploadConfigRequest(
                id = remoteId,
                encrypted_blob_base64 = encrypted,
                vector_clock = vectorClock,
            ))
            remoteId = uploaded.id
            vectorClock = uploaded.vector_clock
        }
        local = local.copy(keys = merged.values.toList(), tombstones = tombstones,
            remoteConfigId = remoteId, vectorClock = vectorClock, payloadFingerprint = fingerprint)
        secureCredentialStore.saveSshKeyLibraryDocument(scope, json.encodeToString(local))
        merged.size
    }

    private fun latestSnippetEnvelope(
        items: List<UploadConfigData>,
        masterPassword: String,
        accountScope: AccountScope,
    ): SnippetRemoteCandidate? = items.asSequence()
        .filter { it.state == null || it.state == "active" }
        .mapNotNull { item ->
            runCatching {
                val plaintext = configCipherSession.decrypt(masterPassword, accountScope, item.encrypted_blob_base64)
                val envelope = json.decodeFromString<SnippetSyncEnvelope>(plaintext)
                if (envelope.kind == SnippetSyncEnvelope.MARKER && envelope.version == 1) {
                    SnippetRemoteCandidate(envelope, item.id, item.vector_clock)
                } else {
                    null
                }
            }.getOrNull()
        }
        .maxByOrNull { it.envelope.updatedAtUnix }

    private fun isSnippetEnvelope(plaintext: String): Boolean = runCatching {
        json.decodeFromString<SnippetSyncEnvelope>(plaintext).kind == SnippetSyncEnvelope.MARKER
    }.getOrDefault(false)

    private fun isAuxiliaryEnvelope(plaintext: String): Boolean =
        isSnippetEnvelope(plaintext) ||
            SshKeySyncContract.decode(plaintext) != null ||
            PortForwardProfileSyncContract.decode(plaintext) != null

    private fun sanitizeKeyReference(raw: String): String {
        if (!raw.contains("PRIVATE KEY")) return ""
        return "imported-key"
    }
}

fun Throwable.isRetryableRecentlyDeletedFailure(): Boolean = when (this) {
    is OrbitServiceFailure -> error.retryable
    is SyncFailure -> error.retryable
    else -> false
}

/**
 * Keeps the V2 root key in the repository's account scope only. V1 records
 * still use their independent Argon2id derivation, so this is strictly a
 * reader optimization and does not alter Phase 1 write compatibility.
 */
class ConfigCipherSession {
    private var accountScope: String? = null
    private var rootKey: ByteArray? = null
    private val v2WriteScopes = mutableSetOf<String>()
    private val lastV2MigrationAttemptMillis = mutableMapOf<String, Long>()

    @Synchronized
    fun decrypt(masterPassword: String, scope: AccountScope, encryptedBase64: String): String {
        if (!isV2(encryptedBase64)) {
            return OrbitCoreBridge.decryptConfig(masterPassword, encryptedBase64)
        }
        val key = rootKey?.takeIf { accountScope == scope.storageId }
            ?: OrbitCoreBridge.deriveConfigRootKeyV2(masterPassword, scope.storageId).also { derived ->
                clear()
                accountScope = scope.storageId
                rootKey = derived
            }
        return OrbitCoreBridge.decryptConfigV2(key, encryptedBase64)
    }

    @Synchronized
    fun encryptV2(masterPassword: String, scope: AccountScope, plaintext: String): String {
        val key = rootKey?.takeIf { accountScope == scope.storageId }
            ?: OrbitCoreBridge.deriveConfigRootKeyV2(masterPassword, scope.storageId).also { derived ->
                clear()
                accountScope = scope.storageId
                rootKey = derived
            }
        return OrbitCoreBridge.encryptConfigV2(key, plaintext)
    }

    @Synchronized
    fun markV2WriteEnabled(scope: AccountScope) {
        v2WriteScopes += scope.storageId
    }

    @Synchronized
    fun isV2WriteEnabled(scope: AccountScope): Boolean = scope.storageId in v2WriteScopes

    @Synchronized
    fun shouldAttemptV2Migration(scope: AccountScope, nowMillis: Long = System.currentTimeMillis()): Boolean {
        val lastAttempt = lastV2MigrationAttemptMillis[scope.storageId] ?: return true
        return nowMillis - lastAttempt >= 15 * 60 * 1_000
    }

    @Synchronized
    fun recordV2MigrationAttempt(scope: AccountScope, nowMillis: Long = System.currentTimeMillis()) {
        lastV2MigrationAttemptMillis[scope.storageId] = nowMillis
    }

    @Synchronized
    fun clear() {
        rootKey?.fill(0)
        rootKey = null
        accountScope = null
        v2WriteScopes.clear()
        lastV2MigrationAttemptMillis.clear()
    }

    companion object {
        fun isV2(encryptedBase64: String): Boolean = runCatching {
        Base64.decode(encryptedBase64, Base64.DEFAULT).let { bytes ->
            bytes.size >= 4 && bytes[0] == 'O'.code.toByte() && bytes[1] == 'T'.code.toByte()
                && bytes[2] == 'C'.code.toByte() && bytes[3] == '2'.code.toByte()
        }
        }.getOrDefault(false)
    }
}

@Serializable
private data class SnippetSyncEnvelope(
    val kind: String = MARKER,
    val version: Int = 1,
    val updatedAtUnix: Long,
    val snippets: List<SnippetWireCommand>,
) {
    companion object { const val MARKER = "orbit_snippets" }
}

/** Property names intentionally match Swift Codable (`assetScope`, `assetIDs`, `createdAt`). */
@Serializable
private data class SnippetWireCommand(
    val id: String,
    val title: String,
    val command: String,
    val category: String,
    val assetScope: SnippetAssetScopeWire = SnippetAssetScopeWire(),
    val createdAt: Double,
    val updatedAt: Double,
) {
    fun toDomain(): CustomQuickCommand = CustomQuickCommand(
        id = id,
        title = title,
        command = command,
        category = category.ifBlank { "未分类" },
        allowedAssetIds = if (assetScope.mode == "selectedAssets") assetScope.assetIDs else emptySet(),
        createdAtUnix = (createdAt + APPLE_REFERENCE_DATE_TO_UNIX_SECONDS).toLong(),
        updatedAtUnix = (updatedAt + APPLE_REFERENCE_DATE_TO_UNIX_SECONDS).toLong(),
    )

    companion object {
        fun fromDomain(command: CustomQuickCommand): SnippetWireCommand = SnippetWireCommand(
            id = command.id,
            title = command.title,
            command = command.command,
            category = command.category,
            assetScope = SnippetAssetScopeWire(
                mode = if (command.allowedAssetIds.isEmpty()) "allAssets" else "selectedAssets",
                assetIDs = command.allowedAssetIds,
            ),
            createdAt = command.createdAtUnix.toDouble() - APPLE_REFERENCE_DATE_TO_UNIX_SECONDS,
            updatedAt = command.updatedAtUnix.toDouble() - APPLE_REFERENCE_DATE_TO_UNIX_SECONDS,
        )
    }
}

@Serializable
private data class SnippetAssetScopeWire(
    val mode: String = "allAssets",
    val assetIDs: Set<String> = emptySet(),
)

private data class SnippetRemoteCandidate(
    val envelope: SnippetSyncEnvelope,
    val configId: UInt,
    val vectorClock: String,
)

private const val APPLE_REFERENCE_DATE_TO_UNIX_SECONDS = 978_307_200.0
