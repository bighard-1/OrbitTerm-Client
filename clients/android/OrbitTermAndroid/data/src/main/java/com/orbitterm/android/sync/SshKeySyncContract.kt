package com.orbitterm.android.sync

import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal data class SshKeySyncEnvelope(
    val kind: String,
    val version: Int,
    val updatedAtUnix: Long,
    val keys: List<SshKeySyncWire>,
    val tombstones: List<SshKeyTombstoneWire>,
)

@Serializable
internal data class SshKeySyncWire(
    val id: String,
    val name: String,
    val format: String,
    val materialFingerprint: String,
    val createdAtUnix: Long,
    val updatedAtUnix: Long,
    val assignedAssetIds: List<String>,
    val privateKey: String,
    val passphrase: String,
)

@Serializable
internal data class SshKeyTombstoneWire(val id: String, val deletedAtUnix: Long)

@Serializable
internal data class SshKeyVaultDocument(
    val version: Int = 1,
    val keys: List<SshKeySyncWire> = emptyList(),
    val localOnlyKeys: List<SshKeySyncWire> = emptyList(),
    val tombstones: Map<String, Long> = emptyMap(),
    val remoteConfigId: UInt? = null,
    val vectorClock: String = "{}",
    val payloadFingerprint: String = "",
)

/** Wire-compatible with the Windows `orbit_ssh_keys` v1 encrypted envelope. */
internal object SshKeySyncContract {
    const val MARKER = "orbit_ssh_keys"
    const val VERSION = 1
    const val MAXIMUM_KEYS = 128
    private const val MAXIMUM_PRIVATE_KEY_BYTES = 1024 * 1024
    private const val MAXIMUM_PASSPHRASE_BYTES = 16 * 1024
    private const val MAXIMUM_NAME_LENGTH = 80
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun decode(plaintext: String): SshKeySyncEnvelope? = runCatching {
        validate(json.decodeFromString<SshKeySyncEnvelope>(plaintext))
    }.getOrNull()

    fun encode(envelope: SshKeySyncEnvelope): String = json.encodeToString(validate(envelope))

    fun validate(envelope: SshKeySyncEnvelope): SshKeySyncEnvelope {
        require(envelope.kind == MARKER && envelope.version == VERSION)
        require(envelope.updatedAtUnix > 0)
        require(envelope.keys.size <= MAXIMUM_KEYS)
        require(envelope.tombstones.size <= MAXIMUM_KEYS * 4)

        val normalizedKeys = envelope.keys.map(::normalizeKey)
        val normalizedTombstones = envelope.tombstones.map { item ->
            require(item.deletedAtUnix > 0)
            item.copy(id = canonicalUuid(item.id))
        }
        require(normalizedKeys.map(SshKeySyncWire::id).distinct().size == normalizedKeys.size)
        require(normalizedKeys.map(SshKeySyncWire::materialFingerprint).distinct().size == normalizedKeys.size)
        require(normalizedTombstones.map(SshKeyTombstoneWire::id).distinct().size == normalizedTombstones.size)
        return envelope.copy(keys = normalizedKeys, tombstones = normalizedTombstones)
    }

    private fun normalizeKey(item: SshKeySyncWire): SshKeySyncWire {
        val normalizedName = item.name.trim().filterNot(Char::isISOControl)
        require(normalizedName.isNotEmpty() && normalizedName.length <= MAXIMUM_NAME_LENGTH)
        require(item.createdAtUnix > 0 && item.updatedAtUnix >= item.createdAtUnix)
        require(item.assignedAssetIds.size <= 512)
        require(item.passphrase.toByteArray(Charsets.UTF_8).size <= MAXIMUM_PASSPHRASE_BYTES)
        val normalizedPrivateKey = normalizePrivateKey(item.privateKey)
        require(materialFingerprint(normalizedPrivateKey) == item.materialFingerprint)
        return item.copy(
            id = canonicalUuid(item.id),
            name = normalizedName,
            assignedAssetIds = item.assignedAssetIds.map(::canonicalUuid).distinct().sorted(),
            privateKey = normalizedPrivateKey,
        )
    }

    private fun normalizePrivateKey(raw: String): String {
        val value = raw.replace("\r\n", "\n").replace('\r', '\n').trimStart('\uFEFF').trim()
        require(value.isNotEmpty() && '\u0000' !in value)
        require(value.toByteArray(Charsets.UTF_8).size <= MAXIMUM_PRIVATE_KEY_BYTES)
        require(
            value.startsWith("PuTTY-User-Key-File-2:") ||
                value.startsWith("PuTTY-User-Key-File-3:") ||
                "-----BEGIN OPENSSH PRIVATE KEY-----" in value ||
                "-----BEGIN RSA PRIVATE KEY-----" in value ||
                "-----BEGIN EC PRIVATE KEY-----" in value ||
                "-----BEGIN PRIVATE KEY-----" in value ||
                "-----BEGIN ENCRYPTED PRIVATE KEY-----" in value,
        )
        return "$value\n"
    }

    private fun materialFingerprint(privateKey: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(privateKey.toByteArray(Charsets.UTF_8))
        return "SHA256:${Base64.getEncoder().withoutPadding().encodeToString(digest)}"
    }

    private fun canonicalUuid(raw: String): String = UUID.fromString(raw.trim()).toString()
}
