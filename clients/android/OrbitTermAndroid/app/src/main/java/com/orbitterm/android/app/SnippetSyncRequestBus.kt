package com.orbitterm.android.app

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import javax.inject.Inject
import javax.inject.Singleton
import com.orbitterm.android.domain.sync.SyncRequester

/** One-way request only; secrets remain owned by the unlocked activity ViewModel. */
@Singleton
class AppSyncRequestBus @Inject constructor() : SyncRequester {
    private val mutableRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val requests = mutableRequests.asSharedFlow()

    override fun requestSync() {
        mutableRequests.tryEmit(Unit)
    }
}
