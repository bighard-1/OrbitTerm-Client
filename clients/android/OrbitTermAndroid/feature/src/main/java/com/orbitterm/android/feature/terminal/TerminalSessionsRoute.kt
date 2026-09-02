package com.orbitterm.android.feature.terminal

import android.graphics.Rect
import android.view.ViewTreeObserver
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.AssistChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.South
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.rounded.List
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.domain.session.CustomQuickCommand
import com.orbitterm.android.domain.session.CommandSnippetTemplate
import com.orbitterm.android.domain.session.QuickCommandRepository
import com.orbitterm.android.domain.session.TerminalKeyUsageRepository
import com.orbitterm.android.domain.session.TerminalCustomKey
import com.orbitterm.android.domain.session.TerminalCustomKeySection
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.assets.ServerCredentials
import com.orbitterm.android.domain.assets.AndroidTransportSupportPolicy
import com.orbitterm.android.domain.assets.ServerTransportProtocol
import com.orbitterm.android.core.CheckedSshConnectResult
import com.orbitterm.android.core.CheckedSshNativeClient
import com.orbitterm.android.feature.monitor.MonitorPanel
import com.orbitterm.android.feature.batch.BatchCommandUiState
import com.orbitterm.android.feature.batch.BatchCommandViewModel
import com.orbitterm.android.security.SecureCredentialStore
import com.orbitterm.android.domain.settings.TerminalAppearance
import com.orbitterm.android.domain.settings.MonitorRefreshInterval
import com.orbitterm.android.domain.sync.SyncRequester
import com.orbitterm.android.core.OperationScopeCoordinator
import com.orbitterm.android.core.SessionNetworkAvailability
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.design.OrbitFormDialog
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID
import javax.inject.Inject

data class TerminalSessionsUiState(
    val sessions: List<ActiveTerminalSession> = emptyList(),
    val assets: List<com.orbitterm.android.domain.assets.ServerAsset> = emptyList(),
    val selectedSession: ActiveTerminalSession? = null,
    val selectedModule: SessionWorkspaceModule = SessionWorkspaceModule.Terminal,
    val customCommands: List<CustomQuickCommand> = emptyList(),
    val shortcutError: String? = null,
    val reconnecting: Boolean = false,
    val reconnectError: String? = null,
    val terminalNotice: String? = null,
    val processRecoveryNotice: String? = null,
    val isNetworkUsable: Boolean = true,
    val specialKeyUsage: Map<String, Int> = emptyMap(),
    val customTerminalKeys: List<TerminalCustomKey> = emptyList(),
)

enum class SessionWorkspaceModule(val label: String) {
    Terminal("终端"),
    Shortcuts("快捷操作"),
    Monitor("监控"),
    Snippets("Snippets"),
}

