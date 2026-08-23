package com.orbitterm.android.feature.monitor

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.orbitterm.android.core.CheckedMonitorNativeClient
import com.orbitterm.android.core.CheckedExecNativeClient
import com.orbitterm.android.core.CheckedExecResult
import com.orbitterm.android.core.CheckedMonitorResult
import com.orbitterm.android.core.MonitorSnapshot
import com.orbitterm.android.core.OperationScopeCoordinator
import com.orbitterm.android.core.TcpLatencyProbe
import com.orbitterm.android.core.tcpProbeFailurePercent
import com.orbitterm.android.core.tcpLatencyPercentile
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.feature.terminal.ActiveTerminalSession
import com.orbitterm.android.domain.settings.MonitorRefreshInterval
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.orbitterm.android.domain.error.OrbitError
import com.orbitterm.android.domain.error.orbitNativeError
import com.orbitterm.android.ui.design.OrbitEmptyState
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.design.OrbitStatusLine
import dagger.hilt.android.lifecycle.HiltViewModel
import java.util.Locale
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class MonitorUiState(
    val sessionId: String? = null,
    val snapshot: MonitorSnapshot? = null,
    val history: List<MonitorSnapshot> = emptyList(),
    val loading: Boolean = false,
    val isPolling: Boolean = false,
    val error: OrbitError? = null,
    val processes: List<RemoteProcessUi> = emptyList(),
    val processesLoading: Boolean = false,
    val processesError: String? = null,
)

data class RemoteProcessUi(
    val pid: Int,
    val parentPid: Int,
    val user: String,
    val cpuPercent: Double,
    val memoryPercent: Double,
    val elapsedSeconds: Int,
    val state: String,
    val command: String,
)

enum class ProcessSort(val label: String) { CPU("CPU"), MEMORY("内存"), PID("PID"), NAME("名称") }

@HiltViewModel
class MonitorViewModel @Inject constructor(
    private val monitor: CheckedMonitorNativeClient,
    private val operations: OperationScopeCoordinator,
    private val assets: AssetRepository,
    private val tcpLatencyProbe: TcpLatencyProbe,
    private val exec: CheckedExecNativeClient,
) : ViewModel() {
    private val state = MutableStateFlow(MonitorUiState())
    val uiState = state.asStateFlow()
    private var pollingJob: Job? = null

    fun refresh(session: ActiveTerminalSession) {
        viewModelScope.launch {
            refreshSnapshot(session)
        }
    }

    fun startPolling(session: ActiveTerminalSession, refreshInterval: MonitorRefreshInterval) {
        if (pollingJob?.isActive == true) return
        val current = state.value.takeIf { it.sessionId == session.id } ?: MonitorUiState(sessionId = session.id)
        state.value = current.copy(isPolling = true, error = null)
        pollingJob = viewModelScope.launch {
            while (true) {
                refreshSnapshot(session)
                delay(refreshInterval.seconds * MILLIS_PER_SECOND)
            }
        }
    }

    fun stopPolling(sessionId: String? = null) {
        if (sessionId != null && state.value.sessionId != sessionId) return
        state.value.sessionId?.let { operations.invalidate("monitor_snapshot", it) }
        pollingJob?.cancel()
        pollingJob = null
        state.value = state.value.copy(isPolling = false, loading = false)
    }

    private suspend fun refreshSnapshot(session: ActiveTerminalSession) {
        if (state.value.loading) return
        val operation = operations.begin("monitor_snapshot", session.id) ?: return
        val current = state.value.takeIf { it.sessionId == session.id } ?: MonitorUiState(sessionId = session.id)
        state.value = current.copy(loading = true, error = null)
        val asset = withContext(Dispatchers.IO) { assets.findAsset(session.assetId) }
        val tcpLatency = asset?.let { tcpLatencyProbe.measure(it.host, it.port) }
        when (val result = withContext(Dispatchers.IO) { monitor.snapshot(session.baseSessionId) }) {
            is CheckedMonitorResult.Snapshot -> if (operations.isCurrent(operation) && state.value.sessionId == session.id) state.value = state.value.copy(
                snapshot = result.snapshot.copy(pingLatencyMs = tcpLatency),
                history = (current.history + result.snapshot.copy(pingLatencyMs = tcpLatency)).takeLast(RuntimeResourceBudget.MONITOR_HISTORY_SAMPLES),
                loading = false,
            )
            is CheckedMonitorResult.Failure -> if (operations.isCurrent(operation) && state.value.sessionId == session.id) state.value = state.value.copy(error = orbitNativeError(result.code), loading = false)
        }
    }

    fun refreshProcesses(session: ActiveTerminalSession) {
        if (state.value.processesLoading) return
        state.value = state.value.copy(processesLoading = true, processesError = null)
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                exec.execute(
                    session.baseSessionId,
                    "LC_ALL=C ps -eo pid=,ppid=,user=,pcpu=,pmem=,etimes=,stat=,comm= --sort=-pcpu | head -n 257",
                    timeoutSeconds = 12,
                )
            }
            state.value = when (result) {
                is CheckedExecResult.Completed -> if (result.exitStatus == 0) {
                    state.value.copy(
                        processes = parseRemoteProcesses(result.stdout),
                        processesLoading = false,
                        processesError = null,
                    )
                } else {
                    state.value.copy(processesLoading = false, processesError = "进程读取失败（退出码 ${result.exitStatus}）")
                }
                is CheckedExecResult.Failure -> state.value.copy(
                    processesLoading = false,
                    processesError = "进程读取失败：${result.code}",
                )
            }
        }
    }

    override fun onCleared() {
        pollingJob?.cancel()
        super.onCleared()
    }

    private companion object {
        const val MILLIS_PER_SECOND = 1_000L
    }
}

