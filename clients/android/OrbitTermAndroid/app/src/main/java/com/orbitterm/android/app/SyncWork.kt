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
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

internal object SyncWorkContract {
    const val ACCOUNT_SCOPE_KEY = "account_scope"
    fun uniqueName(scopeId: String) = "orbitterm.sync.$scopeId"
    fun tag(scopeId: String) = "orbitterm.sync.scope.$scopeId"
}

/** A persisted entitlement, never a master password or an access token. */
@Singleton
class SyncWorkAuthority @Inject constructor(@ApplicationContext context: Context) {
    private val preferences = context.getSharedPreferences("orbitterm_sync_work", Context.MODE_PRIVATE)

    fun allow(scope: AccountScope) {
        check(preferences.edit().putBoolean(key(scope.storageId), true).commit())
    }

    fun revoke(scope: AccountScope) {
        check(preferences.edit().remove(key(scope.storageId)).commit())
    }

    fun isAllowed(scope: AccountScope): Boolean = preferences.getBoolean(key(scope.storageId), false)

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
        if (!authority.isAllowed(scope)) {
            state.update(SyncStatus.AwaitingUnlock)
            return
        }
        state.update(SyncStatus.Syncing)
        WorkManager.getInstance(context).enqueueUniqueWork(
            SyncWorkContract.uniqueName(scope.storageId),
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<OrbitSyncWorker>()
                .setInputData(workDataOf(SyncWorkContract.ACCOUNT_SCOPE_KEY to scope.storageId))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
                .addTag(SyncWorkContract.tag(scope.storageId))
                .build(),
        )
    }

    fun cancel(scope: AccountScope) {
        authority.revoke(scope)
        WorkManager.getInstance(context).cancelUniqueWork(SyncWorkContract.uniqueName(scope.storageId))
        state.update(SyncStatus.Idle)
    }

    fun stateAwaitingNetwork() = state.awaitNetwork()

}

@EntryPoint
@InstallIn(SingletonComponent::class)
interface SyncWorkerDependencies {
    fun syncRepository(): SyncRepository
    fun assetRepository(): AssetRepository
    fun credentialStore(): SecureCredentialStore
    fun syncAuthority(): SyncWorkAuthority
    fun syncState(): SyncWorkStateStore
    fun orbitApi(): OrbitApi
}

class OrbitSyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val scopeId = inputData.getString(SyncWorkContract.ACCOUNT_SCOPE_KEY) ?: return Result.failure()
        val scope = AccountScope(scopeId)
        val deps = EntryPointAccessors.fromApplication(applicationContext, SyncWorkerDependencies::class.java)
        if (isStopped || !deps.syncAuthority().isAllowed(scope)) return Result.success()

        val storedSession = deps.credentialStore().readAuthSession()
            ?.takeIf { AccountScope.fromUsername(it.username) == scope }
            ?: run {
                deps.syncState().update(SyncStatus.Failed(syncError(OrbitErrorCode.AuthenticationExpired)))
                return Result.success()
            }
        val session = when (val refresh = refreshSessionIfNeeded(deps, scope, storedSession)) {
            is RefreshResult.Ready -> refresh.session
            RefreshResult.Retry -> return Result.retry()
            RefreshResult.Stopped -> return Result.success()
        }
        val masterPassword = deps.credentialStore().readBackgroundSyncMasterPassword(scope.storageId)
            ?: run {
                deps.syncState().update(SyncStatus.AwaitingUnlock)
                return Result.success()
            }
        if (isStopped || !deps.syncAuthority().isAllowed(scope)) return Result.success()

        return runCatching {
            val outbox = deps.syncRepository().processAssetOutbox(session.accessToken, masterPassword, scope.storageId)
            ensureActiveScope(deps, scope)
            val assetCount = deps.syncRepository().pullAndApplyAssets(
                token = session.accessToken,
                masterPassword = masterPassword,
                credentialNamespace = scope.storageId,
                assetRepository = deps.assetRepository(),
            )
            ensureActiveScope(deps, scope)
            val snippetCount = deps.syncRepository().syncSnippets(session.accessToken, masterPassword, scope)
            ensureActiveScope(deps, scope)
            deps.syncRepository().syncSshKeys(session.accessToken, masterPassword, scope)
            ensureActiveScope(deps, scope)
            deps.syncRepository().syncPortForwardProfiles(session.accessToken, masterPassword, scope)
            ensureActiveScope(deps, scope)
            deps.syncState().update(SyncStatus.Succeeded(assetCount, snippetCount, outbox))
            Result.success()
        }.getOrElse { error ->
            if (error is SyncScopeInvalidated || isStopped || !deps.syncAuthority().isAllowed(scope)) {
                Result.success()
            } else if (error is SyncFailure) {
                deps.syncState().update(SyncStatus.Failed(error.error))
                Result.success()
            } else if (error is OrbitServiceFailure) {
                deps.syncState().update(SyncStatus.Failed(error.error))
                Result.success()
            } else {
                deps.syncState().awaitNetwork()
                Result.retry()
            }
        }
    }

    private fun ensureActiveScope(deps: SyncWorkerDependencies, scope: AccountScope) {
        if (isStopped || !deps.syncAuthority().isAllowed(scope)) throw SyncScopeInvalidated
    }

    private suspend fun refreshSessionIfNeeded(
        deps: SyncWorkerDependencies,
        scope: AccountScope,
        session: AuthSession,
    ): RefreshResult {
        if (!session.accessToken.isExpiringSoon()) return RefreshResult.Ready(session)
        val refreshToken = session.refreshToken ?: run {
            deps.syncState().update(SyncStatus.Failed(syncError(OrbitErrorCode.AuthenticationExpired)))
            return RefreshResult.Stopped
        }
        val refreshed = runCatching { deps.orbitApi().refresh(refreshToken) }
            .getOrElse {
                deps.syncState().awaitNetwork()
                return RefreshResult.Retry
            }
        val updated = session.copy(
            accessToken = refreshed.accessTokenValue.takeIf(String::isNotBlank) ?: session.accessToken,
            refreshToken = refreshed.refresh_token ?: refreshToken,
        )
        if (!deps.syncAuthority().isAllowed(scope)) return RefreshResult.Stopped
        val current = deps.credentialStore().readAuthSession()
        if (current?.username != session.username) return RefreshResult.Stopped
        deps.credentialStore().saveAuthSession(updated)
        return RefreshResult.Ready(updated)
    }

    private object SyncScopeInvalidated : IllegalStateException()

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
