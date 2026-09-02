package com.orbitterm.android.feature.sftp

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.NoteAdd
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.UploadFile
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.net.Uri
import android.content.Context
import android.content.ClipData
import android.content.Intent
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.util.ArrayDeque
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.core.CheckedSftpListResult
import com.orbitterm.android.core.CheckedSftpMutationResult
import com.orbitterm.android.core.CheckedSftpTextResult
import com.orbitterm.android.core.CheckedSftpTransferResult
import com.orbitterm.android.core.CheckedSftpNativeClient
import com.orbitterm.android.core.CheckedSftpOpenResult
import com.orbitterm.android.core.NativeSftpProgressRouter
import com.orbitterm.android.core.SftpDirectoryEntry
import com.orbitterm.android.feature.terminal.ActiveTerminalSession
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.feature.terminal.selectActiveTerminalSession
import com.orbitterm.android.feature.presentation.OperationalContentPhase
import com.orbitterm.android.feature.presentation.OperationalContentPresentationMapper
import com.orbitterm.android.feature.presentation.OperationalModuleKind
import com.orbitterm.android.feature.presentation.OperationalFailureFeedback
import com.orbitterm.android.feature.presentation.OperationalRefreshAction
import com.orbitterm.android.feature.presentation.OperationalTransientSuccessFeedback
import com.orbitterm.android.core.DocumentInteractionCoordinator
import com.orbitterm.android.core.OperationScopeCoordinator
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.orbitterm.android.domain.performance.TransferProgressUpdateGate
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.orbitNativeError
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import com.orbitterm.android.ui.design.OrbitEmptyState
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.design.OrbitFormDialog
import com.orbitterm.android.ui.design.OrbitStatusLine
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

data class SftpUiState(
    val session: ActiveTerminalSession? = null,
    val sftpSessionId: Long? = null,
    val path: String = "/",
    val entries: List<SftpDirectoryEntry> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
    val transferMessage: String? = null,
    val transferMessageIsError: Boolean = false,
    val transfer: SftpTransferUiState? = null,
    val activeTransferRequestId: String? = null,
    val canCancelTransfer: Boolean = false,
    val cancellationRequested: Boolean = false,
    val queuedTransfers: List<SftpQueuedTransferUiState> = emptyList(),
    val queuePaused: Boolean = false,
    val retryTransferLabel: String? = null,
    val textDocument: SftpTextDocument? = null,
    val textDocumentError: String? = null,
    val shareArchive: SftpShareArchive? = null,
)

data class SftpTextDocument(
    val entry: SftpDirectoryEntry,
    val path: String,
    val content: String,
    val textFormat: SftpTextFormat,
    val isEditing: Boolean = false,
)
data class SftpTransferUiState(
    val label: String,
    val detail: String,
    val transferredBytes: Long = 0,
    val totalBytes: Long? = null,
)
data class SftpQueuedTransferUiState(val id: String, val label: String)
data class SftpShareArchive(val id: String, val uri: Uri, val displayName: String)

private data class PendingSftpTransfer(
    val id: String,
    val label: String,
    val detail: String,
    val operation: (requestId: String, markNativeTransferStarted: () -> Boolean) -> CheckedSftpTransferResult,
    val onCompleted: (() -> Unit)? = null,
    val onDiscarded: (() -> Unit)? = null,
)

