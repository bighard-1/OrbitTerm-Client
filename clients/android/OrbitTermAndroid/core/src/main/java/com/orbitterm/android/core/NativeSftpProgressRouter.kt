package com.orbitterm.android.core

import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

data class SftpTransferProgress(
    val requestId: String,
    val transferredBytes: Long,
    val totalBytes: Long?,
)

/** Receives non-sensitive byte counters emitted by the checked native SFTP path. */
object NativeSftpProgressRouter {
    private val mutableProgress = MutableSharedFlow<SftpTransferProgress>(
        extraBufferCapacity = RuntimeResourceBudget.SFTP_PROGRESS_BUFFER_EVENTS,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val progress = mutableProgress.asSharedFlow()

    fun onSftpTransferProgress(requestId: String, transferredBytes: Long, totalBytes: Long) {
        if (requestId.isBlank() || transferredBytes < 0) return
        mutableProgress.tryEmit(
            SftpTransferProgress(requestId, transferredBytes, totalBytes.takeIf { it >= 0 }),
        )
    }
}