@HiltViewModel
class TerminalSessionsViewModel @Inject constructor(
    private val terminalSessionController: TerminalSessionController,
    private val quickCommandRepository: QuickCommandRepository,
    private val assetRepository: AssetRepository,
    private val credentialStore: SecureCredentialStore,
    private val checkedSsh: CheckedSshNativeClient,
    private val terminalClipboard: TerminalClipboard,
    private val syncRequests: SyncRequester,
    private val terminalKeyUsageRepository: TerminalKeyUsageRepository,
    private val operations: OperationScopeCoordinator,
    private val networkAvailability: SessionNetworkAvailability,
) : ViewModel() {
    private data class TerminalKeyPreferences(
        val usage: Map<String, Int>,
        val customKeys: List<TerminalCustomKey>,
    )

    private val terminalKeyPreferences = combine(
        terminalKeyUsageRepository.usageCounts,
        terminalKeyUsageRepository.customKeys,
    ) { usage, customKeys -> TerminalKeyPreferences(usage, customKeys) }
    private val selectedSessionId = MutableStateFlow<String?>(null)
    private val selectedModule = MutableStateFlow(SessionWorkspaceModule.Terminal)
    private val shortcutError = MutableStateFlow<String?>(null)
    private val terminalNotice = MutableStateFlow<String?>(null)
    private val processRecoveryNotice = MutableStateFlow(
        if (terminalSessionController.hadInterruptedSessionsAtProcessStart) {
            "应用进程已重新启动。出于安全，先前的实时会话未自动恢复，请从服务器页重新连接。"
        } else {
            null
        },
    )
    private val reconnectState = MutableStateFlow(ReconnectState())
    private val reconnectAvailability = combine(
        reconnectState,
        networkAvailability.isNetworkUsable,
    ) { reconnect, isNetworkUsable ->
        ReconnectAvailability(reconnect, isNetworkUsable)
    }
    private val workspaceState = combine(
        selectedSessionId,
        selectedModule,
        shortcutError,
        reconnectAvailability,
        terminalNotice,
    ) { selectedId, module, shortcutError, reconnectAvailability, notice ->
        WorkspaceState(selectedId, module, shortcutError, reconnectAvailability, notice)
    }
    val uiState = combine(
        terminalSessionController.activeSessions,
        quickCommandRepository.customCommands,
        assetRepository.observeAssets(),
        terminalKeyPreferences,
        combine(workspaceState, processRecoveryNotice) { workspace, recoveryNotice -> workspace to recoveryNotice },
    ) { sessions, customCommands, assets, keyPreferences, workspaceAndNotice ->
        val (workspace, recoveryNotice) = workspaceAndNotice
        TerminalSessionsUiState(
            sessions = sessions,
            assets = assets,
            selectedSession = selectActiveTerminalSession(sessions, workspace.selectedSessionId),
            selectedModule = workspace.selectedModule,
            customCommands = customCommands,
            shortcutError = workspace.shortcutError,
            reconnecting = workspace.reconnectAvailability.reconnect.isRunning,
            reconnectError = workspace.reconnectAvailability.reconnect.error,
            terminalNotice = workspace.terminalNotice,
            processRecoveryNotice = recoveryNotice,
            isNetworkUsable = workspace.reconnectAvailability.isNetworkUsable,
            specialKeyUsage = keyPreferences.usage,
            customTerminalKeys = keyPreferences.customKeys,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = TerminalSessionsUiState(),
    )

    fun select(sessionId: String) {
        selectedSessionId.value = sessionId
        terminalSessionController.select(sessionId)
    }

    fun resize(sessionId: String, columns: Int, rows: Int) =
        terminalSessionController.resize(sessionId, columns, rows)

    fun close(sessionId: String) {
        operations.invalidate("ssh_reconnect", sessionId)
        terminalSessionController.close(sessionId)
        if (selectedSessionId.value == sessionId) selectedSessionId.value = null
    }

    fun selectModule(module: SessionWorkspaceModule) {
        selectedModule.value = module
    }

    fun sendInput(sessionId: String, bytes: ByteArray) {
        terminalSessionController.sendInput(sessionId, bytes)
    }

    fun recordSpecialKeyUse(label: String) {
        viewModelScope.launch { terminalKeyUsageRepository.recordUse(label) }
    }

    fun saveCustomTerminalKey(label: String, payload: String, section: TerminalCustomKeySection) {
        val normalizedLabel = label.trim()
        if (normalizedLabel.isEmpty() || parseTerminalCustomKeyPayload(payload) == null) return
        viewModelScope.launch {
            terminalKeyUsageRepository.saveCustomKey(
                TerminalCustomKey(
                    id = UUID.randomUUID().toString(),
                    label = normalizedLabel,
                    payload = payload,
                    section = section,
                ),
            )
        }
    }

    fun deleteCustomTerminalKey(id: String) {
        viewModelScope.launch { terminalKeyUsageRepository.deleteCustomKey(id) }
    }

    fun executeCommand(sessionId: String, command: String) {
        terminalSessionController.sendCommand(sessionId, command)
    }

    fun insertCommand(sessionId: String, command: String) {
        terminalSessionController.insertCommand(sessionId, command)
    }

    fun clearTerminal(sessionId: String) {
        terminalSessionController.clearTerminal(sessionId)
    }

    fun pasteFromClipboard(sessionId: String) {
        when (val content = terminalClipboard.readForPaste()) {
            is TerminalClipboardContent.Text -> {
                terminalSessionController.sendInput(sessionId, content.bytes)
                terminalNotice.value = null
            }
            TerminalClipboardContent.Empty -> terminalNotice.value = "剪贴板中没有可粘贴的文本。"
            TerminalClipboardContent.TooLarge -> terminalNotice.value = "剪贴板内容超过 16 KB，未粘贴。"
        }
    }

    /** Keeps the existing terminal alive until a new checked terminal is fully open. */
    fun reconnect(session: ActiveTerminalSession) {
        if (!TerminalReconnectPolicy.canReconnect(networkAvailability.isNetworkUsable.value, reconnectState.value.isRunning)) {
            if (!networkAvailability.isNetworkUsable.value) {
                reconnectState.value = ReconnectState(error = "网络当前不可用。恢复后可手动重新连接，应用不会自动恢复会话。")
            }
            return
        }
        val operation = operations.begin("ssh_reconnect", session.id) ?: return
        reconnectState.value = ReconnectState(isRunning = true)
        viewModelScope.launch {
            val asset = withContext(Dispatchers.IO) { assetRepository.findAsset(session.assetId) }
            if (!operations.isCurrent(operation)) return@launch
            if (asset == null) {
                reconnectState.value = ReconnectState(error = "找不到此会话对应的资产。")
                return@launch
            }
            val credentials = withContext(Dispatchers.IO) {
                credentialStore.read(asset.credentialID) ?: ServerCredentials()
            }
            if (!operations.isCurrent(operation)) return@launch
            if (session.transport == ServerTransportProtocol.telnet.name) {
                val opened = terminalSessionController.openTelnet(asset, credentials)
                if (!operations.isCurrent(operation)) return@launch
                if (opened) {
                    terminalSessionController.close(session.id)
                    selectedSessionId.value = null
                    reconnectState.value = ReconnectState()
                } else {
                    reconnectState.value = ReconnectState(error = "Telnet 重新连接失败，已保留原会话。")
                }
                return@launch
            }
            when (val connected = withContext(Dispatchers.IO) { checkedSsh.connect(asset, credentials) }) {
                is CheckedSshConnectResult.Connected -> {
                    if (!operations.isCurrent(operation)) {
                        withContext(Dispatchers.IO) { checkedSsh.disconnect(connected.baseSessionId) }
                        return@launch
                    }
                    val opened = terminalSessionController.open(
                        assetId = asset.id,
                        displayName = asset.name,
                        baseSessionId = connected.baseSessionId,
                        shouldAttach = { operations.isCurrent(operation) },
                    )
                    if (!operations.isCurrent(operation)) {
                        return@launch
                    }
                    if (opened) {
                        terminalSessionController.close(session.id)
                        selectedSessionId.value = null
                        reconnectState.value = ReconnectState()
                    } else {
                        withContext(Dispatchers.IO) { checkedSsh.disconnect(connected.baseSessionId) }
                        reconnectState.value = ReconnectState(error = "新终端无法打开，已保留原会话。")
                    }
                }
                is CheckedSshConnectResult.HostKeyChallenge -> {
                    withContext(Dispatchers.IO) { checkedSsh.rejectChallenge(connected.challengeId) }
                    if (operations.isCurrent(operation)) {
                        reconnectState.value = ReconnectState(error = "服务器身份需要重新确认，请从服务器页发起连接。")
                    }
                }
                is CheckedSshConnectResult.Blocked -> if (operations.isCurrent(operation)) reconnectState.value = ReconnectState(
                    error = "服务器身份校验被阻断。原会话未受影响。",
                )
                is CheckedSshConnectResult.Failure -> if (operations.isCurrent(operation)) reconnectState.value = ReconnectState(
                    error = run {
                        val error = com.orbitterm.android.domain.error.orbitNativeError(
                            connected.code,
                            connected.retryable,
                            connected.detailCode,
                        )
                        "重新连接失败：${error.userMessage()} 诊断代码：${error.diagnosticCode}。原会话未受影响。"
                    },
                )
            }
        }
    }

    fun dismissProcessRecoveryNotice() {
        processRecoveryNotice.value = null
    }

    fun addCustomCommand(title: String, command: String, category: String, allowedAssetIds: Set<String>) {
        val normalizedTitle = title.trim()
        val normalizedCommand = command.trim()
        if (normalizedTitle.isEmpty() || normalizedCommand.isEmpty()) return
        viewModelScope.launch {
            val next = uiState.value.customCommands + CustomQuickCommand(
                id = UUID.randomUUID().toString(),
                title = normalizedTitle,
                command = normalizedCommand,
                category = category.trim().ifBlank { "未分类" },
                allowedAssetIds = allowedAssetIds,
                createdAtUnix = System.currentTimeMillis() / 1_000,
                updatedAtUnix = System.currentTimeMillis() / 1_000,
            )
            runCatching { quickCommandRepository.save(next) }
                .onSuccess { shortcutError.value = null; syncRequests.requestSync() }
                .onFailure { shortcutError.value = "保存快捷指令失败，请稍后重试。" }
        }
    }

    fun saveCommandFromHistory(command: String) {
        val normalized = command.trim()
        if (normalized.isEmpty()) return
        val title = normalized.split(Regex("\\s+")).take(3).joinToString(" ").take(64).ifBlank { "历史命令" }
        addCustomCommand(title, normalized, "历史", emptySet())
    }

    fun deleteCustomCommand(id: String) {
        viewModelScope.launch {
            val next = uiState.value.customCommands.filterNot { it.id == id }
            runCatching { quickCommandRepository.save(next) }
                .onSuccess { shortcutError.value = null; syncRequests.requestSync() }
                .onFailure { shortcutError.value = "删除快捷指令失败，请稍后重试。" }
        }
    }

    fun updateCustomCommand(id: String, title: String, command: String, category: String, allowedAssetIds: Set<String>) {
        val normalizedTitle = title.trim()
        val normalizedCommand = command.trim()
        if (normalizedTitle.isEmpty() || normalizedCommand.isEmpty()) return
        viewModelScope.launch {
            val next = uiState.value.customCommands.map { current ->
                if (current.id == id) current.copy(
                    title = normalizedTitle,
                    command = normalizedCommand,
                    category = category.trim().ifBlank { "未分类" },
                    allowedAssetIds = allowedAssetIds,
                    updatedAtUnix = System.currentTimeMillis() / 1_000,
                ) else current
            }
            runCatching { quickCommandRepository.save(next) }
                .onSuccess { shortcutError.value = null; syncRequests.requestSync() }
                .onFailure { shortcutError.value = "保存快捷指令失败，请稍后重试。" }
        }
    }

    private data class ReconnectState(val isRunning: Boolean = false, val error: String? = null)
    private data class ReconnectAvailability(
        val reconnect: ReconnectState,
        val isNetworkUsable: Boolean,
    )
    private data class WorkspaceState(
        val selectedSessionId: String?,
        val selectedModule: SessionWorkspaceModule,
        val shortcutError: String?,
        val reconnectAvailability: ReconnectAvailability,
        val terminalNotice: String?,
    )
}

@Composable
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
fun TerminalSessionsRoute(
    terminalAppearance: TerminalAppearance,
    monitorRefreshInterval: MonitorRefreshInterval,
    modifier: Modifier = Modifier,
    onBackToServers: () -> Unit = {},
    viewModel: TerminalSessionsViewModel = viewModel(),
    batchViewModel: BatchCommandViewModel = viewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val batchState by batchViewModel.uiState.collectAsStateWithLifecycle()
    val session = uiState.selectedSession
    var terminalCanvas by remember { mutableStateOf<RemoteTerminalCanvasView?>(null) }
    var customKeyEditorSection by remember { mutableStateOf<TerminalCustomKeySection?>(null) }
    var sessionMenuExpanded by rememberSaveable { mutableStateOf(false) }
    val isImeVisible = rememberReliableImeVisibility()
    if (session == null) {
        Column(
            modifier = modifier.fillMaxSize().padding(24.dp),
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        ) {
            uiState.processRecoveryNotice?.let { notice ->
                TerminalProcessRecoveryNotice(
                    message = notice,
                    onDismiss = viewModel::dismissProcessRecoveryNotice,
                )
            }
            Text("终端工作台", style = androidx.compose.material3.MaterialTheme.typography.headlineMedium)
            Text(
                "暂无活动会话。请先在服务器页连接一台资产。",
                modifier = Modifier.padding(top = 8.dp),
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                style = androidx.compose.material3.MaterialTheme.typography.bodyMedium,
            )
        }
        return
    }
    LaunchedEffect(session.id, uiState.selectedModule, isImeVisible, terminalCanvas) {
        if (uiState.selectedModule == SessionWorkspaceModule.Terminal) {
            // Opening or dismissing the IME changes the native terminal viewport.
            // Re-anchor after Compose has applied the new inset so the prompt and
            // latest output stay above both the keyboard and its shortcut bar.
            terminalCanvas?.post { terminalCanvas?.scrollToBottom() }
        }
    }
    val leaveTerminalWorkspace: () -> Unit = {
        val canvas = terminalCanvas
        canvas?.dismissKeyboard()
        // Let the IME consume the hide request before the server page restores its Dock.
        if (canvas != null) canvas.postDelayed(onBackToServers, 80L) else onBackToServers()
        Unit
    }
    BackHandler(onBack = leaveTerminalWorkspace)
    Column(modifier = modifier.fillMaxSize()) {
        Surface(tonalElevation = 1.dp) {
            Row(
                modifier = Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 4.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                IconButton(onClick = leaveTerminalWorkspace) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回服务器")
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        session.displayName,
                        style = androidx.compose.material3.MaterialTheme.typography.titleSmall,
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    )
                    Text(
                        terminalSessionStatusLabel(
                            state = session.connectionState,
                            reconnecting = uiState.reconnecting,
                            sessionCount = uiState.sessions.size,
                        ),
                        color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                        style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                    )
                }
                if (uiState.sessions.size > 1) {
                    Box {
                        IconButton(onClick = { sessionMenuExpanded = true }) {
                            Icon(Icons.AutoMirrored.Rounded.List, contentDescription = "切换资产会话")
                        }
                        DropdownMenu(
                            expanded = sessionMenuExpanded,
                            onDismissRequest = { sessionMenuExpanded = false },
                        ) {
                            uiState.sessions.forEach { candidate ->
                                DropdownMenuItem(
                                    text = {
                                        Column {
                                            Text(candidate.displayName, maxLines = 1)
                                            Text(
                                                if (candidate.id == session.id) "当前会话" else "切换到此终端",
                                                style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                                                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                                            )
                                        }
                                    },
                                    leadingIcon = if (candidate.id == session.id) {
                                        { Icon(Icons.Rounded.Check, contentDescription = null) }
                                    } else null,
                                    onClick = {
                                        viewModel.select(candidate.id)
                                        sessionMenuExpanded = false
                                    },
                                )
                            }
                        }
                    }
                }
                TerminalReconnectAction(
                    reconnecting = uiState.reconnecting,
                    isNetworkUsable = uiState.isNetworkUsable,
                    onReconnect = { viewModel.reconnect(session) },
                )
                if (uiState.selectedModule == SessionWorkspaceModule.Terminal) {
                    IconButton(onClick = { terminalCanvas?.scrollToBottom() }) {
                        Icon(Icons.Rounded.South, contentDescription = "回到最新输出")
                    }
                }
                IconButton(onClick = { viewModel.close(session.id) }) {
                    Icon(Icons.Rounded.Close, contentDescription = "关闭当前会话")
                }
            }
        }
        ModuleSelector(
            selected = uiState.selectedModule,
            onSelected = viewModel::selectModule,
        )
        uiState.reconnectError?.let { error ->
            TerminalReconnectFailure(error)
        }
        uiState.processRecoveryNotice?.let { notice ->
            TerminalProcessRecoveryNotice(
                message = notice,
                onDismiss = viewModel::dismissProcessRecoveryNotice,
            )
        }
        if (!uiState.isNetworkUsable) {
            OrbitFeedbackBanner(
                message = "网络当前不可用。恢复后可手动重连；应用不会自动恢复会话。",
                isError = true,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        uiState.terminalNotice?.let { notice ->
            OrbitFeedbackBanner(
                message = notice,
                isError = true,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        when (uiState.selectedModule) {
            SessionWorkspaceModule.Terminal -> Column(
                // The native terminal owns the remaining work area. Android's
                // IME writes straight into it; there is deliberately no second
                // command staging field competing with the real terminal input.
                modifier = Modifier
                    .weight(1f)
                    .imePadding(),
            ) {
                AndroidView(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    factory = { context -> RemoteTerminalCanvasView(context).also { terminalCanvas = it } },
                    update = { view ->
                        // revision changes whenever new terminal output has been parsed.
                        session.revision
                        view.setAppearance(terminalAppearance)
                        view.bind(session) { columns, rows -> viewModel.resize(session.id, columns, rows) }
                    },
                )
                if (isImeVisible) {
                    TerminalKeyBar(
                        usageCounts = uiState.specialKeyUsage,
                        customKeys = uiState.customTerminalKeys,
                        onSend = { key ->
                            viewModel.sendInput(session.id, key.bytes)
                            viewModel.recordSpecialKeyUse(key.label)
                        },
                        onPaste = { viewModel.pasteFromClipboard(session.id) },
                        onManageCustomKeys = { section ->
                            terminalCanvas?.dismissKeyboard()
                            customKeyEditorSection = section
                        },
                    )
                }
            }
            SessionWorkspaceModule.Shortcuts -> ShortcutControlsPanel(
                onSendRaw = { bytes -> viewModel.sendInput(session.id, bytes) },
            )
            SessionWorkspaceModule.Snippets -> QuickCommandsPanel(
                onExecute = { command ->
                    viewModel.executeCommand(session.id, command)
                    viewModel.selectModule(SessionWorkspaceModule.Terminal)
                },
                onInsert = { command -> viewModel.insertCommand(session.id, command) },
                customCommands = uiState.customCommands,
                assets = uiState.assets,
                activeAssetId = session.assetId,
                commandHistory = session.commandHistory,
                error = uiState.shortcutError,
                onAddCustomCommand = viewModel::addCustomCommand,
                onUpdateCustomCommand = viewModel::updateCustomCommand,
                onDeleteCustomCommand = viewModel::deleteCustomCommand,
                onSaveCommandFromHistory = viewModel::saveCommandFromHistory,
                batchState = batchState,
                onRunBatch = batchViewModel::execute,
                onRetryBatchFailures = batchViewModel::retryFailures,
                onDismissBatchReceipt = batchViewModel::dismissReceipt,
            )
            SessionWorkspaceModule.Monitor -> if (session.transport == ServerTransportProtocol.telnet.name) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
                ) {
                    Text("Telnet 会话不提供系统监控", style = androidx.compose.material3.MaterialTheme.typography.titleMedium)
                    Text(
                        "系统监控、SFTP 与 Docker 需要经过验证的 SSH 会话。Telnet 仅提供明文终端。",
                        modifier = Modifier.padding(top = 8.dp),
                        color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else MonitorPanel(
                session = session,
                refreshInterval = monitorRefreshInterval,
            )
        }
    }
    customKeyEditorSection?.let { section ->
        TerminalCustomKeyDialog(
            initialSection = section,
            customKeys = uiState.customTerminalKeys,
            onSaveCustomKey = viewModel::saveCustomTerminalKey,
            onDeleteCustomKey = viewModel::deleteCustomTerminalKey,
            onDismiss = { customKeyEditorSection = null },
        )
    }
}

/**
 * Some keyboards and older Android window configurations resize the activity correctly while
 * Compose's IME visibility flag remains false. That made the terminal move above the keyboard but
 * kept its shortcut bar hidden. Combine the platform insets signal with the visible-window height
 * delta so the bar follows the real keyboard on both modern edge-to-edge and adjustResize hosts.
 */
@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun rememberReliableImeVisibility(): Boolean {
    val view = LocalView.current
    val composeImeVisible = WindowInsets.isImeVisible
    var fallbackImeVisible by remember(view) { mutableStateOf(false) }

    DisposableEffect(view) {
        val visibleFrame = Rect()
        val thresholdPixels = (120f * view.resources.displayMetrics.density).toInt()
        var largestVisibleHeight = 0

        val listener = ViewTreeObserver.OnGlobalLayoutListener {
            view.getWindowVisibleDisplayFrame(visibleFrame)
            val visibleHeight = visibleFrame.height().coerceAtLeast(0)
            largestVisibleHeight = maxOf(largestVisibleHeight, visibleHeight)

            val rootBottomGap = (view.rootView.height - visibleFrame.bottom).coerceAtLeast(0)
            val resizedHeightGap = (largestVisibleHeight - visibleHeight).coerceAtLeast(0)
            fallbackImeVisible = rootBottomGap > thresholdPixels || resizedHeightGap > thresholdPixels
        }

        view.viewTreeObserver.addOnGlobalLayoutListener(listener)
        view.post { listener.onGlobalLayout() }
        onDispose {
            if (view.viewTreeObserver.isAlive) {
                view.viewTreeObserver.removeOnGlobalLayoutListener(listener)
            }
        }
    }

    return composeImeVisible || fallbackImeVisible
}

internal data class TerminalSpecialKey(
    val label: String,
    val bytes: ByteArray,
    val id: String = "builtin:$label",
)

internal val terminalSpecialKeys = listOf(
    TerminalSpecialKey("Tab", byteArrayOf(9)),
    TerminalSpecialKey("Ctrl+C", byteArrayOf(3)),
    TerminalSpecialKey("Esc", byteArrayOf(27)),
    TerminalSpecialKey("Ctrl+D", byteArrayOf(4)),
    TerminalSpecialKey("Ctrl+L", byteArrayOf(12)),
    TerminalSpecialKey("Ctrl+U", byteArrayOf(21)),
    TerminalSpecialKey("Enter", byteArrayOf(13)),
    TerminalSpecialKey("←", "\u001B[D".toByteArray()),
    TerminalSpecialKey("↑", "\u001B[A".toByteArray()),
    TerminalSpecialKey("↓", "\u001B[B".toByteArray()),
    TerminalSpecialKey("→", "\u001B[C".toByteArray()),
    TerminalSpecialKey("-", "-".toByteArray()),
    TerminalSpecialKey("+", "+".toByteArray()),
    TerminalSpecialKey("×", "*".toByteArray()),
    TerminalSpecialKey("/", "/".toByteArray()),
    TerminalSpecialKey("|", "|".toByteArray()),
    TerminalSpecialKey("\\", "\\".toByteArray()),
    TerminalSpecialKey("~", "~".toByteArray()),
    TerminalSpecialKey("=", "=".toByteArray()),
    TerminalSpecialKey("_", "_".toByteArray()),
    TerminalSpecialKey("$", "$".toByteArray()),
    TerminalSpecialKey("#", "#".toByteArray()),
    TerminalSpecialKey(";", ";".toByteArray()),
    TerminalSpecialKey(":", ":".toByteArray()),
    TerminalSpecialKey("?", "?".toByteArray()),
)

private val terminalSymbolLabels = setOf("←", "↑", "↓", "→", "-", "+", "×", "/", "|", "\\", "~", "=", "_", "$", "#", ";", ":", "?")

/** Highest explicit-use count first; the base order is retained for ties. */
internal fun orderedTerminalSpecialKeys(
    usageCounts: Map<String, Int>,
    keys: List<TerminalSpecialKey> = terminalSpecialKeys,
): List<TerminalSpecialKey> =
    keys.withIndex()
        .sortedWith(
            compareByDescending<IndexedValue<TerminalSpecialKey>> { usageCounts[it.value.label] ?: 0 }
                .thenBy { it.index },
        )
        .map { it.value }

/** Parses the deliberately small, auditable escape grammar accepted by the custom-key editor. */
internal fun parseTerminalCustomKeyPayload(payload: String): ByteArray? {
    if (payload.isEmpty()) return null
    val result = ArrayList<Byte>(payload.length)
    var index = 0
    while (index < payload.length) {
        val character = payload[index]
        if (character != '\\') {
            result += character.toString().toByteArray(Charsets.UTF_8).toList()
            index += 1
            continue
        }
        if (index + 1 >= payload.length) return null
        when (val escaped = payload[index + 1]) {
            't' -> result += 9
            'r' -> result += 13
            'n' -> result += 10
            'e' -> result += 27
            '\\' -> result += '\\'.code.toByte()
            'x' -> {
                if (index + 3 >= payload.length) return null
                val value = payload.substring(index + 2, index + 4).toIntOrNull(16) ?: return null
                result += value.toByte()
                index += 2
            }
            else -> return null
        }
        index += 2
    }
    return result.toByteArray().takeIf { it.isNotEmpty() && it.size <= 64 }
}

@Composable
private fun TerminalKeyBar(
    modifier: Modifier = Modifier,
    usageCounts: Map<String, Int>,
    customKeys: List<TerminalCustomKey>,
    onSend: (TerminalSpecialKey) -> Unit,
    onPaste: () -> Unit,
    onManageCustomKeys: (TerminalCustomKeySection) -> Unit,
) {
    val keyboardController = LocalSoftwareKeyboardController.current
    var symbolsVisible by rememberSaveable { mutableStateOf(false) }
    val customSpecialKeys = customKeys.mapNotNull { key ->
        parseTerminalCustomKeyPayload(key.payload)?.let { bytes ->
            TerminalSpecialKey(key.label, bytes, id = "custom:${key.id}")
        }
    }
    val orderedCustomKeys = orderedTerminalSpecialKeys(usageCounts, customSpecialKeys)
    val commonKeys = terminalSpecialKeys.filter { it.label !in terminalSymbolLabels } +
        orderedCustomKeys.filter { key ->
            val custom = customKeys.firstOrNull { "custom:${it.id}" == key.id }
            custom?.section == TerminalCustomKeySection.Common
        }
    val symbolKeys = terminalSpecialKeys.filter { it.label in terminalSymbolLabels } + orderedCustomKeys.filter { key ->
        val custom = customKeys.firstOrNull { "custom:${it.id}" == key.id }
        custom?.section == TerminalCustomKeySection.Symbols
    }
    val visibleKeys = if (symbolsVisible) symbolKeys else commonKeys
    Surface(modifier = modifier, tonalElevation = 2.dp) {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            androidx.compose.foundation.layout.Row(
                modifier = Modifier.padding(start = 8.dp, end = 4.dp),
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(4.dp),
            ) {
                AssistChip(onClick = { symbolsVisible = false }, label = { Text("常用") })
                AssistChip(onClick = { symbolsVisible = true }, label = { Text("符号") })
            }
            LazyRow(
                modifier = Modifier.weight(1f).testTag("terminal_keyboard_accessory_keys"),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp, vertical = 4.dp),
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
            ) {
                items(visibleKeys, key = TerminalSpecialKey::id) { key ->
                    AssistChip(onClick = { onSend(key) }, label = { Text(key.label) })
                }
                if (!symbolsVisible) item { AssistChip(onClick = onPaste, label = { Text("粘贴") }) }
                item {
                    AssistChip(
                        onClick = {
                            onManageCustomKeys(
                                if (symbolsVisible) TerminalCustomKeySection.Symbols else TerminalCustomKeySection.Common,
                            )
                        },
                        label = { Text("+") },
                        modifier = Modifier.semantics { contentDescription = "添加自定义终端按键" },
                    )
                }
            }
            IconButton(
                onClick = { keyboardController?.hide() },
                modifier = Modifier
                    .testTag("terminal_keyboard_hide")
                    .semantics { contentDescription = "收起软键盘" },
            ) {
                Icon(Icons.Rounded.KeyboardArrowDown, contentDescription = null)
            }
        }
    }
}

@Composable
private fun TerminalCustomKeyDialog(
    initialSection: TerminalCustomKeySection,
    customKeys: List<TerminalCustomKey>,
    onSaveCustomKey: (String, String, TerminalCustomKeySection) -> Unit,
    onDeleteCustomKey: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var customKeyLabel by remember { mutableStateOf("") }
    var customKeyPayload by remember { mutableStateOf("") }
    var customKeySection by remember(initialSection) { mutableStateOf(initialSection) }
    val parsedPayload = parseTerminalCustomKeyPayload(customKeyPayload)
    val duplicateLabel = terminalSpecialKeys.any { it.label.equals(customKeyLabel.trim(), ignoreCase = true) } ||
        customKeys.any { it.label.equals(customKeyLabel.trim(), ignoreCase = true) }
    OrbitFormDialog(
        title = "自定义终端按键",
        confirmLabel = "添加",
        confirmEnabled = customKeyLabel.isNotBlank() && parsedPayload != null && !duplicateLabel,
        onConfirm = {
            onSaveCustomKey(customKeyLabel, customKeyPayload, customKeySection)
            customKeyLabel = ""
            customKeyPayload = ""
        },
        onDismiss = onDismiss,
    ) {
        Text(
            "自定义内容仅发送到当前终端。支持普通字符以及 \\t、\\r、\\n、\\e、\\xNN；包含 \\r 或 \\n 时可能立即执行命令。",
            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
            style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
        )
        androidx.compose.foundation.layout.Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
            FilterChip(
                selected = customKeySection == TerminalCustomKeySection.Common,
                onClick = { customKeySection = TerminalCustomKeySection.Common },
                label = { Text("常用") },
            )
            FilterChip(
                selected = customKeySection == TerminalCustomKeySection.Symbols,
                onClick = { customKeySection = TerminalCustomKeySection.Symbols },
                label = { Text("符号") },
            )
        }
        OutlinedTextField(
            value = customKeyLabel,
            onValueChange = { customKeyLabel = it.take(16) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            label = { Text("按钮名称") },
            supportingText = if (duplicateLabel) ({ Text("名称不能与现有按键重复") }) else null,
        )
        OutlinedTextField(
            value = customKeyPayload,
            onValueChange = { customKeyPayload = it.take(64) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            label = { Text("发送内容") },
            supportingText = if (customKeyPayload.isNotEmpty() && parsedPayload == null) ({ Text("转义格式无效或内容过长") }) else null,
        )
        if (customKeys.isNotEmpty()) {
            Text("已添加", style = androidx.compose.material3.MaterialTheme.typography.labelLarge)
            customKeys.forEach { key ->
                androidx.compose.foundation.layout.Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                ) {
                    Text(
                        "${key.label} · ${if (key.section == TerminalCustomKeySection.Common) "常用" else "符号"}",
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { onDeleteCustomKey(key.id) }) {
                        Icon(Icons.Rounded.Delete, contentDescription = "删除 ${key.label}")
                    }
                }
            }
        }
    }
}

@Composable
internal fun TerminalReconnectAction(
    reconnecting: Boolean,
    isNetworkUsable: Boolean,
    onReconnect: () -> Unit,
) {
    IconButton(
        onClick = onReconnect,
        enabled = TerminalReconnectPolicy.canReconnect(isNetworkUsable, reconnecting),
        modifier = Modifier
            .testTag("terminal_reconnect_action")
            .semantics {
                contentDescription = TerminalReconnectPolicy.accessibilityLabel(
                    isNetworkUsable = isNetworkUsable,
                    reconnecting = reconnecting,
                )
            },
    ) {
        Icon(Icons.Rounded.Refresh, contentDescription = null)
    }
}

@Composable
internal fun TerminalProcessRecoveryNotice(message: String, onDismiss: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .semantics { contentDescription = "会话恢复提示：$message" },
        shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
        color = androidx.compose.material3.MaterialTheme.colorScheme.secondaryContainer,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            Text(
                text = message,
                modifier = Modifier.weight(1f),
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSecondaryContainer,
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
            )
            TextButton(onClick = onDismiss) { Text("知道了") }
        }
    }
}