@Composable
fun MonitorPanel(
    session: ActiveTerminalSession,
    refreshInterval: MonitorRefreshInterval,
    modifier: Modifier = Modifier,
    viewModel: MonitorViewModel = viewModel(),
) {
    val state = viewModel.uiState.collectAsStateWithLifecycle().value
    LaunchedEffect(session.id, refreshInterval) {
        // A session switch keeps this composable alive. Cancel whichever poller is
        // active before binding the new session; otherwise startPolling() observes
        // the old job and silently keeps sampling the wrong server.
        viewModel.stopPolling()
        viewModel.startPolling(session, refreshInterval)
    }
    val isCurrentSession = state.sessionId == session.id
    val snapshot = state.snapshot.takeIf { isCurrentSession }
    val history = state.history.takeIf { isCurrentSession }.orEmpty()
    val currentError = state.error.takeIf { isCurrentSession }
    var processExpanded by remember(session.id) { mutableStateOf(false) }
    var processSearch by remember(session.id) { mutableStateOf("") }
    var processSort by remember(session.id) { mutableStateOf(ProcessSort.CPU) }
    LaunchedEffect(processExpanded, session.id) {
        while (processExpanded) {
            viewModel.refreshProcesses(session)
            delay(5_000)
        }
    }
    LazyColumn(
        modifier = modifier.fillMaxSize().background(MaterialTheme.colorScheme.background),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Text("系统监控", style = MaterialTheme.typography.titleMedium)
                    OrbitStatusLine(
                        label = if (state.isPolling) "已连接 · 每 ${refreshInterval.seconds} 秒采样" else "采样已暂停",
                        isActive = state.isPolling,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
                Row {
                    IconButton(onClick = { viewModel.refresh(session) }, enabled = !state.loading) {
                        Icon(Icons.Rounded.Refresh, contentDescription = if (state.loading) "正在刷新监控" else "刷新监控")
                    }
                    TextButton(onClick = {
                        if (state.isPolling) viewModel.stopPolling(session.id) else viewModel.startPolling(session, refreshInterval)
                    }) { Text(if (state.isPolling) "停止" else "开始") }
                }
            }
        }
        currentError?.let { error -> item {
            OrbitFeedbackBanner(
                message = "监控读取失败：${error.userMessage()} 诊断代码：${error.diagnosticCode}。",
                isError = true,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        } }
        snapshot?.let { values ->
            val recentTcpSamples = history.takeLast(20).map(MonitorSnapshot::pingLatencyMs)
            val tcpFailure = tcpProbeFailurePercent(recentTcpSamples)
            val tcpP50 = tcpLatencyPercentile(recentTcpSamples, 0.50)
            val tcpP95 = tcpLatencyPercentile(recentTcpSamples, 0.95)
            item {
                MonitorMetricStrip(
                    listOf(
                        "CPU" to values.cpuUsagePercent.percent(),
                        "内存" to values.memoryUsedPercent.percent(),
                        "磁盘" to values.diskUsedPercent.percent(),
                        "TCP 延迟" to (values.pingLatencyMs?.let { "${it.oneDecimal()} ms" } ?: "不可用"),
                        "TCP失败率" to (tcpFailure?.let { "${it.oneDecimal()}%" } ?: "暂无"),
                        "下载" to "${values.rxRateKbps.oneDecimal()} KB/s",
                        "上传" to "${values.txRateKbps.oneDecimal()} KB/s",
                    ),
                )
            }
            item { TrendCard(title = "CPU（5分钟）", value = values.cpuUsagePercent.percent()) {
                MonitorSparkline(listOf(history.map(MonitorSnapshot::cpuUsagePercent) to MaterialTheme.colorScheme.primary), ceiling = 100.0)
            } }
            item { TrendCard(title = "内存（5分钟）", value = values.memoryUsedPercent.percent()) {
                MonitorSparkline(listOf(history.map(MonitorSnapshot::memoryUsedPercent) to MaterialTheme.colorScheme.primary), ceiling = 100.0)
            } }
            item { TrendCard(title = "磁盘（5分钟）", value = values.diskUsedPercent.percent()) {
                MonitorSparkline(listOf(history.map(MonitorSnapshot::diskUsedPercent) to MaterialTheme.colorScheme.primary), ceiling = 100.0)
            } }
            item { TrendCard(
                title = "TCP 延迟（5分钟）",
                value = values.pingLatencyMs?.let {
                    "${it.oneDecimal()} ms · P50 ${tcpP50?.oneDecimal() ?: "--"} · P95 ${tcpP95?.oneDecimal() ?: "--"} · 失败 ${tcpFailure?.oneDecimal() ?: "0.0"}%"
                } ?: "不可用 · TCP 探测失败 ${tcpFailure?.oneDecimal() ?: "--"}%"
            ) {
                val latency = history.mapNotNull(MonitorSnapshot::pingLatencyMs)
                MonitorSparkline(listOf(latency to MaterialTheme.colorScheme.primary), ceiling = latency.maxOrNull()?.coerceAtLeast(1.0) ?: 1.0)
            } }
            item { TrendCard(title = "下载（5分钟）", value = "${values.rxRateKbps.oneDecimal()} KB/s") {
                val downloads = history.map(MonitorSnapshot::rxRateKbps)
                MonitorSparkline(listOf(downloads to MaterialTheme.colorScheme.primary), ceiling = downloads.maxOrNull()?.coerceAtLeast(1.0) ?: 1.0)
            } }
            item { TrendCard(title = "上传（5分钟）", value = "${values.txRateKbps.oneDecimal()} KB/s") {
                val uploads = history.map(MonitorSnapshot::txRateKbps)
                MonitorSparkline(listOf(uploads to MaterialTheme.colorScheme.secondary), ceiling = uploads.maxOrNull()?.coerceAtLeast(1.0) ?: 1.0)
            } }
            item {
                MobileProcessMonitorCard(
                    expanded = processExpanded,
                    onToggle = { processExpanded = !processExpanded },
                    search = processSearch,
                    onSearchChanged = { processSearch = it },
                    sort = processSort,
                    onSortChanged = { processSort = it },
                    processes = state.processes,
                    loading = state.processesLoading,
                    error = state.processesError,
                    onRefresh = { viewModel.refreshProcesses(session) },
                )
            }
        }
        if (snapshot == null && currentError == null) {
            item {
                OrbitEmptyState(
                    title = if (state.loading) "正在读取系统状态" else "暂无监控数据",
                    message = if (state.loading) "正在通过当前已验证 SSH 会话采样。" else "启动采样后，CPU、内存、磁盘与网络信息会显示在这里。",
                    modifier = Modifier.fillParentMaxSize(),
                )
            }
        }
    }
    DisposableEffect(session.id) {
        onDispose { viewModel.stopPolling(session.id) }
    }
}

