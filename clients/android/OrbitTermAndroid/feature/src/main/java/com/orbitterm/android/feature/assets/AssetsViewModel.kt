package com.orbitterm.android.feature.assets

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.core.CheckedSshConnectResult
import com.orbitterm.android.core.CheckedSshNativeClient
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.assets.NetworkDeviceProfile
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.ServerAuthMethod
import com.orbitterm.android.domain.assets.ServerCredentials
import com.orbitterm.android.domain.assets.JumpHostConfiguration
import com.orbitterm.android.domain.assets.ServerTransportProtocol
import com.orbitterm.android.domain.assets.AndroidTransportSupportPolicy
import com.orbitterm.android.domain.session.BlockReason
import com.orbitterm.android.domain.session.ConnectionError
import com.orbitterm.android.domain.session.ConnectionPhase
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.orbitNativeError
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.security.SecureCredentialStore
import com.orbitterm.android.data.repository.AssetMutationRepository
import com.orbitterm.android.domain.sync.SyncRequester
import com.orbitterm.android.domain.deeplink.ServerDeepLink
import com.orbitterm.android.core.OperationScopeCoordinator
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID
import java.net.InetSocketAddress
import java.net.Socket
import javax.inject.Inject

data class AssetsUiState(
    val assets: List<ServerAsset> = emptyList(),
    val editor: AssetEditorUiState? = null,
    val connection: AssetConnectionUiState? = null,
    val operationError: String? = null,
    val activeAssetIds: Set<String> = emptySet(),
    /** Mirrors iOS: groups are collapsed until the user explicitly expands them. */
    val expandedGroups: Set<String> = emptySet(),
    val bulkImport: AssetBulkImportUiState = AssetBulkImportUiState(),
)

data class AssetBulkImportUiState(
    val isVisible: Boolean = false,
    val rawInput: String = "",
    val isImporting: Boolean = false,
    val summary: String? = null,
    val issues: List<AssetBulkImportIssue> = emptyList(),
)

data class AssetConnectionUiState(
    val assetId: String,
    val phase: ConnectionPhase,
    val hostKeyChallenge: CheckedSshConnectResult.HostKeyChallenge? = null,
    val baseSessionId: Long? = null,
    val transport: ServerTransportProtocol = ServerTransportProtocol.ssh,
)

data class AssetEditorUiState(
    val id: String,
    val credentialID: String,
    val isNew: Boolean,
    val createdAtUnix: Long,
    val name: String = "",
    val group: String = "",
    val tags: String = "",
    val host: String = "",
    val port: String = "22",
    val username: String = "",
    val authMethod: ServerAuthMethod = ServerAuthMethod.password,
    val transport: ServerTransportProtocol = ServerTransportProtocol.ssh,
    val networkDeviceProfile: NetworkDeviceProfile = NetworkDeviceProfile.auto,
    val allowPasswordFallback: Boolean = false,
    val password: String = "",
    val privateKeyContent: String = "",
    val privateKeyPassphrase: String = "",
    val isJumpHostEnabled: Boolean = false,
    val jumpCredentialID: String = "",
    val jumpHost: String = "",
    val jumpPort: String = "22",
    val jumpUsername: String = "",
    val jumpAuthMethod: ServerAuthMethod = ServerAuthMethod.password,
    val jumpAllowPasswordFallback: Boolean = false,
    val jumpPassword: String = "",
    val jumpPrivateKeyContent: String = "",
    val jumpPrivateKeyPassphrase: String = "",
    val isSaving: Boolean = false,
    val isDeleting: Boolean = false,
    val deleteConfirmationVisible: Boolean = false,
    val connectionTest: AssetConnectionUiState? = null,
    val validationError: String? = null,
)

