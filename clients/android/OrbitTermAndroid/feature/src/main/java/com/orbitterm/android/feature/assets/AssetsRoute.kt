package com.orbitterm.android.feature.assets

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Checkbox
import androidx.compose.material3.TriStateCheckbox
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.FileUpload
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.state.ToggleableState
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.ServerAuthMethod
import com.orbitterm.android.domain.assets.ServerTransportProtocol
import com.orbitterm.android.domain.assets.NetworkDeviceProfile
import com.orbitterm.android.domain.assets.AndroidTransportSupportPolicy
import com.orbitterm.android.domain.session.ConnectionError
import com.orbitterm.android.domain.session.ConnectionPhase
import com.orbitterm.android.domain.deeplink.ServerDeepLink
import com.orbitterm.android.feature.batch.BatchCommandUiState
import com.orbitterm.android.feature.batch.BatchCommandViewModel
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import com.orbitterm.android.ui.design.OrbitFormDialog
import com.orbitterm.android.security.ClipboardContentKind
import com.orbitterm.android.security.SensitiveClipboard
import com.orbitterm.android.ui.design.OrbitStatusLine
import androidx.compose.runtime.LaunchedEffect

@Composable
fun AssetsRoute(
    modifier: Modifier = Modifier,
    telnetEnabled: Boolean = false,
    onTerminalOpened: () -> Unit = {},
    deepLink: ServerDeepLink? = null,
    onDeepLinkConsumed: () -> Unit = {},
    isSynchronizing: Boolean = false,
    onSyncRequested: () -> Unit = {},
    viewModel: AssetsViewModel = viewModel(),
    batchViewModel: BatchCommandViewModel = viewModel(),
) {
    val uiState = viewModel.uiState.collectAsStateWithLifecycle().value
    val editor = uiState.editor
    val batchState = batchViewModel.uiState.collectAsStateWithLifecycle().value
    LaunchedEffect(deepLink) {
        deepLink?.let {
            viewModel.openDeepLink(it, onDeepLinkConsumed)
        }
    }

    if (editor == null) {
        AssetList(
            assets = uiState.assets,
            telnetEnabled = telnetEnabled,
            modifier = modifier,
            onAdd = viewModel::createAsset,
            onAssetSelected = viewModel::editAsset,
            activeAssetIds = uiState.activeAssetIds,
            onConnect = { assetId ->
                if (assetId in uiState.activeAssetIds) onTerminalOpened() else viewModel.connectAsset(assetId, telnetEnabled)
            },
            onDeleteAssets = viewModel::deleteAssets,
            batchState = batchState,
            onRunBatch = batchViewModel::execute,
            onRetryBatchFailures = batchViewModel::retryFailures,
            onDismissBatchReceipt = batchViewModel::dismissReceipt,
            onRenameGroup = viewModel::renameGroup,
            onDeleteGroup = viewModel::deleteGroup,
            operationError = uiState.operationError,
            onDismissOperationError = viewModel::dismissOperationError,
            expandedGroups = uiState.expandedGroups,
            onToggleGroupExpansion = viewModel::toggleGroupExpansion,
            bulkImport = uiState.bulkImport,
            onShowBulkImport = viewModel::showBulkImport,
            onUpdateBulkImport = viewModel::updateBulkImportInput,
            onImportBulkAssets = viewModel::importBulkAssets,
            onDismissBulkImport = viewModel::dismissBulkImport,
            isSynchronizing = isSynchronizing,
            onSyncRequested = onSyncRequested,
        )
    } else {
        AssetEditor(
            state = editor,
            telnetEnabled = telnetEnabled,
            modifier = modifier,
            onUpdate = viewModel::updateEditor,
            onSave = { viewModel.saveEditor(telnetEnabled) },
            onCancel = viewModel::cancelEditor,
            onRequestDelete = viewModel::requestDelete,
            onConfirmDelete = viewModel::confirmDelete,
            onDismissDeleteConfirmation = viewModel::dismissDeleteConfirmation,
            onImportPrivateKey = viewModel::importPrivateKey,
            onPrivateKeyImportFailure = viewModel::reportEditorError,
            onTestConnection = { viewModel.testEditorConnection(telnetEnabled) },
            onTrustTestHostKey = viewModel::trustEditorHostKeyAndRetest,
            onDismissConnectionTest = viewModel::dismissEditorConnectionTest,
        )
    }
    uiState.connection?.let { connection ->
        ConnectionDialog(
            connection = connection,
            onTrust = viewModel::trustHostKeyAndReconnect,
            onOpenTerminal = { viewModel.openTerminal(onTerminalOpened) },
            onDismiss = viewModel::dismissConnectionPrompt,
        )
    }
}