@Composable
internal fun TerminalReconnectFailure(message: String) {
    OrbitFeedbackBanner(
        message = message,
        isError = true,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
}

@Composable
private fun ModuleSelector(
    selected: SessionWorkspaceModule,
    onSelected: (SessionWorkspaceModule) -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 3.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
        color = androidx.compose.material3.MaterialTheme.colorScheme.surfaceVariant,
    ) {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier.fillMaxWidth().padding(2.dp),
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(2.dp),
        ) {
            SessionWorkspaceModule.entries.forEach { module ->
                Surface(
                    modifier = Modifier
                        .weight(1f)
                        .height(44.dp)
                        .selectable(
                            selected = selected == module,
                            role = Role.Tab,
                            onClick = { onSelected(module) },
                        )
                        .semantics { contentDescription = "${module.label}模块" },
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(9.dp),
                    color = if (selected == module) androidx.compose.material3.MaterialTheme.colorScheme.primaryContainer
                    else androidx.compose.ui.graphics.Color.Transparent,
                ) {
                    androidx.compose.foundation.layout.Box(contentAlignment = androidx.compose.ui.Alignment.Center) {
                        Text(
                            text = module.label,
                            maxLines = 1,
                            textAlign = TextAlign.Center,
                            color = if (selected == module) androidx.compose.material3.MaterialTheme.colorScheme.onPrimaryContainer
                            else androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                            style = androidx.compose.material3.MaterialTheme.typography.labelMedium,
                        )
                    }
                }
            }
        }
    }
}

