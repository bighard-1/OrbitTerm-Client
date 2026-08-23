package com.orbitterm.android.smoke

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.ui.MasterPasswordScreen
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import com.orbitterm.android.ui.design.OrbitEmptyState
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.design.OrbitPageHeader
import com.orbitterm.android.ui.design.OrbitSectionCard
import com.orbitterm.android.ui.design.OrbitStatusBadge
import com.orbitterm.android.ui.design.OrbitStatusTone
import com.orbitterm.android.ui.design.OrbitTerminalThemeSwatch
import com.orbitterm.android.ui.theme.OrbitTheme

/**
 * Data-free visual fixtures compiled exclusively into the debug-signed smoke
 * package. State is selected by an explicit intent extra and never invokes the
 * production DI graph, storage, network, native bridge, or account session.
 */
class SmokeFixtureActivity : ComponentActivity() {
    private val state = mutableStateOf(FixtureState.Locked)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        state.value = FixtureState.from(intent?.getStringExtra(EXTRA_STATE))
        setContent { SmokeFixture(state.value) }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        state.value = FixtureState.from(intent.getStringExtra(EXTRA_STATE))
    }

    companion object {
        const val EXTRA_STATE = "com.orbitterm.android.smoke.fixture.STATE"
    }
}

private enum class FixtureState(val wireValue: String, val dark: Boolean) {
    Locked("locked", true),
    LightTheme("light", false),
    DarkTheme("dark", true),
    EmptySession("empty-session", true),
    ConnectionFailure("connection-failure", true),
    SyncFailure("sync-failure", false),
    DockerEmpty("docker-empty", true),
    TransferQueue("transfer-queue", true),
    HostKeyChallenge("host-key-challenge", true),
    AuthenticationFailure("authentication-failure", true),
    Offline("offline", false),
    SyncConflict("sync-conflict", false),
    TransferFeedback("transfer-feedback", true),
    ReconnectRecovery("reconnect-recovery", true),
    LargeTransferPaused("large-transfer-paused", true),
    TerminalStress("terminal-stress", true),
    ;

    companion object {
        fun from(value: String?): FixtureState = entries.firstOrNull { it.wireValue == value } ?: Locked
    }
}

@Composable
private fun SmokeFixture(state: FixtureState) {
    OrbitTheme(darkTheme = state.dark, colorTheme = AppColorTheme.GlacierMint) {
        when (state) {
            FixtureState.Locked -> MasterPasswordScreen(
                configured = true,
                biometricEnabled = true,
                error = null,
                onSubmit = { _, _ -> Unit },
                onBiometricUnlock = {},
            )
            FixtureState.EmptySession -> FixtureEmptySession()
            FixtureState.LightTheme, FixtureState.DarkTheme -> FixtureTheme(state)
            FixtureState.ConnectionFailure -> FixtureConnectionFailure()
            FixtureState.SyncFailure -> FixtureSyncFailure()
            FixtureState.DockerEmpty -> FixtureDockerEmpty()
            FixtureState.TransferQueue -> FixtureTransferQueue()
            FixtureState.HostKeyChallenge -> FixtureHostKeyChallenge()
            FixtureState.AuthenticationFailure -> FixtureAuthenticationFailure()
            FixtureState.Offline -> FixtureOffline()
            FixtureState.SyncConflict -> FixtureSyncConflict()
            FixtureState.TransferFeedback -> FixtureTransferFeedback()
            FixtureState.ReconnectRecovery -> FixtureReconnectRecovery()
            FixtureState.LargeTransferPaused -> FixtureLargeTransferPaused()
            FixtureState.TerminalStress -> FixtureTerminalStress()
        }
    }
}

@Composable
private fun FixtureEmptySession() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column {
            OrbitPageHeader(title = "会话", subtitle = "Smoke 无数据状态夹具")
            OrbitEmptyState(
                title = "终端工作台",
                message = "暂无活动会话。请先在服务器页连接一台资产。",
            )
        }
    }
}

@Composable
private fun FixtureTheme(state: FixtureState) {
    val label = if (state == FixtureState.LightTheme) "浅色主题夹具" else "深色主题夹具"
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "界面配色", subtitle = label)
            OrbitSectionCard(title = "状态与终端主题", subtitle = "固定数据，不连接账户或服务器") {
                OrbitStatusBadge(
                    label = if (state == FixtureState.LightTheme) "浅色模式" else "深色模式",
                    tone = OrbitStatusTone.Information,
                )
                OrbitTerminalThemeSwatch(
                    label = "Dracula",
                    background = Color(0xFF282A36),
                    foreground = Color(0xFFF8F8F2),
                    ansiColors = listOf(
                        Color(0xFFFF5555), Color(0xFF50FA7B), Color(0xFFF1FA8C), Color(0xFF6272A4),
                        Color(0xFFFF79C6), Color(0xFF8BE9FD), Color(0xFFF8F8F2), Color(0xFFBD93F9),
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text("此页面仅用于视觉与状态回归。", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun FixtureConnectionFailure() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column {
            OrbitPageHeader(title = "服务器", subtitle = "Smoke 无数据状态夹具")
        }
    }
    OrbitConfirmationDialog(
        title = "连接未建立",
        message = "连接超时。请检查网络、地址和防火墙。诊断代码：ssh_timeout。",
        confirmLabel = "关闭",
        onConfirm = {},
        onDismiss = {},
    )
}

@Composable
private fun FixtureSyncFailure() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "监控与同步", subtitle = "Smoke 无数据状态夹具")
            OrbitSectionCard(title = "同步需要处理", subtitle = "不会读取或写入任何账户数据") {
                OrbitFeedbackBanner(
                    message = "同步失败，请检查网络和登录状态后重试。",
                    isError = true,
                )
                Button(onClick = {}) { Text("重试同步") }
            }
        }
    }
}

