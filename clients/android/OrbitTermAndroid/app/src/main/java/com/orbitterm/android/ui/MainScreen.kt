package com.orbitterm.android.ui

import android.content.Intent
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.rounded.CloudSync
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Fingerprint
import androidx.compose.material.icons.rounded.Inventory2
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.SettingsEthernet
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.Restore
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.orbitterm.android.app.AppDestination
import com.orbitterm.android.app.OrbitTermAppUiState
import com.orbitterm.android.feature.assets.AssetsRoute
import com.orbitterm.android.feature.sftp.SftpRoute
import com.orbitterm.android.feature.docker.DockerRoute
import com.orbitterm.android.feature.terminal.TerminalSessionsRoute
import com.orbitterm.android.feature.security.PortForwardingDialog
import com.orbitterm.android.feature.security.SshKeyManagementDialog
import com.orbitterm.android.domain.settings.AppThemePreference
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.domain.settings.TerminalAppearance
import com.orbitterm.android.domain.settings.TerminalThemePreference
import com.orbitterm.android.domain.settings.MonitorRefreshInterval
import com.orbitterm.android.app.SyncStatus
import com.orbitterm.android.app.RecentlyDeletedUiState
import com.orbitterm.android.app.SecurityOperationFeedback
import com.orbitterm.android.app.SecurityOperationPresentation
import com.orbitterm.android.sync.AssetSyncConflict
import com.orbitterm.android.domain.deeplink.ServerDeepLink
import com.orbitterm.android.domain.error.PrivacySafeErrorMetrics
import com.orbitterm.android.security.ClipboardContentKind
import com.orbitterm.android.security.SensitiveClipboard
import com.orbitterm.android.ui.theme.appColorThemeAccent
import com.orbitterm.android.ui.theme.appColorThemeHighlight
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.design.OrbitFormDialog
import com.orbitterm.android.ui.design.OrbitTerminalThemeSwatch