internal fun parseRemoteProcesses(stdout: String): List<RemoteProcessUi> = stdout.lineSequence().mapNotNull { line ->
    val columns = line.trim().split(Regex("\\s+"), limit = 8)
    if (columns.size != 8) return@mapNotNull null
    RemoteProcessUi(
        pid = columns[0].toIntOrNull() ?: return@mapNotNull null,
        parentPid = columns[1].toIntOrNull() ?: return@mapNotNull null,
        user = columns[2],
        cpuPercent = columns[3].toDoubleOrNull() ?: return@mapNotNull null,
        memoryPercent = columns[4].toDoubleOrNull() ?: return@mapNotNull null,
        elapsedSeconds = columns[5].toIntOrNull() ?: return@mapNotNull null,
        state = columns[6],
        command = columns[7],
    )
}.toList()

@Composable
private fun MonitorMetricStrip(metrics: List<Pair<String, String>>) {
    LazyRow(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items(metrics, key = { it.first }) { (label, value) ->
            MetricCard(label, value, Modifier.widthIn(min = 92.dp))
        }
    }
}

@Composable
private fun MobileProcessMonitorCard(
    expanded: Boolean,
    onToggle: () -> Unit,
    search: String,
    onSearchChanged: (String) -> Unit,
    sort: ProcessSort,
    onSortChanged: (ProcessSort) -> Unit,
    processes: List<RemoteProcessUi>,
    loading: Boolean,
    error: String?,
    onRefresh: () -> Unit,
) {
    val query = search.trim()
    val visible = (if (query.isEmpty()) processes else processes.filter {
        it.command.contains(query, ignoreCase = true) ||
            it.user.contains(query, ignoreCase = true) ||
            it.pid.toString().contains(query)
    }).sortedWith(when (sort) {
        ProcessSort.CPU -> compareByDescending<RemoteProcessUi> { it.cpuPercent }.thenBy { it.pid }
        ProcessSort.MEMORY -> compareByDescending<RemoteProcessUi> { it.memoryPercent }.thenBy { it.pid }
        ProcessSort.PID -> compareBy { it.pid }
        ProcessSort.NAME -> compareBy(String.CASE_INSENSITIVE_ORDER) { it.command }
    })
    Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.78f)),
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("进程监控", modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                Text(if (processes.isEmpty()) "按需加载" else "${processes.size} 项", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
                TextButton(onClick = onToggle) { Text(if (expanded) "收起" else "展开") }
            }
            if (expanded) {
                OutlinedTextField(
                    value = search,
                    onValueChange = onSearchChanged,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("搜索名称、用户或 PID") },
                    singleLine = true,
                )
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(ProcessSort.entries, key = ProcessSort::name) { item ->
                        TextButton(onClick = { onSortChanged(item) }) {
                            Text(if (item == sort) "✓ ${item.label}" else item.label)
                        }
                    }
                    item { TextButton(onClick = onRefresh, enabled = !loading) { Text(if (loading) "刷新中…" else "刷新") } }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                if (visible.isEmpty() && error == null) {
                    Text(if (loading) "正在读取远端进程…" else "没有匹配的进程", color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    visible.take(100).forEach { process ->
                        Row(
                            modifier = Modifier.fillMaxWidth().background(
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                                androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
                            ).padding(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(process.command, maxLines = 1, style = MaterialTheme.typography.labelLarge)
                                Text(
                                    "PID ${process.pid} · ${process.user} · PPID ${process.parentPid}",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                            Text(
                                "CPU ${process.cpuPercent.oneDecimal()}%\n内存 ${process.memoryPercent.oneDecimal()}%",
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MetricCard(label: String, value: String, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)),
    ) {
        Column(modifier = Modifier.padding(horizontal = 7.dp, vertical = 9.dp)) {
            Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium, maxLines = 1)
            Text(value, style = MaterialTheme.typography.labelLarge, maxLines = 2)
        }
    }
}

@Composable
private fun SystemSummary(snapshot: MonitorSnapshot) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.78f)),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(snapshot.osName, style = MaterialTheme.typography.titleSmall)
            Text("${snapshot.cpuCoreCount} 核 CPU · ${snapshot.memoryAvailableMb} MB 可用内存", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("内存 ${snapshot.memoryTotalMb} MB · 磁盘 ${snapshot.diskTotalMb} MB", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun TrendCard(title: String, value: String, chart: @Composable () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.78f)),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(title, style = MaterialTheme.typography.labelLarge)
                Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
            }
            chart()
        }
    }
}

@Composable
private fun MonitorSparkline(series: List<Pair<List<Double>, Color>>, ceiling: Double) {
    Canvas(modifier = Modifier.fillMaxWidth().height(92.dp).padding(top = 10.dp)) {
        series.forEach { (values, color) ->
            if (values.isEmpty()) return@forEach
            val path = Path()
            values.forEachIndexed { index, value ->
                val x = if (values.size == 1) size.width else size.width * index / (values.size - 1)
                val y = size.height - (value.coerceIn(0.0, ceiling) / ceiling * size.height).toFloat()
                if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path, color = color, style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round))
            if (values.size == 1) drawCircle(color = color, radius = 4.dp.toPx(), center = androidx.compose.ui.geometry.Offset(0f, size.height - (values.first().coerceIn(0.0, ceiling) / ceiling * size.height).toFloat()))
        }
    }
}

private fun Double.percent(): String = "${oneDecimal()}%"
private fun Double.oneDecimal(): String = String.format(Locale.ROOT, "%.1f", this)
