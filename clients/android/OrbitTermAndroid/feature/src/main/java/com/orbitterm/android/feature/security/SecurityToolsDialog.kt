package com.orbitterm.android.feature.security

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.orbitterm.android.core.CheckedPortForwardNativeClient
import com.orbitterm.android.core.CheckedPortForwardResult
import com.orbitterm.android.core.LocalTunnelLease
import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.security.ClipboardContentKind
import com.orbitterm.android.security.SensitiveClipboard
import com.orbitterm.android.sync.PortablePortForwardProfile
import com.orbitterm.android.sync.PortableSecurityLibrary
import com.orbitterm.android.sync.PortableSshKey
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class SecurityToolsUiState(
    val assets: List<ServerAsset> = emptyList(),
    val keys: List<PortableSshKey> = emptyList(),
    val profiles: List<PortablePortForwardProfile> = emptyList(),
    val running: Map<String, LocalTunnelLease> = emptyMap(),
    val message: String? = null,
)

@HiltViewModel
class SecurityToolsViewModel @Inject constructor(
    private val library: PortableSecurityLibrary,
    private val assetsRepository: AssetRepository,
    private val terminalSessions: TerminalSessionController,
    private val tunnels: CheckedPortForwardNativeClient,
) : ViewModel() {
    private val local = kotlinx.coroutines.flow.MutableStateFlow(SecurityToolsUiState())
    val state = combine(assetsRepository.observeAssets(), local) { assets, value ->
        value.copy(assets = assets.filter { it.transport == "ssh" })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), local.value)

    init { reload() }
    fun reload() { local.value = local.value.copy(keys = library.listKeys(), profiles = library.listPortForwardProfiles()) }
    fun importKey(name: String, privateKey: String, passphrase: String, synchronize: Boolean) = viewModelScope.launch {
        runCatching { library.importKey(name, privateKey, passphrase, synchronize) }
            .onSuccess { local.value = local.value.copy(message = "密钥已安全导入${if (synchronize) "并加入加密同步" else "为仅本机"}。") }
            .onFailure { local.value = local.value.copy(message = "密钥格式无效或安全存储不可用。") }
        reload()
    }
    fun generateKey(name: String, synchronize: Boolean) = viewModelScope.launch {
        runCatching { withContext(Dispatchers.Default) { library.generateEd25519Key(name, synchronize) } }
            .onSuccess { local.value = local.value.copy(message = "Ed25519 密钥已生成并安全保存。请复制公钥后部署到目标服务器。") }
            .onFailure { local.value = local.value.copy(message = "密钥生成失败，请重试。") }
        reload()
    }
    fun renameKey(id: String, name: String) = viewModelScope.launch {
        runCatching { library.renameKey(id, name) }
            .onSuccess { local.value = local.value.copy(message = "密钥名称与备注已更新。") }
            .onFailure { local.value = local.value.copy(message = "备注不能为空或包含无效字符。") }
        reload()
    }
    fun assign(keyId: String, assetId: String) = viewModelScope.launch {
        runCatching { withContext(Dispatchers.IO) { library.assignKey(keyId, assetId) } }
            .onSuccess { local.value = local.value.copy(message = "密钥已应用到所选资产。") }
            .onFailure { local.value = local.value.copy(message = "无法将密钥写入资产凭据。") }
        reload()
    }
    fun deleteKey(id: String) { runCatching { library.deleteKey(id) }; reload() }
    fun saveProfile(assetId: String, name: String, bindPort: Int, destinationHost: String, destinationPort: Int, sync: Boolean) {
        runCatching { library.savePortForwardProfile(assetId, name, bindPort, destinationHost, destinationPort, sync) }
            .onSuccess { local.value = local.value.copy(message = "端口映射配置已保存。") }
            .onFailure { local.value = local.value.copy(message = "配置不完整或端口无效。") }
        reload()
    }
    fun deleteProfile(id: String) { runCatching { library.deletePortForwardProfile(id) }; reload() }
    fun start(profile: PortablePortForwardProfile) = viewModelScope.launch {
        val session = terminalSessions.activeSessions.value.firstOrNull { it.assetId == profile.assetId }
        if (session == null) {
            local.value = local.value.copy(message = "请先连接该资产并完成主机密钥验证。")
            return@launch
        }
        when (val result = withContext(Dispatchers.IO) {
            tunnels.start(session.baseSessionId, profile.bindPort, profile.destinationHost, profile.destinationPort)
        }) {
            is CheckedPortForwardResult.Started -> local.value = local.value.copy(
                running = local.value.running + (profile.id to result.lease),
                message = "映射已启动：${result.lease.bindHost}:${result.lease.bindPort}",
            )
            is CheckedPortForwardResult.Failure -> local.value = local.value.copy(message = "映射启动失败：${result.code}")
            else -> Unit
        }
    }
    fun stop(profileId: String) = viewModelScope.launch {
        val lease = local.value.running[profileId] ?: return@launch
        if (withContext(Dispatchers.IO) { tunnels.stop(lease.tunnelId) } is CheckedPortForwardResult.Stopped) {
            local.value = local.value.copy(running = local.value.running - profileId, message = "映射已停止。")
        }
    }
}

