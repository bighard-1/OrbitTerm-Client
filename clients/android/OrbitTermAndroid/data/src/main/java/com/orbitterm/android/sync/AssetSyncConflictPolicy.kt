package com.orbitterm.android.sync

import com.orbitterm.android.data.sync.PortableServerConfig
import com.orbitterm.android.domain.assets.ServerAsset
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** A non-sensitive baseline used to detect concurrent cross-device edits. */
@Serializable
data class AssetSyncShadow(
    val name: String,
    val group: String,
    val tags: List<String> = emptyList(),
    val host: String,
    val port: Int,
    val username: String,
    val authMethod: String,
    val transport: String,
    val networkDeviceProfile: String,
    val allowPasswordFallback: Boolean,
    val jumpHost: AssetJumpHostShadow? = null,
)

/** Route identity only; credential IDs are device-scoped and never compared across clients. */
@Serializable
data class AssetJumpHostShadow(
    val host: String,
    val port: Int,
    val username: String,
    val authMethod: String,
    val allowPasswordFallback: Boolean,
)

enum class AssetSyncField(val label: String) {
    Name("名称"), Group("分组"), Tags("标签"), Host("主机"), Port("端口"), Username("用户名"),
    AuthMethod("认证方式"), Transport("传输协议"), NetworkDeviceProfile("设备类型"),
    PasswordMaterial("认证凭据"), JumpHost("跳板机"),
}

sealed interface AssetMergeDecision {
    data object NoLocalChange : AssetMergeDecision
    data class AutoMerge(val localFields: Set<AssetSyncField>) : AssetMergeDecision
    data class RequiresUserChoice(val fields: Set<AssetSyncField>) : AssetMergeDecision
}

object AssetSyncConflictPolicy {
    private val json = Json { ignoreUnknownKeys = true }

    fun shadow(asset: ServerAsset): AssetSyncShadow = AssetSyncShadow(
        name = asset.name,
        group = asset.group,
        tags = asset.tags,
        host = asset.host,
        port = asset.port,
        username = asset.username,
        authMethod = asset.authMethod,
        transport = asset.transport,
        networkDeviceProfile = asset.networkDeviceProfile,
        allowPasswordFallback = asset.allowPasswordFallback,
        jumpHost = asset.jumpHost?.toAssetJumpHostShadow(),
    )

    fun encode(shadow: AssetSyncShadow): String = json.encodeToString(shadow)
    fun decode(value: String): AssetSyncShadow? = runCatching { json.decodeFromString<AssetSyncShadow>(value) }.getOrNull()

    fun changedFields(base: AssetSyncShadow, newer: AssetSyncShadow): Set<AssetSyncField> = buildSet {
        if (base.name != newer.name) add(AssetSyncField.Name)
        if (base.group != newer.group) add(AssetSyncField.Group)
        if (base.tags != newer.tags) add(AssetSyncField.Tags)
        if (base.host != newer.host) add(AssetSyncField.Host)
        if (base.port != newer.port) add(AssetSyncField.Port)
        if (base.username != newer.username) add(AssetSyncField.Username)
        if (base.authMethod != newer.authMethod) add(AssetSyncField.AuthMethod)
        if (base.transport != newer.transport) add(AssetSyncField.Transport)
        if (base.networkDeviceProfile != newer.networkDeviceProfile) add(AssetSyncField.NetworkDeviceProfile)
        if (base.allowPasswordFallback != newer.allowPasswordFallback) add(AssetSyncField.PasswordMaterial)
        if (base.jumpHost != newer.jumpHost) add(AssetSyncField.JumpHost)
    }

    /**
     * Composes a configuration from a common baseline: fields changed locally
     * win, untouched fields are refreshed from the cloud. Credentials are
     * deliberately outside this function and are never copied or persisted here.
     */
    fun mergeRemoteConfiguration(
        local: ServerAsset,
        remote: PortableServerConfig,
        localFields: Set<AssetSyncField>,
    ): ServerAsset = local.copy(
        name = if (AssetSyncField.Name in localFields) local.name else remote.name,
        group = if (AssetSyncField.Group in localFields) local.group else remote.group,
        tags = if (AssetSyncField.Tags in localFields) local.tags else remote.tags,
        host = if (AssetSyncField.Host in localFields) local.host else remote.host,
        port = if (AssetSyncField.Port in localFields) local.port else remote.port,
        username = if (AssetSyncField.Username in localFields) local.username else remote.username,
        authMethod = if (AssetSyncField.AuthMethod in localFields) local.authMethod else remote.authMethod,
        transport = if (AssetSyncField.Transport in localFields) local.transport else remote.transport,
        networkDeviceProfile = if (AssetSyncField.NetworkDeviceProfile in localFields) local.networkDeviceProfile else remote.networkDeviceProfile,
        allowPasswordFallback = if (AssetSyncField.PasswordMaterial in localFields) local.allowPasswordFallback else remote.allowPasswordFallback,
    )

    /**
     * Authentication material is intentionally conservative: Android cannot
     * persist a comparable secret fingerprint, so simultaneous remote changes
     * must be confirmed by the user rather than guessed.
     */
    fun decide(local: Set<AssetSyncField>, remote: Set<AssetSyncField>): AssetMergeDecision {
        if (local.isEmpty()) return AssetMergeDecision.NoLocalChange
        val overlap = local.intersect(remote)
        val connectionSemantics = setOf(
            AssetSyncField.AuthMethod,
            AssetSyncField.Transport,
            AssetSyncField.JumpHost,
        )
        val sensitiveConcurrentChanges = (local + remote).intersect(connectionSemantics + AssetSyncField.PasswordMaterial)
        return when {
            overlap.isNotEmpty() -> AssetMergeDecision.RequiresUserChoice(overlap)
            remote.isNotEmpty() && sensitiveConcurrentChanges.isNotEmpty() ->
                AssetMergeDecision.RequiresUserChoice(sensitiveConcurrentChanges)
            else -> AssetMergeDecision.AutoMerge(local)
        }
    }
}

internal fun com.orbitterm.android.domain.assets.JumpHostConfiguration.toAssetJumpHostShadow() = AssetJumpHostShadow(
    host = host,
    port = port,
    username = username,
    authMethod = authMethod,
    allowPasswordFallback = allowPasswordFallback,
)
