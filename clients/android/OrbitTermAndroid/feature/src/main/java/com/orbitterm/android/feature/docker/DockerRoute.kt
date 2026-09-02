package com.orbitterm.android.feature.docker

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.core.CheckedDockerNativeClient
import com.orbitterm.android.core.OperationScopeCoordinator
import com.orbitterm.android.core.CheckedDockerResult
import com.orbitterm.android.core.DockerContainer
import com.orbitterm.android.core.DockerStats
import com.orbitterm.android.feature.terminal.ActiveTerminalSession
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.feature.terminal.selectActiveTerminalSession
import com.orbitterm.android.feature.presentation.OperationalContentPhase
import com.orbitterm.android.feature.presentation.OperationalContentPresentationMapper
import com.orbitterm.android.feature.presentation.OperationalModuleKind
import com.orbitterm.android.feature.presentation.OperationalFailureFeedback
import com.orbitterm.android.feature.presentation.OperationalRefreshAction
import com.orbitterm.android.feature.presentation.OperationalTransientSuccessFeedback
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.orbitterm.android.domain.error.OrbitError
import com.orbitterm.android.domain.error.orbitNativeError
import com.orbitterm.android.security.ClipboardContentKind
import com.orbitterm.android.security.SensitiveClipboard
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import com.orbitterm.android.ui.design.OrbitEmptyState
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.design.OrbitStatusLine
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import java.util.Locale

data class DockerUiState(
    val session: ActiveTerminalSession? = null,
    val containers: List<DockerContainer> = emptyList(),
    val statsByContainerId: Map<String, DockerStats> = emptyMap(),
    val loading: Boolean = false,
    val error: OrbitError? = null,
    val notice: String? = null,
    val actionContainerId: String? = null,
    val pendingAction: DockerPendingAction? = null,
    val detailContainer: DockerContainer? = null,
    val logsTitle: String? = null,
    val logsContent: String? = null,
    val logsTruncated: Boolean = false,
    val logContainer: DockerContainer? = null,
    val isLogAutoRefreshEnabled: Boolean = true,
)

data class DockerPendingAction(val container: DockerContainer, val action: String)