@Composable
fun SshKeyManagementDialog(onDismiss: () -> Unit, viewModel: SecurityToolsViewModel = viewModel()) {
    val context = LocalContext.current
    val state = viewModel.state.collectAsStateWithLifecycle().value
    var importing by rememberSaveable { mutableStateOf(false) }
    var generating by rememberSaveable { mutableStateOf(false) }
    var selectedKey by remember { mutableStateOf<PortableSshKey?>(null) }
    var renamingKey by remember { mutableStateOf<PortableSshKey?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("SSH 密钥管理") },
        text = {
            Column(Modifier.fillMaxWidth().heightIn(max = 560.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("私钥由 Android Keystore 加密保存；选择同步时再使用主密码封装为端到端加密数据。", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { generating = true }, modifier = Modifier.weight(1f)) { Text("生成 Ed25519") }
                    Button(onClick = { importing = true }, modifier = Modifier.weight(1f)) { Text("导入私钥") }
                }
                state.message?.let { Text(it, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall) }
                if (state.keys.isEmpty()) Text("暂无密钥", color = MaterialTheme.colorScheme.onSurfaceVariant)
                state.keys.forEach { key ->
                    HorizontalDivider()
                    Text(key.name, style = MaterialTheme.typography.titleSmall)
                    Text("${key.format} · ${if (key.isSynced) "端到端加密同步" else "仅本机"} · ${key.assignedAssetIds.size} 项资产", style = MaterialTheme.typography.bodySmall)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { selectedKey = key }) { Text("应用到资产") }
                        TextButton(onClick = {
                            if (key.publicKey.isNotBlank()) {
                                SensitiveClipboard.copy(
                                    context,
                                    "SSH public key",
                                    key.publicKey,
                                    ClipboardContentKind.ORDINARY_TEXT,
                                )
                            }
                        }, enabled = key.publicKey.isNotBlank()) { Text("复制公钥") }
                        TextButton(onClick = { renamingKey = key }) { Text("备注") }
                        TextButton(onClick = { viewModel.deleteKey(key.id) }) { Text("删除", color = MaterialTheme.colorScheme.error) }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("完成") } },
    )
    if (importing) ImportKeyDialog(onDismiss = { importing = false }) { name, key, passphrase, sync ->
        importing = false; viewModel.importKey(name, key, passphrase, sync)
    }
    if (generating) GenerateKeyDialog(onDismiss = { generating = false }) { name, sync ->
        generating = false; viewModel.generateKey(name, sync)
    }
    renamingKey?.let { key ->
        RenameKeyDialog(key.name, onDismiss = { renamingKey = null }) { name ->
            renamingKey = null
            viewModel.renameKey(key.id, name)
        }
    }
    selectedKey?.let { key ->
        AlertDialog(
            onDismissRequest = { selectedKey = null }, title = { Text("应用密钥到资产") },
            text = { Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                state.assets.forEach { asset -> TextButton(onClick = { viewModel.assign(key.id, asset.id); selectedKey = null }, modifier = Modifier.fillMaxWidth()) { Text("${asset.name} · ${asset.username}@${asset.host}:${asset.port}") } }
            } },
            confirmButton = { TextButton(onClick = { selectedKey = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun GenerateKeyDialog(onDismiss: () -> Unit, onGenerate: (String, Boolean) -> Unit) {
    var name by rememberSaveable { mutableStateOf("OrbitTerm 移动端密钥") }
    var synchronize by rememberSaveable { mutableStateOf(true) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("生成 Ed25519 密钥") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("私钥会直接进入本机安全存储；应用不会在界面展示私钥。生成后复制公钥并部署到服务器。", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it.take(80) },
                    label = { Text("名称 / 备注") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                Row { Checkbox(synchronize, { synchronize = it }); Text("端到端加密同步", modifier = Modifier.padding(top = 12.dp)) }
            }
        },
        confirmButton = { TextButton(onClick = { onGenerate(name, synchronize) }, enabled = name.isNotBlank()) { Text("生成") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun RenameKeyDialog(initialName: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var name by rememberSaveable(initialName) { mutableStateOf(initialName) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("修改密钥备注") },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it.take(80) },
                label = { Text("名称 / 备注") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
        },
        confirmButton = { TextButton(onClick = { onSave(name) }, enabled = name.isNotBlank()) { Text("保存") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun ImportKeyDialog(onDismiss: () -> Unit, onImport: (String, String, String, Boolean) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }; var key by rememberSaveable { mutableStateOf("") }
    var passphrase by rememberSaveable { mutableStateOf("") }; var sync by rememberSaveable { mutableStateOf(true) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("导入 SSH 私钥") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text("密钥名称") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(key, { key = it }, label = { Text("粘贴 OpenSSH / PEM / PuTTY 私钥") }, modifier = Modifier.fillMaxWidth(), minLines = 5)
            OutlinedTextField(passphrase, { passphrase = it }, label = { Text("私钥口令（可选）") }, modifier = Modifier.fillMaxWidth())
            Row { Checkbox(sync, { sync = it }); Text("端到端加密同步", modifier = Modifier.padding(top = 12.dp)) }
        }
    }, confirmButton = { TextButton(onClick = { onImport(name, key, passphrase, sync) }, enabled = key.isNotBlank()) { Text("导入") } }, dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}

@Composable
fun PortForwardingDialog(onDismiss: () -> Unit, viewModel: SecurityToolsViewModel = viewModel()) {
    val state = viewModel.state.collectAsStateWithLifecycle().value
    var editing by rememberSaveable { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("端口映射") }, text = {
        Column(Modifier.fillMaxWidth().heightIn(max = 560.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("保存配置可跨端同步；启动映射必须先建立对应资产的已验证 SSH 会话。", style = MaterialTheme.typography.bodySmall)
            Button(onClick = { editing = true }, modifier = Modifier.fillMaxWidth()) { Text("新建本地映射") }
            state.message?.let { Text(it, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall) }
            if (state.profiles.isEmpty()) Text("暂无映射配置")
            state.profiles.forEach { profile ->
                HorizontalDivider(); Text(profile.name, style = MaterialTheme.typography.titleSmall)
                Text("${profile.bindHost}:${profile.bindPort} → ${profile.destinationHost}:${profile.destinationPort}\n${if (profile.isSynced) "端到端加密同步" else "仅本机"}", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (profile.id in state.running) TextButton(onClick = { viewModel.stop(profile.id) }) { Text("停止") }
                    else TextButton(onClick = { viewModel.start(profile) }) { Text("启动") }
                    TextButton(onClick = { viewModel.deleteProfile(profile.id) }) { Text("删除", color = MaterialTheme.colorScheme.error) }
                }
            }
        }
    }, confirmButton = { TextButton(onClick = onDismiss) { Text("完成") } })
    if (editing) NewPortForwardDialog(state.assets, { editing = false }) { assetId, name, bind, host, port, sync ->
        editing = false; viewModel.saveProfile(assetId, name, bind, host, port, sync)
    }
}

@Composable
private fun NewPortForwardDialog(assets: List<ServerAsset>, onDismiss: () -> Unit, onSave: (String, String, Int, String, Int, Boolean) -> Unit) {
    var assetId by rememberSaveable { mutableStateOf(assets.firstOrNull()?.id.orEmpty()) }; var name by rememberSaveable { mutableStateOf("") }
    var bind by rememberSaveable { mutableStateOf("0") }; var host by rememberSaveable { mutableStateOf("127.0.0.1") }
    var port by rememberSaveable { mutableStateOf("8080") }; var sync by rememberSaveable { mutableStateOf(true) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("新建本地映射") }, text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("选择资产", style = MaterialTheme.typography.labelLarge)
        assets.forEach { asset -> Row { Checkbox(assetId == asset.id, { if (it) assetId = asset.id }); Text("${asset.name} · ${asset.host}:${asset.port}", Modifier.padding(top = 12.dp)) } }
        OutlinedTextField(name, { name = it }, label = { Text("名称") }); OutlinedTextField(bind, { bind = it }, label = { Text("本地端口（0 自动）") })
        OutlinedTextField(host, { host = it }, label = { Text("目标主机") }); OutlinedTextField(port, { port = it }, label = { Text("目标端口") })
        Row { Checkbox(sync, { sync = it }); Text("端到端加密同步", Modifier.padding(top = 12.dp)) }
    } }, confirmButton = { TextButton(onClick = { onSave(assetId, name, bind.toIntOrNull() ?: -1, host, port.toIntOrNull() ?: -1, sync) }, enabled = assetId.isNotBlank()) { Text("保存") } }, dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}
