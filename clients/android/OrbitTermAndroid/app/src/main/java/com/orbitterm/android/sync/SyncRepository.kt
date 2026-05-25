package com.orbitterm.android.sync

import com.orbitterm.android.core.OrbitCoreBridge
import com.orbitterm.android.data.PortableServerConfig
import com.orbitterm.android.data.ServerAsset
import com.orbitterm.android.data.ServerCredentials
import com.orbitterm.android.security.SecureCredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant

class SyncRepository(
    private val api: OrbitApi,
    private val credentialStore: SecureCredentialStore
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    suspend fun uploadAsset(
        token: String,
        masterPassword: String,
        asset: ServerAsset,
        vectorClock: String = "{}"
    ): UploadConfigData = withContext(Dispatchers.IO) {
        val credentials = credentialStore.read(asset.credentialID) ?: ServerCredentials()
        val portable = PortableServerConfig(
            id = asset.id,
            credentialID = asset.credentialID,
            name = asset.name,
            group = asset.group,
            host = asset.host,
            port = asset.port,
            username = asset.username,
            authMethod = asset.authMethod,
            transport = asset.transport,
            networkDeviceProfile = asset.networkDeviceProfile,
            allowPasswordFallback = asset.allowPasswordFallback,
            password = credentials.password,
            privateKeyContent = credentials.privateKeyContent,
            privateKeyPassphrase = credentials.privateKeyPassphrase,
            keyReference = sanitizeKeyReference(credentials.privateKeyContent),
            savedAtUnix = Instant.now().epochSecond
        ).validate()
        val plaintext = json.encodeToString(portable)
        val encrypted = OrbitCoreBridge.encryptConfig(masterPassword, plaintext)
        val bumped = runCatching { OrbitCoreBridge.unwrapResult(OrbitCoreBridge.orbitVectorClockBump(vectorClock, "android")) }
            .getOrElse { vectorClock }
        api.uploadConfig(token, UploadConfigRequest(encrypted_blob_base64 = encrypted, vector_clock = bumped))
    }

    suspend fun pullAssets(token: String, masterPassword: String): List<ServerAsset> = withContext(Dispatchers.IO) {
        api.pullConfigs(token).mapNotNull { item ->
            runCatching {
                val plaintext = OrbitCoreBridge.decryptConfig(masterPassword, item.encrypted_blob_base64)
                val portable = json.decodeFromString<PortableServerConfig>(plaintext).validate()
                credentialStore.save(
                    portable.credentialID,
                    ServerCredentials(
                        password = portable.password,
                        privateKeyContent = portable.privateKeyContent,
                        privateKeyPassphrase = portable.privateKeyPassphrase
                    )
                )
                ServerAsset(
                    id = portable.id,
                    credentialID = portable.credentialID,
                    name = portable.name,
                    group = portable.group,
                    host = portable.host,
                    port = portable.port,
                    username = portable.username,
                    authMethod = portable.authMethod,
                    transport = portable.transport,
                    networkDeviceProfile = portable.networkDeviceProfile,
                    allowPasswordFallback = portable.allowPasswordFallback,
                    createdAtUnix = portable.savedAtUnix
                )
            }.getOrNull()
        }
    }

    private fun sanitizeKeyReference(raw: String): String {
        if (!raw.contains("PRIVATE KEY")) return ""
        return "imported-key"
    }
}