internal const val ORBIT_LEGAL_TERMS_VERSION = "2026-08-22"
internal const val ORBIT_LEGAL_TERMS = """OrbitTerm 使用条款、免责声明与隐私说明
生效日期：2026-08-21

1. 授权范围
您只能连接、管理您拥有、管理或已取得明确合法授权的设备、账户、网络及数据。不得将本软件用于未授权访问、规避安全控制、破坏服务或其他违法活动。

2. 账户与安全责任
您负责妥善保管账户密码、主密码、SSH 私钥、令牌和远程资产凭据，并负责由您的账户或设备发起的操作。主密码和端到端加密密钥无法由 OrbitTerm 代为恢复；遗失可能导致加密数据无法解密。

3. 同步、备份与数据
跨设备同步采用端到端加密，但同步服务不等同于完整备份或长期托管。您应自行保留必要的独立备份，并在删除、覆盖、权限修改、批量命令、端口映射、进程终止等操作前核对目标与影响。

4. 高风险操作与远端结果
SSH、Telnet、RDP、SFTP、Docker、批量命令及端口映射会直接影响远端系统。网络中断、权限、系统差异、第三方组件或远端配置可能导致失败、重复、部分完成或数据损失。

5. 隐私与诊断
OrbitTerm 按最小必要原则处理数据。脱敏诊断不应包含密码、私钥、令牌、命令正文、终端内容或远端文件内容；导出、复制、截图或分享前，您仍应检查并移除敏感信息。

6. 第三方服务与开源组件
操作系统能力、网络、远端服务及开源组件的可用性、安全策略和许可由相应提供者负责，OrbitTerm 不保证其持续可用或完全兼容。

7. 免责声明与责任限制
在适用法律允许的最大范围内，本软件按“现状”和“可用状态”提供，不对不间断运行、无错误、适用于特定目的或绝对安全作出保证。开发者不对间接、附带、特殊、惩罚性或后果性损失承担责任；法律不允许排除的法定责任不受本条限制。

8. 更新、暂停与联系
为安全、兼容或合规需要，功能、协议和条款可能更新。严重滥用或违法使用时，相关服务可被限制。问题、权利请求或安全报告可通过应用内“帮助与反馈”联系维护者。

继续使用即表示您已阅读并同意上述条款；若不同意，请停止使用相关功能。"""

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    uiState: OrbitTermAppUiState,
    onDestinationSelected: (AppDestination) -> Unit,
    deepLink: ServerDeepLink?,
    onDeepLinkConsumed: () -> Unit,
    onThemePreferenceSelected: (AppThemePreference) -> Unit,
    onColorThemeSelected: (AppColorTheme) -> Unit,
    onTerminalThemeSelected: (TerminalThemePreference) -> Unit,
    onTerminalFontSizeSelected: (Int) -> Unit,
    onMonitorRefreshIntervalSelected: (MonitorRefreshInterval) -> Unit,
    onTelnetEnabledChanged: (Boolean) -> Unit,
    accountName: String,
    administratorEmail: String,
    onLogout: () -> Unit,
    onLock: () -> Unit,
    biometricEnabled: Boolean,
    biometricFeedback: SecurityOperationFeedback?,
    loginPasswordFeedback: SecurityOperationFeedback?,
    masterPasswordFeedback: SecurityOperationFeedback?,
    onToggleBiometric: () -> Unit,
    isChangingLoginPassword: Boolean,
    onChangeLoginPassword: (String, String, String) -> Unit,
    isRotatingMasterPassword: Boolean,
    hasPendingMasterPasswordCommit: Boolean,
    onFinishPendingMasterPasswordCommit: () -> Unit,
    onRotateMasterPassword: (String, String, String, String) -> Unit,
    syncStatus: SyncStatus,
    onRetrySync: () -> Unit,
    onRetryBlockedSync: () -> Unit,
    onDiscardBlockedSync: () -> Unit,
    onResolveConflict: (AssetSyncConflict, Boolean) -> Unit,
    recentlyDeletedState: RecentlyDeletedUiState,
    onLoadRecentlyDeleted: () -> Unit,
    onRestoreRecentlyDeleted: (String) -> Unit,
    onPurgeRecentlyDeleted: (String) -> Unit,
    onDismissRecentlyDeletedFeedback: () -> Unit,
) {
    BackHandler(enabled = uiState.destination != AppDestination.Servers) {
        onDestinationSelected(AppDestination.Servers)
    }
    Scaffold(
        topBar = {
            if (
                uiState.destination != AppDestination.Servers &&
                (uiState.destination != AppDestination.Sessions || !uiState.hasActiveTerminalSession)
            ) {
                OrbitCompactPageBar(
                    title = destinationTitle(uiState.destination),
                    syncStatus = syncStatus,
                    onRetrySync = onRetrySync,
                    onNavigateUp = if (uiState.destination == AppDestination.Sessions) {
                        { onDestinationSelected(AppDestination.Servers) }
                    } else {
                        null
                    },
                )
            }
        },
        bottomBar = {
            if (!shouldShowBottomDock(uiState.destination, uiState.hasActiveTerminalSession)) return@Scaffold
            NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
                    AppDestination.entries.forEach { destination ->
                        NavigationBarItem(
                        selected = uiState.destination == destination,
                        onClick = { onDestinationSelected(destination) },
                        icon = {
                            Icon(imageVector = destinationIcon(destination), contentDescription = null)
                        },
                        label = { Text(destinationLabel(destination)) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            selectedTextColor = MaterialTheme.colorScheme.primary,
                            indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                            unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                        )
                    }
            }
        },
    ) { paddingValues ->
        when (uiState.destination) {
            AppDestination.Servers -> AssetsRoute(
                modifier = Modifier.padding(paddingValues),
                telnetEnabled = uiState.telnetEnabled,
                onTerminalOpened = { onDestinationSelected(AppDestination.Sessions) },
                deepLink = deepLink,
                onDeepLinkConsumed = onDeepLinkConsumed,
                isSynchronizing = syncStatus == SyncStatus.Syncing,
                onSyncRequested = onRetrySync,
            )
            AppDestination.Sessions -> TerminalSessionsRoute(
                terminalAppearance = uiState.terminalAppearance,
                monitorRefreshInterval = uiState.monitorRefreshInterval,
                modifier = Modifier.padding(paddingValues),
                onBackToServers = { onDestinationSelected(AppDestination.Servers) },
            )
            AppDestination.More -> MoreScreen(
                preference = uiState.appThemePreference,
                colorTheme = uiState.appColorTheme,
                terminalAppearance = uiState.terminalAppearance,
                monitorRefreshInterval = uiState.monitorRefreshInterval,
                modifier = Modifier.padding(paddingValues),
                onPreferenceSelected = onThemePreferenceSelected,
                onColorThemeSelected = onColorThemeSelected,
                onTerminalThemeSelected = onTerminalThemeSelected,
                onTerminalFontSizeSelected = onTerminalFontSizeSelected,
                onMonitorRefreshIntervalSelected = onMonitorRefreshIntervalSelected,
                telnetEnabled = uiState.telnetEnabled,
                onTelnetEnabledChanged = onTelnetEnabledChanged,
                accountName = accountName,
                administratorEmail = administratorEmail,
                onLogout = onLogout,
                onLock = onLock,
                biometricEnabled = biometricEnabled,
                biometricFeedback = biometricFeedback,
                loginPasswordFeedback = loginPasswordFeedback,
                masterPasswordFeedback = masterPasswordFeedback,
                onToggleBiometric = onToggleBiometric,
                isChangingLoginPassword = isChangingLoginPassword,
                onChangeLoginPassword = onChangeLoginPassword,
                isRotatingMasterPassword = isRotatingMasterPassword,
                hasPendingMasterPasswordCommit = hasPendingMasterPasswordCommit,
                onFinishPendingMasterPasswordCommit = onFinishPendingMasterPasswordCommit,
                onRotateMasterPassword = onRotateMasterPassword,
                syncStatus = syncStatus,
                onSync = onRetrySync,
                onRetryBlockedSync = onRetryBlockedSync,
                onDiscardBlockedSync = onDiscardBlockedSync,
                recentlyDeletedState = recentlyDeletedState,
                onLoadRecentlyDeleted = onLoadRecentlyDeleted,
                onRestoreRecentlyDeleted = onRestoreRecentlyDeleted,
                onPurgeRecentlyDeleted = onPurgeRecentlyDeleted,
                onDismissRecentlyDeletedFeedback = onDismissRecentlyDeletedFeedback,
            )
            AppDestination.Sftp -> SftpRoute(modifier = Modifier.padding(paddingValues))
            AppDestination.Docker -> DockerRoute(modifier = Modifier.padding(paddingValues))
        }
    }
    val conflict = (syncStatus as? SyncStatus.Succeeded)?.outbox?.conflicts?.firstOrNull()
    conflict?.let { pending ->
        val presentation = pending.presentation()
        AlertDialog(
            onDismissRequest = {},
            title = { Text(presentation.title) },
            text = { Text(presentation.detail) },
            confirmButton = { TextButton(onClick = { onResolveConflict(pending, true) }) { Text(presentation.keepLocalLabel) } },
            dismissButton = { TextButton(onClick = { onResolveConflict(pending, false) }) { Text(presentation.keepCloudLabel) } },
            shape = RoundedCornerShape(28.dp),
            containerColor = MaterialTheme.colorScheme.surface,
        )
    }
}