@Composable
private fun AssetList(
    assets: List<ServerAsset>,
    telnetEnabled: Boolean,
    modifier: Modifier,
    onAdd: () -> Unit,
    onAssetSelected: (String) -> Unit,
    activeAssetIds: Set<String>,
    onConnect: (String) -> Unit,
    onDeleteAssets: (Set<String>) -> Unit,
    batchState: BatchCommandUiState,
    onRunBatch: (String, Set<String>) -> Unit,
    onRetryBatchFailures: () -> Unit,
    onDismissBatchReceipt: () -> Unit,
    onRenameGroup: (String, String) -> Unit,
    onDeleteGroup: (String) -> Unit,
    operationError: String?,
    onDismissOperationError: () -> Unit,
    expandedGroups: Set<String>,
    onToggleGroupExpansion: (String) -> Unit,
    bulkImport: AssetBulkImportUiState,
    onShowBulkImport: () -> Unit,
    onUpdateBulkImport: (String) -> Unit,
    onImportBulkAssets: () -> Unit,
    onDismissBulkImport: () -> Unit,
    isSynchronizing: Boolean,
    onSyncRequested: () -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var batchMode by rememberSaveable { mutableStateOf(false) }
    var selectedIds by rememberSaveable { mutableStateOf(setOf<String>()) }
    var deleteConfirmationVisible by rememberSaveable { mutableStateOf(false) }
    var batchCommandDialog by rememberSaveable { mutableStateOf(false) }
    var batchCommand by rememberSaveable { mutableStateOf("") }
    var batchConfirmationVisible by rememberSaveable { mutableStateOf(false) }
    var expandedBatchReceipts by rememberSaveable { mutableStateOf(emptySet<String>()) }
    val context = LocalContext.current
    var renamingGroup by rememberSaveable { mutableStateOf<String?>(null) }
    var groupRenameText by rememberSaveable { mutableStateOf("") }
    var groupMenu by rememberSaveable { mutableStateOf<String?>(null) }
    var groupPendingDeletion by rememberSaveable { mutableStateOf<String?>(null) }
    val filteredAssets = assets.filter { asset ->
        val normalizedQuery = query.trim()
        normalizedQuery.isBlank() || listOf(asset.name, asset.host, asset.username, asset.group, *asset.tags.toTypedArray())
            .any { it.contains(normalizedQuery, ignoreCase = true) }
    }
    val groupedAssets = filteredAssets.groupBy { it.group.ifBlank { "未分组" } }
        .toSortedMap(String.CASE_INSENSITIVE_ORDER)

    androidx.compose.material3.Scaffold(
        modifier = modifier,
        containerColor = Color.Transparent,
        topBar = {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 20.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Surface(
                    modifier = Modifier.clickable {
                        batchMode = !batchMode
                        if (!batchMode) selectedIds = emptySet()
                    },
                    shape = androidx.compose.foundation.shape.CircleShape,
                    color = MaterialTheme.colorScheme.surface,
                ) {
                    Icon(
                        Icons.Rounded.Checklist,
                        contentDescription = if (batchMode) "退出批量命令与批量管理" else "批量命令与批量管理",
                        modifier = Modifier.padding(12.dp),
                    )
                }
                Text(
                    "服务器",
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    style = MaterialTheme.typography.titleLarge,
                )
                IconButton(onClick = onShowBulkImport) {
                    Icon(Icons.Rounded.FileUpload, contentDescription = "批量导入资产")
                }
                IconButton(onClick = onSyncRequested, enabled = !isSynchronizing) {
                    if (isSynchronizing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(22.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Icon(Icons.Rounded.Sync, contentDescription = "立即双向同步")
                    }
                }
                Surface(
                    modifier = Modifier.clickable(onClick = onAdd),
                    shape = androidx.compose.foundation.shape.CircleShape,
                    color = MaterialTheme.colorScheme.surface,
                ) {
                    Icon(Icons.Rounded.Add, contentDescription = "添加资产", modifier = Modifier.padding(12.dp))
                }
            }
        },
    ) { paddingValues ->
        if (assets.isEmpty()) {
            EmptyAssetsState(
                Modifier
                    .fillMaxSize()
                    .background(assetWorkspaceBackground())
                    .padding(paddingValues),
            )
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .background(assetWorkspaceBackground()),
                contentPadding = PaddingValues(
                    start = 20.dp,
                    top = 4.dp + paddingValues.calculateTopPadding(),
                    end = 20.dp,
                    bottom = 18.dp + paddingValues.calculateBottomPadding(),
                ),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        OutlinedTextField(
                            value = query,
                            onValueChange = { query = it },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            placeholder = { Text("搜索名称、IP、用户、分组或标签") },
                            leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
                            shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
                            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                                focusedContainerColor = MaterialTheme.colorScheme.surface,
                                unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                                focusedBorderColor = Color.Transparent,
                                unfocusedBorderColor = Color.Transparent,
                            ),
                        )
                        if (batchMode && selectedIds.isNotEmpty()) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(onClick = { batchCommandDialog = true }) { Text("批量命令") }
                                TextButton(onClick = { deleteConfirmationVisible = true }) {
                                    Text("删除 ${selectedIds.size} 项", color = MaterialTheme.colorScheme.error)
                                }
                            }
                        }
                        if (batchMode && selectedIds.isEmpty()) {
                            Text(
                                "选择一个或多个 SSH 资产后，可直接执行批量命令；也可批量删除资产。",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        operationError?.let { message ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    message,
                                    modifier = Modifier.weight(1f),
                                    color = MaterialTheme.colorScheme.error,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                                TextButton(onClick = onDismissOperationError) { Text("关闭") }
                            }
                        }
                    }
                }
                if (filteredAssets.isEmpty()) {
                    item {
                        Text(
                            "没有匹配的服务器",
                            modifier = Modifier.padding(vertical = 32.dp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                groupedAssets.forEach { (group, groupAssets) ->
                    val allGroupAssetIds = assets
                        .filter { asset -> asset.group.ifBlank { "未分组" } == group }
                        .mapTo(linkedSetOf()) { it.id }
                    stickyHeader(key = "group-$group") {
                        val selectedInGroup = allGroupAssetIds.count { it in selectedIds }
                        val groupSelectionState = when {
                            selectedInGroup == 0 -> ToggleableState.Off
                            selectedInGroup == allGroupAssetIds.size -> ToggleableState.On
                            else -> ToggleableState.Indeterminate
                        }
                        Surface(
                            modifier = Modifier.fillMaxWidth().clickable { onToggleGroupExpansion(group) },
                            color = MaterialTheme.colorScheme.surface,
                            shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
                        ) {
                            Row(
                                modifier = Modifier.padding(start = 18.dp, end = 8.dp, top = 7.dp, bottom = 7.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (batchMode) {
                                    TriStateCheckbox(
                                        state = groupSelectionState,
                                        onClick = {
                                            selectedIds = if (groupSelectionState == ToggleableState.On) {
                                                selectedIds - allGroupAssetIds
                                            } else {
                                                selectedIds + allGroupAssetIds
                                            }
                                        },
                                    )
                                }
                                Text(text = group, modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                                Text("${groupAssets.size}", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
                                androidx.compose.foundation.layout.Box {
                                    IconButton(onClick = { groupMenu = group }) {
                                        Icon(Icons.Rounded.MoreVert, contentDescription = "分组操作 $group")
                                    }
                                    DropdownMenu(
                                        expanded = groupMenu == group,
                                        onDismissRequest = { groupMenu = null },
                                    ) {
                                        if (batchMode) {
                                            val isWholeGroupSelected = allGroupAssetIds.all { it in selectedIds }
                                            DropdownMenuItem(
                                                text = { Text(if (isWholeGroupSelected) "取消选择此分组" else "选择此分组") },
                                                onClick = {
                                                    groupMenu = null
                                                    selectedIds = if (isWholeGroupSelected) selectedIds - allGroupAssetIds else selectedIds + allGroupAssetIds
                                                },
                                            )
                                        }
                                        DropdownMenuItem(
                                            text = { Text("重命名分组") },
                                            onClick = {
                                                groupMenu = null
                                                renamingGroup = group
                                                groupRenameText = if (group == "未分组") "" else group
                                            },
                                        )
                                        if (group != "未分组") {
                                            DropdownMenuItem(
                                                text = { Text("删除分组", color = MaterialTheme.colorScheme.error) },
                                                onClick = {
                                                    groupMenu = null
                                                    groupPendingDeletion = group
                                                },
                                            )
                                        }
                                    }
                                }
                                Icon(
                                    imageVector = if (group in expandedGroups) Icons.Rounded.ExpandLess else Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                                    contentDescription = if (group in expandedGroups) "收起 $group" else "展开 $group",
                                )
                            }
                        }
                    }
                    if (group in expandedGroups) {
                        items(items = groupAssets, key = ServerAsset::id) { asset ->
                            AssetListItem(
                                asset = asset,
                                telnetEnabled = telnetEnabled,
                                batchMode = batchMode,
                                isConnected = asset.id in activeAssetIds,
                                isSelected = asset.id in selectedIds,
                                onClick = {
                                    if (batchMode) {
                                        selectedIds = selectedIds.toggle(asset.id)
                                    } else {
                                        onConnect(asset.id)
                                    }
                                },
                                onEdit = { onAssetSelected(asset.id) },
                            )
                        }
                    }
                }
            }
        }
    }
    if (batchCommandDialog) OrbitFormDialog(
        title = "批量命令",
        confirmLabel = "继续",
        confirmEnabled = batchCommand.isNotBlank(),
        onConfirm = { batchConfirmationVisible = true },
        onDismiss = { batchCommandDialog = false },
    ) {
        OutlinedTextField(
            value = batchCommand,
            onValueChange = { batchCommand = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Shell 命令") },
            minLines = 3,
        )
    }
    if (batchConfirmationVisible) OrbitFormDialog(
        title = "确认执行批量命令",
        confirmLabel = "执行",
        onConfirm = { onRunBatch(batchCommand, selectedIds); batchConfirmationVisible = false; batchCommandDialog = false },
        onDismiss = { batchConfirmationVisible = false },
    ) {
        Text("所选资产必须全部已有已验证 SSH 会话。缺少会话时不会执行，也不会自动连接。\n\n${batchCommand}")
    }
    if (batchState.running || batchState.receipts.isNotEmpty() || batchState.error != null) {
        AlertDialog(
            onDismissRequest = { if (!batchState.running) onDismissBatchReceipt() }, title = { Text("批量命令回执") },
            text = {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 360.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    if (batchState.running) Text("正在逐台执行…")
                    else Text("完成：成功 ${batchState.successCount} 台，失败 ${batchState.failureCount} 台")
                    batchState.receipts.forEach { receipt ->
                        Text(receipt.name, style = MaterialTheme.typography.titleSmall)
                        val resultSummary = receipt.errorCode
                            ?.let { code -> "失败：${com.orbitterm.android.domain.error.orbitNativeError(code).diagnosticCode}" }
                            ?: "退出码 ${receipt.exitStatus}"
                        Text("$resultSummary · ${receipt.elapsedMillis} ms")
                        val output = listOf(receipt.stdout, receipt.stderr).filter { it.isNotBlank() }.joinToString("\n")
                        if (output.isNotBlank()) {
                            val expanded = receipt.assetId in expandedBatchReceipts
                            Text(if (expanded || output.length <= 800) output else output.take(800) + "…", color = if (receipt.stderr.isBlank()) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                            if (output.length > 800) TextButton(onClick = { expandedBatchReceipts = if (expanded) expandedBatchReceipts - receipt.assetId else expandedBatchReceipts + receipt.assetId }) { Text(if (expanded) "收起输出" else "查看完整输出") }
                        }
                    }
                    batchState.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
            },
            confirmButton = {
                if (batchState.failureCount > 0 && !batchState.running) TextButton(onClick = onRetryBatchFailures) { Text("重试失败项") }
                else TextButton(enabled = !batchState.running, onClick = onDismissBatchReceipt) { Text("完成") }
            },
            dismissButton = {
                TextButton(onClick = {
                    val text = batchState.receipts.joinToString("\n\n") { receipt ->
                        val resultSummary = receipt.errorCode
                            ?.let { code -> "failure:${com.orbitterm.android.domain.error.orbitNativeError(code).diagnosticCode}" }
                            ?: "exit ${receipt.exitStatus}"
                        "${receipt.name}\n$resultSummary\n${receipt.stdout}${if (receipt.stderr.isBlank()) "" else "\n${receipt.stderr}"}"
                    }
                    // Command output can contain tokens or operational details.
                    // Treat it like terminal text and clear it only if it has
                    // not been superseded by the user within the timeout.
                    SensitiveClipboard.copy(
                        context,
                        "OrbitTerm 批量命令回执",
                        text,
                        ClipboardContentKind.TERMINAL_OUTPUT,
                    )
                }) { Text("复制回执") }
            },
            shape = androidx.compose.foundation.shape.RoundedCornerShape(28.dp),
            containerColor = MaterialTheme.colorScheme.surface,
        )
    }
    if (deleteConfirmationVisible) {
        OrbitConfirmationDialog(
            title = "删除选中的资产？",
            message = "将 ${selectedIds.size} 个资产移入最近删除，并移除本机凭据。保留期内可在个人中心恢复。",
            confirmLabel = "删除",
            onConfirm = {
                onDeleteAssets(selectedIds)
                selectedIds = emptySet()
                batchMode = false
                deleteConfirmationVisible = false
            },
            onDismiss = { deleteConfirmationVisible = false },
            destructive = true,
        )
    }
    renamingGroup?.let { group ->
        OrbitFormDialog(
            title = "重命名分组",
            confirmLabel = "保存",
            confirmEnabled = groupRenameText.isNotBlank(),
            onConfirm = { onRenameGroup(group, groupRenameText); renamingGroup = null },
            onDismiss = { renamingGroup = null },
        ) {
            OutlinedTextField(
                value = groupRenameText,
                onValueChange = { groupRenameText = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("分组名称") },
                singleLine = true,
            )
        }
    }
    groupPendingDeletion?.let { group ->
        val count = assets.count { it.group == group }
        OrbitConfirmationDialog(
            title = "删除分组？",
            message = "将“$group”下 $count 个资产移入最近删除，并移除本机凭据。保留期内可恢复。",
            confirmLabel = "删除",
            onConfirm = { onDeleteGroup(group); groupPendingDeletion = null },
            onDismiss = { groupPendingDeletion = null },
            destructive = true,
        )
    }
    if (bulkImport.isVisible) {
        AlertDialog(
            onDismissRequest = onDismissBulkImport,
            title = { Text("批量导入 SSH 资产") },
            text = {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 520.dp)
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        "字段顺序：名称、分组、主机、端口、用户名、密码、协议、认证方式、私钥内容、标签。支持逗号、Tab 或分号；标签可用 | 分隔，私钥换行可写为 \\n。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(
                        value = bulkImport.rawInput,
                        onValueChange = onUpdateBulkImport,
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 10,
                        maxLines = 16,
                        label = { Text("粘贴资产列表") },
                        supportingText = { Text("最多 500 项 / 1 MB；仅在安全存储中保存凭据。") },
                    )
                    bulkImport.summary?.let {
                        OrbitStatusLine(label = it, isActive = bulkImport.issues.isEmpty())
                    }
                    bulkImport.issues.take(8).forEach { issue ->
                        Text(
                            buildString {
                                issue.lineNumber?.let { append("第 $it 行：") }
                                append(issue.message)
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    if (bulkImport.issues.size > 8) {
                        Text(
                            "另有 ${bulkImport.issues.size - 8} 条记录未显示。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = onImportBulkAssets,
                    enabled = bulkImport.rawInput.isNotBlank() && !bulkImport.isImporting,
                ) { Text(if (bulkImport.isImporting) "正在导入…" else "导入并同步") }
            },
            dismissButton = {
                TextButton(onClick = onDismissBulkImport, enabled = !bulkImport.isImporting) { Text("关闭") }
            },
            shape = androidx.compose.foundation.shape.RoundedCornerShape(28.dp),
        )
    }
}

@Composable
private fun assetWorkspaceBackground(): Brush = SolidColor(MaterialTheme.colorScheme.background)

@Composable
private fun EmptyAssetsState(modifier: Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = "还没有服务器", style = MaterialTheme.typography.headlineSmall)
        Text(
            text = "添加服务器后，即可在此安全地发起连接。",
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@Composable
private fun AssetWorkspaceHeader(
    assetCount: Int,
    groupCount: Int,
    connectedCount: Int,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "$assetCount",
                        style = MaterialTheme.typography.headlineSmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    Text(
                        text = "已保存",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Clip,
                    )
                }
                WorkspaceStatDivider()
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "$groupCount",
                        style = MaterialTheme.typography.headlineSmall,
                    )
                    Text(
                        text = "服务器分组",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
                WorkspaceStatDivider()
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "$connectedCount",
                        style = MaterialTheme.typography.headlineSmall,
                        color = if (connectedCount > 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "当前已连接",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
            }
        }
    }
}

@Composable
private fun WorkspaceStatDivider() {
    Box(
        modifier = Modifier
            .width(1.dp)
            .heightIn(min = 32.dp)
            .background(MaterialTheme.colorScheme.outlineVariant),
    )
}

@Composable
private fun AssetListItem(
    asset: ServerAsset,
    telnetEnabled: Boolean,
    batchMode: Boolean,
    isConnected: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
    onEdit: () -> Unit,
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
        border = CardDefaults.outlinedCardBorder(),
    ) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (batchMode) {
                    Checkbox(checked = isSelected, onCheckedChange = { onClick() })
                }
                Text(
                    text = asset.name,
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = "${asset.username}@${asset.host}:${asset.port}",
                modifier = Modifier.padding(top = 4.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
            if (!batchMode) {
                OrbitStatusLine(
                    label = if (isConnected) "已连接" else "未连接",
                    isActive = isConnected,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
            if (!AndroidTransportSupportPolicy.allowsCheckedConnection(asset.transport, telnetEnabled)) {
                Text(
                    text = AndroidTransportSupportPolicy.compatibilityLabel(asset.transport),
                    modifier = Modifier.padding(top = 6.dp),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            if (asset.tags.isNotEmpty()) {
                Text(
                    text = asset.tags.joinToString(separator = " · "),
                    modifier = Modifier.padding(top = 8.dp),
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (!batchMode) Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    when {
                        isConnected -> "打开会话"
                        else -> "点击连接"
                    },
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.labelLarge,
                )
                IconButton(onClick = onEdit) {
                    Icon(Icons.Rounded.Edit, contentDescription = "编辑资产")
                }
            }
        }
    }
}

private fun Set<String>.toggle(id: String): Set<String> =
    if (id in this) this - id else this + id

@Composable
private fun ConnectionDialog(
    connection: AssetConnectionUiState,
    onTrust: () -> Unit,
    onOpenTerminal: () -> Unit,
    onDismiss: () -> Unit,
) {
    val challenge = connection.hostKeyChallenge
    val context = LocalContext.current
    when (connection.phase) {
        ConnectionPhase.AwaitingHostKeyDecision if challenge != null -> OrbitFormDialog(
            title = "确认服务器身份",
            confirmLabel = "信任此服务器",
            onConfirm = onTrust,
            onDismiss = onDismiss,
        ) {
            Text("首次连接 ${challenge.host}:${challenge.port}\n${challenge.keyAlgorithm}\n${challenge.fingerprintSha256}")
            TextButton(onClick = {
                SensitiveClipboard.copy(
                    context,
                    "SSH Host Key fingerprint",
                    challenge.fingerprintSha256,
                    ClipboardContentKind.HOST_KEY_FINGERPRINT,
                )
            }) { Text("复制指纹") }
        }
        ConnectionPhase.Connected -> OrbitFormDialog(
            title = if (connection.transport == ServerTransportProtocol.telnet) "Telnet 端口可达" else "服务器身份已验证",
            confirmLabel = "打开终端",
            onConfirm = onOpenTerminal,
            onDismiss = onDismiss,
        ) {
            Text(
                if (connection.transport == ServerTransportProtocol.telnet) {
                    "将通过明文 Telnet 连接发送用户名、密码和命令；此协议不提供服务器身份验证。"
                } else {
                    "已建立经过 Host Key 验证的 SSH 会话。"
                },
            )
        }
        is ConnectionPhase.Blocked, is ConnectionPhase.Failed -> OrbitConfirmationDialog(
            title = connection.phase.presentationHeadline(),
            message = connection.phase.userMessage(),
            confirmLabel = "关闭",
            onConfirm = onDismiss,
            onDismiss = onDismiss,
        )
        else -> Unit
    }
}

private fun ConnectionPhase.userMessage(): String = when (this) {
    is ConnectionPhase.Blocked -> when (reason) {
        com.orbitterm.android.domain.session.BlockReason.UnsupportedTransport ->
            AndroidTransportSupportPolicy.unsupportedConnectionMessage
        com.orbitterm.android.domain.session.BlockReason.HostKeyChanged -> "服务器主机密钥已变更，连接已被安全阻断。"
        com.orbitterm.android.domain.session.BlockReason.HostKeyRevoked -> "服务器主机密钥已撤销，连接已被安全阻断。"
        com.orbitterm.android.domain.session.BlockReason.HostKeyUnsupported -> "服务器主机密钥无法验证，连接已被安全阻断。"
        com.orbitterm.android.domain.session.BlockReason.TrustStoreFailure -> "本机信任存储不可用，连接已被安全阻断。"
    }
    is ConnectionPhase.Failed -> buildString {
        append(
            when (error) {
                ConnectionError.AuthenticationFailed -> "服务器拒绝认证。请检查用户名、认证方式及密码或私钥。"
                ConnectionError.AuthenticationTimedOut -> "服务器在认证阶段未及时响应。请检查认证方式与服务器认证策略。"
                ConnectionError.NetworkUnavailable -> "无法建立网络连接。请检查主机地址、端口和网络。"
                ConnectionError.TimedOut -> "连接超时。请检查网络、地址和防火墙。"
                ConnectionError.NativeBridgeUnavailable -> "本机安全连接组件不可用。"
                ConnectionError.Unknown -> "连接失败。"
            },
        )
        diagnosticCode?.let { append("诊断代码：$it。") }
    }
    else -> "连接状态已更新。"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AssetEditor(
    state: AssetEditorUiState,
    telnetEnabled: Boolean,
    modifier: Modifier,
    onUpdate: ((AssetEditorUiState) -> AssetEditorUiState) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
    onRequestDelete: () -> Unit,
    onConfirmDelete: () -> Unit,
    onDismissDeleteConfirmation: () -> Unit,
    onImportPrivateKey: (String) -> Unit,
    onPrivateKeyImportFailure: (String) -> Unit,
    onTestConnection: () -> Unit,
    onTrustTestHostKey: () -> Unit,
    onDismissConnectionTest: () -> Unit,
) {
    val context = LocalContext.current
    val privateKeyPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching { context.contentResolver.openInputStream(uri)?.use(::readPrivateKeyText) ?: error("无法读取私钥文件。") }
            .onSuccess(onImportPrivateKey)
            .onFailure { onPrivateKeyImportFailure("无法导入私钥文件。") }
    }
    val jumpPrivateKeyPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.openInputStream(uri)?.use(::readPrivateKeyText) ?: error("无法读取私钥文件。")
        }.onSuccess { contents ->
            val normalized = contents.trim()
            if (normalized.length > MAX_PRIVATE_KEY_BYTES || !normalized.contains("PRIVATE KEY")) {
                onUpdate { it.copy(validationError = "所选文件不是受支持的跳板机私钥。") }
            } else {
                onUpdate {
                    it.copy(
                        jumpAuthMethod = ServerAuthMethod.key,
                        jumpPrivateKeyContent = normalized,
                        validationError = null,
                    )
                }
            }
        }.onFailure {
            onUpdate { current -> current.copy(validationError = "无法导入跳板机私钥文件。") }
        }
    }
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(if (state.isNew) "添加资产" else "编辑资产") },
            navigationIcon = {
                IconButton(onClick = onCancel, enabled = !state.isSaving && !state.isDeleting) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "取消编辑")
                }
            },
            actions = {
                if (!state.isNew) {
                    IconButton(
                        onClick = onRequestDelete,
                        enabled = !state.isSaving && !state.isDeleting,
                    ) {
                        Icon(Icons.Rounded.Delete, contentDescription = "删除资产")
                    }
                }
                Button(onClick = onSave, enabled = !state.isSaving && !state.isDeleting) {
                    Text(if (state.isSaving) "保存中" else "保存")
                }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            state.validationError?.let { message ->
                item { Text(message, color = MaterialTheme.colorScheme.error) }
            }
            item {
                Button(
                    onClick = onTestConnection,
                    enabled = state.connectionTest?.phase !is ConnectionPhase.Connecting && !state.isSaving && !state.isDeleting,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(if (state.connectionTest?.phase is ConnectionPhase.Connecting) "正在测试连接…" else "保存前测试连接")
                }
            }
            item {
                EditorTextField("名称", state.name) { value -> onUpdate { it.copy(name = value) } }
            }
            item {
                EditorTextField("分组（可选）", state.group) { value -> onUpdate { it.copy(group = value) } }
            }
            item {
                EditorTextField("标签（可选，使用逗号分隔）", state.tags) { value -> onUpdate { it.copy(tags = value) } }
            }
            item {
                TransportSelector(
                    selected = state.transport,
                    telnetEnabled = telnetEnabled || state.transport == ServerTransportProtocol.telnet,
                    onSelected = { transport ->
                        onUpdate { current -> current.selectTransport(transport) }
                    },
                )
                if (!telnetEnabled && state.transport != ServerTransportProtocol.telnet) {
                    Text(
                        "如需创建 Telnet 资产，请先在个人中心的“设置与偏好”中明确启用。",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            item {
                EditorTextField("主机地址", state.host) { value -> onUpdate { it.copy(host = value) } }
            }
            item {
                EditorTextField(
                    if (state.transport == ServerTransportProtocol.telnet) "端口（Telnet 默认 23）" else "端口（SSH 默认 22）",
                    state.port,
                    keyboardType = KeyboardType.Number,
                ) { value ->
                    onUpdate { it.copy(port = value.filter(Char::isDigit)) }
                }
            }
            item {
                EditorTextField("用户名", state.username) { value -> onUpdate { it.copy(username = value) } }
            }
            if (state.transport == ServerTransportProtocol.telnet) {
                item {
                    NetworkDeviceProfileSelector(state.networkDeviceProfile) { profile ->
                        onUpdate { it.copy(networkDeviceProfile = profile) }
                    }
                }
                item {
                    Text(
                        "Telnet 为明文协议，不验证服务器身份；用户名、密码和命令可能被同网段设备读取。",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            if (state.transport == ServerTransportProtocol.ssh) item {
                AuthMethodSelector(state.authMethod) { method -> onUpdate { it.copy(authMethod = method) } }
            }
            if (state.authMethod == ServerAuthMethod.password) {
                item {
                    EditorTextField(
                        label = "密码",
                        value = state.password,
                        keyboardType = KeyboardType.Password,
                        sensitive = true,
                    ) { value -> onUpdate { it.copy(password = value) } }
                }
            } else {
                item {
                    TextButton(
                        onClick = { privateKeyPicker.launch(arrayOf("application/octet-stream", "text/plain", "*/*")) },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("从文件导入私钥") }
                }
                item {
                    EditorTextField(
                        label = "私钥内容",
                        value = state.privateKeyContent,
                        minLines = 5,
                        sensitive = true,
                    ) { value -> onUpdate { it.copy(privateKeyContent = value) } }
                }
                item {
                    EditorTextField(
                        label = "私钥口令（可选）",
                        value = state.privateKeyPassphrase,
                        keyboardType = KeyboardType.Password,
                        sensitive = true,
                    ) { value -> onUpdate { it.copy(privateKeyPassphrase = value) } }
                }
                item {
                    FilterChip(
                        selected = !state.allowPasswordFallback,
                        onClick = {
                            onUpdate { current ->
                                current.copy(allowPasswordFallback = !current.allowPasswordFallback)
                            }
                        },
                        label = { Text(if (state.allowPasswordFallback) "允许密码回退" else "仅允许私钥登录") },
                    )
                }
                if (state.allowPasswordFallback) {
                    item {
                        EditorTextField(
                            label = "密码（私钥失败时回退）",
                            value = state.password,
                            keyboardType = KeyboardType.Password,
                            sensitive = true,
                        ) { value -> onUpdate { it.copy(password = value) } }
                    }
                }
            }
            if (state.transport == ServerTransportProtocol.ssh) item {
                FilterChip(
                    selected = state.isJumpHostEnabled,
                    onClick = { onUpdate { it.copy(isJumpHostEnabled = !it.isJumpHostEnabled) } },
                    label = { Text(if (state.isJumpHostEnabled) "已启用 SSH 跳板机" else "通过 SSH 跳板机连接（可选）") },
                )
            }
            if (state.isJumpHostEnabled) {
                item {
                    Text(
                        "先验证并登录跳板机，再建立到目标资产的加密通道。两台服务器的主机密钥和凭据会独立校验。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                item {
                    EditorTextField("跳板机地址", state.jumpHost) { value -> onUpdate { it.copy(jumpHost = value) } }
                }
                item {
                    EditorTextField("跳板机端口", state.jumpPort, keyboardType = KeyboardType.Number) { value ->
                        onUpdate { it.copy(jumpPort = value.filter(Char::isDigit)) }
                    }
                }
                item {
                    EditorTextField("跳板机用户名", state.jumpUsername) { value -> onUpdate { it.copy(jumpUsername = value) } }
                }
                item {
                    AuthMethodSelector(state.jumpAuthMethod) { method -> onUpdate { it.copy(jumpAuthMethod = method) } }
                }
                if (state.jumpAuthMethod == ServerAuthMethod.password) {
                    item {
                        EditorTextField(
                            label = "跳板机密码",
                            value = state.jumpPassword,
                            keyboardType = KeyboardType.Password,
                            sensitive = true,
                        ) { value -> onUpdate { it.copy(jumpPassword = value) } }
                    }
                } else {
                    item {
                        TextButton(
                            onClick = { jumpPrivateKeyPicker.launch(arrayOf("application/octet-stream", "text/plain", "*/*")) },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("从文件导入跳板机私钥") }
                    }
                    item {
                        EditorTextField(
                            label = "跳板机私钥内容",
                            value = state.jumpPrivateKeyContent,
                            minLines = 5,
                            sensitive = true,
                        ) { value -> onUpdate { it.copy(jumpPrivateKeyContent = value) } }
                    }
                    item {
                        EditorTextField(
                            label = "跳板机私钥口令（可选）",
                            value = state.jumpPrivateKeyPassphrase,
                            keyboardType = KeyboardType.Password,
                            sensitive = true,
                        ) { value -> onUpdate { it.copy(jumpPrivateKeyPassphrase = value) } }
                    }
                    item {
                        FilterChip(
                            selected = !state.jumpAllowPasswordFallback,
                            onClick = {
                                onUpdate { current ->
                                    current.copy(jumpAllowPasswordFallback = !current.jumpAllowPasswordFallback)
                                }
                            },
                            label = { Text(if (state.jumpAllowPasswordFallback) "允许跳板机密码回退" else "仅允许跳板机私钥登录") },
                        )
                    }
                    if (state.jumpAllowPasswordFallback) {
                        item {
                            EditorTextField(
                                label = "跳板机密码（私钥失败时回退）",
                                value = state.jumpPassword,
                                keyboardType = KeyboardType.Password,
                                sensitive = true,
                            ) { value -> onUpdate { it.copy(jumpPassword = value) } }
                        }
                    }
                }
            }
        }
    }
    if (state.deleteConfirmationVisible) {
        OrbitConfirmationDialog(
            title = "删除资产？",
            message = "将该资产移入最近删除，并移除本机凭据。保留期内可在个人中心恢复。",
            confirmLabel = "删除",
            onConfirm = onConfirmDelete,
            onDismiss = onDismissDeleteConfirmation,
            destructive = true,
        )
    }
    state.connectionTest?.let { connection ->
        EditorConnectionTestDialog(
            connection = connection,
            onTrust = onTrustTestHostKey,
            onDismiss = onDismissConnectionTest,
        )
    }
}

@Composable
private fun EditorConnectionTestDialog(
    connection: AssetConnectionUiState,
    onTrust: () -> Unit,
    onDismiss: () -> Unit,
) {
    val challenge = connection.hostKeyChallenge
    when (connection.phase) {
        ConnectionPhase.AwaitingHostKeyDecision if challenge != null -> OrbitFormDialog(
            title = "测试连接 · 确认服务器身份",
            confirmLabel = "信任并继续测试",
            onConfirm = onTrust,
            onDismiss = onDismiss,
        ) {
            Text("${challenge.host}:${challenge.port}\n${challenge.keyAlgorithm}\n${challenge.fingerprintSha256}")
        }
        ConnectionPhase.Connected -> OrbitConfirmationDialog(
            title = if (connection.transport == ServerTransportProtocol.telnet) "Telnet 端口测试成功" else "连接测试成功",
            message = if (connection.transport == ServerTransportProtocol.telnet) {
                "目标端口可达。Telnet 不支持服务器身份验证，实际认证将在打开终端时进行。"
            } else {
                "认证和服务器身份验证均已完成；测试会话已经安全关闭，资产尚未保存。"
            },
            confirmLabel = "完成",
            onConfirm = onDismiss,
            onDismiss = onDismiss,
        )
        is ConnectionPhase.Blocked, is ConnectionPhase.Failed -> OrbitConfirmationDialog(
            title = "连接测试未通过 · ${connection.phase.presentationHeadline()}",
            message = connection.phase.userMessage(),
            confirmLabel = "关闭",
            onConfirm = onDismiss,
            onDismiss = onDismiss,
        )
        else -> Unit
    }
}

private fun readPrivateKeyText(input: java.io.InputStream): String {
    val output = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8_192)
    var total = 0
    while (true) {
        val read = input.read(buffer)
        if (read < 0) break
        total += read
        require(total <= MAX_PRIVATE_KEY_BYTES)
        output.write(buffer, 0, read)
    }
    return output.toString(Charsets.UTF_8.name())
}

private const val MAX_PRIVATE_KEY_BYTES = 1_048_576

@Composable
private fun AuthMethodSelector(
    selected: ServerAuthMethod,
    onSelected: (ServerAuthMethod) -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(
            selected = selected == ServerAuthMethod.key,
            onClick = { onSelected(ServerAuthMethod.key) },
            label = { Text("私钥") },
        )
        FilterChip(
            selected = selected == ServerAuthMethod.password,
            onClick = { onSelected(ServerAuthMethod.password) },
            label = { Text("密码") },
        )
    }
}

@Composable
private fun TransportSelector(
    selected: ServerTransportProtocol,
    telnetEnabled: Boolean,
    onSelected: (ServerTransportProtocol) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("连接协议", style = MaterialTheme.typography.labelLarge)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(
                selected = selected == ServerTransportProtocol.ssh,
                onClick = { onSelected(ServerTransportProtocol.ssh) },
                label = { Text("SSH") },
            )
            FilterChip(
                selected = selected == ServerTransportProtocol.telnet,
                enabled = telnetEnabled,
                onClick = { onSelected(ServerTransportProtocol.telnet) },
                label = { Text("Telnet") },
            )
            if (selected == ServerTransportProtocol.rdp) {
                FilterChip(
                    selected = true,
                    enabled = false,
                    onClick = {},
                    label = { Text("RDP · 仅同步") },
                )
            }
        }
    }
}

@Composable
private fun NetworkDeviceProfileSelector(
    selected: NetworkDeviceProfile,
    onSelected: (NetworkDeviceProfile) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("网络设备类型", style = MaterialTheme.typography.labelLarge)
        LazyColumn(
            modifier = Modifier.fillMaxWidth().heightIn(max = 180.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            items(NetworkDeviceProfile.entries) { profile ->
                FilterChip(
                    modifier = Modifier.fillMaxWidth(),
                    selected = selected == profile,
                    onClick = { onSelected(profile) },
                    label = { Text(profile.displayName()) },
                )
            }
        }
    }
}

private fun NetworkDeviceProfile.displayName(): String = when (this) {
    NetworkDeviceProfile.auto -> "自动识别"
    NetworkDeviceProfile.huaweiVRP -> "Huawei VRP"
    NetworkDeviceProfile.h3cComware -> "H3C Comware"
    NetworkDeviceProfile.ciscoIOS -> "Cisco IOS"
    NetworkDeviceProfile.ciscoASA -> "Cisco ASA"
    NetworkDeviceProfile.juniperJunos -> "Juniper Junos"
    NetworkDeviceProfile.fortinetFortiGate -> "Fortinet FortiGate"
    NetworkDeviceProfile.paloAltoPANOS -> "Palo Alto PAN-OS"
    NetworkDeviceProfile.mikrotikRouterOS -> "MikroTik RouterOS"
    NetworkDeviceProfile.ruijie -> "Ruijie"
    NetworkDeviceProfile.sangfor -> "Sangfor"
    NetworkDeviceProfile.hillstone -> "Hillstone"
    NetworkDeviceProfile.checkPoint -> "Check Point"
    NetworkDeviceProfile.f5BIGIP -> "F5 BIG-IP"
    NetworkDeviceProfile.generic -> "通用设备"
}

@Composable
private fun EditorTextField(
    label: String,
    value: String,
    keyboardType: KeyboardType = KeyboardType.Text,
    minLines: Int = 1,
    sensitive: Boolean = false,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label) },
        minLines = minLines,
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = keyboardType),
        visualTransformation = if (sensitive) PasswordVisualTransformation() else VisualTransformation.None,
        singleLine = minLines == 1,
    )
}