private data class QuickCommand(val title: String, val bytes: ByteArray, val description: String)

private val immediateKeys = listOf(
    QuickCommand("Ctrl+C", byteArrayOf(3), "中断当前命令"),
    QuickCommand("Ctrl+D", byteArrayOf(4), "发送 EOF"),
    QuickCommand("Ctrl+L", byteArrayOf(12), "清屏"),
    QuickCommand("Esc", byteArrayOf(27), "取消当前输入"),
    QuickCommand("Tab", byteArrayOf(9), "补全"),
)

@Composable
private fun ShortcutControlsPanel(onSendRaw: (ByteArray) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
    ) {
        item {
            Text(
                "快捷操作只发送终端控制键和常用符号；需要保存、分类、同步或限定资产范围的命令，请使用 Snippets。",
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
        item { Text("终端控制键", style = androidx.compose.material3.MaterialTheme.typography.titleMedium) }
        items(immediateKeys, key = QuickCommand::title) { action ->
            QuickCommandRow(action.title, action.description, onClick = { onSendRaw(action.bytes) })
        }
        item {
            Text(
                "常用符号",
                modifier = Modifier.padding(top = 16.dp),
                style = androidx.compose.material3.MaterialTheme.typography.titleMedium,
            )
        }
        items(terminalSpecialKeys.filter { it.label in terminalSymbolLabels }, key = TerminalSpecialKey::label) { action ->
            QuickCommandRow(action.label, "插入到当前终端", onClick = { onSendRaw(action.bytes) })
        }
    }
}

@Composable
private fun QuickCommandsPanel(
    onExecute: (String) -> Unit,
    onInsert: (String) -> Unit,
    customCommands: List<CustomQuickCommand>,
    error: String?,
    assets: List<com.orbitterm.android.domain.assets.ServerAsset>,
    activeAssetId: String,
    commandHistory: List<String>,
    onAddCustomCommand: (String, String, String, Set<String>) -> Unit,
    onUpdateCustomCommand: (String, String, String, String, Set<String>) -> Unit,
    onDeleteCustomCommand: (String) -> Unit,
    onSaveCommandFromHistory: (String) -> Unit,
    batchState: BatchCommandUiState,
    onRunBatch: (String, Set<String>) -> Unit,
    onRetryBatchFailures: () -> Unit,
    onDismissBatchReceipt: () -> Unit,
) {
    var addDialogVisible by rememberSaveable { mutableStateOf(false) }
    var editingCommand by androidx.compose.runtime.remember { mutableStateOf<CustomQuickCommand?>(null) }
    var draftTitle by rememberSaveable { mutableStateOf("") }
    var draftCommand by rememberSaveable { mutableStateOf("") }
    var draftCategory by rememberSaveable { mutableStateOf("未分类") }
    var draftAllowedAssetIds by rememberSaveable { mutableStateOf(setOf<String>()) }
    var selectedCategory by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    var deletionTarget by androidx.compose.runtime.remember { mutableStateOf<CustomQuickCommand?>(null) }
    var variablePrompt by androidx.compose.runtime.remember { mutableStateOf<SnippetVariablePrompt?>(null) }
    var batchPrompt by androidx.compose.runtime.remember { mutableStateOf<SnippetBatchPrompt?>(null) }
    fun useSnippet(snippet: CustomQuickCommand, mode: SnippetUseMode) {
        val keys = CommandSnippetTemplate.variables(snippet.command)
        if (keys.isEmpty()) {
            when (mode) {
                SnippetUseMode.Insert -> onInsert(snippet.command)
                SnippetUseMode.Execute -> onExecute(snippet.command)
                SnippetUseMode.Batch -> batchPrompt = SnippetBatchPrompt.from(snippet)
            }
        } else {
            variablePrompt = SnippetVariablePrompt(snippet, mode, keys.associateWith { "" })
        }
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
    ) {
        if (commandHistory.isNotEmpty()) {
            item { Text("最近命令", style = androidx.compose.material3.MaterialTheme.typography.titleMedium) }
            items(commandHistory.take(12), key = { "history-$it" }) { command ->
                QuickCommandRow(
                    title = command,
                    description = "点按插入；可保存为命令片段",
                    onClick = { onInsert(command) },
                    trailingAction = { TextButton(onClick = { onSaveCommandFromHistory(command) }) { Text("保存") } },
                )
            }
        }
        item {
            Text(
                "命令片段",
                modifier = Modifier.padding(top = 16.dp),
                style = androidx.compose.material3.MaterialTheme.typography.titleMedium,
            )
        }
        item {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                label = { Text("搜索命令片段") },
                placeholder = { Text("标题、命令或分类") },
            )
        }
        val categories = customCommands.map { it.category.ifBlank { "未分类" } }.distinct().sorted()
        if (categories.isNotEmpty()) {
            item {
                LazyRow(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
                    item {
                        FilterChip(
                            selected = selectedCategory == null,
                            onClick = { selectedCategory = null },
                            label = { Text("全部") },
                        )
                    }
                    items(categories, key = { it }) { category ->
                        FilterChip(
                            selected = selectedCategory == category,
                            onClick = { selectedCategory = category },
                            label = { Text(category) },
                        )
                    }
                }
            }
        }
        val normalizedQuery = query.trim()
        val visibleCustomCommands = customCommands
            .asSequence()
            .filter { command ->
                (command.allowedAssetIds.isEmpty() || activeAssetId in command.allowedAssetIds) &&
                    (selectedCategory == null || command.category.ifBlank { "未分类" } == selectedCategory)
            }
            .filter { command ->
                normalizedQuery.isBlank() || listOf(command.title, command.command, command.category)
                    .any { it.contains(normalizedQuery, ignoreCase = true) }
            }
            .sortedByDescending(CustomQuickCommand::updatedAtUnix)
            .toList()
        if (visibleCustomCommands.isEmpty()) {
            item {
                Text(
                    if (normalizedQuery.isBlank()) "暂无自定义指令" else "未找到匹配的命令片段",
                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            visibleCustomCommands
                .groupBy { it.category.ifBlank { "未分类" } }
                .toSortedMap(String.CASE_INSENSITIVE_ORDER)
                .forEach { (category, commands) ->
                    item(key = "snippet-category-$category") {
                        Text(
                            category,
                            modifier = Modifier.padding(top = 12.dp),
                            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                            style = androidx.compose.material3.MaterialTheme.typography.labelLarge,
                        )
                    }
                    items(commands, key = CustomQuickCommand::id) { command ->
                        QuickCommandRow(
                            title = command.title,
                            description = buildString {
                                if (command.allowedAssetIds.isNotEmpty()) append("限 ${command.allowedAssetIds.size} 台 · ")
                                append(command.command)
                            },
                            onClick = { useSnippet(command, SnippetUseMode.Insert) },
                            trailingAction = {
                                androidx.compose.foundation.layout.Row {
                                    TextButton(onClick = { useSnippet(command, SnippetUseMode.Execute) }) { Text("执行") }
                                    TextButton(onClick = { useSnippet(command, SnippetUseMode.Batch) }) { Text("批量") }
                                    IconButton(onClick = {
                                        editingCommand = command
                                        draftTitle = command.title
                                        draftCommand = command.command
                                        draftCategory = command.category
                                        draftAllowedAssetIds = command.allowedAssetIds
                                    }) {
                                        Icon(Icons.Rounded.Edit, contentDescription = "编辑 ${command.title}")
                                    }
                                    IconButton(onClick = { deletionTarget = command }) {
                                        Icon(Icons.Rounded.Delete, contentDescription = "删除 ${command.title}")
                                    }
                                }
                            }
                        )
                    }
                }
        }
        item {
            TextButton(onClick = { addDialogVisible = true }) {
                Icon(Icons.Rounded.Add, contentDescription = null)
                Text("添加快捷指令")
            }
        }
        error?.let { message ->
            item { Text(message, color = androidx.compose.material3.MaterialTheme.colorScheme.error) }
        }
    }
    if (addDialogVisible || editingCommand != null) {
        val editing = editingCommand
        OrbitFormDialog(
            title = if (editing == null) "新增快捷指令" else "编辑快捷指令",
            confirmLabel = "保存",
            confirmEnabled = draftTitle.isNotBlank() && draftCommand.isNotBlank(),
            onConfirm = {
                if (editing == null) onAddCustomCommand(draftTitle, draftCommand, draftCategory, draftAllowedAssetIds)
                else onUpdateCustomCommand(editing.id, draftTitle, draftCommand, draftCategory, draftAllowedAssetIds)
                draftTitle = ""
                draftCommand = ""
                draftCategory = "未分类"
                draftAllowedAssetIds = emptySet()
                addDialogVisible = false
                editingCommand = null
            },
            onDismiss = {
                addDialogVisible = false
                editingCommand = null
                draftTitle = ""
                draftCommand = ""
                draftCategory = "未分类"
                draftAllowedAssetIds = emptySet()
            },
        ) {
            OutlinedTextField(value = draftTitle, onValueChange = { draftTitle = it }, modifier = Modifier.fillMaxWidth(), label = { Text("标题") })
            OutlinedTextField(value = draftCommand, onValueChange = { draftCommand = it }, modifier = Modifier.fillMaxWidth(), label = { Text("命令") })
            OutlinedTextField(value = draftCategory, onValueChange = { draftCategory = it }, modifier = Modifier.fillMaxWidth(), label = { Text("分类") })
            Text("适用资产（不选择表示全部）", style = androidx.compose.material3.MaterialTheme.typography.labelMedium)
            LazyRow(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(6.dp)) {
                items(assets, key = { it.id }) { asset ->
                    FilterChip(
                        selected = asset.id in draftAllowedAssetIds,
                        onClick = {
                            draftAllowedAssetIds = if (asset.id in draftAllowedAssetIds) draftAllowedAssetIds - asset.id
                            else draftAllowedAssetIds + asset.id
                        },
                        label = { Text(asset.name) },
                    )
                }
            }
        }
    }
    deletionTarget?.let { command ->
        OrbitConfirmationDialog(
            title = "删除命令片段？",
            message = "将删除“${command.title}”。该操作无法撤销，并会在当前已解锁账户中同步到其他设备。",
            confirmLabel = "删除",
            onConfirm = { onDeleteCustomCommand(command.id); deletionTarget = null },
            onDismiss = { deletionTarget = null },
            destructive = true,
        )
    }
    variablePrompt?.let { prompt ->
        OrbitFormDialog(
            title = "填写命令变量",
            confirmLabel = when (prompt.mode) {
                SnippetUseMode.Insert -> "插入"
                SnippetUseMode.Execute -> "执行"
                SnippetUseMode.Batch -> "选择目标"
            },
            onConfirm = {
                val resolved = CommandSnippetTemplate.resolve(prompt.snippet.command, prompt.values)
                when (prompt.mode) {
                    SnippetUseMode.Insert -> onInsert(resolved)
                    SnippetUseMode.Execute -> onExecute(resolved)
                    SnippetUseMode.Batch -> batchPrompt = SnippetBatchPrompt.from(prompt.snippet, resolved)
                }
                variablePrompt = null
            },
            onDismiss = { variablePrompt = null },
        ) {
            Text("检测到变量占位符，请填写后继续。")
            prompt.values.keys.sorted().forEach { key ->
                OutlinedTextField(
                    value = prompt.values[key].orEmpty(),
                    onValueChange = { value -> variablePrompt = prompt.copy(values = prompt.values + (key to value)) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(key) },
                )
            }
        }
    }
    batchPrompt?.let { prompt ->
        val eligibleAssets = assets.filter { asset ->
            AndroidTransportSupportPolicy.allowsCheckedConnection(asset.transport) &&
                (prompt.allowedAssetIds.isEmpty() || asset.id in prompt.allowedAssetIds)
        }
        val groupedAssets = eligibleAssets.groupBy { it.group.ifBlank { "未分组" } }
            .toSortedMap(String.CASE_INSENSITIVE_ORDER)
        OrbitFormDialog(
            title = "批量执行 · ${prompt.title}",
            confirmLabel = if (batchState.running) "执行中…" else "执行",
            confirmEnabled = prompt.selectedAssetIds.isNotEmpty() && !batchState.running,
            dismissEnabled = !batchState.running,
            onConfirm = {
                onRunBatch(prompt.command, prompt.selectedAssetIds)
                batchPrompt = null
            },
            onDismiss = { batchPrompt = null },
        ) {
            Text(
                "可同时选择多个分组或单台资产。仅通过当前已验证 SSH 会话执行，并按资产隔离回执。",
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
            )
            if (eligibleAssets.isEmpty()) {
                Text("没有符合此片段范围的 SSH 资产。")
            } else {
                LazyColumn(modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp)) {
                    groupedAssets.forEach { (group, groupAssets) ->
                        val groupIds = groupAssets.mapTo(linkedSetOf()) { it.id }
                        item(key = "batch-snippet-group-$group") {
                            val allSelected = groupIds.all { it in prompt.selectedAssetIds }
                            androidx.compose.foundation.layout.Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        batchPrompt = prompt.copy(
                                            selectedAssetIds = if (allSelected) prompt.selectedAssetIds - groupIds
                                            else prompt.selectedAssetIds + groupIds,
                                        )
                                    }
                                    .padding(vertical = 6.dp),
                                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                            ) {
                                Checkbox(checked = allSelected, onCheckedChange = null)
                                Text("$group（${groupAssets.size}）", style = androidx.compose.material3.MaterialTheme.typography.labelLarge)
                            }
                        }
                        items(groupAssets, key = { "batch-snippet-asset-${it.id}" }) { asset ->
                            val selected = asset.id in prompt.selectedAssetIds
                            androidx.compose.foundation.layout.Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        batchPrompt = prompt.copy(
                                            selectedAssetIds = if (selected) prompt.selectedAssetIds - asset.id
                                            else prompt.selectedAssetIds + asset.id,
                                        )
                                    }
                                    .padding(start = 22.dp, top = 4.dp, bottom = 4.dp),
                                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                            ) {
                                Checkbox(checked = selected, onCheckedChange = null)
                                Text(asset.name)
                            }
                        }
                    }
                }
            }
        }
    }
    if (batchState.running || batchState.receipts.isNotEmpty() || batchState.error != null) {
        AlertDialog(
            onDismissRequest = { if (!batchState.running) onDismissBatchReceipt() },
            title = { Text("Snippet 批量执行回执") },
            text = {
                Column(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
                ) {
                    if (batchState.running) {
                        CircularProgressIndicator()
                        Text("正在按资产顺序安全执行…")
                    }
                    batchState.error?.let { Text(it, color = androidx.compose.material3.MaterialTheme.colorScheme.error) }
                    batchState.receipts.forEach { receipt ->
                        Text("${receipt.name} · ${if (receipt.succeeded) "成功" else "失败"}", style = androidx.compose.material3.MaterialTheme.typography.labelLarge)
                        Text(
                            (receipt.stdout + receipt.stderr).ifBlank { receipt.errorCode ?: "（无输出）" },
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            },
            confirmButton = {
                if (batchState.failureCount > 0 && !batchState.running) {
                    TextButton(onClick = onRetryBatchFailures) { Text("重试失败项") }
                }
            },
            dismissButton = {
                TextButton(onClick = onDismissBatchReceipt, enabled = !batchState.running) { Text("完成") }
            },
        )
    }
}

private enum class SnippetUseMode { Insert, Execute, Batch }

private data class SnippetVariablePrompt(
    val snippet: CustomQuickCommand,
    val mode: SnippetUseMode,
    val values: Map<String, String>,
)

private data class SnippetBatchPrompt(
    val title: String,
    val command: String,
    val allowedAssetIds: Set<String>,
    val selectedAssetIds: Set<String> = emptySet(),
) {
    companion object {
        fun from(snippet: CustomQuickCommand, resolvedCommand: String = snippet.command) = SnippetBatchPrompt(
            title = snippet.title,
            command = resolvedCommand,
            allowedAssetIds = snippet.allowedAssetIds,
        )
    }
}

// Both closing braces must be literal. Escaping them also keeps this portable across
// Android's ICU regex engine and the JVM implementation used by unit tests.
@Composable
private fun QuickCommandRow(
    title: String,
    description: String,
    onClick: () -> Unit,
    trailingAction: @Composable (() -> Unit)? = null,
) {
    androidx.compose.material3.ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(description) },
        trailingContent = trailingAction,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .clickable(onClick = onClick),
    )
}
