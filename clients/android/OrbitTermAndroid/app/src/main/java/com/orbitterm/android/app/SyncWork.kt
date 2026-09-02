package com.orbitterm.android.app

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.AuthSession
import com.orbitterm.android.security.SecureCredentialStore
import com.orbitterm.android.sync.OrbitApi
import com.orbitterm.android.sync.OrbitServiceFailure
import com.orbitterm.android.sync.SyncFailure
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.OrbitError
import com.orbitterm.android.domain.error.syncError
import com.orbitterm.android.sync.SyncRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

internal object SyncWorkContract {
    const val ACCOUNT_SCOPE_KEY = "account_scope"
    const val AUTHORITY_LEASE_KEY = "authority_lease"
    fun uniqueName(scopeId: String, leaseId: String) = "orbitterm.sync.$scopeId.$leaseId"
    fun tag(scopeId: String) = "orbitterm.sync.scope.$scopeId"

    fun isValidScopeId(value: String): Boolean = value.matches(Regex("^[0-9a-f]{64}$"))

    fun isValidLeaseId(value: String): Boolean = runCatching {
        UUID.fromString(value).toString() == value.lowercase()
    }.getOrDefault(false)
}

internal object SyncWorkLeasePolicy {
    fun encode(processEpoch: String, leaseId: String): String = "$processEpoch:$leaseId"

    fun owns(persisted: Any?, processEpoch: String, leaseId: String): Boolean =
        persisted is String && persisted == encode(processEpoch, leaseId)

    fun currentLease(persisted: Any?, processEpoch: String): String? {
        val value = persisted as? String ?: return null
        val prefix = "$processEpoch:"
        return value.takeIf { it.startsWith(prefix) }
            ?.removePrefix(prefix)
            ?.takeIf(SyncWorkContract::isValidLeaseId)
    }
}

internal object SyncWorkAuthorityPolicy {
    fun replacement(activePreferenceKey: String, encodedLease: String): Map<String, String> =
        mapOf(activePreferenceKey to encodedLease)
}

internal sealed interface SyncWorkerFailureDecision {
    data object RetryWithSystemBackoff : SyncWorkerFailureDecision
    data class RetryAfter(val seconds: Long) : SyncWorkerFailureDecision
    data object Stop : SyncWorkerFailureDecision
}

internal object SyncWorkerFailurePolicy {
    fun decide(error: OrbitError): SyncWorkerFailureDecision {
        val retryAfterSeconds = error.retryAfterSeconds
        return when {
            !error.retryable -> SyncWorkerFailureDecision.Stop
            retryAfterSeconds != null -> SyncWorkerFailureDecision.RetryAfter(retryAfterSeconds)
            else -> SyncWorkerFailureDecision.RetryWithSystemBackoff
        }
    }
}

/**
 * A process- and unlock-scoped entitlement, never a master password or access token.
 * Persisting the opaque lease lets WorkManager validate its input, while the
 * in-memory process epoch makes every prior-process lease fail closed.
 */
@Singleton
class SyncWorkAuthority @Inject constructor(@ApplicationContext context: Context) {
    private val preferences = context.getSharedPreferences("orbitterm_sync_work", Context.MODE_PRIVATE)
    private val processEpoch = UUID.randomUUID().toString()

    @Synchronized
    fun allow(scope: AccountScope): String {
        val leaseId = UUID.randomUUID().toString()
        val replacement = SyncWorkAuthorityPolicy.replacement(
            key(scope.storageId),
            SyncWorkLeasePolicy.encode(processEpoch, leaseId),
        )
        val editor = preferences.edit().clear()
        replacement.forEach(editor::putString)
        check(
            editor.commit(),
        )
        return leaseId
    }

    @Synchronized
    fun revoke(scope: AccountScope) {
        check(preferences.edit().remove(key(scope.storageId)).commit())
    }

    @Synchronized
    fun currentLease(scope: AccountScope): String? =
        SyncWorkLeasePolicy.currentLease(preferences.all[key(scope.storageId)], processEpoch)

