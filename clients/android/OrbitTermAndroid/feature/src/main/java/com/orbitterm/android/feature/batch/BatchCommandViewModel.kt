package com.orbitterm.android.feature.batch

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.core.CheckedExecNativeClient
import com.orbitterm.android.core.CheckedExecResult
import com.orbitterm.android.feature.terminal.TerminalSessionController
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

data class BatchCommandReceipt(val assetId: String, val name: String, val exitStatus: Int?, val stdout: String, val stderr: String, val errorCode: String?, val elapsedMillis: Long) {
    val succeeded get() = errorCode == null && exitStatus == 0
}
data class BatchCommandUiState(val running: Boolean = false, val receipts: List<BatchCommandReceipt> = emptyList(), val error: String? = null, val command: String = "") {
    val successCount get() = receipts.count { it.succeeded }
    val failureCount get() = receipts.size - successCount
}

/** Serial, bounded command execution over existing verified sessions only. */
@HiltViewModel
class BatchCommandViewModel @Inject constructor(
    private val sessions: TerminalSessionController,
    private val exec: CheckedExecNativeClient,
) : ViewModel() {
    private val mutableUiState = MutableStateFlow(BatchCommandUiState())
    val uiState = mutableUiState.asStateFlow()

    fun dismissReceipt() { if (!mutableUiState.value.running) mutableUiState.value = BatchCommandUiState() }

    fun retryFailures() {
        val state = mutableUiState.value
        execute(state.command, state.receipts.filterNot { it.succeeded }.mapTo(linkedSetOf()) { it.assetId })
    }

    fun execute(command: String, assetIds: Set<String>) {
        val normalizedCommand = command.trim()
        if (normalizedCommand.isEmpty() || assetIds.isEmpty() || mutableUiState.value.running) return
        // A batch command is deliberately never allowed to partially run because a
        // selected asset is disconnected.  Silently skipping it makes the receipt
        // misleading and differs from the iOS workflow, which requires every target
        // to have an already verified SSH session.
        val sessionsByAsset = sessions.activeSessions.value.associateBy { it.assetId }
        val missingSessionCount = assetIds.count { it !in sessionsByAsset }
        if (missingSessionCount > 0) {
            mutableUiState.value = BatchCommandUiState(
                error = "所选资产中有 $missingSessionCount 台未建立已验证 SSH 会话。请先完成连接后再执行批量命令。",
            )
            return
        }
        val targets = assetIds.mapNotNull(sessionsByAsset::get)
        mutableUiState.value = BatchCommandUiState(running = true, command = normalizedCommand)
        viewModelScope.launch {
            val receipts = withContext(Dispatchers.IO) { targets.map { target ->
                val startedAt = android.os.SystemClock.elapsedRealtime()
                when (val result = exec.execute(target.baseSessionId, normalizedCommand)) {
                    is CheckedExecResult.Completed -> BatchCommandReceipt(target.assetId, target.displayName, result.exitStatus, result.stdout, result.stderr, null, android.os.SystemClock.elapsedRealtime() - startedAt)
                    is CheckedExecResult.Failure -> BatchCommandReceipt(target.assetId, target.displayName, null, "", "", result.code, android.os.SystemClock.elapsedRealtime() - startedAt)
                }
            } }
            mutableUiState.value = BatchCommandUiState(receipts = receipts, command = normalizedCommand)
        }
    }
}