@Composable
private fun MoreScreen(
    preference: AppThemePreference,
    colorTheme: AppColorTheme,
    terminalAppearance: TerminalAppearance,
    modifier: Modifier,
    onPreferenceSelected: (AppThemePreference) -> Unit,
    onColorThemeSelected: (AppColorTheme) -> Unit,
    onTerminalThemeSelected: (TerminalThemePreference) -> Unit,
    onTerminalFontSizeSelected: (Int) -> Unit,
    monitorRefreshInterval: MonitorRefreshInterval,
    onMonitorRefreshIntervalSelected: (MonitorRefreshInterval) -> Unit,
    telnetEnabled: Boolean,
    onTelnetEnabledChanged: (Boolean) -> Unit,
    accountName: String,
    administratorEmail: String,
    onLogout: () -> Unit,
    onLock: () -> Unit,
    biometricEnabled: Boolean,
    biometricFeedback: SecurityOperationFeedback?,
    loginPasswordFeedback: SecurityOperationFeedback?,
    masterPasswordFeedback: SecurityOperationFeedback?,
    onToggleBiometric: () -> Unit,
    isChangingLoginPassword: Boolean,
    onChangeLoginPassword: (String, String, String) -> Unit,
    isRotatingMasterPassword: Boolean,
    hasPendingMasterPasswordCommit: Boolean,
    onFinishPendingMasterPasswordCommit: () -> Unit,
    onRotateMasterPassword: (String, String, String, String) -> Unit,
    syncStatus: SyncStatus,
    onSync: () -> Unit,
    onRetryBlockedSync: () -> Unit,
    onDiscardBlockedSync: () -> Unit,
    recentlyDeletedState: RecentlyDeletedUiState,
    onLoadRecentlyDeleted: () -> Unit,
    onRestoreRecentlyDeleted: (String) -> Unit,
    onPurgeRecentlyDeleted: (String) -> Unit,
    onDismissRecentlyDeletedFeedback: () -> Unit,
) {
    val context = LocalContext.current
    val appVersion = remember(context) {
        runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull().orEmpty().ifBlank { "unknown" }
    }
    var diagnosticsCopied by remember { mutableStateOf(false) }
    var feedbackLaunchError by remember { mutableStateOf<String?>(null) }
    var switchAccountConfirmationVisible by remember { mutableStateOf(false) }
    var logoutConfirmationVisible by remember { mutableStateOf(false) }
    var loginPasswordChangeVisible by remember { mutableStateOf(false) }
    var masterRotationVisible by remember { mutableStateOf(false) }
    var recentlyDeletedVisible by remember { mutableStateOf(false) }
    var purgeCandidateId by remember { mutableStateOf<String?>(null) }
    var termsVisible by remember { mutableStateOf(false) }
    var keyManagementVisible by remember { mutableStateOf(false) }
    var portForwardingVisible by remember { mutableStateOf(false) }
    var telnetEnableConfirmationVisible by remember { mutableStateOf(false) }
    var aboutVisible by remember { mutableStateOf(false) }
    var discardBlockedSyncConfirmationVisible by remember { mutableStateOf(false) }
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { PersonalCenterHeader(accountName) }
        if (hasPendingMasterPasswordCommit) {
            item {
                SettingsSectionCard(
                    icon = { Icon(Icons.Rounded.Lock, contentDescription = null) },
                    title = "完成安全更新",
                    subtitle = "云端主密码已更新，本机仍需完成最后一步",
                ) {
                    OrbitFeedbackBanner(
                        message = "请在当前登录会话有效期间完成本机更新。完成后生物识别会保持关闭，可用新主密码重新启用。",
                        isError = true,
                    )
                    TextButton(
                        enabled = !isRotatingMasterPassword,
                        onClick = onFinishPendingMasterPasswordCommit,
                    ) {
                        Text(if (isRotatingMasterPassword) "正在完成…" else "完成本地主密码更新")
                    }
                }
            }
        }
        item {
            AccountSecuritySection(
                biometricEnabled = biometricEnabled,
                biometricFeedback = biometricFeedback,
                loginPasswordFeedback = loginPasswordFeedback,
                masterPasswordFeedback = masterPasswordFeedback,
                isChangingLoginPassword = isChangingLoginPassword,
                isRotatingMasterPassword = isRotatingMasterPassword,
                onToggleBiometric = onToggleBiometric,
                onChangeLoginPasswordRequested = { loginPasswordChangeVisible = true },
                onRotateMasterPasswordRequested = { masterRotationVisible = true },
                onLock = onLock,
            )
        }
        item {
            SettingsSectionCard(
                icon = { Icon(Icons.Rounded.Palette, contentDescription = null) },
                title = "设置与偏好",
                subtitle = "界面、终端、同步、诊断与应用信息",
            ) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(AppThemePreference.entries) { candidate ->
                        FilterChip(
                            selected = preference == candidate,
                            onClick = { onPreferenceSelected(candidate) },
                            label = { Text(candidate.label()) },
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
                SettingLabel("界面配色", colorTheme.displayName)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    AppColorTheme.entries.forEach { candidate ->
                        AppColorThemeChip(
                            theme = candidate,
                            selected = colorTheme == candidate,
                            onClick = { onColorThemeSelected(candidate) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                Text(
                    colorTheme.description,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
                SettingLabel("终端外观", "${terminalAppearance.theme.displayName} · ${terminalAppearance.fontSizeSp}sp")
                TerminalPalettePreview(terminalAppearance.theme)
                SettingLabel("终端主题", "为当前和新建会话即时生效")
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    TerminalThemePreference.entries.forEach { candidate ->
                        TerminalThemeChip(
                            theme = candidate,
                            selected = terminalAppearance.theme == candidate,
                            onClick = { onTerminalThemeSelected(candidate) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SettingLabel("终端字号", "${terminalAppearance.fontSizeSp}sp", Modifier.weight(1f))
                    Surface(
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        shape = RoundedCornerShape(14.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            IconButton(
                                enabled = terminalAppearance.fontSizeSp > 8,
                                onClick = { onTerminalFontSizeSelected(terminalAppearance.fontSizeSp - 1) },
                            ) { Text("−", style = MaterialTheme.typography.titleLarge) }
                            Text("${terminalAppearance.fontSizeSp}", style = MaterialTheme.typography.labelLarge)
                            IconButton(
                                enabled = terminalAppearance.fontSizeSp < 24,
                                onClick = { onTerminalFontSizeSelected(terminalAppearance.fontSizeSp + 1) },
                            ) { Text("+", style = MaterialTheme.typography.titleLarge) }
                        }
                    }
                }
                SettingLabel("终端与连接", "协议能力必须由用户主动开启")
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("启用 Telnet", style = MaterialTheme.typography.labelLarge)
                        Text(
                            "明文传输，仅建议在可信隔离网络使用",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    Switch(
                        checked = telnetEnabled,
                        onCheckedChange = { enabled ->
                            if (enabled) telnetEnableConfirmationVisible = true
                            else onTelnetEnabledChanged(false)
                        },
                    )
                }
                SettingLabel("同步与诊断", syncStatus.presentation().detail)
                SyncStatusFeedback(
                    status = syncStatus,
                    onRetry = onSync,
                    modifier = Modifier.padding(top = 10.dp),
                )
                val blockedSyncCount = (syncStatus as? SyncStatus.Succeeded)?.outbox?.blocked ?: 0
                if (blockedSyncCount > 0) {
                    Text(
                        "$blockedSyncCount 项本地同步变更已停止后台重试。可在检查服务设置后重新尝试，或确认不再需要后丢弃。",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = onRetryBlockedSync) { Text("重新尝试受阻项目") }
                        TextButton(onClick = { discardBlockedSyncConfirmationVisible = true }) {
                            Text("丢弃受阻项目")
                        }
                    }
                }
                SettingLabel("监控刷新间隔", "高级设置 · 已验证 SSH 会话")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(MonitorRefreshInterval.entries) { candidate ->
                        FilterChip(
                            selected = monitorRefreshInterval == candidate,
                            onClick = { onMonitorRefreshIntervalSelected(candidate) },
                            label = { Text("${candidate.seconds} 秒") },
                        )
                    }
                }
                TextButton(
                    onClick = onSync,
                    enabled = syncStatus !is SyncStatus.Syncing,
                    modifier = Modifier.padding(top = 6.dp),
                ) {
                    Icon(Icons.Rounded.CloudSync, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (syncStatus is SyncStatus.Syncing) "同步中…" else "立即同步")
                }
                SettingLabel("最近删除", "查看、恢复或永久清理云端删除记录")
                TextButton(onClick = {
                    recentlyDeletedVisible = true
                    onLoadRecentlyDeleted()
                }) {
                    Icon(Icons.Rounded.Restore, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("管理最近删除")
                }
                Spacer(Modifier.height(6.dp))
                SettingLabel("应用诊断", "仅导出本机版本与偏好，不含资产和凭据")
                Text(
                    "需要反馈问题时，可复制一段不含敏感信息的诊断文本。",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
                TextButton(onClick = {
                    diagnosticsCopied = SensitiveClipboard.copy(
                        context,
                        "OrbitTerm diagnostics",
                        diagnosticText(
                            context = context,
                            appTheme = preference,
                            terminalAppearance = terminalAppearance,
                            monitorRefreshInterval = monitorRefreshInterval,
                            syncStatus = syncStatus,
                        ),
                        ClipboardContentKind.ORDINARY_TEXT,
                    )
                }) {
                    Icon(Icons.Rounded.BugReport, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (diagnosticsCopied) "诊断信息已复制" else "复制诊断信息")
                }
            }
        }
        item {
            SettingsSectionCard(
                icon = { Icon(Icons.Rounded.SettingsEthernet, contentDescription = null) },
                title = "运维工具",
                subtitle = "密钥库、端口映射与多资产命令",
            ) {
                SettingLabel("SSH 密钥管理", "Android Keystore 本机加密与端到端加密同步")
                TextButton(onClick = { keyManagementVisible = true }) { Text("打开密钥管理") }
                SettingLabel("端口映射", "保存配置并通过已验证 SSH 会话启动")
                TextButton(onClick = { portForwardingVisible = true }) { Text("打开端口映射") }
                SettingLabel("批量命令", "从服务器页进入批量选择，按资产查看隔离回执")
            }
        }
        item {
            SettingsSectionCard(
                icon = { Icon(Icons.Rounded.BugReport, contentDescription = null) },
                title = "帮助与信息",
                subtitle = "帮助、问题反馈与 OrbitTerm 信息",
            ) {
                SettingLabel("帮助与反馈", "联系支持并反馈问题")
                TextButton(onClick = {
                    val emailIntent = Intent(Intent.ACTION_SENDTO).apply {
                        data = "mailto:$administratorEmail".toUri()
                        putExtra(Intent.EXTRA_SUBJECT, "OrbitTerm Android 反馈")
                    }
                    val launched = runCatching { context.startActivity(emailIntent) }.isSuccess
                    feedbackLaunchError = if (launched) null else "未找到可用的邮件应用，可复制邮箱后发送。"
                }) {
                    Text("发送邮件至 $administratorEmail")
                }
                feedbackLaunchError?.let { message ->
                    OrbitFeedbackBanner(message = message, isError = true)
                }
                TextButton(onClick = { aboutVisible = true }) { Text("关于 OrbitTerm") }
                TextButton(onClick = { termsVisible = true }) { Text("使用条款与隐私") }
            }
        }
        item {
            SettingsSectionCard(
                icon = { Icon(Icons.Rounded.Lock, contentDescription = null) },
                title = "当前会话",
                subtitle = "本机数据始终按账户隔离",
            ) {
                TextButton(onClick = { switchAccountConfirmationVisible = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.AutoMirrored.Rounded.Logout, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("切换账户")
                }
                TextButton(onClick = { logoutConfirmationVisible = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.AutoMirrored.Rounded.Logout, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    Spacer(Modifier.width(8.dp))
                    Text("退出登录", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
    if (telnetEnableConfirmationVisible) {
        OrbitConfirmationDialog(
            title = "启用 Telnet？",
            message = "Telnet 不加密用户名、密码和命令，也无法验证服务器身份。仅应在可信、隔离的内网中使用。",
            confirmLabel = "了解风险并启用",
            onConfirm = {
                telnetEnableConfirmationVisible = false
                onTelnetEnabledChanged(true)
            },
            onDismiss = { telnetEnableConfirmationVisible = false },
            destructive = true,
        )
    }
    if (aboutVisible) {
        OrbitConfirmationDialog(
            title = "关于 OrbitTerm",
            message = "原生安全远程工作台\nAndroid 版本 $appVersion\n\n资产凭据仅在当前账户的本机安全边界内解锁。",
            confirmLabel = "完成",
            onConfirm = { aboutVisible = false },
            onDismiss = { aboutVisible = false },
        )
    }
    if (switchAccountConfirmationVisible) {
        OrbitConfirmationDialog(
            title = "切换账号？",
            message = "将锁定应用并结束当前登录会话，随后回到登录页。已加密的本机资产会按账户隔离保留，不会展示给下一个账号。",
            confirmLabel = "继续",
            onConfirm = {
                switchAccountConfirmationVisible = false
                onLogout()
            },
            onDismiss = { switchAccountConfirmationVisible = false },
            destructive = true,
        )
    }
    if (logoutConfirmationVisible) {
        OrbitConfirmationDialog(
            title = SecurityOperationPresentation.LOGOUT_TITLE,
            message = SecurityOperationPresentation.LOGOUT_MESSAGE,
            confirmLabel = SecurityOperationPresentation.LOGOUT_CONFIRM,
            onConfirm = {
                logoutConfirmationVisible = false
                onLogout()
            },
            onDismiss = { logoutConfirmationVisible = false },
            destructive = true,
        )
    }
    if (masterRotationVisible) {
        MasterPasswordRotationDialog(
            isRotating = isRotatingMasterPassword,
            error = masterPasswordFeedback?.takeIf { it.isError }?.message,
            onDismiss = { if (!isRotatingMasterPassword) masterRotationVisible = false },
            onConfirm = { current, next, confirmation, loginPassword ->
                onRotateMasterPassword(current, next, confirmation, loginPassword)
            },
        )
    }
    if (loginPasswordChangeVisible) {
        LoginPasswordChangeDialog(
            isSubmitting = isChangingLoginPassword,
            error = loginPasswordFeedback?.takeIf { it.isError }?.message,
            onDismiss = { if (!isChangingLoginPassword) loginPasswordChangeVisible = false },
            onConfirm = onChangeLoginPassword,
        )
    }
    if (recentlyDeletedVisible) {
        val recentlyDeletedPresentation = recentlyDeletedState.presentation()
        AlertDialog(
            onDismissRequest = { if (recentlyDeletedState.mutatingAssetId == null) recentlyDeletedVisible = false },
            title = { Text("最近删除") },
            text = {
                Column(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 480.dp).verticalScroll(androidx.compose.foundation.rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        "删除记录由服务器按保留期限清理。恢复会重新写入本机安全存储；永久删除不可撤销。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    when {
                        recentlyDeletedState.isLoading && recentlyDeletedState.items.isEmpty() -> Text(recentlyDeletedPresentation.headline)
                        recentlyDeletedState.items.isEmpty() && recentlyDeletedState.error == null -> Column {
                            Text(recentlyDeletedPresentation.headline, style = MaterialTheme.typography.titleSmall)
                            Text(
                                recentlyDeletedPresentation.detail,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        else -> recentlyDeletedState.items.forEach { item ->
                            Surface(
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(18.dp),
                                color = MaterialTheme.colorScheme.surfaceVariant,
                            ) {
                                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text(item.displayName, style = MaterialTheme.typography.titleSmall)
                                    Text(item.endpoint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    item.purgeAfter?.let { Text("计划清理：$it", style = MaterialTheme.typography.labelSmall) }
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        TextButton(
                                            onClick = { onRestoreRecentlyDeleted(item.assetId) },
                                            enabled = item.canRestore && recentlyDeletedState.mutatingAssetId == null,
                                        ) { Text(if (recentlyDeletedState.mutatingAssetId == item.assetId) "处理中…" else "恢复") }
                                        TextButton(
                                            onClick = { purgeCandidateId = item.assetId },
                                            enabled = recentlyDeletedState.mutatingAssetId == null,
                                        ) {
                                            Icon(Icons.Rounded.DeleteForever, contentDescription = null)
                                            Spacer(Modifier.width(4.dp))
                                            Text("永久删除", color = MaterialTheme.colorScheme.error)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    RecentlyDeletedFeedback(
                        presentation = recentlyDeletedPresentation,
                        successMessage = recentlyDeletedState.message,
                        onDismissSuccess = onDismissRecentlyDeletedFeedback,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = onLoadRecentlyDeleted,
                    enabled = recentlyDeletedPresentation.refreshEnabled,
                ) {
                    Text(recentlyDeletedPresentation.refreshLabel)
                }
            },
            dismissButton = {
                TextButton(onClick = { recentlyDeletedVisible = false; onDismissRecentlyDeletedFeedback() }, enabled = recentlyDeletedState.mutatingAssetId == null) {
                    Text("关闭")
                }
            },
            shape = RoundedCornerShape(28.dp),
        )
    }
    purgeCandidateId?.let { assetId ->
        OrbitConfirmationDialog(
            title = "永久删除资产？",
            message = "服务器上的加密配置和删除记录都将被清除，此操作无法撤销。",
            confirmLabel = "永久删除",
            onConfirm = { purgeCandidateId = null; onPurgeRecentlyDeleted(assetId) },
            onDismiss = { purgeCandidateId = null },
            destructive = true,
        )
    }
    if (termsVisible) {
        AlertDialog(
            onDismissRequest = { termsVisible = false },
            title = { Text("使用条款与隐私说明") },
            text = { Text(ORBIT_LEGAL_TERMS, Modifier.heightIn(max = 520.dp).verticalScroll(androidx.compose.foundation.rememberScrollState())) },
            confirmButton = { TextButton(onClick = { termsVisible = false }) { Text("我已阅读") } },
            dismissButton = { TextButton(onClick = { termsVisible = false }) { Text("关闭") } },
            shape = RoundedCornerShape(28.dp),
        )
    }
    if (discardBlockedSyncConfirmationVisible) {
        OrbitConfirmationDialog(
            title = "丢弃受阻同步项目？",
            message = "只会移除已确认停止重试的同步请求，不会删除本机资产、可自动重试项目或待处理冲突。此操作无法撤销。",
            confirmLabel = "确认丢弃",
            onConfirm = {
                discardBlockedSyncConfirmationVisible = false
                onDiscardBlockedSync()
            },
            onDismiss = { discardBlockedSyncConfirmationVisible = false },
            destructive = true,
        )
    }
    if (keyManagementVisible) SshKeyManagementDialog(onDismiss = { keyManagementVisible = false })
    if (portForwardingVisible) PortForwardingDialog(onDismiss = { portForwardingVisible = false })
}

@Composable
private fun OrbitCompactPageBar(
    title: String,
    syncStatus: SyncStatus,
    onRetrySync: () -> Unit,
    onNavigateUp: (() -> Unit)? = null,
) {
    val syncPresentation = syncStatus.presentation()
    Surface(color = MaterialTheme.colorScheme.background) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .height(48.dp)
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            onNavigateUp?.let { navigateUp ->
                IconButton(onClick = navigateUp) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回服务器")
                }
            }
            Text(
                text = title,
                modifier = Modifier.weight(1f),
                color = MaterialTheme.colorScheme.onBackground,
                style = MaterialTheme.typography.titleLarge,
            )
            when (syncPresentation.phase) {
                SyncPresentationPhase.BUSY,
                SyncPresentationPhase.WAITING -> Text(syncPresentation.headline, style = MaterialTheme.typography.labelMedium)
                SyncPresentationPhase.FAILURE -> TextButton(onClick = onRetrySync) { Text("同步失败 · 重试") }
                SyncPresentationPhase.IDLE,
                SyncPresentationPhase.SUCCESS -> Unit
            }
        }
    }
}

/** Keeps navigation reachable when the session workbench has no live terminal. */
internal fun shouldShowBottomDock(destination: AppDestination, hasActiveTerminalSession: Boolean): Boolean =
    destination != AppDestination.Sessions || !hasActiveTerminalSession

@Composable
private fun LoginPasswordChangeDialog(
    isSubmitting: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onConfirm: (String, String, String) -> Unit,
) {
    var currentPassword by remember { mutableStateOf("") }
    var nextPassword by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var observedSubmit by remember { mutableStateOf(false) }
    LaunchedEffect(isSubmitting, observedSubmit, error) {
        if (isSubmitting) observedSubmit = true
        else if (observedSubmit && error == null) onDismiss()
    }
    OrbitFormDialog(
        title = "更换登录密码",
        confirmLabel = if (isSubmitting) "更新中…" else "确认更新",
        confirmEnabled = !isSubmitting && currentPassword.isNotBlank() && nextPassword.isNotBlank() && confirmation.isNotBlank(),
        dismissEnabled = !isSubmitting,
        onConfirm = { onConfirm(currentPassword, nextPassword, confirmation) },
        onDismiss = onDismiss,
    ) {
        Text("此操作不会修改主密码、资产密文或本机凭据。其他设备需要使用新密码重新登录。", style = MaterialTheme.typography.bodySmall)
        AuthField(currentPassword, { currentPassword = it }, "当前登录密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(), true)
        AuthField(nextPassword, { nextPassword = it }, "新登录密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(), true)
        AuthField(confirmation, { confirmation = it }, "确认新登录密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(imeAction = ImeAction.Done), true)
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun MasterPasswordRotationDialog(
    isRotating: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onConfirm: (String, String, String, String) -> Unit,
) {
    var currentMaster by remember { mutableStateOf("") }
    var nextMaster by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var loginPassword by remember { mutableStateOf("") }
    var observedRotation by remember { mutableStateOf(false) }
    LaunchedEffect(isRotating, observedRotation, error) {
        if (isRotating) {
            observedRotation = true
        } else if (observedRotation && error == null) {
            onDismiss()
        }
    }
    OrbitFormDialog(
        title = "更换主密码",
        confirmLabel = if (isRotating) "轮换中…" else "确认轮换",
        confirmEnabled = !isRotating && currentMaster.isNotBlank() && nextMaster.isNotBlank() && confirmation.isNotBlank() && loginPassword.isNotBlank(),
        dismissEnabled = !isRotating,
        onConfirm = { onConfirm(currentMaster, nextMaster, confirmation, loginPassword) },
        onDismiss = onDismiss,
    ) {
        Text("会原子重加密全部云端资产和最近删除记录；其他设备需要使用新主密码重新解锁。", style = MaterialTheme.typography.bodySmall)
        AuthField(currentMaster, { currentMaster = it }, "当前主密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(), true)
        AuthField(nextMaster, { nextMaster = it }, "新主密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(), true)
        AuthField(confirmation, { confirmation = it }, "确认新主密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(), true)
        AuthField(loginPassword, { loginPassword = it }, "当前登录密码", { Icon(Icons.Rounded.Lock, null) }, KeyboardOptions(imeAction = ImeAction.Done), true)
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun PersonalCenterHeader(accountName: String) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        shape = RoundedCornerShape(24.dp),
        border = CardDefaults.outlinedCardBorder(),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                shape = RoundedCornerShape(18.dp),
                color = MaterialTheme.colorScheme.primaryContainer,
            ) {
                Icon(
                    Icons.Rounded.Person,
                    contentDescription = null,
                    modifier = Modifier.padding(12.dp),
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(accountName, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    "管理安全、同步、终端和界面偏好",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun SettingsSectionCard(
    icon: @Composable () -> Unit,
    title: String,
    subtitle: String,
    content: @Composable () -> Unit,
) {
    var expanded by rememberSaveable(title) { mutableStateOf(false) }
    Card(
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = CardDefaults.outlinedCardBorder(),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Surface(
                    color = MaterialTheme.colorScheme.primaryContainer,
                    shape = RoundedCornerShape(14.dp),
                ) {
                    androidx.compose.foundation.layout.Box(Modifier.padding(8.dp)) { icon() }
                }
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, style = MaterialTheme.typography.titleMedium)
                    Text(
                        subtitle,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Icon(
                    imageVector = if (expanded) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,
                    contentDescription = if (expanded) "收起$title" else "展开$title",
                )
            }
            if (expanded) content()
        }
    }
}

@Composable
private fun AccountSecuritySection(
    biometricEnabled: Boolean,
    biometricFeedback: SecurityOperationFeedback?,
    loginPasswordFeedback: SecurityOperationFeedback?,
    masterPasswordFeedback: SecurityOperationFeedback?,
    isChangingLoginPassword: Boolean,
    isRotatingMasterPassword: Boolean,
    onToggleBiometric: () -> Unit,
    onChangeLoginPasswordRequested: () -> Unit,
    onRotateMasterPasswordRequested: () -> Unit,
    onLock: () -> Unit,
) {
    SettingsSectionCard(
        icon = { Icon(Icons.Rounded.SettingsEthernet, contentDescription = null) },
        title = "账户与安全",
        subtitle = "登录、解锁与凭据保护",
    ) {
        OutlinedButton(onClick = onToggleBiometric, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Rounded.Fingerprint, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(if (biometricEnabled) "关闭生物识别解锁" else "启用生物识别解锁")
        }
        biometricFeedback?.let {
            OrbitFeedbackBanner(message = it.message, isError = it.isError)
        }
        loginPasswordFeedback?.let {
            OrbitFeedbackBanner(message = it.message, isError = it.isError)
        }
        masterPasswordFeedback?.let {
            OrbitFeedbackBanner(message = it.message, isError = it.isError)
        }
        TextButton(
            onClick = onChangeLoginPasswordRequested,
            enabled = !isChangingLoginPassword,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Rounded.Lock, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(if (isChangingLoginPassword) "正在更新登录密码…" else "更换登录密码")
        }
        TextButton(
            onClick = onRotateMasterPasswordRequested,
            enabled = !isRotatingMasterPassword,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Rounded.Lock, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(if (isRotatingMasterPassword) "正在轮换主密码…" else "更换主密码")
        }
        OutlinedButton(onClick = onLock, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Rounded.Lock, contentDescription = null)
            Spacer(Modifier.width(6.dp))
            Text("锁定应用")
        }
    }
}

@Composable
private fun SettingLabel(title: String, subtitle: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Text(title, style = MaterialTheme.typography.labelLarge)
        Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun TerminalThemeChip(
    theme: TerminalThemePreference,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    FilterChip(
        modifier = modifier,
        selected = selected,
        onClick = onClick,
        leadingIcon = {
            Box(
                modifier = Modifier
                    .width(18.dp)
                    .height(18.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(Color(theme.backgroundArgb)),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        .width(7.dp)
                        .height(7.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(Color(theme.foregroundArgb)),
                )
            }
        },
        label = { Text(theme.displayName) },
    )
}

@Composable
private fun AppColorThemeChip(
    theme: AppColorTheme,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    FilterChip(
        modifier = modifier,
        selected = selected,
        onClick = onClick,
        leadingIcon = {
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                Box(
                    modifier = Modifier
                        .width(10.dp)
                        .height(18.dp)
                        .clip(RoundedCornerShape(topStart = 5.dp, bottomStart = 5.dp))
                        .background(appColorThemeAccent(theme)),
                )
                Box(
                    modifier = Modifier
                        .width(6.dp)
                        .height(18.dp)
                        .clip(RoundedCornerShape(topEnd = 4.dp, bottomEnd = 4.dp))
                        .background(appColorThemeHighlight(theme)),
                )
            }
        },
        label = { Text(theme.displayName) },
    )
}

@Composable
private fun TerminalPalettePreview(theme: TerminalThemePreference) {
    OrbitTerminalThemeSwatch(
        label = theme.displayName,
        background = Color(theme.backgroundArgb),
        foreground = Color(theme.foregroundArgb),
        ansiColors = theme.ansi16.map(::Color),
        modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
        compact = true,
    )
}

private fun diagnosticText(
    context: android.content.Context,
    appTheme: AppThemePreference,
    terminalAppearance: TerminalAppearance,
    monitorRefreshInterval: MonitorRefreshInterval,
    syncStatus: SyncStatus,
): String {
    val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
    val errorMetrics = PrivacySafeErrorMetrics.snapshot()
        .toList()
        .sortedBy { (code, _) -> code.diagnosticCode }
        .joinToString(separator = "、") { (code, count) -> "${code.diagnosticCode}=$count" }
    val syncMetrics = com.orbitterm.android.domain.sync.PrivacySafeSyncMetrics.snapshot()
        .toList()
        .sortedBy { (event, _) -> event.diagnosticCode }
        .joinToString(separator = "、") { (event, count) -> "${event.diagnosticCode}=$count" }
    return listOf(
        "OrbitTerm Android 诊断信息",
        "版本：${packageInfo.versionName ?: "unknown"} (${Build.VERSION.SDK_INT})",
        "设备：${Build.MANUFACTURER} ${Build.MODEL}",
        "应用主题：${appTheme.label()}",
        "终端：${terminalAppearance.theme.displayName} · ${terminalAppearance.fontSizeSp}sp",
        "监控刷新：${monitorRefreshInterval.seconds} 秒",
        "同步状态：${syncStatus.presentation().headline}；${syncStatus.presentation().detail}",
        "错误指标：${errorMetrics.ifBlank { "无" }}",
        "同步事件：${syncMetrics.ifBlank { "无" }}",
        "说明：本信息不包含账户、资产地址、主机密钥、命令、路径或凭据。",
    ).joinToString(separator = "\n")
}

@Composable
private fun DestinationPlaceholder(destination: AppDestination, modifier: Modifier = Modifier) {
    val (headline, supportingText) = when (destination) {
        AppDestination.Servers -> error("Servers uses AssetsRoute")
        AppDestination.Sessions -> "没有活动会话" to "已验证的 SSH 会话将显示在这里。"
        AppDestination.Sftp -> "SFTP" to "文件管理只会使用已验证的 SSH 会话。"
        AppDestination.Docker -> "Docker" to "容器管理只会使用已验证的 SSH 会话。"
        AppDestination.More -> error("More uses MoreScreen")
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = headline, style = MaterialTheme.typography.headlineSmall)
        Text(
            text = supportingText,
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
        )
    }
}

private fun destinationTitle(destination: AppDestination): String = when (destination) {
    AppDestination.Servers -> "服务器"
    AppDestination.Sessions -> "会话"
    AppDestination.Sftp -> "SFTP"
    AppDestination.Docker -> "Docker"
    AppDestination.More -> "个人中心"
}

private fun destinationLabel(destination: AppDestination): String = destinationTitle(destination)

private fun destinationIcon(destination: AppDestination) = when (destination) {
    AppDestination.Servers -> Icons.Rounded.Dns
    AppDestination.Sessions -> Icons.Rounded.Terminal
    AppDestination.Sftp -> Icons.Rounded.Folder
    AppDestination.Docker -> Icons.Rounded.Inventory2
    AppDestination.More -> Icons.Rounded.Person
}

private fun AppThemePreference.label(): String = when (this) {
    AppThemePreference.System -> "跟随系统"
    AppThemePreference.Light -> "浅色"
    AppThemePreference.Dark -> "深色"
}