    @Synchronized
    fun isAllowed(scope: AccountScope, leaseId: String): Boolean =
        SyncWorkContract.isValidLeaseId(leaseId) &&
            SyncWorkLeasePolicy.owns(preferences.all[key(scope.storageId)], processEpoch, leaseId)

    private fun key(scopeId: String) = "allowed.$scopeId"
}

@Singleton
class SyncWorkStateStore @Inject constructor() {
    private val mutableStatus = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    val status = mutableStatus.asStateFlow()
    fun update(status: SyncStatus) { mutableStatus.value = status }
    fun awaitNetwork() { update(SyncStatus.AwaitingNetwork) }
}

@Singleton
class SyncWorkScheduler @Inject constructor(
    @param:ApplicationContext private val context: Context,
    private val authority: SyncWorkAuthority,
    private val state: SyncWorkStateStore,
) {
    fun enqueue(scope: AccountScope) {
        val leaseId = authority.currentLease(scope)
        if (leaseId == null) {
            state.update(SyncStatus.AwaitingUnlock)
            return
        }
        state.update(SyncStatus.Syncing)
        WorkManager.getInstance(context).enqueueUniqueWork(
            SyncWorkContract.uniqueName(scope.storageId, leaseId),
            ExistingWorkPolicy.KEEP,
            request(scope, leaseId),
        )
    }

    /**
     * Appends the next successful outbox slice to the currently running chain.
     * Normal backlog is not a failure and therefore must not consume the
     * exponential network-error backoff budget.
     */
    @Synchronized
    fun enqueueOutboxContinuation(
        scope: AccountScope,
        leaseId: String,
        initialDelaySeconds: Long = 0,
    ): Boolean {
        if (!authority.isAllowed(scope, leaseId)) return false
        WorkManager.getInstance(context).enqueueUniqueWork(
            SyncWorkContract.uniqueName(scope.storageId, leaseId),
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            request(scope, leaseId, initialDelaySeconds),
        )
        return true
    }

    @Synchronized
    fun cancel(scope: AccountScope) {
        val activeLease = authority.currentLease(scope)
        authority.revoke(scope)
        activeLease?.let { leaseId ->
            WorkManager.getInstance(context).cancelUniqueWork(
                SyncWorkContract.uniqueName(scope.storageId, leaseId),
            )
        }
        state.update(SyncStatus.Idle)
    }

    fun stateAwaitingNetwork() = state.awaitNetwork()

    private fun request(scope: AccountScope, leaseId: String, initialDelaySeconds: Long = 0) =
        OneTimeWorkRequestBuilder<OrbitSyncWorker>()
            .setInputData(
                workDataOf(
                    SyncWorkContract.ACCOUNT_SCOPE_KEY to scope.storageId,
                    SyncWorkContract.AUTHORITY_LEASE_KEY to leaseId,
                ),
            )
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
            .apply {
                if (initialDelaySeconds > 0) {
                    setInitialDelay(initialDelaySeconds, TimeUnit.SECONDS)
                }
            }
            .addTag(SyncWorkContract.tag(scope.storageId))
            .build()

}

@EntryPoint
@InstallIn(SingletonComponent::class)
interface SyncWorkerDependencies {
    fun syncRepository(): SyncRepository
    fun assetRepository(): AssetRepository
    fun credentialStore(): SecureCredentialStore
    fun syncAuthority(): SyncWorkAuthority
    fun syncScheduler(): SyncWorkScheduler
    fun syncState(): SyncWorkStateStore
    fun orbitApi(): OrbitApi
}

class OrbitSyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val scopeId = inputData.getString(SyncWorkContract.ACCOUNT_SCOPE_KEY)
            ?.takeIf(SyncWorkContract::isValidScopeId)
            ?: return Result.failure()
        val leaseId = inputData.getString(SyncWorkContract.AUTHORITY_LEASE_KEY)
            ?.takeIf(SyncWorkContract::isValidLeaseId)
            ?: return Result.failure()
        val scope = AccountScope(scopeId)
        val deps = EntryPointAccessors.fromApplication(applicationContext, SyncWorkerDependencies::class.java)
        if (isStopped || !deps.syncAuthority().isAllowed(scope, leaseId)) return Result.success()

        val storedSession = deps.credentialStore().readAuthSession()
            ?.takeIf { AccountScope.fromUsername(it.username) == scope }
            ?: run {
                if (deps.syncAuthority().isAllowed(scope, leaseId)) {
                    deps.syncState().update(SyncStatus.Failed(syncError(OrbitErrorCode.AuthenticationExpired)))
                }
                return Result.success()
            }
        val session = when (val refresh = refreshSessionIfNeeded(deps, scope, leaseId, storedSession)) {
            is RefreshResult.Ready -> refresh.session
            RefreshResult.Retry -> return Result.retry()
            RefreshResult.Stopped -> return Result.success()
        }
        val masterPassword = deps.credentialStore().readBackgroundSyncMasterPassword(scope.storageId)
            ?: run {
                if (deps.syncAuthority().isAllowed(scope, leaseId)) {
                    deps.syncState().update(SyncStatus.AwaitingUnlock)
                }
                return Result.success()
            }
        if (isStopped || !deps.syncAuthority().isAllowed(scope, leaseId)) return Result.success()

        return runCatching {
            val outbox = deps.syncRepository().processAssetOutbox(session.accessToken, masterPassword, scope.storageId)
            ensureActiveScope(deps, scope, leaseId)
            if (outbox.requiresSystemBackoff) {
                val code = outbox.retryableFailureCode ?: OrbitErrorCode.NetworkUnavailable
                deps.syncState().update(SyncStatus.Failed(syncError(code)))
                return@runCatching Result.retry()
            }
            outbox.retryAfterSeconds?.let { retryAfterSeconds ->
                val code = outbox.retryableFailureCode ?: OrbitErrorCode.RemoteRateLimited
                deps.syncState().update(SyncStatus.Failed(syncError(code, retryAfterSeconds)))
                deps.syncScheduler().enqueueOutboxContinuation(scope, leaseId, retryAfterSeconds)
                return@runCatching Result.success()
            }
            if (outbox.waitingForAuthentication > 0) {
                deps.syncState().update(SyncStatus.Failed(syncError(OrbitErrorCode.AuthenticationExpired)))
                return@runCatching Result.success()
            }
            if (outbox.waitingForUnlock > 0) {
                deps.syncState().update(SyncStatus.AwaitingUnlock)
                return@runCatching Result.success()
            }
            if (outbox.hasUnprocessedBacklog) {
                // A durable successful slice hands ownership to a fresh work
                // item. Other pull/merge stages run only after the local
                // mutation backlog is drained, preventing redundant full-sync
                // passes and preserving local-change precedence.
                // Scheduler serialization makes continuation versus
                // lock/logout deterministic: if revocation wins, nothing is
                // appended and this stale worker publishes no further state.
                deps.syncScheduler().enqueueOutboxContinuation(scope, leaseId)
                return@runCatching Result.success()
            }
            val assetCount = deps.syncRepository().pullAndApplyAssets(
                token = session.accessToken,
                masterPassword = masterPassword,
                credentialNamespace = scope.storageId,
                assetRepository = deps.assetRepository(),
            )
            ensureActiveScope(deps, scope, leaseId)
            val snippetCount = deps.syncRepository().syncSnippets(session.accessToken, masterPassword, scope)
            ensureActiveScope(deps, scope, leaseId)
            deps.syncRepository().syncSshKeys(session.accessToken, masterPassword, scope)
            ensureActiveScope(deps, scope, leaseId)
            deps.syncRepository().syncPortForwardProfiles(session.accessToken, masterPassword, scope)
            ensureActiveScope(deps, scope, leaseId)
            deps.syncState().update(SyncStatus.Succeeded(assetCount, snippetCount, outbox))
            Result.success()
        }.getOrElse { error ->
            if (error is SyncScopeInvalidated || isStopped || !deps.syncAuthority().isAllowed(scope, leaseId)) {
                Result.success()
            } else if (error is SyncFailure) {
                deps.syncState().update(SyncStatus.Failed(error.error))
                failureResult(deps, scope, leaseId, error.error)
            } else if (error is OrbitServiceFailure) {
                deps.syncState().update(SyncStatus.Failed(error.error))
                failureResult(deps, scope, leaseId, error.error)
            } else {
                deps.syncState().awaitNetwork()
                Result.retry()
            }
        }
    }

    private fun ensureActiveScope(deps: SyncWorkerDependencies, scope: AccountScope, leaseId: String) {
        if (isStopped || !deps.syncAuthority().isAllowed(scope, leaseId)) throw SyncScopeInvalidated
    }

    private suspend fun refreshSessionIfNeeded(
        deps: SyncWorkerDependencies,
        scope: AccountScope,
        leaseId: String,
        session: AuthSession,
    ): RefreshResult {
        if (!session.accessToken.isExpiringSoon()) return RefreshResult.Ready(session)
        val refreshToken = session.refreshToken ?: run {
            if (deps.syncAuthority().isAllowed(scope, leaseId)) {
                deps.syncState().update(SyncStatus.Failed(syncError(OrbitErrorCode.AuthenticationExpired)))
            }
            return RefreshResult.Stopped
        }
        val refreshed = runCatching { deps.orbitApi().refresh(refreshToken) }
            .getOrElse { failure ->
                if (deps.syncAuthority().isAllowed(scope, leaseId)) {
                    val orbitError = (failure as? OrbitServiceFailure)?.error
                    if (orbitError == null) {
                        deps.syncState().awaitNetwork()
                        return RefreshResult.Retry
                    }
                    deps.syncState().update(SyncStatus.Failed(orbitError))
                    return when (val decision = SyncWorkerFailurePolicy.decide(orbitError)) {
                        SyncWorkerFailureDecision.RetryWithSystemBackoff -> RefreshResult.Retry
                        is SyncWorkerFailureDecision.RetryAfter -> {
                            deps.syncScheduler().enqueueOutboxContinuation(scope, leaseId, decision.seconds)
                            RefreshResult.Stopped
                        }
                        SyncWorkerFailureDecision.Stop -> RefreshResult.Stopped
                    }
                }
                return RefreshResult.Stopped
            }
        val updated = session.copy(
            accessToken = refreshed.accessTokenValue.takeIf(String::isNotBlank) ?: session.accessToken,
            refreshToken = refreshed.refresh_token ?: refreshToken,
        )
        if (!deps.syncAuthority().isAllowed(scope, leaseId)) return RefreshResult.Stopped
        val current = deps.credentialStore().readAuthSession()
        if (current?.username != session.username) return RefreshResult.Stopped
        deps.credentialStore().saveAuthSession(updated)
        return RefreshResult.Ready(updated)
    }

    private object SyncScopeInvalidated : IllegalStateException()

    private fun failureResult(
        deps: SyncWorkerDependencies,
        scope: AccountScope,
        leaseId: String,
        error: OrbitError,
    ): Result = when (val decision = SyncWorkerFailurePolicy.decide(error)) {
        SyncWorkerFailureDecision.RetryWithSystemBackoff -> Result.retry()
        is SyncWorkerFailureDecision.RetryAfter -> {
            deps.syncScheduler().enqueueOutboxContinuation(scope, leaseId, decision.seconds)
            Result.success()
        }
        SyncWorkerFailureDecision.Stop -> Result.success()
    }

    private sealed interface RefreshResult {
        data class Ready(val session: AuthSession) : RefreshResult
        data object Retry : RefreshResult
        data object Stopped : RefreshResult
    }

}

private fun String.isExpiringSoon(nowUnixSeconds: Long = System.currentTimeMillis() / 1_000): Boolean = runCatching {
    val payload = split('.')[1]
    val decoded = String(Base64.getUrlDecoder().decode(payload), Charsets.UTF_8)
    Json.parseToJsonElement(decoded).jsonObject["exp"]?.toString()?.toLongOrNull()
        ?.let { it <= nowUnixSeconds + 60 }
        ?: false
}.getOrDefault(false)
