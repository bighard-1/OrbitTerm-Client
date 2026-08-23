package com.orbitterm.android.sync

import com.orbitterm.android.domain.assets.AssetRepository
import com.orbitterm.android.domain.assets.CredentialVault
import com.orbitterm.android.domain.assets.ServerAuthMethod
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import com.orbitterm.android.domain.sync.SyncRequester
import com.orbitterm.android.core.OrbitCoreBridge
import com.orbitterm.android.security.SecureCredentialStore
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

data class PortableSshKey(
    val id: String,
    val name: String,
    val format: String,
    val assignedAssetIds: Set<String>,
    val isSynced: Boolean,
    val publicKey: String,
)

@Serializable
private data class GeneratedEd25519KeyPair(
    @SerialName("private_key") val privateKey: String,
    @SerialName("public_key") val publicKey: String,
    val format: String,
)

data class PortablePortForwardProfile(
    val id: String,
    val assetId: String,
    val name: String,
    val bindHost: String,
    val bindPort: Int,
    val destinationHost: String,
    val destinationPort: Int,
    val isSynced: Boolean,
)

/** Account-isolated Android Keystore facade for the portable encrypted libraries. */
@Singleton
class PortableSecurityLibrary @Inject constructor(
    private val secureStore: SecureCredentialStore,
    private val accountScope: ActiveAccountScopeProvider,
    private val assets: AssetRepository,
    private val credentials: CredentialVault,
    private val syncRequester: SyncRequester,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun listKeys(): List<PortableSshKey> {
        val document = readKeyDocument()
        return document.keys.map { it.toSummary(true) } + document.localOnlyKeys.map { it.toSummary(false) }
    }

    fun importKey(name: String, privateKey: String, passphrase: String, synchronize: Boolean): PortableSshKey {
        val normalized = privateKey.replace("\r\n", "\n").replace('\r', '\n').trim() + "\n"
        val now = System.currentTimeMillis() / 1_000
        val item = SshKeySyncWire(
            id = UUID.randomUUID().toString(),
            name = name.trim().ifBlank { "SSH 密钥" },
            format = keyFormat(normalized),
            materialFingerprint = fingerprint(normalized),
            createdAtUnix = now,
            updatedAtUnix = now,
            assignedAssetIds = emptyList(),
            privateKey = normalized,
            passphrase = passphrase,
        )
        // Reuse the cross-platform contract as the validation boundary.
        SshKeySyncContract.validate(SshKeySyncEnvelope(SshKeySyncContract.MARKER, SshKeySyncContract.VERSION, now, listOf(item), emptyList()))
        val document = readKeyDocument()
        writeKeyDocument(if (synchronize) document.copy(keys = document.keys + item) else document.copy(localOnlyKeys = document.localOnlyKeys + item))
        if (synchronize) syncRequester.requestSync()
        return item.toSummary(synchronize)
    }

    fun generateEd25519Key(name: String, synchronize: Boolean): PortableSshKey {
        val safeName = name.trim().ifBlank { "OrbitTerm 移动端密钥" }
        val generated = json.decodeFromString<GeneratedEd25519KeyPair>(
            OrbitCoreBridge.generateEd25519KeyPair(safeName),
        )
        return importKey(safeName, generated.privateKey, "", synchronize)
    }

    fun renameKey(id: String, name: String) {
        val normalizedName = name.trim().filterNot(Char::isISOControl).take(80)
        require(normalizedName.isNotEmpty())
        val now = System.currentTimeMillis() / 1_000
        val document = readKeyDocument()
        fun update(item: SshKeySyncWire) = if (item.id == id) {
            item.copy(name = normalizedName, updatedAtUnix = maxOf(now, item.updatedAtUnix + 1))
        } else item
        val synced = document.keys.any { it.id == id }
        require(synced || document.localOnlyKeys.any { it.id == id })
        writeKeyDocument(document.copy(
            keys = document.keys.map(::update),
            localOnlyKeys = document.localOnlyKeys.map(::update),
        ))
        if (synced) syncRequester.requestSync()
    }

    fun deleteKey(id: String) {
        val document = readKeyDocument()
        val wasSynced = document.keys.any { it.id == id }
        val now = System.currentTimeMillis() / 1_000
        writeKeyDocument(document.copy(
            keys = document.keys.filterNot { it.id == id },
            localOnlyKeys = document.localOnlyKeys.filterNot { it.id == id },
            tombstones = if (wasSynced) document.tombstones + (id to now) else document.tombstones,
        ))
        if (wasSynced) syncRequester.requestSync()
    }

    suspend fun assignKey(keyId: String, assetId: String) {
        val document = readKeyDocument()
        val key = (document.keys + document.localOnlyKeys).first { it.id == keyId }
        val asset = requireNotNull(assets.findAsset(assetId))
        val current = credentials.read(asset.credentialID) ?: com.orbitterm.android.domain.assets.ServerCredentials()
        credentials.save(asset.credentialID, current.copy(privateKeyContent = key.privateKey, privateKeyPassphrase = key.passphrase))
        assets.saveAsset(asset.copy(authMethod = ServerAuthMethod.key.name))
        val now = System.currentTimeMillis() / 1_000
        fun update(item: SshKeySyncWire) = if (item.id == keyId) item.copy(
            assignedAssetIds = (item.assignedAssetIds + assetId).distinct().sorted(),
            updatedAtUnix = now,
        ) else item
        writeKeyDocument(document.copy(keys = document.keys.map(::update), localOnlyKeys = document.localOnlyKeys.map(::update)))
        if (document.keys.any { it.id == keyId }) syncRequester.requestSync()
    }

    fun listPortForwardProfiles(): List<PortablePortForwardProfile> {
        val document = readProfileDocument()
        return document.profiles.map { it.toSummary(true) } + document.localOnlyProfiles.map { it.toSummary(false) }
    }

    fun savePortForwardProfile(
        assetId: String,
        name: String,
        bindPort: Int,
        destinationHost: String,
        destinationPort: Int,
        synchronize: Boolean,
    ): PortablePortForwardProfile {
        val now = System.currentTimeMillis() / 1_000
        val item = PortForwardProfileWire(
            id = UUID.randomUUID().toString(), assetId = assetId, name = name.trim().ifBlank { "$destinationHost:$destinationPort" },
            mode = "local", bindHost = "127.0.0.1", bindPort = bindPort,
            destinationHost = destinationHost.trim(), destinationPort = destinationPort,
            createdAtUnix = now, updatedAtUnix = now,
        )
        PortForwardProfileSyncContract.validate(PortForwardProfileSyncEnvelope(
            PortForwardProfileSyncContract.MARKER, PortForwardProfileSyncContract.VERSION, now, listOf(item), emptyList(),
        ))
        val document = readProfileDocument()
        writeProfileDocument(if (synchronize) document.copy(profiles = document.profiles + item) else document.copy(localOnlyProfiles = document.localOnlyProfiles + item))
        if (synchronize) syncRequester.requestSync()
        return item.toSummary(synchronize)
    }

    fun deletePortForwardProfile(id: String) {
        val document = readProfileDocument()
        val wasSynced = document.profiles.any { it.id == id }
        val now = System.currentTimeMillis() / 1_000
        writeProfileDocument(document.copy(
            profiles = document.profiles.filterNot { it.id == id },
            localOnlyProfiles = document.localOnlyProfiles.filterNot { it.id == id },
            tombstones = if (wasSynced) document.tombstones + (id to now) else document.tombstones,
        ))
        if (wasSynced) syncRequester.requestSync()
    }

    private fun readKeyDocument(): SshKeyVaultDocument = secureStore.readSshKeyLibraryDocument(storageId())
        ?.let { runCatching { json.decodeFromString<SshKeyVaultDocument>(it) }.getOrNull() } ?: SshKeyVaultDocument()
    private fun writeKeyDocument(value: SshKeyVaultDocument) = secureStore.saveSshKeyLibraryDocument(storageId(), json.encodeToString(value))
    private fun readProfileDocument(): PortForwardProfileVaultDocument = secureStore.readPortForwardProfileDocument(storageId())
        ?.let { runCatching { json.decodeFromString<PortForwardProfileVaultDocument>(it) }.getOrNull() } ?: PortForwardProfileVaultDocument()
    private fun writeProfileDocument(value: PortForwardProfileVaultDocument) = secureStore.savePortForwardProfileDocument(storageId(), json.encodeToString(value))
    private fun storageId() = requireNotNull(accountScope.scope.value) { "no active account" }.storageId
    private fun fingerprint(value: String): String = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)),
    )
    private fun keyFormat(value: String) = when {
        value.startsWith("PuTTY-User-Key-File-") -> "PuTTY"
        "OPENSSH" in value -> "OpenSSH"
        "RSA PRIVATE KEY" in value -> "PEM RSA"
        "EC PRIVATE KEY" in value -> "PEM EC"
        else -> "PKCS#8"
    }
    private fun SshKeySyncWire.toSummary(synced: Boolean) = PortableSshKey(
        id = id,
        name = name,
        format = format,
        assignedAssetIds = assignedAssetIds.toSet(),
        isSynced = synced,
        publicKey = runCatching { OrbitCoreBridge.publicKeyFromPrivate(privateKey, passphrase) }.getOrDefault(""),
    )
    private fun PortForwardProfileWire.toSummary(synced: Boolean) = PortablePortForwardProfile(
        id, assetId, name, bindHost, bindPort, destinationHost, destinationPort, synced,
    )
}