@Composable
private fun FixtureDockerEmpty() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column {
            OrbitPageHeader(title = "Docker", subtitle = "Smoke 无数据状态夹具")
            OrbitEmptyState(
                title = "未发现容器",
                message = "当前已连接服务器没有可管理的 Docker 容器。",
            )
        }
    }
}

@Composable
private fun FixtureTransferQueue() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "SFTP", subtitle = "Smoke 无数据状态夹具")
            OrbitSectionCard(title = "传输队列 · 2 个待处理项目", subtitle = "固定进度，不连接远程服务器") {
                Text("正在下载 archive.tar.zst", style = MaterialTheme.typography.titleSmall)
                LinearProgressIndicator(progress = { 0.62f }, modifier = Modifier.fillMaxWidth())
                Text("62% · 1.2 GB / 2.0 GB", style = MaterialTheme.typography.bodySmall)
                Button(onClick = {}) { Text("取消当前传输") }
                Text("等待中：reports-2026.zip", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun FixtureHostKeyChallenge() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column { OrbitPageHeader(title = "服务器", subtitle = "Smoke 无数据状态夹具") }
    }
    OrbitConfirmationDialog(
        title = "主机密钥需要确认",
        message = "服务器 host.example:22 的 ED25519 指纹尚未受信任。连接已阻断，诊断代码：host_key_challenge。",
        confirmLabel = "查看并信任",
        onConfirm = {},
        onDismiss = {},
    )
}

@Composable
private fun FixtureAuthenticationFailure() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column { OrbitPageHeader(title = "服务器", subtitle = "Smoke 无数据状态夹具") }
    }
    OrbitConfirmationDialog(
        title = "连接未建立",
        message = "认证失败。请检查账号、密码或私钥。诊断代码：ssh_auth_failed。",
        confirmLabel = "关闭",
        onConfirm = {},
        onDismiss = {},
    )
}

@Composable
private fun FixtureOffline() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "监控与同步", subtitle = "Smoke 无数据状态夹具")
            OrbitSectionCard(title = "等待网络恢复后自动同步", subtitle = "不读取账户或待同步数据") {
                OrbitStatusBadge(label = "当前离线", tone = OrbitStatusTone.Warning)
                OrbitFeedbackBanner(message = "当前离线，网络恢复后将自动同步。", isError = false)
            }
        }
    }
}

@Composable
private fun FixtureSyncConflict() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "监控与同步", subtitle = "Smoke 无数据状态夹具")
            OrbitSectionCard(title = "发现同步冲突", subtitle = "选择前不会读取或写入任何资产") {
                Text("同一资产在本机与云端均有修改。", style = MaterialTheme.typography.bodyMedium)
                Button(onClick = {}) { Text("保留本机版本") }
                Button(onClick = {}) { Text("采用云端版本") }
            }
        }
    }
}

@Composable
private fun FixtureTransferFeedback() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "SFTP", subtitle = "Smoke 无数据状态夹具")
            OrbitSectionCard(title = "传输需要处理", subtitle = "固定反馈，不创建任何传输") {
                OrbitFeedbackBanner(
                    message = "下载失败：目标位置不可写入。诊断代码：destination_unwritable。",
                    isError = true,
                )
                OrbitFeedbackBanner(message = "已从队列移除 reports-2026.zip。", isError = false)
            }
        }
    }
}

@Composable
private fun FixtureReconnectRecovery() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "会话", subtitle = "弱网恢复状态夹具")
            OrbitSectionCard(title = "正在重新连接", subtitle = "不建立真实 SSH 连接") {
                OrbitStatusBadge(label = "连接恢复中", tone = OrbitStatusTone.Warning)
                OrbitFeedbackBanner(
                    message = "网络已恢复，正在重新连接。原会话在连接结果确认前保持不变。",
                    isError = false,
                )
                Button(onClick = {}) { Text("取消重连") }
            }
        }
    }
}

@Composable
private fun FixtureLargeTransferPaused() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "SFTP", subtitle = "大文件与断网恢复夹具")
            OrbitSectionCard(title = "大文件传输 · 2.0 GB", subtitle = "固定状态，不创建远程连接") {
                Text("正在下载 archive.tar.zst", style = MaterialTheme.typography.titleSmall)
                LinearProgressIndicator(progress = { 0.62f }, modifier = Modifier.fillMaxWidth())
                Text("62% · 1.2 GB / 2.0 GB", style = MaterialTheme.typography.bodySmall)
                OrbitFeedbackBanner(message = "网络已中断，传输已安全暂停。网络恢复后可继续队列。", isError = false)
                Button(onClick = {}) { Text("继续队列") }
            }
        }
    }
}

@Composable
private fun FixtureTerminalStress() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OrbitPageHeader(title = "终端", subtitle = "长输出资源边界夹具")
            OrbitSectionCard(title = "终端输出压力夹具 · 4,096 个数据块", subtitle = "不连接服务器或保留终端内容") {
                OrbitStatusBadge(label = "输出已限流并合并渲染", tone = OrbitStatusTone.Information)
                Text("仅保留受限缓冲区，避免长时间会话占用无限内存。", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}