@HiltViewModel
class AssetsViewModel @Inject constructor(
    private val assetRepository: AssetRepository,
    private val credentialStore: SecureCredentialStore,
    private val assetMutations: AssetMutationRepository,
    private val checkedSshNativeClient: CheckedSshNativeClient,
    private val terminalSessionController: TerminalSessionController,
    private val accountScopeController: ActiveAccountScopeProvider,
    private val syncRequests: SyncRequester,
    private val operations: OperationScopeCoordinator,
) : ViewModel() {
    private val editor = MutableStateFlow<AssetEditorUiState?>(null)
    private val connection = MutableStateFlow<AssetConnectionUiState?>(null)
    private val operationError = MutableStateFlow<String?>(null)
    private val expandedGroups = MutableStateFlow<Set<String>>(emptySet())
    private val bulkImport = MutableStateFlow(AssetBulkImportUiState())
    private val activeAssetIds = terminalSessionController.activeSessions
        .map { sessions -> sessions.mapTo(linkedSetOf()) { it.assetId } }
        .distinctUntilChanged()
    private val listPresentation = combine(activeAssetIds, expandedGroups, bulkImport) { activeIds, expanded, bulk ->
        AssetListPresentation(activeIds, expanded, bulk)
    }

    val uiState: StateFlow<AssetsUiState> = combine(
        assetRepository.observeAssets(), editor, connection, operationError, listPresentation,
    ) {
            assets,
            editorState,
            connectionState,
            operationError,
            presentation,
        ->
        AssetsUiState(
            assets = assets,
            editor = editorState,
            connection = connectionState,
            operationError = operationError,
            activeAssetIds = presentation.activeAssetIds,
            expandedGroups = presentation.expandedGroups,
            bulkImport = presentation.bulkImport,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = AssetsUiState(),
    )

    fun createAsset() {
        val scope = accountScopeController.scope.value ?: return
        val id = UUID.randomUUID().toString()
        editor.value = AssetEditorUiState(
            id = id,
            credentialID = "${scope.storageId}:$id",
            jumpCredentialID = "${scope.storageId}:$id:jump",
            isNew = true,
            createdAtUnix = System.currentTimeMillis() / 1_000,
        )
    }

    /** A link can only prefill an editor; the user still reviews and saves it. */
    fun openDeepLink(link: ServerDeepLink, onReviewReady: () -> Unit) {
        val scope = accountScopeController.scope.value ?: return
        val existing = uiState.value.assets.firstOrNull {
            it.host == link.host && it.port == link.port && it.username == link.username
        }
        if (existing != null) {
            loadAssetEditor(existing.id, onReviewReady)
            return
        }
        val id = UUID.randomUUID().toString()
        editor.value = AssetEditorUiState(
            id = id,
            credentialID = "${scope.storageId}:$id",
            jumpCredentialID = "${scope.storageId}:$id:jump",
            isNew = true,
            createdAtUnix = System.currentTimeMillis() / 1_000,
            name = link.suggestedName,
            host = link.host,
            port = link.port.toString(),
            username = link.username,
        )
        onReviewReady()
    }

    fun editAsset(id: String) {
        loadAssetEditor(id)
    }

    private fun loadAssetEditor(id: String, onReady: () -> Unit = {}) {
        viewModelScope.launch {
            val asset = withContext(Dispatchers.IO) { assetRepository.findAsset(id) } ?: return@launch
            val credentials = withContext(Dispatchers.IO) {
                credentialStore.read(asset.credentialID) ?: ServerCredentials()
            }
            val jumpCredentials = asset.jumpHost?.let { jump ->
                withContext(Dispatchers.IO) { credentialStore.read(jump.credentialID) ?: ServerCredentials() }
            }
            editor.value = asset.toEditorState(credentials, jumpCredentials)
            onReady()
        }
    }

    fun updateEditor(transform: (AssetEditorUiState) -> AssetEditorUiState) {
        editor.value = editor.value?.let(transform)?.copy(connectionTest = null)
    }

    fun toggleGroupExpansion(group: String) {
        expandedGroups.value = expandedGroups.value.let { current ->
            if (group in current) current - group else current + group
        }
    }

    /** File contents remain transient in the editor and are encrypted only on save. */
    fun importPrivateKey(contents: String) {
        val normalized = contents.trim()
        val error = when {
            normalized.isBlank() -> "私钥文件为空。"
            normalized.length > MAX_PRIVATE_KEY_CHARS -> "私钥文件过大。"
            !normalized.contains("PRIVATE KEY") -> "所选文件不是受支持的私钥。"
            else -> null
        }
        editor.value = editor.value?.let { current ->
            current.copy(
                authMethod = ServerAuthMethod.key,
                privateKeyContent = if (error == null) normalized else current.privateKeyContent,
                validationError = error,
            )
        }
    }

    fun reportEditorError(message: String) {
        editor.value = editor.value?.copy(validationError = message)
    }

    fun cancelEditor() {
        editor.value?.connectionTest?.hostKeyChallenge?.let { challenge ->
            viewModelScope.launch(Dispatchers.IO) { checkedSshNativeClient.rejectChallenge(challenge.challengeId) }
        }
        editor.value?.let { operations.invalidate("asset_editor_test", it.id) }
        editor.value = null
    }

    fun testEditorConnection(telnetEnabled: Boolean = false) {
        val draft = editor.value ?: return
        if (draft.connectionTest?.phase is ConnectionPhase.Connecting) return
        val validationError = draft.validationError(telnetEnabled)
        if (validationError != null) {
            editor.value = draft.copy(validationError = validationError, connectionTest = null)
            return
        }
        val operation = operations.begin("asset_editor_test", draft.id) ?: return
        editor.value = draft.copy(
            validationError = null,
            connectionTest = AssetConnectionUiState(draft.id, ConnectionPhase.Connecting),
        )
        viewModelScope.launch {
            val result = if (draft.transport == ServerTransportProtocol.telnet) {
                withContext(Dispatchers.IO) {
                    runCatching {
                        Socket().use { socket ->
                            socket.connect(InetSocketAddress(draft.host, draft.port.toInt()), 8_000)
                        }
                        AssetConnectionUiState(draft.id, ConnectionPhase.Connected, transport = ServerTransportProtocol.telnet)
                    }.getOrElse {
                        AssetConnectionUiState(
                            draft.id,
                            ConnectionPhase.Failed(ConnectionError.NetworkUnavailable, retryable = true),
                            transport = ServerTransportProtocol.telnet,
                        )
                    }
                }
            } else withContext(Dispatchers.IO) {
                checkedSshNativeClient.connect(
                    draft.toAsset(),
                    draft.toCredentials(),
                    draft.toJumpHostCredentials(),
                ).also { connected ->
                    if (connected is CheckedSshConnectResult.Connected) {
                        checkedSshNativeClient.disconnect(connected.baseSessionId)
                    }
                }.toConnectionUiState(draft.id)
            }
            if (!operations.isCurrent(operation) || editor.value?.id != draft.id) return@launch
            editor.value = editor.value?.copy(connectionTest = result)
        }
    }

    fun trustEditorHostKeyAndRetest() {
        val draft = editor.value ?: return
        val challenge = draft.connectionTest?.hostKeyChallenge ?: return
        val operation = operations.begin("asset_editor_test", draft.id) ?: return
        viewModelScope.launch {
            val failure = withContext(Dispatchers.IO) {
                checkedSshNativeClient.trustChallenge(challenge.challengeId)
            }
            if (!operations.isCurrent(operation) || editor.value?.id != draft.id) return@launch
            if (failure == null) {
                testEditorConnection(telnetEnabled = false)
            } else {
                editor.value = editor.value?.copy(connectionTest = failure.toConnectionUiState(draft.id))
            }
        }
    }

    fun dismissEditorConnectionTest() {
        val draft = editor.value ?: return
        operations.invalidate("asset_editor_test", draft.id)
        draft.connectionTest?.hostKeyChallenge?.let { challenge ->
            viewModelScope.launch(Dispatchers.IO) { checkedSshNativeClient.rejectChallenge(challenge.challengeId) }
        }
        editor.value = draft.copy(connectionTest = null)
    }

    fun dismissOperationError() {
        operationError.value = null
    }

    fun showBulkImport() {
        bulkImport.value = AssetBulkImportUiState(isVisible = true)
    }

    fun updateBulkImportInput(value: String) {
        if (value.length > AssetBulkImportParser.MAX_INPUT_CHARS) return
        bulkImport.value = bulkImport.value.copy(rawInput = value, summary = null, issues = emptyList())
    }

    fun dismissBulkImport() {
        if (bulkImport.value.isImporting) return
        operations.invalidate("asset_bulk_import", "active")
        bulkImport.value = AssetBulkImportUiState()
    }

    fun importBulkAssets() {
        val state = bulkImport.value
        if (state.isImporting) return
        val scope = accountScopeController.scope.value ?: return
        val parsed = AssetBulkImportParser.parse(state.rawInput)
        if (parsed.rows.isEmpty()) {
            bulkImport.value = state.copy(
                summary = "没有可导入的有效 SSH 资产。",
                issues = parsed.issues,
            )
            return
        }
        val operation = operations.begin("asset_bulk_import", "active") ?: return
        bulkImport.value = state.copy(isImporting = true, summary = null, issues = parsed.issues)
        viewModelScope.launch {
            val existingKeys = uiState.value.assets.mapTo(mutableSetOf()) { it.endpointImportKey() }
            val seenKeys = mutableSetOf<String>()
            var imported = 0
            var skipped = 0
            var failed = 0
            val runtimeIssues = parsed.issues.toMutableList()
            withContext(Dispatchers.IO) {
                parsed.rows.forEach { row ->
                    if (!operations.isCurrent(operation)) return@withContext
                    val importKey = "${row.username.lowercase()}@${row.host.lowercase()}:${row.port}"
                    if (importKey in existingKeys || !seenKeys.add(importKey)) {
                        skipped++
                        runtimeIssues += AssetBulkImportIssue(row.lineNumber, "与已有资产或本次其他记录重复，已跳过。")
                        return@forEach
                    }
                    val id = UUID.randomUUID().toString()
                    val credentialId = "${scope.storageId}:$id"
                    val asset = ServerAsset(
                        id = id,
                        credentialID = credentialId,
                        name = row.name,
                        group = row.group,
                        tags = row.tags,
                        host = row.host,
                        port = row.port,
                        username = row.username,
                        authMethod = row.authMethod.name,
                        transport = ServerTransportProtocol.ssh.name,
                        networkDeviceProfile = NetworkDeviceProfile.auto.name,
                        allowPasswordFallback = row.authMethod == ServerAuthMethod.key && row.password.isNotBlank(),
                        jumpHost = null,
                        createdAtUnix = System.currentTimeMillis() / 1_000,
                    )
                    val credentials = ServerCredentials(
                        password = row.password,
                        privateKeyContent = row.privateKeyContent,
                    )
                    runCatching { assetMutations.save(asset, credentials) }
                        .onSuccess { imported++; existingKeys += importKey }
                        .onFailure {
                            failed++
                            runtimeIssues += AssetBulkImportIssue(row.lineNumber, "安全保存失败，请单独检查此行。")
                        }
                }
            }
            if (!operations.isCurrent(operation)) return@launch
            if (imported > 0) syncRequests.requestSync()
            bulkImport.value = bulkImport.value.copy(
                isImporting = false,
                summary = "已导入 $imported 项，跳过 $skipped 项，失败 $failed 项。",
                issues = runtimeIssues,
            )
        }
    }

    fun connectAsset(id: String, telnetEnabled: Boolean = false) {
        if (connection.value?.phase is ConnectionPhase.Connecting) return
        val operation = operations.begin("ssh_connect", id) ?: return
        viewModelScope.launch {
            val asset = withContext(Dispatchers.IO) { assetRepository.findAsset(id) } ?: return@launch
            if (!operations.isCurrent(operation)) return@launch
            if (!AndroidTransportSupportPolicy.allowsCheckedConnection(asset.transport, telnetEnabled)) {
                if (operations.isCurrent(operation)) connection.value = AssetConnectionUiState(
                    assetId = id, phase = ConnectionPhase.Blocked(BlockReason.UnsupportedTransport),
                )
                return@launch
            }
            if (asset.transport == ServerTransportProtocol.telnet.name) {
                connection.value = AssetConnectionUiState(
                    id,
                    ConnectionPhase.Connected,
                    transport = ServerTransportProtocol.telnet,
                )
                return@launch
            }
            val credentials = withContext(Dispatchers.IO) {
                credentialStore.read(asset.credentialID) ?: ServerCredentials()
            }
            val jumpCredentials = asset.jumpHost?.let { jump ->
                withContext(Dispatchers.IO) { credentialStore.read(jump.credentialID) }
            }
            if (!operations.isCurrent(operation)) return@launch
            connection.value = AssetConnectionUiState(id, ConnectionPhase.Connecting)
            val result = withContext(Dispatchers.IO) {
                checkedSshNativeClient.connect(asset, credentials, jumpCredentials)
            }
            if (operations.isCurrent(operation)) connection.value = result.toConnectionUiState(id)
        }
    }

    fun trustHostKeyAndReconnect() {
        val current = connection.value ?: return
        val challenge = current.hostKeyChallenge ?: return
        val operation = operations.begin("host_key", current.assetId) ?: return
        connection.value = current.copy(phase = ConnectionPhase.AwaitingHostKeyDecision)
        viewModelScope.launch {
            val failure = withContext(Dispatchers.IO) { checkedSshNativeClient.trustChallenge(challenge.challengeId) }
            if (!operations.isCurrent(operation)) return@launch
            if (failure == null) {
                connectAsset(current.assetId)
            } else {
                connection.value = failure.toConnectionUiState(current.assetId)
            }
        }
    }

    fun dismissConnectionPrompt() {
        val current = connection.value
        current?.let { operations.invalidate("ssh_connect", it.assetId); operations.invalidate("host_key", it.assetId) }
        connection.value = null
        when {
            current?.hostKeyChallenge != null -> viewModelScope.launch(Dispatchers.IO) {
                checkedSshNativeClient.rejectChallenge(current.hostKeyChallenge.challengeId)
            }
            current?.baseSessionId != null -> viewModelScope.launch(Dispatchers.IO) {
                checkedSshNativeClient.disconnect(current.baseSessionId)
            }
        }
    }

    fun openTerminal(onOpened: () -> Unit) {
        val current = connection.value ?: return
        val asset = uiState.value.assets.firstOrNull { it.id == current.assetId } ?: return
        val operation = operations.begin("terminal_open", asset.id) ?: return
        viewModelScope.launch {
            val opened = if (asset.transport == ServerTransportProtocol.telnet.name) {
                val credentials = withContext(Dispatchers.IO) {
                    credentialStore.read(asset.credentialID) ?: ServerCredentials()
                }
                terminalSessionController.openTelnet(asset, credentials)
            } else {
                val baseSessionId = current.baseSessionId ?: return@launch
                terminalSessionController.open(
                    assetId = asset.id,
                    displayName = asset.name,
                    baseSessionId = baseSessionId,
                    shouldAttach = { operations.isCurrent(operation) },
                )
            }
            if (!operations.isCurrent(operation)) return@launch
            if (opened) {
                connection.value = null
                onOpened()
            } else {
                connection.value = current.copy(
                    phase = ConnectionPhase.Failed(
                        error = ConnectionError.Unknown,
                        retryable = true,
                    ),
                )
            }
        }
    }

    fun requestDelete() {
        editor.value = editor.value?.takeUnless { it.isNew || it.isSaving || it.isDeleting }?.copy(
            deleteConfirmationVisible = true,
            validationError = null,
        )
    }

    fun dismissDeleteConfirmation() {
        editor.value = editor.value?.copy(deleteConfirmationVisible = false)
    }

    fun confirmDelete() {
        val draft = editor.value ?: return
        if (draft.isNew || draft.isSaving || draft.isDeleting) return

        editor.value = draft.copy(isDeleting = true, deleteConfirmationVisible = false, validationError = null)
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    assetMutations.delete(draft.toAsset())
                }
            }.onSuccess {
                editor.value = null
                syncRequests.requestSync()
            }.onFailure {
                editor.value = draft.copy(
                    isDeleting = false,
                    deleteConfirmationVisible = false,
                    validationError = "删除失败，请稍后重试。",
                )
            }
        }
    }

    /** Deletes metadata and the corresponding encrypted credential as one user-confirmed operation. */
    fun deleteAssets(assetIds: Set<String>) {
        if (assetIds.isEmpty()) return
        viewModelScope.launch {
            val targets = uiState.value.assets.filter { it.id in assetIds }
            runCatching {
                withContext(Dispatchers.IO) {
                    targets.forEach { asset ->
                        assetMutations.delete(asset)
                    }
                }
            }.onSuccess { syncRequests.requestSync() }
                .onFailure { operationError.value = "批量删除失败，请稍后重试。" }
        }
    }

    /** Renames every asset in the group, including assets hidden by an active search filter. */
    fun renameGroup(currentGroup: String, requestedName: String) {
        val normalizedCurrent = currentGroup.takeUnless { it == "未分组" }.orEmpty()
        val normalizedRequested = requestedName.trim()
        if (normalizedCurrent == normalizedRequested) return
        viewModelScope.launch {
            val targets = uiState.value.assets.filter { it.group == normalizedCurrent }
            runCatching {
                withContext(Dispatchers.IO) {
                    targets.forEach { asset -> assetMutations.saveMetadataAndQueue(asset.copy(group = normalizedRequested)) }
                }
            }.onSuccess { syncRequests.requestSync() }
                .onFailure { operationError.value = "重命名分组失败，请稍后重试。" }
        }
    }

    /** Deletes all assets and encrypted credentials in one explicitly confirmed group operation. */
    fun deleteGroup(group: String) {
        if (group == "未分组") return
        viewModelScope.launch {
            val targets = uiState.value.assets.filter { it.group == group }
            runCatching {
                withContext(Dispatchers.IO) {
                    targets.forEach { asset ->
                        assetMutations.delete(asset)
                    }
                }
            }.onSuccess { syncRequests.requestSync() }
                .onFailure { operationError.value = "删除分组失败，请稍后重试。" }
        }
    }

    fun saveEditor(telnetEnabled: Boolean = false) {
        val draft = editor.value ?: return
        val validationError = draft.validationError(telnetEnabled)
        if (validationError != null) {
            editor.value = draft.copy(validationError = validationError)
            return
        }

        editor.value = draft.copy(isSaving = true, validationError = null)
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    assetMutations.save(draft.toAsset(), draft.toCredentials(), draft.toJumpHostCredentials())
                }
            }.onSuccess {
                editor.value = null
                syncRequests.requestSync()
            }.onFailure {
                editor.value = draft.copy(
                    isSaving = false,
                    validationError = "保存失败，请稍后重试。",
                )
            }
        }
    }
}