/** File browser state is tied to the process-lifetime checked SSH session, never to credentials. */
@HiltViewModel
class SftpViewModel @Inject constructor(
    private val terminalSessionController: TerminalSessionController,
    private val sftpClient: CheckedSftpNativeClient,
    private val assetRepository: AssetRepository,
    private val externalActivityLockCoordinator: DocumentInteractionCoordinator,
    private val operations: OperationScopeCoordinator,
    @param:ApplicationContext private val context: Context,
) : ViewModel() {
    private val mutableUiState = MutableStateFlow(SftpUiState())
    val uiState = mutableUiState.asStateFlow()
    private var retryLastTransfer: (() -> Unit)? = null
    private val pendingTransfers = ArrayDeque<PendingSftpTransfer>()
    private var activeTransfer: PendingSftpTransfer? = null
    private val progressUpdateGate = TransferProgressUpdateGate()
    private val archiveStatusUpdateGate = TransferProgressUpdateGate()

    fun prepareDocumentInteraction() = externalActivityLockCoordinator.beginDocumentInteraction()

    /** Retries only the last failed foreground transfer on its original checked session. */
    fun retryLastTransfer() {
        val retry = retryLastTransfer ?: return
        retryLastTransfer = null
        mutableUiState.value = mutableUiState.value.copy(retryTransferLabel = null, error = null)
        retry()
    }

    fun cancelActiveTransfer() {
        val state = mutableUiState.value
        val requestId = state.activeTransferRequestId ?: return
        if (!state.canCancelTransfer || state.cancellationRequested) return
        mutableUiState.value = state.copy(
            cancellationRequested = true,
            transfer = state.transfer?.copy(detail = "正在请求取消，当前分块完成后将停止…"),
        )
        viewModelScope.launch {
            val accepted = withContext(Dispatchers.IO) { sftpClient.cancelTransfer(requestId) }
            val current = mutableUiState.value
            if (!accepted && current.activeTransferRequestId == requestId) {
                // Native progress may have arrived while the cancellation request was in
                // flight. Update only the cancellation affordance, never restore the
                // stale `state.transfer` captured when the user pressed the button.
                mutableUiState.value = current.copy(
                    cancellationRequested = false,
                    transfer = current.transfer?.copy(detail = "传输已接近完成，无法取消。"),
                )
            }
        }
    }

    fun cancelQueuedTransfer(id: String) {
        val iterator = pendingTransfers.iterator()
        while (iterator.hasNext()) {
            if (iterator.next().id == id) {
                iterator.remove()
                publishQueueState("已从队列移除")
                return
            }
        }
    }

    fun resumeTransferQueue() {
        if (!mutableUiState.value.queuePaused || activeTransfer != null) return
        mutableUiState.value = mutableUiState.value.copy(queuePaused = false, error = null)
        startNextTransfer()
    }

    fun dismissTransferMessage(message: String) {
        if (mutableUiState.value.transferMessage == message) {
            mutableUiState.value = mutableUiState.value.copy(
                transferMessage = null,
                transferMessageIsError = false,
            )
        }
    }

    private fun clearTransfersForSessionChange() {
        pendingTransfers.clear()
        val requestId = mutableUiState.value.activeTransferRequestId
        activeTransfer = null
        if (requestId != null) {
            progressUpdateGate.clear(requestId)
            archiveStatusUpdateGate.clear(requestId)
            sftpClient.cancelTransfer(requestId)
        }
    }

    init {
        viewModelScope.launch {
            NativeSftpProgressRouter.progress.collect { progress ->
                val state = mutableUiState.value
                if (progress.requestId == state.activeTransferRequestId && progressUpdateGate.shouldPublish(
                        requestId = progress.requestId,
                        transferredBytes = progress.transferredBytes,
                        totalBytes = progress.totalBytes,
                        nowMillis = android.os.SystemClock.elapsedRealtime(),
                    )
                ) {
                    mutableUiState.value = state.copy(
                        transfer = state.transfer?.copy(
                            transferredBytes = progress.transferredBytes,
                            totalBytes = progress.totalBytes,
                        ),
                    )
                }
            }
        }
        viewModelScope.launch {
            combine(
                terminalSessionController.activeSessions,
                terminalSessionController.selectedSessionId,
            ) { sessions, selectedId ->
                selectActiveTerminalSession(sessions, selectedId)
            }
                .distinctUntilChangedBy { session -> session?.baseSessionId }
                .collect { session -> bind(session) }
        }
    }

    fun refresh() {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        listDirectory(sftpSessionId, state.path)
    }

    fun refreshFromUser() {
        mutableUiState.value = mutableUiState.value.copy(
            transferMessage = null,
            transferMessageIsError = false,
        )
        refresh()
    }

    fun openDirectory(entry: SftpDirectoryEntry) {
        if (!entry.isDirectory) return
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        listDirectory(sftpSessionId, childPath(state.path, entry.name))
    }

    fun openFile(entry: SftpDirectoryEntry) {
        if (entry.isDirectory) {
            openDirectory(entry)
            return
        }
        val state = mutableUiState.value
        when (val decision = SftpInAppDocumentPolicy.evaluate(entry)) {
            SftpInAppDocumentDecision.Allowed -> Unit
            SftpInAppDocumentDecision.Directory -> return
            is SftpInAppDocumentDecision.TooLarge -> {
                mutableUiState.value = state.copy(
                    error = "无法在应用内打开：文件大小为 ${formatBytes(decision.size.coerceAtLeast(0L))}，文本预览与编辑上限为 2 MB。可使用下载功能处理该文件。",
                )
                return
            }
        }
        val sftpSessionId = state.sftpSessionId ?: return
        val path = childPath(state.path, entry.name)
        val sessionId = state.session?.id ?: return
        val operation = operations.begin("sftp_read", "$sessionId:$path") ?: return
        mutableUiState.value = state.copy(isLoading = true, error = null)
        viewModelScope.launch {
            when (val result = withContext(Dispatchers.IO) { sftpClient.readText(sftpSessionId, path) }) {
                is CheckedSftpTextResult.Read -> if (isCurrentForSession(operation, sessionId)) mutableUiState.value = mutableUiState.value.copy(
                    isLoading = false,
                    textDocument = SftpTextFormat.detectAndNormalize(result.content).let { (content, format) ->
                        SftpTextDocument(entry, path, content, format)
                    },
                    textDocumentError = null,
                )
                is CheckedSftpTextResult.Failure -> if (isCurrentForSession(operation, sessionId)) mutableUiState.value = mutableUiState.value.copy(
                    isLoading = false,
                    error = sftpErrorMessage("读取文件失败", result.code),
                )
            }
        }
    }

    fun dismissTextDocument() {
        mutableUiState.value = mutableUiState.value.copy(textDocument = null, textDocumentError = null)
    }

    fun beginEditingTextDocument() {
        val document = mutableUiState.value.textDocument ?: return
        mutableUiState.value = mutableUiState.value.copy(
            textDocument = document.copy(isEditing = true),
            textDocumentError = null,
        )
    }

    fun saveTextDocument(content: String) {
        val state = mutableUiState.value
        val document = state.textDocument ?: return
        val sftpSessionId = state.sftpSessionId ?: return
        if (state.isLoading) return
        val sessionId = state.session?.id ?: return
        val operation = operations.begin("sftp_write", "$sessionId:${document.path}") ?: return
        // The checked SFTP write compares the entry snapshot before publishing the
        // replacement. Keep this editor and its Compose-owned draft open until that
        // comparison and the atomic write both succeed; otherwise a conflict must
        // never discard the user's local text.
        mutableUiState.value = state.copy(isLoading = true, error = null, textDocumentError = null)
        viewModelScope.launch {
            when (val result = withContext(Dispatchers.IO) {
                sftpClient.writeText(
                    sftpSessionId,
                    document.path,
                    document.textFormat.serialize(content),
                    document.entry,
                )
            }) {
                CheckedSftpMutationResult.Completed -> if (isCurrentForSession(operation, sessionId)) {
                    mutableUiState.value = mutableUiState.value.copy(textDocument = null, textDocumentError = null)
                    listDirectory(sftpSessionId, state.path)
                }
                is CheckedSftpMutationResult.Failure -> if (isCurrentForSession(operation, sessionId)) {
                    mutableUiState.value = mutableUiState.value.copy(
                        isLoading = false,
                        textDocumentError = result.code.textDocumentMessage(),
                    )
                }
            }
        }
    }

    fun navigateToParent() {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        if (state.path == "/") return
        listDirectory(sftpSessionId, parentPath(state.path))
    }

    /** Opens only an absolute, normalized remote path on the already checked SFTP channel. */
    fun navigateToPath(requestedPath: String) {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        val path = requestedPath.trim().normalizeRemoteNavigationPath()
        if (path == null) {
            mutableUiState.value = state.copy(error = "路径必须是绝对路径，且不能包含 .. 或反斜杠。")
            return
        }
        listDirectory(sftpSessionId, path)
    }

    fun createDirectory(name: String) = create(name, isDirectory = true)

    fun createFile(name: String) = create(name, isDirectory = false)

    fun rename(entry: SftpDirectoryEntry, newName: String) {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        val target = childPath(state.path, newName.trim())
        if (!target.isSafeRemoteMutationPath()) return
        mutate {
            sftpClient.rename(sftpSessionId, childPath(state.path, entry.name), target, entry)
        }
    }

    fun remove(entry: SftpDirectoryEntry) {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        if (entry.isDirectory) {
            removeDirectoryTree(sftpSessionId, state.path, entry)
            return
        }
        mutate {
            sftpClient.remove(sftpSessionId, childPath(state.path, entry.name), entry)
        }
    }

    fun removeAll(entries: List<SftpDirectoryEntry>) {
        if (entries.isEmpty()) return
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        val sessionId = state.session?.id ?: return
        val operation = operations.begin("sftp_bulk_remove", "$sessionId:${state.path}") ?: return
        mutableUiState.value = state.copy(
            isLoading = true,
            error = null,
            transferMessage = null,
            transferMessageIsError = false,
            transfer = SftpTransferUiState("批量删除", "正在删除 ${entries.size} 个项目…"),
        )
        viewModelScope.launch {
            val summary = withContext(Dispatchers.IO) {
                var succeeded = 0
                var failed = 0
                entries.forEach { entry ->
                    val result = if (entry.isDirectory) {
                        deleteDirectoryTree(sftpSessionId, state.path, entry, 0, RecursiveDeleteBudget())
                    } else {
                        sftpClient.remove(sftpSessionId, childPath(state.path, entry.name), entry)
                    }
                    if (result == CheckedSftpMutationResult.Completed) succeeded += 1 else failed += 1
                }
                BatchRemoveSummary(succeeded, failed)
            }
            if (isCurrentForSession(operation, sessionId)) {
                listDirectory(sftpSessionId, state.path)
                mutableUiState.value = mutableUiState.value.copy(
                    transfer = null,
                    transferMessage = if (summary.failed == 0) {
                        "批量删除完成：${summary.succeeded} 项"
                    } else {
                        "批量删除未全部完成：成功 ${summary.succeeded} 项，失败 ${summary.failed} 项。"
                    },
                    transferMessageIsError = summary.failed > 0,
                    error = null,
                )
            }
        }
    }

    fun chmod(entry: SftpDirectoryEntry, mode: Int) {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        mutate { sftpClient.chmod(sftpSessionId, childPath(state.path, entry.name), mode, entry) }
    }

    fun upload(source: Uri) {
        val state = mutableUiState.value
        val sessionId = state.sftpSessionId ?: return
        mutateTransfer("上传", "正在准备本地文件…") { requestId, markNativeTransferStarted ->
            val name = context.contentResolver.query(source, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                cursor.takeIf { it.moveToFirst() }?.getString(0)
            }?.takeIf { it.isNotBlank() } ?: "upload.bin"
            val staging = File(context.cacheDir, "sftp-upload-${UUID.randomUUID()}")
            try {
                context.contentResolver.openInputStream(source)?.use { input -> staging.outputStream().use(input::copyTo) }
                    ?: return@mutateTransfer CheckedSftpTransferResult.Failure("local_file_unreadable")
                if (!markNativeTransferStarted()) {
                    return@mutateTransfer CheckedSftpTransferResult.Failure("sftp_transfer_session_changed")
                }
                sftpClient.upload(sessionId, staging.absolutePath, childPath(state.path, name), requestId)
            } finally { staging.delete() }
        }
    }

    fun download(entry: SftpDirectoryEntry, destination: Uri) {
        if (entry.isDirectory) return
        val state = mutableUiState.value
        val sessionId = state.sftpSessionId ?: return
        mutateTransfer("下载", "正在写入所选位置…") { requestId, markNativeTransferStarted ->
            val staging = File(context.cacheDir, "sftp-download-${UUID.randomUUID()}")
            try {
                if (!markNativeTransferStarted()) {
                    return@mutateTransfer CheckedSftpTransferResult.Failure("sftp_transfer_session_changed")
                }
                when (val result = sftpClient.download(sessionId, childPath(state.path, entry.name), staging.absolutePath, requestId)) {
                    is CheckedSftpTransferResult.Completed -> {
                        val output = context.contentResolver.openOutputStream(destination)
                            ?: return@mutateTransfer CheckedSftpTransferResult.Failure("destination_unwritable")
                        output.use { destinationStream ->
                            staging.inputStream().use { sourceStream -> sourceStream.copyTo(destinationStream) }
                        }
                        result
                    }
                    is CheckedSftpTransferResult.Failure -> result
                }
            } finally { staging.delete() }
        }
    }

    /**
     * Downloads one or more remote entries as a single ZIP. Directories are walked through SFTP,
     * so the server never has to provide shell access or an archive utility.
     */
    fun downloadAsZip(entries: List<SftpDirectoryEntry>, destination: Uri) {
        if (entries.isEmpty()) return
        val state = mutableUiState.value
        val sessionId = state.sftpSessionId ?: return
        mutateTransfer("打包下载", "正在准备 ${entries.size} 个项目…") { requestId, markNativeTransferStarted ->
            archiveRemoteEntries(
                sessionId = sessionId,
                parentPath = state.path,
                entries = entries,
                destination = destination,
                requestId = requestId,
                markNativeTransferStarted = markNativeTransferStarted,
            )
        }
    }

    /** Creates a checked archive in app-private cache, then exposes only a short-lived URI. */
    fun shareAsZip(entries: List<SftpDirectoryEntry>) {
        if (entries.isEmpty()) return
        val state = mutableUiState.value
        val sessionId = state.sftpSessionId ?: return
        var preparedArchive: File? = null
        val displayName = SftpShareArchivePolicy.displayName(entries)
        mutateTransfer(
            label = "打包分享",
            detail = "正在准备 ${entries.size} 个项目…",
            onCompleted = { preparedArchive?.let { publishShareArchive(it, displayName) } },
            onDiscarded = { preparedArchive?.delete() },
        ) { requestId, markNativeTransferStarted ->
            archiveRemoteEntries(
                sessionId = sessionId,
                parentPath = state.path,
                entries = entries,
                destination = null,
                requestId = requestId,
                markNativeTransferStarted = markNativeTransferStarted,
                onArchivePrepared = { preparedArchive = it },
            )
        }
    }

    fun consumeShareArchive(id: String) {
        if (mutableUiState.value.shareArchive?.id == id) {
            mutableUiState.value = mutableUiState.value.copy(shareArchive = null)
        }
    }

    fun reportShareLaunchFailure(id: String) {
        val archive = mutableUiState.value.shareArchive ?: return
        if (archive.id != id) return
        File(context.cacheDir, "${SftpShareArchivePolicy.cacheDirectory}/${archive.id}").deleteRecursively()
        mutableUiState.value = mutableUiState.value.copy(
            shareArchive = null,
            error = "无法打开系统分享面板。",
        )
    }

    private fun mutateTransfer(
        label: String,
        detail: String,
        onCompleted: (() -> Unit)? = null,
        onDiscarded: (() -> Unit)? = null,
        operation: (requestId: String, markNativeTransferStarted: () -> Boolean) -> CheckedSftpTransferResult,
    ) {
        val state = mutableUiState.value
        if (state.sftpSessionId == null) return
        if (pendingTransfers.size >= RuntimeResourceBudget.SFTP_MAX_QUEUED_TRANSFERS) {
            mutableUiState.value = state.copy(error = "传输队列已满，请完成或移除等待项目后再试。")
            return
        }
        val pending = PendingSftpTransfer(
            id = UUID.randomUUID().toString(),
            label = label,
            detail = detail,
            operation = operation,
            onCompleted = onCompleted,
            onDiscarded = onDiscarded,
        )
        retryLastTransfer = null
        if (activeTransfer == null && !state.queuePaused) {
            pendingTransfers.addLast(pending)
            startNextTransfer()
        } else {
            pendingTransfers.addLast(pending)
            publishQueueState("${label}已加入传输队列")
        }
    }

    private fun startNextTransfer() {
        if (activeTransfer != null || mutableUiState.value.queuePaused) return
        val pending = if (pendingTransfers.isEmpty()) null else pendingTransfers.removeFirst()
        if (pending == null) {
            publishQueueState()
            return
        }
        val sessionId = mutableUiState.value.session?.id ?: run {
            publishQueueState("当前会话不可用，传输已取消")
            return
        }
        val operation = operations.begin("sftp_transfer", sessionId) ?: run {
            publishQueueState("当前账户不可用，传输已取消")
            return
        }
        activeTransfer = pending
        val requestId = UUID.randomUUID().toString()
        mutableUiState.value = mutableUiState.value.copy(
            isLoading = true,
            error = null,
            transferMessage = null,
            transferMessageIsError = false,
            transfer = SftpTransferUiState(pending.label, pending.detail),
            activeTransferRequestId = requestId,
            canCancelTransfer = false,
            cancellationRequested = false,
            retryTransferLabel = null,
            queuedTransfers = pendingTransfers.map { SftpQueuedTransferUiState(it.id, it.label) },
        )
        viewModelScope.launch {
            val markNativeTransferStarted = {
                val current = mutableUiState.value
                if (isCurrentForSession(operation, sessionId) && activeTransfer?.id == pending.id && current.activeTransferRequestId == requestId) {
                    mutableUiState.value = current.copy(
                        canCancelTransfer = true,
                        transfer = SftpTransferUiState(pending.label, "正在通过安全 SFTP 通道传输…"),
                    )
                    true
                } else {
                    false
                }
            }
            val result = withContext(Dispatchers.IO) { pending.operation(requestId, markNativeTransferStarted) }
            if (!isCurrentForSession(operation, sessionId) || activeTransfer?.id != pending.id) {
                pending.onDiscarded?.invoke()
                return@launch
            }
            activeTransfer = null
            progressUpdateGate.clear(requestId)
            archiveStatusUpdateGate.clear(requestId)
            when (result) {
                is CheckedSftpTransferResult.Completed -> {
                    mutableUiState.value = mutableUiState.value.copy(
                        isLoading = false,
                        transfer = null,
                        activeTransferRequestId = null,
                        canCancelTransfer = false,
                        cancellationRequested = false,
                        transferMessage = "${pending.label}完成：${formatBytes(result.byteLength)}",
                        transferMessageIsError = false,
                    )
                    pending.onCompleted?.invoke()
                    if (pendingTransfers.isEmpty()) refresh() else startNextTransfer()
                }
                is CheckedSftpTransferResult.Failure -> {
                    if (orbitNativeError(result.code).code == OrbitErrorCode.OperationCancelled) {
                        mutableUiState.value = mutableUiState.value.copy(
                            isLoading = false,
                            transfer = null,
                            activeTransferRequestId = null,
                            canCancelTransfer = false,
                            cancellationRequested = false,
                            transferMessage = "${pending.label}已取消",
                            transferMessageIsError = false,
                        )
                        if (pendingTransfers.isEmpty()) refresh() else startNextTransfer()
                        return@launch
                    }
                    retryLastTransfer = {
                        mutateTransfer(
                            label = pending.label,
                            detail = pending.detail,
                            onCompleted = pending.onCompleted,
                            onDiscarded = pending.onDiscarded,
                            operation = pending.operation,
                        )
                    }
                    mutableUiState.value = mutableUiState.value.copy(
                        isLoading = false,
                        transfer = null,
                        activeTransferRequestId = null,
                        canCancelTransfer = false,
                        cancellationRequested = false,
                        retryTransferLabel = pending.label,
                        queuePaused = pendingTransfers.isNotEmpty(),
                        error = sftpErrorMessage("文件传输失败", result.code),
                        queuedTransfers = pendingTransfers.map { SftpQueuedTransferUiState(it.id, it.label) },
                    )
                }
            }
        }
    }

    private fun publishQueueState(message: String? = null) {
        mutableUiState.value = mutableUiState.value.copy(
            queuedTransfers = pendingTransfers.map { SftpQueuedTransferUiState(it.id, it.label) },
            transferMessage = message ?: mutableUiState.value.transferMessage,
            transferMessageIsError = if (message != null) false else mutableUiState.value.transferMessageIsError,
        )
    }

    private fun archiveRemoteEntries(
        sessionId: Long,
        parentPath: String,
        entries: List<SftpDirectoryEntry>,
        destination: Uri?,
        requestId: String,
        markNativeTransferStarted: () -> Boolean,
        onArchivePrepared: ((File) -> Unit)? = null,
    ): CheckedSftpTransferResult {
        val archive = File(context.cacheDir, "sftp-download-${UUID.randomUUID()}.zip")
        val workspace = File(context.cacheDir, "sftp-archive-${UUID.randomUUID()}")
        var byteLength = 0L
        var downloadedFiles = 0
        var retainArchive = false
        return try {
            if (!workspace.mkdirs()) return CheckedSftpTransferResult.Failure("archive_workspace_unavailable")
            ZipOutputStream(archive.outputStream().buffered()).use { zip ->
                entries.forEach { entry ->
                    val remotePath = childPath(parentPath, entry.name)
                    byteLength += archiveEntry(
                        sessionId = sessionId,
                        remotePath = remotePath,
                        archivePath = entry.name,
                        entry = entry,
                        workspace = workspace,
                        zip = zip,
                        requestId = requestId,
                        markNativeTransferStarted = markNativeTransferStarted,
                        onFileDownloaded = {
                            downloadedFiles += 1
                            if (archiveStatusUpdateGate.shouldPublish(
                                    requestId = requestId,
                                    transferredBytes = downloadedFiles.toLong(),
                                    totalBytes = null,
                                    nowMillis = android.os.SystemClock.elapsedRealtime(),
                                )
                            ) {
                                val current = mutableUiState.value
                                mutableUiState.value = current.copy(
                                    transfer = current.transfer?.copy(
                                        detail = "已整理 $downloadedFiles 个文件：$it",
                                    ),
                                )
                            }
                        },
                    )
                }
            }
            if (destination != null) {
                val output = context.contentResolver.openOutputStream(destination)
                    ?: return CheckedSftpTransferResult.Failure("destination_unwritable")
                output.use { destinationStream -> archive.inputStream().use { it.copyTo(destinationStream) } }
            } else {
                onArchivePrepared?.invoke(archive)
                retainArchive = true
            }
            CheckedSftpTransferResult.Completed(byteLength)
        } catch (error: SftpArchiveException) {
            CheckedSftpTransferResult.Failure(error.code)
        } catch (_: Exception) {
            CheckedSftpTransferResult.Failure("archive_write_failed")
        } finally {
            if (!retainArchive) archive.delete()
            workspace.deleteRecursively()
        }
    }

    private fun publishShareArchive(archive: File, displayName: String) {
        val shareId = UUID.randomUUID().toString()
        val shareDirectory = File(context.cacheDir, "${SftpShareArchivePolicy.cacheDirectory}/$shareId")
        if (!shareDirectory.mkdirs()) {
            archive.delete()
            mutableUiState.value = mutableUiState.value.copy(error = "无法准备分享文件。")
            return
        }
        val shareFile = File(shareDirectory, displayName)
        if (!archive.renameTo(shareFile)) {
            archive.delete()
            mutableUiState.value = mutableUiState.value.copy(error = "无法准备分享文件。")
            return
        }
        val uri = runCatching {
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", shareFile)
        }.getOrElse {
            shareDirectory.deleteRecursively()
            mutableUiState.value = mutableUiState.value.copy(error = "无法准备分享文件。")
            return
        }
        mutableUiState.value = mutableUiState.value.copy(
            shareArchive = SftpShareArchive(shareId, uri, displayName),
        )
        viewModelScope.launch {
            delay(SftpShareArchivePolicy.retentionMillis)
            shareDirectory.deleteRecursively()
            if (mutableUiState.value.shareArchive?.id == shareId) {
                mutableUiState.value = mutableUiState.value.copy(shareArchive = null)
            }
        }
    }

    private fun archiveEntry(
        sessionId: Long,
        remotePath: String,
        archivePath: String,
        entry: SftpDirectoryEntry,
        workspace: File,
        zip: ZipOutputStream,
        requestId: String,
        markNativeTransferStarted: () -> Boolean,
        onFileDownloaded: (String) -> Unit,
    ): Long {
        if (!archivePath.isSafeArchivePath()) throw SftpArchiveException("invalid_archive_path")
        if (!entry.isDirectory) {
            val localFile = File(workspace, UUID.randomUUID().toString())
            return try {
                if (!markNativeTransferStarted()) {
                    throw SftpArchiveException("sftp_transfer_session_changed")
                }
                val result = sftpClient.download(sessionId, remotePath, localFile.absolutePath, requestId)
                val completed = result as? CheckedSftpTransferResult.Completed
                    ?: throw SftpArchiveException((result as CheckedSftpTransferResult.Failure).code)
                zip.putNextEntry(ZipEntry(archivePath))
                localFile.inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
                onFileDownloaded(archivePath)
                completed.byteLength
            } finally {
                localFile.delete()
            }
        }

        zip.putNextEntry(ZipEntry("${archivePath.trimEnd('/')}/"))
        zip.closeEntry()
        val children = when (val listed = sftpClient.list(sessionId, remotePath)) {
            is CheckedSftpListResult.Listed -> listed.entries
            is CheckedSftpListResult.Failure -> throw SftpArchiveException(listed.code)
        }
        return children.sumOf { child ->
            archiveEntry(
                sessionId = sessionId,
                remotePath = childPath(remotePath, child.name),
                archivePath = "$archivePath/${child.name}",
                entry = child,
                workspace = workspace,
                zip = zip,
                requestId = requestId,
                markNativeTransferStarted = markNativeTransferStarted,
                onFileDownloaded = onFileDownloaded,
            )
        }
    }

    /**
     * Deletes a directory bottom-up with the same bounded traversal model as iOS.
     * Every removal remains metadata-checked; before removing a directory we list its
     * parent again, because deleting children normally changes the directory mtime.
     */
    private fun removeDirectoryTree(sftpSessionId: Long, parentPath: String, entry: SftpDirectoryEntry) {
        val state = mutableUiState.value
        val sessionId = state.session?.id ?: return
        val operation = operations.begin("sftp_recursive_remove", "$sessionId:$parentPath/${entry.name}") ?: return
        mutableUiState.value = state.copy(
            isLoading = true,
            error = null,
            transferMessage = null,
            transferMessageIsError = false,
            transfer = SftpTransferUiState("删除", "正在删除目录及其内容…"),
        )
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                deleteDirectoryTree(
                    sftpSessionId = sftpSessionId,
                    parentPath = parentPath,
                    entry = entry,
                    depth = 0,
                    budget = RecursiveDeleteBudget(),
                )
            }
            when (result) {
                CheckedSftpMutationResult.Completed -> if (isCurrentForSession(operation, sessionId)) {
                    listDirectory(sftpSessionId, state.path)
                    mutableUiState.value = mutableUiState.value.copy(
                        transfer = null,
                        transferMessage = "目录及其内容已删除",
                        transferMessageIsError = false,
                    )
                }
                is CheckedSftpMutationResult.Failure -> if (isCurrentForSession(operation, sessionId)) mutableUiState.value = mutableUiState.value.copy(
                    isLoading = false,
                    transfer = null,
                    error = sftpErrorMessage("删除目录失败", result.code),
                )
            }
        }
    }

    private fun deleteDirectoryTree(
        sftpSessionId: Long,
        parentPath: String,
        entry: SftpDirectoryEntry,
        depth: Int,
        budget: RecursiveDeleteBudget,
    ): CheckedSftpMutationResult {
        if (depth >= MAX_RECURSIVE_DELETE_DEPTH) return CheckedSftpMutationResult.Failure("delete_depth_limit", retryable = false)
        if (!entry.name.isSafeRemoteChildName()) return CheckedSftpMutationResult.Failure("unsafe_remote_name", retryable = false)
        val directoryPath = childPath(parentPath, entry.name)
        val children = when (val listed = sftpClient.list(sftpSessionId, directoryPath)) {
            is CheckedSftpListResult.Listed -> listed.entries
            is CheckedSftpListResult.Failure -> return CheckedSftpMutationResult.Failure(listed.code, listed.retryable)
        }
        for (child in children) {
            if (!child.name.isSafeRemoteChildName()) return CheckedSftpMutationResult.Failure("unsafe_remote_name", retryable = false)
            if (--budget.remainingEntries < 0) return CheckedSftpMutationResult.Failure("delete_entry_limit", retryable = false)
            val result = if (child.isDirectory) {
                deleteDirectoryTree(sftpSessionId, directoryPath, child, depth + 1, budget)
            } else {
                sftpClient.remove(sftpSessionId, childPath(directoryPath, child.name), child)
            }
            if (result is CheckedSftpMutationResult.Failure) return result
        }

        val refreshedEntry = when (val parent = sftpClient.list(sftpSessionId, parentPath)) {
            is CheckedSftpListResult.Listed -> parent.entries.firstOrNull { it.name == entry.name }
                ?: return CheckedSftpMutationResult.Failure("entry_changed", retryable = true)
            is CheckedSftpListResult.Failure -> return CheckedSftpMutationResult.Failure(parent.code, parent.retryable)
        }
        return sftpClient.remove(sftpSessionId, directoryPath, refreshedEntry)
    }

    private fun bind(session: ActiveTerminalSession?) {
        clearTransfersForSessionChange()
        retryLastTransfer = null
        if (session == null) {
            mutableUiState.value = SftpUiState()
            return
        }
        val operation = operations.begin("sftp_bind", session.id) ?: return
        mutableUiState.value = SftpUiState(session = session, isLoading = true)
        viewModelScope.launch {
            when (val opened = withContext(Dispatchers.IO) { sftpClient.open(session.baseSessionId) }) {
                is CheckedSftpOpenResult.Opened -> if (isCurrentForSession(operation, session.id)) {
                    var lastFailure: CheckedSftpListResult.Failure? = null
                    val initialPaths = preferredSftpInitialPaths(opened.homePath)
                    for (path in initialPaths) {
                        val listed = withContext(Dispatchers.IO) {
                            sftpClient.list(opened.sftpSessionId, path)
                        }
                        if (!isCurrentForSession(operation, session.id)) return@launch
                        when (listed) {
                            is CheckedSftpListResult.Listed -> {
                                mutableUiState.value = mutableUiState.value.copy(
                                    sftpSessionId = opened.sftpSessionId,
                                    path = listed.path,
                                    entries = listed.entries.sortedWith(
                                        compareByDescending<SftpDirectoryEntry> { it.isDirectory }
                                            .thenBy(String.CASE_INSENSITIVE_ORDER) { it.name },
                                    ),
                                    isLoading = false,
                                    error = null,
                                    transferMessage = if (path == "/" && opened.homePath != "/") {
                                        "用户主目录不可用，已打开根目录；新建项请选择有写入权限的位置。"
                                    } else null,
                                    transferMessageIsError = false,
                                )
                                return@launch
                            }
                            is CheckedSftpListResult.Failure -> lastFailure = listed
                        }
                    }
                    val failure = lastFailure
                    mutableUiState.value = mutableUiState.value.copy(
                        sftpSessionId = opened.sftpSessionId,
                        isLoading = false,
                        error = failure?.let {
                            sftpErrorMessage("读取目录失败", it.code, it.retryable)
                        } ?: "读取目录失败，请重新建立会话后重试。",
                    )
                }
                is CheckedSftpOpenResult.Failure -> if (isCurrentForSession(operation, session.id)) mutableUiState.value = mutableUiState.value.copy(
                    isLoading = false,
                    error = sftpErrorMessage("无法打开 SFTP", opened.code, opened.retryable),
                )
            }
        }
    }

    override fun onCleared() {
        clearTransfersForSessionChange()
        super.onCleared()
    }

    private fun listDirectory(sftpSessionId: Long, path: String) {
        val current = mutableUiState.value
        val sessionId = current.session?.id ?: return
        val operation = operations.begin("sftp_list", "$sessionId:$path") ?: return
        mutableUiState.value = current.copy(isLoading = true, error = null)
        viewModelScope.launch {
            when (val listed = withContext(Dispatchers.IO) { sftpClient.list(sftpSessionId, path) }) {
                is CheckedSftpListResult.Listed -> if (isCurrentForSession(operation, sessionId)) mutableUiState.value = mutableUiState.value.copy(
                    sftpSessionId = sftpSessionId,
                    path = listed.path,
                    entries = listed.entries.sortedWith(
                        compareByDescending<SftpDirectoryEntry> { it.isDirectory }
                            .thenBy(String.CASE_INSENSITIVE_ORDER) { it.name },
                    ),
                    isLoading = false,
                    error = null,
                )
                is CheckedSftpListResult.Failure -> if (isCurrentForSession(operation, sessionId)) mutableUiState.value = mutableUiState.value.copy(
                    isLoading = false,
                    error = sftpErrorMessage("读取目录失败", listed.code, listed.retryable),
                )
            }
        }
    }

    private fun create(name: String, isDirectory: Boolean) {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        val cleanedName = name.trim()
        if (!cleanedName.isSafeRemoteChildName()) {
            mutableUiState.value = state.copy(error = "名称无效：不能包含 /、\\、空字符、. 或 ..。")
            return
        }
        val target = childPath(state.path, cleanedName)
        if (!target.isSafeRemoteMutationPath()) {
            mutableUiState.value = state.copy(error = "当前路径无效，请刷新目录后重试。")
            return
        }
        mutate {
            if (isDirectory) sftpClient.createDirectory(sftpSessionId, target)
            else sftpClient.createFile(sftpSessionId, target)
        }
    }

    private fun mutate(operation: () -> CheckedSftpMutationResult) {
        val state = mutableUiState.value
        val sftpSessionId = state.sftpSessionId ?: return
        val sessionId = state.session?.id ?: return
        val guard = operations.begin("sftp_mutation", "$sessionId:${state.path}") ?: return
        mutableUiState.value = state.copy(isLoading = true, error = null)
        viewModelScope.launch {
            when (val result = withContext(Dispatchers.IO) { operation() }) {
                CheckedSftpMutationResult.Completed -> if (isCurrentForSession(guard, sessionId)) listDirectory(sftpSessionId, state.path)
                is CheckedSftpMutationResult.Failure -> if (isCurrentForSession(guard, sessionId)) mutableUiState.value = mutableUiState.value.copy(
                    isLoading = false,
                    error = sftpErrorMessage("文件操作失败", result.code, result.retryable),
                )
            }
        }
    }

    private fun isCurrentForSession(operation: com.orbitterm.android.core.OperationScopeToken, sessionId: String): Boolean =
        operations.isCurrent(operation) && mutableUiState.value.session?.id == sessionId
}

