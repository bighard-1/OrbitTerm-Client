package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.sync.AssetSyncConflict
import com.orbitterm.android.sync.SyncFailure
import com.orbitterm.android.sync.SyncRepository
import com.orbitterm.android.core.OperationScopeCoordinator
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** Process-scoped sync orchestration; activities never own its collection jobs. */
@Singleton
class ApplicationSyncCoordinator @Inject constructor(
    private val accountScopes: AccountScopeController,
    private val authority: SyncWorkAuthority,
    private val scheduler: SyncWorkScheduler,
    private val requests: AppSyncRequestBus,
    private val network: NetworkAvailabilityObserver,
    private val syncRepository: SyncRepository,
    private val state: SyncWorkStateStore,
    private val operations: OperationScopeCoordinator,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val conflictJobs = ConcurrentHashMap<Long, Job>()

    init {
        scope.launch {
            requests.requests.collectLatest { enqueueCurrentIfAllowed() }
        }
        scope.launch {
            network.isOnline.collectLatest { online ->
                if (online) enqueueCurrentIfAllowed() else scheduler.stateAwaitingNetwork()
            }
        }
    }

    fun onUnlocked(accountScope: AccountScope) {
        // A fresh unlock also forms an account boundary for transient V2 root
        // material; the repository will derive it lazily only if a V2 record
        // is actually encountered.
        syncRepository.clearTransientConfigCrypto()
        authority.allow(accountScope)
        scope.launch {
            syncRepository.resumeCredentialBlockedOutbox(accountScope.storageId)
            enqueueCurrentIfAllowed()
        }
    }

    fun onLockedOrLoggedOut(accountScope: AccountScope) {
        conflictJobs.values.forEach(Job::cancel)
        conflictJobs.clear()
        syncRepository.clearTransientConfigCrypto()
        accountScopes.invalidateOperations()
        scheduler.cancel(accountScope)
    }

    fun requestNow() {
        val current = accountScopes.scope.value ?: return
        scope.launch {
            syncRepository.resumeUserActionOutbox(current.storageId)
            enqueueCurrentIfAllowed()
        }
    }

    fun retryBlockedOutbox() {
        val current = accountScopes.scope.value ?: return
        scope.launch {
            syncRepository.retryBlockedOutbox(current.storageId)
            enqueueCurrentIfAllowed()
        }
    }

    fun discardBlockedOutbox() {
        val current = accountScopes.scope.value ?: return
        scope.launch {
            syncRepository.discardBlockedOutbox(current.storageId)
            enqueueCurrentIfAllowed()
        }
    }

    /**
     * A conflict choice needs the currently unlocked master password, but this
     * coordinator never persists it.  The completion is bound to both account
     * generation and conflict identity so an old account cannot update UI or
     * enqueue work after a lock, logout, or account switch.
     */
    fun resolveConflict(
        conflict: AssetSyncConflict,
        keepLocal: Boolean,
        accessToken: String,
        masterPassword: String,
    ) {
        val operation = operations.begin("sync_conflict", conflict.assetId) ?: return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            runCatching {
                syncRepository.resolveAssetConflict(
                    assetId = conflict.assetId,
                    keepLocal = keepLocal,
                    token = accessToken,
                    masterPassword = masterPassword,
                    accountScope = operation.accountScope.storageId,
                )
            }.onSuccess {
                if (operations.isCurrent(operation)) enqueueCurrentIfAllowed()
            }.onFailure { error ->
                if (operations.isCurrent(operation)) state.update(SyncStatus.Failed(error.toSyncError()))
            }
            conflictJobs.remove(operation.sequence)
        }
        conflictJobs[operation.sequence] = job
        job.start()
    }

    private fun enqueueCurrentIfAllowed() {
        val current = accountScopes.scope.value ?: return
        if (authority.currentLease(current) == null) return
        if (network.isOnline.value) scheduler.enqueue(current) else scheduler.stateAwaitingNetwork()
    }
}

private fun Throwable.toSyncError(): com.orbitterm.android.domain.error.OrbitError = when (this) {
    is SyncFailure -> error
    is com.orbitterm.android.sync.OrbitServiceFailure -> error
    else -> com.orbitterm.android.domain.error.syncError(com.orbitterm.android.domain.error.OrbitErrorCode.NetworkUnavailable)
}