private data class AssetListPresentation(
    val activeAssetIds: Set<String>,
    val expandedGroups: Set<String>,
    val bulkImport: AssetBulkImportUiState,
)

private fun ServerAsset.toEditorState(
    credentials: ServerCredentials,
    jumpCredentials: ServerCredentials?,
): AssetEditorUiState = AssetEditorUiState(
    id = id,
    credentialID = credentialID,
    isNew = false,
    createdAtUnix = createdAtUnix,
    name = name,
    group = group,
    tags = tags.joinToString(", "),
    host = host,
    port = port.toString(),
    username = username,
    authMethod = enumValueOrDefault(authMethod, ServerAuthMethod.key),
    transport = enumValueOrDefault(transport, ServerTransportProtocol.ssh),
    networkDeviceProfile = enumValueOrDefault(networkDeviceProfile, NetworkDeviceProfile.auto),
    allowPasswordFallback = allowPasswordFallback,
    password = credentials.password,
    privateKeyContent = credentials.privateKeyContent,
    privateKeyPassphrase = credentials.privateKeyPassphrase,
    isJumpHostEnabled = jumpHost != null,
    jumpCredentialID = jumpHost?.credentialID.orEmpty(),
    jumpHost = jumpHost?.host.orEmpty(),
    jumpPort = jumpHost?.port?.toString() ?: "22",
    jumpUsername = jumpHost?.username.orEmpty(),
    jumpAuthMethod = jumpHost?.authMethod?.let { enumValueOrDefault(it, ServerAuthMethod.key) } ?: ServerAuthMethod.key,
    jumpAllowPasswordFallback = jumpHost?.allowPasswordFallback ?: false,
    jumpPassword = jumpCredentials?.password.orEmpty(),
    jumpPrivateKeyContent = jumpCredentials?.privateKeyContent.orEmpty(),
    jumpPrivateKeyPassphrase = jumpCredentials?.privateKeyPassphrase.orEmpty(),
)

