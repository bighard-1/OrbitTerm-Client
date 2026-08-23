package com.orbitterm.android.app

import androidx.lifecycle.ViewModel
import com.orbitterm.android.domain.error.OrbitError
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

/** UI observes durable work state; it never owns a network sync coroutine. */
@HiltViewModel
class SyncViewModel @Inject constructor(
    private val stateStore: SyncWorkStateStore,
) : ViewModel() {
    val status = stateStore.status
}

sealed interface SyncStatus {
    data object Idle : SyncStatus
    data object AwaitingNetwork : SyncStatus
    data object AwaitingUnlock : SyncStatus
    data object Syncing : SyncStatus
    data class Succeeded(
        val assetCount: Int,
        val snippetCount: Int,
        val outbox: com.orbitterm.android.sync.AssetOutboxResult,
    ) : SyncStatus
    data class Failed(val error: OrbitError) : SyncStatus {
        val message: String get() = error.userMessage()
    }
}
