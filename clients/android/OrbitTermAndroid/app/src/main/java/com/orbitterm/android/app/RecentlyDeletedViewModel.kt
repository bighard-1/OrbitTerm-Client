package com.orbitterm.android.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.core.OperationScopeCoordinator
import com.orbitterm.android.domain.auth.AuthSession
import com.orbitterm.android.domain.sync.SyncRequester
import com.orbitterm.android.sync.RecentlyDeletedAssetSummary
import com.orbitterm.android.sync.SyncRepository
import com.orbitterm.android.sync.isRetryableRecentlyDeletedFailure
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import java.util.UUID

data class RecentlyDeletedUiState(
    val isLoading: Boolean = false,
    val items: List<RecentlyDeletedAssetSummary> = emptyList(),
    val error: String? = null,
    val message: String? = null,
    val mutatingAssetId: String? = null,
)

@HiltViewModel
class RecentlyDeletedViewModel @Inject constructor(
    private val repository: SyncRepository,
    private val accountScopes: AccountScopeController,
    private val operations: OperationScopeCoordinator,
    private val syncRequester: SyncRequester,
) : ViewModel() {
    private val mutableState = MutableStateFlow(RecentlyDeletedUiState())
    val uiState = mutableState.asStateFlow()

    fun load(session: AuthSession, masterPassword: String) {
        val scope = accountScopes.scope.value ?: return
        val operation = operations.begin("recently_deleted_load", scope.storageId) ?: return
        mutableState.value = mutableState.value.copy(isLoading = true, error = null, message = null)
        viewModelScope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) { repository.loadRecentlyDeleted(session.accessToken, masterPassword, scope) }
            }
            if (!operations.isCurrent(operation)) return@launch
            mutableState.value = result.fold(
                onSuccess = { mutableState.value.copy(isLoading = false, items = it, error = null) },
                onFailure = { mutableState.value.copy(isLoading = false, error = "无法加载最近删除，请检查网络或登录状态。") },
            )
        }
    }

    fun restore(assetId: String, session: AuthSession, masterPassword: String) = mutate(
        assetId = assetId,
        successMessage = "资产已恢复。",
        purge = false,
    ) { scope, operationId ->
        repository.restoreRecentlyDeleted(assetId, session.accessToken, masterPassword, scope, operationId)
    }

    fun purge(assetId: String, session: AuthSession, masterPassword: String) = mutate(
        assetId = assetId,
        successMessage = "资产已永久删除。",
        purge = true,
    ) { scope, operationId -> repository.purgeRecentlyDeleted(assetId, session.accessToken, scope, operationId) }

    fun dismissFeedback() {
        mutableState.value = mutableState.value.copy(error = null, message = null)
    }

    fun clear() {
        accountScopes.scope.value?.let { operations.invalidate("recently_deleted_load", it.storageId) }
        mutableState.value = RecentlyDeletedUiState()
    }

    private fun mutate(
        assetId: String,
        successMessage: String,
        purge: Boolean,
        action: suspend (com.orbitterm.android.domain.auth.AccountScope, String) -> Unit,
    ) {
        val scope = accountScopes.scope.value ?: return
        if (mutableState.value.mutatingAssetId != null) return
        val operation = operations.begin("recently_deleted_mutation", assetId) ?: return
        val operationId = UUID.randomUUID().toString()
        mutableState.value = mutableState.value.copy(mutatingAssetId = assetId, error = null, message = null)
        viewModelScope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { action(scope, operationId) } }
            if (!operations.isCurrent(operation)) return@launch
            val error = result.exceptionOrNull()
            val queued = error?.isRetryableRecentlyDeletedFailure() == true && runCatching {
                withContext(Dispatchers.IO) {
                    repository.queueRecentlyDeletedMutation(assetId, scope, purge, operationId)
                }
            }.isSuccess
            if (queued) syncRequester.requestSync()
            mutableState.value = when {
                result.isSuccess -> mutableState.value.copy(
                    items = mutableState.value.items.filterNot { it.assetId == assetId },
                    mutatingAssetId = null,
                    message = successMessage,
                )
                queued -> mutableState.value.copy(
                    items = mutableState.value.items.filterNot { it.assetId == assetId },
                    mutatingAssetId = null,
                    message = if (purge) "永久删除已加入后台队列，联网后自动完成。" else "恢复已加入后台队列，联网后自动完成。",
                )
                else -> mutableState.value.copy(
                    mutatingAssetId = null,
                    error = "操作未完成，请检查网络、登录状态和主密码。",
                )
            }
        }
    }
}