private fun AssetEditorUiState.toAsset(): ServerAsset = ServerAsset(
    id = id,
    credentialID = credentialID,
    name = name.trim(),
    group = group.trim(),
    tags = tags.normalizedAssetTags(),
    host = host.trim(),
    port = port.toInt(),
    username = username.trim(),
    authMethod = authMethod.name,
    transport = transport.name,
    networkDeviceProfile = networkDeviceProfile.name,
    allowPasswordFallback = allowPasswordFallback,
    jumpHost = toJumpHostConfiguration(),
    createdAtUnix = createdAtUnix,
)

private fun AssetEditorUiState.toCredentials(): ServerCredentials = when (authMethod) {
    ServerAuthMethod.password -> ServerCredentials(password = password)
    ServerAuthMethod.key -> ServerCredentials(
        password = if (allowPasswordFallback) password else "",
        privateKeyContent = privateKeyContent,
        privateKeyPassphrase = privateKeyPassphrase,
    )
}

private fun AssetEditorUiState.toJumpHostConfiguration(): JumpHostConfiguration? =
    if (!isJumpHostEnabled) null else JumpHostConfiguration(
        credentialID = jumpCredentialID,
        host = jumpHost.trim(),
        port = jumpPort.toInt(),
        username = jumpUsername.trim(),
        authMethod = jumpAuthMethod.name,
        allowPasswordFallback = jumpAllowPasswordFallback,
    )