@HiltViewModel
class DockerViewModel @Inject constructor(
    private val sessions: TerminalSessionController,
    private val docker: CheckedDockerNativeClient,
    private val operations: OperationScopeCoordinator,
) : ViewModel() {
    private val state = MutableStateFlow(DockerUiState())
    private var logRefreshJob: Job? = null
    private var logRequestInFlight = false
    val uiState = state.asStateFlow()
    init {
        viewModelScope.launch {
            combine(sessions.activeSessions, sessions.selectedSessionId) { active, selectedId ->
                selectActiveTerminalSession(active, selectedId)
            }
                .distinctUntilChangedBy { it?.baseSessionId }
                .collect {
                    logRefreshJob?.cancel()
                    state.value = DockerUiState(session = it)
                    if (it != null) refresh()
                }
        }
    }
    fun refresh() {
        val session = state.value.session ?: return
        if (state.value.loading) return
        val operation = operations.begin("docker_refresh", session.id) ?: return
        state.value = state.value.copy(loading = true, error = null)
        viewModelScope.launch {
            when (val result = withContext(Dispatchers.IO) { docker.list(session.baseSessionId) }) {
                is CheckedDockerResult.Listed -> {
                    val stats = withContext(Dispatchers.IO) { docker.stats(session.baseSessionId) }
                    if (!operations.isCurrent(operation) || state.value.session?.baseSessionId != session.baseSessionId) return@launch
                    state.value = state.value.copy(
                        containers = result.containers,
                        statsByContainerId = (stats as? CheckedDockerResult.Stats)
                            ?.items
                            .orEmpty()
                            .associateBy(DockerStats::id),
                        loading = false,
                    )
                }
                is CheckedDockerResult.Failure -> if (operations.isCurrent(operation) && state.value.session?.baseSessionId == session.baseSessionId) {
                    state.value = state.value.copy(loading = false, error = orbitNativeError(result.code))
                }
                else -> if (operations.isCurrent(operation) && state.value.session?.baseSessionId == session.baseSessionId) {
                    state.value = state.value.copy(loading = false)
                }
            }
        }
    }
    fun requestAction(container: DockerContainer, action: String) {
        if (action == "remove" || action == "kill") {
            state.value = state.value.copy(pendingAction = DockerPendingAction(container, action))
        } else {
            performAction(container, action)
        }
    }

    fun confirmPendingAction() {
        val pending = state.value.pendingAction ?: return
        state.value = state.value.copy(pendingAction = null)
        performAction(pending.container, pending.action)
    }

    fun dismissPendingAction() { state.value = state.value.copy(pendingAction = null) }

    fun dismissNotice(message: String) {
        if (state.value.notice == message) state.value = state.value.copy(notice = null)
    }

    private fun performAction(container: DockerContainer, action: String) {
        val session = state.value.session ?: return
        if (state.value.actionContainerId != null) return
        val operation = operations.begin("docker_action", "${session.id}:${container.id}") ?: return
        state.value = state.value.copy(actionContainerId = container.id, error = null, notice = null)
        viewModelScope.launch {
            when (val result = withContext(Dispatchers.IO) {
                docker.action(session.baseSessionId, container.id, action)
            }) {
                CheckedDockerResult.Completed -> {
                    if (!operations.isCurrent(operation) || state.value.session?.baseSessionId != session.baseSessionId) return@launch
                    state.value = state.value.copy(
                        actionContainerId = null,
                        detailContainer = state.value.detailContainer?.takeUnless { it.id == container.id },
                        notice = "${container.name}：${action.label()}操作已完成。",
                    )
                    refresh()
                }
                is CheckedDockerResult.Failure -> if (operations.isCurrent(operation) && state.value.session?.baseSessionId == session.baseSessionId) {
                    state.value = state.value.copy(actionContainerId = null, error = orbitNativeError(result.code))
                }
                else -> if (operations.isCurrent(operation) && state.value.session?.baseSessionId == session.baseSessionId) {
                    state.value = state.value.copy(actionContainerId = null, error = orbitNativeError("invalid_docker_action_response"))
                }
            }
        }
    }

    fun showDetails(container: DockerContainer) { state.value = state.value.copy(detailContainer = container) }
    fun dismissDetails() { state.value = state.value.copy(detailContainer = null) }
    fun logs(container: DockerContainer) {
        logRefreshJob?.cancel()
        state.value = state.value.copy(
            logContainer = container,
            logsTitle = container.name,
            logsContent = "加载日志中…",
            logsTruncated = false,
        )
        refreshLogs()
        if (state.value.isLogAutoRefreshEnabled) startLogAutoRefresh()
    }

    fun setLogAutoRefresh(enabled: Boolean) {
        state.value = state.value.copy(isLogAutoRefreshEnabled = enabled)
        if (enabled && state.value.logContainer != null) startLogAutoRefresh() else logRefreshJob?.cancel()
    }

    private fun refreshLogs() {
        val container = state.value.logContainer ?: return
        val session = state.value.session ?: return
        if (logRequestInFlight) return
        val operation = operations.begin("docker_logs", "${session.id}:${container.id}") ?: return
        logRequestInFlight = true
        viewModelScope.launch {
            try {
                when (val result = withContext(Dispatchers.IO) { docker.logs(session.baseSessionId, container.id) }) {
                    is CheckedDockerResult.Logs -> if (
                        operations.isCurrent(operation) && state.value.session?.baseSessionId == session.baseSessionId && state.value.logContainer?.id == container.id
                    ) {
                        val current = state.value
                        if (current.logsContent != result.content || current.logsTruncated != result.wasTruncated) {
                            state.value = current.copy(
                                logsTitle = container.name,
                                logsContent = result.content,
                                logsTruncated = result.wasTruncated,
                            )
                        }
                    }
                    is CheckedDockerResult.Failure -> if (operations.isCurrent(operation) && state.value.session?.baseSessionId == session.baseSessionId) {
                        state.value = state.value.copy(error = orbitNativeError(result.code))
                    }
                    else -> Unit
                }
            } finally {
                logRequestInFlight = false
            }
        }
    }
    private fun startLogAutoRefresh() {
        logRefreshJob?.cancel()
        logRefreshJob = viewModelScope.launch {
            while (true) {
                delay(RuntimeResourceBudget.DOCKER_LOG_REFRESH_INTERVAL_MILLIS)
                refreshLogs()
            }
        }
    }
    fun dismissLogs() {
        logRefreshJob?.cancel()
        state.value = state.value.copy(logsTitle = null, logsContent = null, logsTruncated = false, logContainer = null)
    }
    override fun onCleared() { logRefreshJob?.cancel(); super.onCleared() }
}