private class RecursiveDeleteBudget(var remainingEntries: Int = MAX_RECURSIVE_DELETE_ENTRIES)
private data class BatchRemoveSummary(val succeeded: Int, val failed: Int)

private const val MAX_RECURSIVE_DELETE_DEPTH = 48
private const val MAX_RECURSIVE_DELETE_ENTRIES = 10_000

internal fun String.normalizeRemoteNavigationPath(): String? {
    if (!startsWith('/') || contains('\\')) return null
    val segments = split('/').filter(String::isNotEmpty)
    if (segments.any { it == "." || it == ".." }) return null
    return "/" + segments.joinToString("/")
}

@Composable
fun SftpRoute(
    modifier: Modifier = Modifier,
    viewModel: SftpViewModel = androidx.lifecycle.viewmodel.compose.viewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val context = androidx.compose.ui.platform.LocalContext.current
    var pendingDownload by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<SftpDirectoryEntry?>(null) }
    var pendingArchiveDownload by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<List<SftpDirectoryEntry>>(emptyList()) }
    val uploadPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> uri?.let(viewModel::upload) }
    val downloadPicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        pendingDownload?.let { entry -> uri?.let { viewModel.download(entry, it) } }
        pendingDownload = null
    }
    val archivePicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        uri?.let { destination -> viewModel.downloadAsZip(pendingArchiveDownload, destination) }
        pendingArchiveDownload = emptyList()
    }
    uiState.shareArchive?.let { archive ->
        androidx.compose.runtime.LaunchedEffect(archive.id) {
            runCatching {
                val shareIntent = Intent(Intent.ACTION_SEND)
                    .setType("application/zip")
                    .putExtra(Intent.EXTRA_STREAM, archive.uri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                shareIntent.clipData = ClipData.newRawUri("OrbitTerm SFTP archive", archive.uri)
                context.startActivity(Intent.createChooser(shareIntent, "分享 ${archive.displayName}"))
            }.onFailure {
                viewModel.reportShareLaunchFailure(archive.id)
            }.onSuccess {
                viewModel.consumeShareArchive(archive.id)
            }
        }
    }
    when {
        uiState.session == null -> SftpEmptyState(modifier)
        else -> {
            BackHandler(enabled = uiState.path != "/") {
                viewModel.navigateToParent()
            }
            SftpBrowser(
                state = uiState,
                modifier = modifier,
                onRefresh = viewModel::refreshFromUser,
                onParent = viewModel::navigateToParent,
                onNavigatePath = viewModel::navigateToPath,
                onDirectoryOpened = viewModel::openDirectory,
                onFileOpened = viewModel::openFile,
                onCreateDirectory = viewModel::createDirectory,
                onCreateFile = viewModel::createFile,
                onRename = viewModel::rename,
                onRemove = viewModel::remove,
                onBatchRemove = viewModel::removeAll,
                onChmod = viewModel::chmod,
                onUpload = { viewModel.prepareDocumentInteraction(); uploadPicker.launch("*/*") },
                onDownload = { entry ->
                    pendingDownload = entry
                    viewModel.prepareDocumentInteraction()
                    downloadPicker.launch(entry.name)
                },
                onDownloadAsZip = { entries ->
                    pendingArchiveDownload = entries
                    val suggestedName = entries.singleOrNull()?.name ?: "orbitterm-download"
                    viewModel.prepareDocumentInteraction()
                    archivePicker.launch("$suggestedName.zip")
                },
                onShareAsZip = viewModel::shareAsZip,
                onRetryLastTransfer = viewModel::retryLastTransfer,
                onCancelActiveTransfer = viewModel::cancelActiveTransfer,
                onCancelQueuedTransfer = viewModel::cancelQueuedTransfer,
                onResumeTransferQueue = viewModel::resumeTransferQueue,
                onDismissTransferMessage = viewModel::dismissTransferMessage,
                onDismissTextDocument = viewModel::dismissTextDocument,
                onEditTextDocument = viewModel::beginEditingTextDocument,
                onSaveTextDocument = viewModel::saveTextDocument,
            )
        }
    }
}