private fun AssetEditorUiState.toJumpHostCredentials(): ServerCredentials? = when {
    !isJumpHostEnabled -> null
    jumpAuthMethod == ServerAuthMethod.password -> ServerCredentials(password = jumpPassword)
    else -> ServerCredentials(
        password = if (jumpAllowPasswordFallback) jumpPassword else "",
        privateKeyContent = jumpPrivateKeyContent,
        privateKeyPassphrase = jumpPrivateKeyPassphrase,
    )
}

private fun AssetEditorUiState.validationError(telnetEnabled: Boolean = false): String? = when {
    name.isBlank() -> "请输入资产名称。"
    tags.normalizedAssetTags().size > MAX_ASSET_TAGS -> "每个资产最多可保存 $MAX_ASSET_TAGS 个标签。"
    tags.normalizedAssetTags().any { it.length > MAX_ASSET_TAG_LENGTH } -> "单个标签不能超过 $MAX_ASSET_TAG_LENGTH 个字符。"
    host.isBlank() -> "请输入主机地址。"
    port.toIntOrNull() !in 1..65_535 -> "端口必须在 1 到 65535 之间。"
    username.isBlank() -> "请输入登录用户名。"
    authMethod == ServerAuthMethod.password && password.isBlank() -> "请输入密码。"
    authMethod == ServerAuthMethod.key && privateKeyContent.isBlank() -> "请导入或粘贴私钥。"
    // Imported Telnet records may be retained and edited for sync compatibility,
    // but Android must never create a new unsupported transport.
    isNew && !AndroidTransportSupportPolicy.allowsCheckedConnection(transport.name, telnetEnabled) ->
        "请先在设置中启用 Telnet，或改用 SSH。"
    isJumpHostEnabled && transport != ServerTransportProtocol.ssh -> "跳板机仅支持 SSH 资产。"
    isJumpHostEnabled && jumpCredentialID.isBlank() -> "跳板机凭据标识无效。"
    isJumpHostEnabled && jumpHost.isBlank() -> "请输入跳板机地址。"
    isJumpHostEnabled && jumpPort.toIntOrNull() !in 1..65_535 -> "跳板机端口必须在 1 到 65535 之间。"
    isJumpHostEnabled && jumpUsername.isBlank() -> "请输入跳板机用户名。"
    isJumpHostEnabled && jumpAuthMethod == ServerAuthMethod.password && jumpPassword.isBlank() -> "请输入跳板机密码。"
    isJumpHostEnabled && jumpAuthMethod == ServerAuthMethod.key && jumpPrivateKeyContent.isBlank() -> "请导入或粘贴跳板机私钥。"
    else -> null
}