@Composable
fun DockerRoute(modifier: Modifier = Modifier, viewModel: DockerViewModel = viewModel()) {
    val state = viewModel.uiState.collectAsStateWithLifecycle().value
    if (state.session == null) {
        OrbitEmptyState(
            title = "容器工作台",
            message = "请先在“会话”中打开一个已验证的 SSH 终端。",
            modifier = modifier,
        )
        return
    }
    val runningCount = state.containers.count(DockerContainer::isRunning)
    val failureDetail = state.error?.let {
        "Docker 操作失败：${it.userMessage()} 诊断代码：${it.diagnosticCode}。"
    }
    val contentPresentation = OperationalContentPresentationMapper.docker(
        isLoading = state.loading,
        hasContainers = state.containers.isNotEmpty(),
        failureDetail = failureDetail,
    )
    val actionPresentation = OperationalContentPresentationMapper.refreshAction(
        module = OperationalModuleKind.DOCKER,
        phase = contentPresentation.phase,
        isRefreshing = state.loading,
        hasContent = state.containers.isNotEmpty(),
    )
    Column(modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 2.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Column {
                Text("容器工作台", style = MaterialTheme.typography.titleSmall)
                OrbitStatusLine(
                    label = contentPresentation.headline,
                    isActive = contentPresentation.phase == OperationalContentPhase.READY ||
                        contentPresentation.phase == OperationalContentPhase.LOADING,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            OperationalRefreshAction(
                presentation = actionPresentation,
                onRefresh = viewModel::refresh,
            )
        }
        Surface(
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
        ) {
            Text("容器 ${state.containers.size} · 运行中 $runningCount · 已停止 ${state.containers.size - runningCount}", modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp), style = MaterialTheme.typography.bodySmall)
        }
        state.error?.let {
            OperationalFailureFeedback(
                content = contentPresentation,
                action = actionPresentation,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
        state.notice?.let { notice ->
            OperationalTransientSuccessFeedback(
                message = notice,
                onDismiss = viewModel::dismissNotice,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
        if (state.containers.isEmpty()) OrbitEmptyState(
            title = contentPresentation.headline,
            message = contentPresentation.detail,
            modifier = Modifier.weight(1f),
        )
        else LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) { items(state.containers, key = { it.id }) { container ->
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            ) { Column(Modifier.padding(18.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(container.name, modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    Text(container.status, color = if (container.isRunning) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
                }
                Text(container.image, modifier = Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                state.statsByContainerId[container.id]?.let { stats ->
                    Text(
                        "CPU ${stats.cpuPercent.oneDecimal()}% · 内存 ${stats.memoryPercent.oneDecimal()}% · ${stats.memoryUsage}",
                        modifier = Modifier.padding(top = 6.dp),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        "网络 ${stats.networkIo} · PIDs ${stats.pids}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    val acting = state.actionContainerId == container.id
                    if (container.isRunning) {
                        item { TextButton({ viewModel.requestAction(container, "stop") }, enabled = !acting) { Text("停止") } }
                        item { TextButton({ viewModel.requestAction(container, "restart") }, enabled = !acting) { Text("重启") } }
                        item { TextButton({ viewModel.requestAction(container, "pause") }, enabled = !acting) { Text("暂停") } }
                    } else if (container.isPaused) {
                        item { TextButton({ viewModel.requestAction(container, "unpause") }, enabled = !acting) { Text("继续") } }
                        item { TextButton({ viewModel.requestAction(container, "stop") }, enabled = !acting) { Text("停止") } }
                    } else {
                        item { TextButton({ viewModel.requestAction(container, "start") }, enabled = !acting) { Text("启动") } }
                        item { TextButton({ viewModel.requestAction(container, "remove") }, enabled = !acting) { Text("删除") } }
                    }
                    item { TextButton({ viewModel.logs(container) }) { Text("日志") } }
                    item { TextButton({ viewModel.showDetails(container) }) { Text("详情") } }
                }
                if (state.actionContainerId == container.id) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp))
            } }
        } }
    }
    state.pendingAction?.let { pending ->
        OrbitConfirmationDialog(
            title = if (pending.action == "kill") "强制停止容器？" else "删除容器？",
            message = if (pending.action == "kill") {
                "将立即终止容器“${pending.container.name}”，正在处理的请求可能丢失。"
            } else {
                "将删除已停止的容器“${pending.container.name}”。该操作不可撤销。"
            },
            confirmLabel = if (pending.action == "kill") "强制停止" else "删除",
            onConfirm = viewModel::confirmPendingAction,
            onDismiss = viewModel::dismissPendingAction,
            destructive = true,
        )
    }
    state.detailContainer?.let { container ->
        DockerDetailsDialog(
            container = container,
            stats = state.statsByContainerId[container.id],
            onForceStop = { viewModel.requestAction(container, "kill") },
            onDismiss = viewModel::dismissDetails,
        )
    }
    state.logsContent?.let { logs ->
        val scrollState = rememberScrollState()
        val scope = rememberCoroutineScope()
        AlertDialog(
            onDismissRequest = viewModel::dismissLogs,
            title = { Text("日志 · ${state.logsTitle}") },
            text = {
                Column {
                    if (state.logsTruncated) {
                        Text(
                            "日志过长，已保留最新的 32 KiB。",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier.padding(bottom = 8.dp),
                        )
                    }
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant,
                    ) {
                        Text(
                            text = logs.ifBlank { "暂无日志" },
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 420.dp)
                                .verticalScroll(scrollState)
                                .padding(12.dp),
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            },
            confirmButton = { TextButton(viewModel::dismissLogs) { Text("关闭") } },
            dismissButton = {
                Row {
                    TextButton(onClick = { viewModel.setLogAutoRefresh(!state.isLogAutoRefreshEnabled) }) { Text(if (state.isLogAutoRefreshEnabled) "停止自动" else "自动刷新") }
                    TextButton(onClick = { scope.launch { scrollState.animateScrollTo(scrollState.maxValue) } }) { Text("最新日志") }
                }
            },
            shape = androidx.compose.foundation.shape.RoundedCornerShape(28.dp),
            containerColor = MaterialTheme.colorScheme.surface,
        )
    }
}

private val DockerContainer.isRunning: Boolean get() = state.equals("running", ignoreCase = true)
private val DockerContainer.isPaused: Boolean get() = state.equals("paused", ignoreCase = true)
private fun Double.oneDecimal(): String = String.format(Locale.ROOT, "%.1f", this)
private fun String.label(): String = when (this) {
    "start" -> "启动"; "stop" -> "停止"; "restart" -> "重启"; "kill" -> "强制停止"; "pause" -> "暂停"; "unpause" -> "恢复"; "remove" -> "删除"; else -> this
}

@Composable
private fun DockerDetailsDialog(
    container: DockerContainer,
    stats: DockerStats?,
    onForceStop: () -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("容器详情") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(container.name, style = MaterialTheme.typography.titleMedium)
                DockerDetailRow("状态", container.status)
                DockerDetailRow("镜像", container.image)
                DockerDetailRow("容器 ID", container.id)
                stats?.let {
                    DockerDetailRow("CPU", "${it.cpuPercent.oneDecimal()}%")
                    DockerDetailRow("内存", "${it.memoryPercent.oneDecimal()}% · ${it.memoryUsage}")
                    DockerDetailRow("网络", it.networkIo)
                    DockerDetailRow("块 IO", it.blockIo)
                    DockerDetailRow("进程", it.pids.toString())
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("关闭") } },
        dismissButton = {
            Row {
                if (container.isRunning) {
                    TextButton(onClick = onForceStop) {
                        Text("强制停止", color = MaterialTheme.colorScheme.error)
                    }
                }
                TextButton(onClick = {
                    SensitiveClipboard.copy(
                        context,
                        "Docker container ID",
                        container.id,
                        ClipboardContentKind.ORDINARY_TEXT,
                    )
                }) { Text("复制容器 ID") }
            }
        },
        shape = androidx.compose.foundation.shape.RoundedCornerShape(28.dp),
        containerColor = MaterialTheme.colorScheme.surface,
    )
}

@Composable
private fun DockerDetailRow(label: String, value: String) {
    Column {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}
