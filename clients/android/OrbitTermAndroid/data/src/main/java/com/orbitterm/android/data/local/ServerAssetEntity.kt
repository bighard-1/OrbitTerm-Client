package com.orbitterm.android.data.local

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.JumpHostConfiguration
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Entity(tableName = "server_assets", primaryKeys = ["accountScope", "id"])
data class ServerAssetEntity(
    val accountScope: String,
    val id: String,
    val credentialID: String,
    val name: String,
    val groupName: String,
    val tagsJson: String,
    val host: String,
    val port: Int,
    val username: String,
    val authMethod: String,
    val transport: String,
    val networkDeviceProfile: String,
    val allowPasswordFallback: Boolean,
    val jumpHostJson: String?,
    val createdAtUnix: Long,
)

internal fun ServerAssetEntity.toDomain(): ServerAsset = ServerAsset(
    id = id,
    credentialID = credentialID,
    name = name,
    group = groupName,
    tags = runCatching { assetJson.decodeFromString<List<String>>(tagsJson) }.getOrDefault(emptyList()),
    host = host,
    port = port,
    username = username,
    authMethod = authMethod,
    transport = transport,
    networkDeviceProfile = networkDeviceProfile,
    allowPasswordFallback = allowPasswordFallback,
    jumpHost = jumpHostJson?.let { serialized -> runCatching { assetJson.decodeFromString<JumpHostConfiguration>(serialized).validate() }.getOrNull() },
    createdAtUnix = createdAtUnix,
)

internal fun ServerAsset.toEntity(accountScope: String): ServerAssetEntity = ServerAssetEntity(
    accountScope = accountScope,
    id = id,
    credentialID = credentialID,
    name = name,
    groupName = group,
    tagsJson = assetJson.encodeToString(tags),
    host = host,
    port = port,
    username = username,
    authMethod = authMethod,
    transport = transport,
    networkDeviceProfile = networkDeviceProfile,
    allowPasswordFallback = allowPasswordFallback,
    jumpHostJson = jumpHost?.let { assetJson.encodeToString(it.validate()) },
    createdAtUnix = createdAtUnix,
)

private val assetJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