internal fun AssetEditorUiState.selectTransport(next: ServerTransportProtocol): AssetEditorUiState {
    val nextPort = when {
        next == ServerTransportProtocol.telnet && port == "22" -> "23"
        next == ServerTransportProtocol.ssh && port == "23" -> "22"
        else -> port
    }
    return copy(
        transport = next,
        port = nextPort,
        authMethod = if (next == ServerTransportProtocol.telnet) ServerAuthMethod.password else authMethod,
        isJumpHostEnabled = isJumpHostEnabled && next == ServerTransportProtocol.ssh,
    )
}

private inline fun <reified T : Enum<T>> enumValueOrDefault(raw: String, default: T): T =
    enumValues<T>().firstOrNull { it.name == raw } ?: default

private const val MAX_PRIVATE_KEY_CHARS = 1_048_576
private const val MAX_ASSET_TAGS = 8
private const val MAX_ASSET_TAG_LENGTH = 24

private fun String.normalizedAssetTags(): List<String> = split(',', '，')
    .map(String::trim)
    .filter(String::isNotEmpty)
    .distinctBy(String::lowercase)

private fun ServerAsset.endpointImportKey(): String =
    "${username.lowercase()}@${host.lowercase()}:$port"

private fun CheckedSshConnectResult.toConnectionUiState(assetId: String): AssetConnectionUiState = when (this) {
    is CheckedSshConnectResult.Connected -> AssetConnectionUiState(
        assetId = assetId,
        phase = ConnectionPhase.Connected,
        baseSessionId = baseSessionId,
    )
    is CheckedSshConnectResult.HostKeyChallenge -> AssetConnectionUiState(
        assetId = assetId,
        phase = ConnectionPhase.AwaitingHostKeyDecision,
        hostKeyChallenge = this,
    )
    is CheckedSshConnectResult.Blocked -> AssetConnectionUiState(
        assetId,
        ConnectionPhase.Blocked(
            when (reasonCode) {
                "changed" -> BlockReason.HostKeyChanged
                "revoked" -> BlockReason.HostKeyRevoked
                else -> BlockReason.HostKeyUnsupported
            },
        ),
    )
    is CheckedSshConnectResult.Failure -> AssetConnectionUiState(
        assetId,
        ConnectionPhase.Failed(
            error = when (orbitNativeError(code, retryable, detailCode).code) {
                OrbitErrorCode.AuthenticationFailed -> if (detailCode == "authentication_timeout") {
                    ConnectionError.AuthenticationTimedOut
                } else {
                    ConnectionError.AuthenticationFailed
                }
                OrbitErrorCode.NetworkTimeout -> ConnectionError.TimedOut
                OrbitErrorCode.NetworkUnavailable -> ConnectionError.NetworkUnavailable
                OrbitErrorCode.NativeBridgeUnavailable -> ConnectionError.NativeBridgeUnavailable
                else -> ConnectionError.Unknown
            },
            retryable = retryable,
            diagnosticCode = orbitNativeError(code, retryable, detailCode).diagnosticCode,
        ),
    )
}