@Composable
private fun SftpEmptyState(modifier: Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Rounded.Security, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("需要已验证会话", modifier = Modifier.padding(top = 16.dp), style = MaterialTheme.typography.headlineSmall)
        Text(
            "请先在终端页建立已验证的 SSH 会话，然后再打开 SFTP。",
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        Text("● 请先完成服务器身份确认并建立连接。", modifier = Modifier.padding(top = 24.dp), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
internal fun SftpBrowser(
    state: SftpUiState,
    modifier: Modifier,
    onRefresh: () -> Unit,
    onParent: () -> Unit,
    onNavigatePath: (String) -> Unit,
    onDirectoryOpened: (SftpDirectoryEntry) -> Unit,
    onFileOpened: (SftpDirectoryEntry) -> Unit,
    onCreateDirectory: (String) -> Unit,
    onCreateFile: (String) -> Unit,
    onRename: (SftpDirectoryEntry, String) -> Unit,
    onRemove: (SftpDirectoryEntry) -> Unit,
    onBatchRemove: (List<SftpDirectoryEntry>) -> Unit,
    onChmod: (SftpDirectoryEntry, Int) -> Unit,
    onUpload: () -> Unit,
    onDownload: (SftpDirectoryEntry) -> Unit,
    onDownloadAsZip: (List<SftpDirectoryEntry>) -> Unit,
    onShareAsZip: (List<SftpDirectoryEntry>) -> Unit,
    onRetryLastTransfer: () -> Unit,
    onCancelActiveTransfer: () -> Unit,
    onCancelQueuedTransfer: (String) -> Unit,
    onResumeTransferQueue: () -> Unit,
    onDismissTransferMessage: (String) -> Unit,
    onDismissTextDocument: () -> Unit,
    onEditTextDocument: () -> Unit,
    onSaveTextDocument: (String) -> Unit,
) {
    var createDirectoryDialog by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    var createFileDialog by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    var renameTarget by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<SftpDirectoryEntry?>(null) }
    var removeTarget by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<SftpDirectoryEntry?>(null) }
    var batchRemoveTarget by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<List<SftpDirectoryEntry>>(emptyList()) }
    var chmodTarget by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<SftpDirectoryEntry?>(null) }
    var chmodDraft by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf("") }
    var actionMenuTarget by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    var draftName by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf("") }
    var selectionMode by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    var selectedNames by androidx.compose.runtime.remember(state.path) { androidx.compose.runtime.mutableStateOf(emptySet<String>()) }
    var headerMenuExpanded by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    var pathEntryVisible by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    var pathDraft by androidx.compose.runtime.saveable.rememberSaveable(state.path) { androidx.compose.runtime.mutableStateOf(state.path) }
    val directoryCount = state.entries.count(SftpDirectoryEntry::isDirectory)
    val contentPresentation = OperationalContentPresentationMapper.sftp(
        isLoading = state.isLoading,
        hasItems = state.entries.isNotEmpty(),
        failureDetail = state.error,
    )
    val actionPresentation = OperationalContentPresentationMapper.refreshAction(
        module = OperationalModuleKind.SFTP,
        phase = contentPresentation.phase,
        isRefreshing = state.isLoading,
        hasContent = state.entries.isNotEmpty(),
    )
    Column(modifier = modifier.fillMaxSize()) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
        ) { androidx.compose.foundation.layout.Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onParent, enabled = state.path != "/") {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "上级目录")
            }
            Text(
                state.path,
                modifier = Modifier.weight(1f),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            OperationalRefreshAction(
                presentation = actionPresentation,
                onRefresh = onRefresh,
            )
            androidx.compose.foundation.layout.Box {
                IconButton(onClick = { headerMenuExpanded = true }) {
                    Icon(Icons.Rounded.MoreVert, contentDescription = "文件操作")
                }
                androidx.compose.material3.DropdownMenu(
                    expanded = headerMenuExpanded,
                    onDismissRequest = { headerMenuExpanded = false },
                ) {
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("新建目录") },
                        enabled = !state.isLoading,
                        onClick = { headerMenuExpanded = false; createDirectoryDialog = true },
                    )
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("新建文件") },
                        enabled = !state.isLoading,
                        onClick = { headerMenuExpanded = false; createFileDialog = true },
                    )
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("上传文件") },
                        enabled = !state.isLoading || state.transfer != null,
                        onClick = { headerMenuExpanded = false; onUpload() },
                    )
                }
            }
        }
        }
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
            shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.62f),
        ) {
            Text(
                "总计 ${state.entries.size} · 目录 $directoryCount · 文件 ${state.entries.size - directoryCount}  ·  ${state.path}",
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        OrbitStatusLine(
            label = contentPresentation.headline,
            isActive = contentPresentation.phase == OperationalContentPhase.READY ||
                contentPresentation.phase == OperationalContentPhase.LOADING,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
        OutlinedTextField(
            value = pathDraft,
            onValueChange = { pathDraft = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            label = { Text("路径直达") },
            placeholder = { Text("/var/log") },
            singleLine = true,
            trailingIcon = { TextButton(onClick = { onNavigatePath(pathDraft) }) { Text("前往") } },
        )
        if (state.isLoading && state.entries.isNotEmpty()) {
            Text(
                "正在更新目录，当前列表仍可浏览…",
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
                color = MaterialTheme.colorScheme.primary,
                style = MaterialTheme.typography.labelMedium,
            )
        }
        if (selectionMode) {
            Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Text("已选择 ${selectedNames.size} 项", style = MaterialTheme.typography.labelLarge)
                LazyRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    item {
                    TextButton(
                        enabled = selectedNames.isNotEmpty() && !state.isLoading,
                        onClick = {
                            onDownloadAsZip(state.entries.filter { it.name in selectedNames })
                            selectionMode = false
                            selectedNames = emptySet()
                        },
                    ) { Text("下载为 ZIP") }
                    }
                    item {
                    TextButton(
                        enabled = selectedNames.isNotEmpty() && !state.isLoading,
                        onClick = {
                            onShareAsZip(state.entries.filter { it.name in selectedNames })
                            selectionMode = false
                            selectedNames = emptySet()
                        },
                    ) { Text("分享 ZIP") }
                    }
                    item {
                    TextButton(
                        enabled = selectedNames.isNotEmpty() && !state.isLoading,
                        onClick = { batchRemoveTarget = state.entries.filter { it.name in selectedNames } },
                    ) { Text("删除", color = MaterialTheme.colorScheme.error) }
                    }
                    item {
                    TextButton(onClick = { selectionMode = false; selectedNames = emptySet() }) { Text("取消") }
                    }
                }
            }
        } else {
            TextButton(
                modifier = Modifier.padding(start = 12.dp),
                enabled = !state.isLoading && state.entries.isNotEmpty(),
                onClick = { selectionMode = true },
            ) { Text("批量选择（${state.entries.size}）") }
        }
        state.transfer?.let { transfer ->
            val knownTotalBytes = transfer.totalBytes?.takeIf { it > 0 }
            val progress = knownTotalBytes?.let { total ->
                (transfer.transferredBytes.toFloat() / total).coerceIn(0f, 1f)
            }
            Surface(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = if (progress != null) "${transfer.label} · ${(progress * 100).toInt()}%" else "${transfer.label}中",
                        style = MaterialTheme.typography.labelLarge,
                    )
                    Text(
                        transfer.detail,
                        modifier = Modifier.padding(top = 4.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    if (progress != null) {
                        androidx.compose.material3.LinearProgressIndicator(
                            progress = { progress },
                            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                        )
                        Text(
                            "${formatBytes(transfer.transferredBytes)} / ${formatBytes(knownTotalBytes!!)}",
                            modifier = Modifier.padding(top = 6.dp),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        androidx.compose.material3.LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                        )
                        Text(
                            "已传输 ${formatBytes(transfer.transferredBytes)}",
                            modifier = Modifier.padding(top = 6.dp),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (state.activeTransferRequestId != null && state.canCancelTransfer) {
                        TextButton(
                            onClick = onCancelActiveTransfer,
                            enabled = !state.cancellationRequested,
                            modifier = Modifier.align(Alignment.End).padding(top = 4.dp),
                        ) { Text(if (state.cancellationRequested) "正在取消…" else "取消传输") }
                    }
                }
            }
        }
        if (state.queuedTransfers.isNotEmpty()) {
            Surface(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 1.dp,
            ) {
                Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                    Text("等待传输（${state.queuedTransfers.size}）", style = MaterialTheme.typography.labelLarge)
                    state.queuedTransfers.forEach { queued ->
                        androidx.compose.foundation.layout.Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(queued.label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                            TextButton(onClick = { onCancelQueuedTransfer(queued.id) }) { Text("移除") }
                        }
                    }
                    if (state.queuePaused) {
                        TextButton(onClick = onResumeTransferQueue, modifier = Modifier.align(Alignment.End)) { Text("继续队列") }
                    }
                }
            }
        }
        state.error?.let { error ->
            OperationalFailureFeedback(
                content = contentPresentation,
                action = actionPresentation,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
        state.transferMessage?.let { message ->
            if (state.transferMessageIsError) {
                OrbitFeedbackBanner(
                    message = message,
                    isError = true,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            } else {
                OperationalTransientSuccessFeedback(
                    message = message,
                    onDismiss = onDismissTransferMessage,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
        state.retryTransferLabel?.let { label ->
            TextButton(
                onClick = onRetryLastTransfer,
                modifier = Modifier.padding(horizontal = 12.dp),
            ) { Text("重试$label") }
        }
        if (state.entries.isEmpty() && state.transfer == null) {
            OrbitEmptyState(
                title = contentPresentation.headline,
                message = contentPresentation.detail,
                modifier = Modifier.weight(1f),
            )
        } else LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(state.entries, key = { entry -> "${state.path}/${entry.name}" }) { entry ->
                Surface(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 3.dp),
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.90f),
                ) { ListItem(
                    headlineContent = { Text(entry.name) },
                    supportingContent = { Text(entry.permissions + " · " + formatBytes(entry.size)) },
                    leadingContent = {
                        Icon(
                            if (entry.isDirectory) Icons.Rounded.Folder else Icons.Rounded.Description,
                            contentDescription = null,
                        )
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            if (selectionMode) {
                                selectedNames = if (entry.name in selectedNames) selectedNames - entry.name else selectedNames + entry.name
                            } else onFileOpened(entry)
                        },
                    trailingContent = {
                        if (selectionMode) {
                            androidx.compose.material3.Checkbox(
                                checked = entry.name in selectedNames,
                                onCheckedChange = { checked ->
                                    selectedNames = if (checked) selectedNames + entry.name else selectedNames - entry.name
                                },
                            )
                        } else androidx.compose.foundation.layout.Box {
                            IconButton(onClick = { actionMenuTarget = entry.name }, enabled = !state.isLoading || state.transfer != null) {
                                Icon(Icons.Rounded.MoreVert, contentDescription = "${entry.name} 更多操作")
                            }
                            androidx.compose.material3.DropdownMenu(
                                expanded = actionMenuTarget == entry.name,
                                onDismissRequest = { actionMenuTarget = null },
                            ) {
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text("重命名") },
                                    enabled = state.transfer == null,
                                    onClick = {
                                        actionMenuTarget = null
                                        draftName = entry.name
                                        renameTarget = entry
                                    },
                                )
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text("修改权限") },
                                    enabled = state.transfer == null,
                                    onClick = {
                                        actionMenuTarget = null
                                        chmodTarget = entry
                                        chmodDraft = (entry.permissionsOctal and 4095).toString(8)
                                    },
                                )
                                if (!entry.isDirectory) androidx.compose.material3.DropdownMenuItem(
                                    text = { Text("在应用内打开") },
                                    enabled = state.transfer == null,
                                    onClick = { actionMenuTarget = null; onFileOpened(entry) },
                                )
                                if (!entry.isDirectory) androidx.compose.material3.DropdownMenuItem(
                                    text = { Text("下载") },
                                    onClick = { actionMenuTarget = null; onDownload(entry) },
                                )
                                if (entry.isDirectory) androidx.compose.material3.DropdownMenuItem(
                                    text = { Text("下载为 ZIP") },
                                    enabled = state.transfer == null,
                                    onClick = { actionMenuTarget = null; onDownloadAsZip(listOf(entry)) },
                                )
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text("删除", color = MaterialTheme.colorScheme.error) },
                                    enabled = state.transfer == null,
                                    onClick = { actionMenuTarget = null; removeTarget = entry },
                                )
                            }
                        }
                    },
                ) }
            }
        }
    }

    if (createDirectoryDialog || createFileDialog || renameTarget != null) {
        val title = when {
            createDirectoryDialog -> "新建目录"
            createFileDialog -> "新建文件"
            else -> "重命名"
        }
        OrbitFormDialog(
            title = title,
            confirmLabel = "确认",
            confirmEnabled = draftName.isNotBlank(),
            onConfirm = {
                when {
                    createDirectoryDialog -> onCreateDirectory(draftName)
                    createFileDialog -> onCreateFile(draftName)
                    else -> renameTarget?.let { onRename(it, draftName) }
                }
                createDirectoryDialog = false
                createFileDialog = false
                renameTarget = null
                draftName = ""
            },
            onDismiss = {
                createDirectoryDialog = false
                createFileDialog = false
                renameTarget = null
                draftName = ""
            },
        ) {
            OutlinedTextField(
                value = draftName,
                onValueChange = { draftName = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("名称") },
                singleLine = true,
            )
        }
    }
    removeTarget?.let { entry ->
        OrbitConfirmationDialog(
            title = "删除 ${entry.name}？",
            message = if (entry.isDirectory) {
                "将递归删除该目录及其全部内容。此操作无法撤销。为保障安全，最多删除 10,000 项、48 层目录。"
            } else {
                "此操作无法撤销。"
            },
            confirmLabel = "删除",
            onConfirm = { onRemove(entry); removeTarget = null },
            onDismiss = { removeTarget = null },
            destructive = true,
        )
    }
    if (batchRemoveTarget.isNotEmpty()) {
        val targets = batchRemoveTarget
        OrbitConfirmationDialog(
            title = "删除选中的项目？",
            message = "将删除 ${targets.size} 个文件或目录及其内容。此操作无法撤销。",
            confirmLabel = "删除",
            onConfirm = {
                onBatchRemove(targets)
                batchRemoveTarget = emptyList()
                selectionMode = false
                selectedNames = emptySet()
            },
            onDismiss = { batchRemoveTarget = emptyList() },
            destructive = true,
        )
    }
    chmodTarget?.let { entry ->
        val mode = chmodDraft.toIntOrNull(8)
        OrbitFormDialog(
            title = "修改权限：${entry.name}",
            confirmLabel = "保存",
            confirmEnabled = mode != null && mode in 0..4095,
            onConfirm = { onChmod(entry, mode!!); chmodTarget = null },
            onDismiss = { chmodTarget = null },
        ) {
            OutlinedTextField(
                value = chmodDraft,
                onValueChange = { chmodDraft = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("八进制权限，例如 755") },
                singleLine = true,
            )
        }
    }
    state.textDocument?.let { document ->
        var content by androidx.compose.runtime.remember(document.path) { androidx.compose.runtime.mutableStateOf(document.content) }
        var confirmDiscard by androidx.compose.runtime.remember(document.path) { androidx.compose.runtime.mutableStateOf(false) }
        val dismissDocument = {
            if (SftpInAppDocumentPolicy.hasUnsavedChanges(document.isEditing, document.content, content)) {
                confirmDiscard = true
            } else {
                onDismissTextDocument()
            }
        }
        OrbitFormDialog(
            title = document.entry.name,
            modifier = Modifier.fillMaxWidth(0.94f),
            confirmLabel = when {
                !document.isEditing -> "编辑"
                state.isLoading -> "保存中…"
                else -> "保存"
            },
            confirmEnabled = !state.isLoading,
            dismissEnabled = !state.isLoading,
            usePlatformDefaultWidth = false,
            onConfirm = {
                if (document.isEditing) onSaveTextDocument(content) else onEditTextDocument()
            },
            onDismiss = dismissDocument,
        ) {
            Text(
                if (document.isEditing) "编辑模式 · ${document.textFormat.displayLabel} · 最大 2 MB" else "只读预览 · ${document.textFormat.displayLabel} · 最大 2 MB",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
            if (document.isEditing) {
                Text(
                    "自动折行仅改变屏幕显示；只有手动换行会写入远端文件。",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            state.textDocumentError?.let { message ->
                Text(
                    message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            OutlinedTextField(
                value = content,
                onValueChange = { content = it },
                modifier = Modifier.fillMaxWidth(),
                minLines = 12,
                maxLines = 24,
                enabled = !state.isLoading,
                readOnly = !document.isEditing,
                textStyle = MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                ),
            )
        }
        if (confirmDiscard) {
            OrbitConfirmationDialog(
                title = "放弃未保存的修改？",
                message = "当前编辑内容尚未保存到远端。离开后，本次修改将丢失。",
                confirmLabel = "放弃修改",
                destructive = true,
                onConfirm = {
                    confirmDiscard = false
                    onDismissTextDocument()
                },
                onDismiss = { confirmDiscard = false },
            )
        }
    }
}

private fun childPath(parent: String, name: String): String =
    if (parent == "/") "/$name" else "$parent/$name"

private fun parentPath(path: String): String = path.substringBeforeLast('/').ifEmpty { "/" }

private fun String.isSafeRemoteMutationPath(): Boolean =
    startsWith('/') && !contains('\\') && split('/').drop(1).none { it.isEmpty() || it == "." || it == ".." }

private fun String.isSafeRemoteChildName(): Boolean =
    isNotBlank() && this != "." && this != ".." && !contains('/') && !contains('\\') && !contains('\u0000')

internal fun preferredSftpInitialPaths(serverResolvedHome: String?): List<String> {
    val home = serverResolvedHome
        ?.trim()
        ?.takeIf { it.isSafeRemoteMutationPath() }
    return listOfNotNull(home, "/").distinct()
}

private fun String.isSafeArchivePath(): Boolean =
    isNotBlank() && !startsWith('/') && !contains('\\') && split('/').none { it.isEmpty() || it == "." || it == ".." }

private class SftpArchiveException(val code: String) : Exception(code)

private fun String.textDocumentMessage(): String = when (this) {
    "sftp_entry_changed" -> "远端文件已被修改，未覆盖保存。当前编辑内容仍已保留，请核对后重试。"
    "sftp_target_exists" -> "远端存在未完成的同名保存文件，未覆盖保存。当前编辑内容仍已保留。"
    else -> "保存失败：${orbitNativeError(this).userMessage()} 当前编辑内容仍已保留。"
}

private fun sftpErrorMessage(prefix: String, code: String, retryable: Boolean = false): String {
    val error = orbitNativeError(code, retryable)
    return "$prefix：${error.userMessage()} 诊断代码：${error.diagnosticCode}。"
}

private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB", "PB")
    var value = bytes.toDouble()
    var unitIndex = -1
    while (value >= 1024 && unitIndex < units.lastIndex) {
        value /= 1024
        unitIndex += 1
    }
    return "%.1f %s".format(java.util.Locale.ROOT, value, units[unitIndex])
}
