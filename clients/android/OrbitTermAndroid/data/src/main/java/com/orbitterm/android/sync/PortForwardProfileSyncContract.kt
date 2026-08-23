package com.orbitterm.android.sync

import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

@Serializable
internal data class PortForwardProfileSyncEnvelope(
    val kind: String,
    val version: Int,
    val updatedAtUnix: Long,
    val profiles: List<PortForwardProfileWire>,
    val tombstones: List<PortForwardProfileTombstoneWire>,
)

@Serializable
internal data class PortForwardProfileWire(
    val id: String,
    val assetId: String,
    val name: String,
    val mode: String,
    val bindHost: String,
    val bindPort: Int,
    val destinationHost: String,
    val destinationPort: Int,
    val createdAtUnix: Long,
    val updatedAtUnix: Long,
)

@Serializable
internal data class PortForwardProfileTombstoneWire(val id: String, val deletedAtUnix: Long)

@Serializable
internal data class PortForwardProfileVaultDocument(
    val version: Int = 1,
    val profiles: List<PortForwardProfileWire> = emptyList(),
    val localOnlyProfiles: List<PortForwardProfileWire> = emptyList(),
    val tombstones: Map<String, Long> = emptyMap(),
    val remoteConfigId: UInt? = null,
    val vectorClock: String = "{}",
    val payloadFingerprint: String = "",
)

/** Saved profile contract only; live tunnel/process/auto-start state is rejected. */
internal object PortForwardProfileSyncContract {
    const val MARKER = "orbit_port_forwards"
    const val VERSION = 1
    const val MAXIMUM_PROFILES = 256
    private const val MAXIMUM_RULES_PER_ASSET = 32
    private val forbiddenLiveFields = setOf(
        "tunnelId", "processId", "isRunning", "running", "autoStart", "startAfterVerifiedConnection",
    )
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun decode(plaintext: String): PortForwardProfileSyncEnvelope? = runCatching {
        val root = json.parseToJsonElement(plaintext).jsonObject
        require(!containsLiveState(root))
        validate(json.decodeFromJsonElement<PortForwardProfileSyncEnvelope>(root))
    }.getOrNull()

    fun encode(envelope: PortForwardProfileSyncEnvelope): String = json.encodeToString(validate(envelope))

    fun validate(envelope: PortForwardProfileSyncEnvelope): PortForwardProfileSyncEnvelope {
        require(envelope.kind == MARKER && envelope.version == VERSION && envelope.updatedAtUnix > 0)
        require(envelope.profiles.size <= MAXIMUM_PROFILES)
        require(envelope.tombstones.size <= MAXIMUM_PROFILES * 4)
        val profiles = envelope.profiles.map(::normalize)
        val tombstones = envelope.tombstones.map { item ->
            require(item.deletedAtUnix > 0)
            item.copy(id = canonicalUuid(item.id))
        }
        require(profiles.map(PortForwardProfileWire::id).distinct().size == profiles.size)
        require(tombstones.map(PortForwardProfileTombstoneWire::id).distinct().size == tombstones.size)
        require(profiles.groupingBy(PortForwardProfileWire::assetId).eachCount().values.all { it <= MAXIMUM_RULES_PER_ASSET })
        return envelope.copy(profiles = profiles, tombstones = tombstones)
    }

    private fun normalize(item: PortForwardProfileWire): PortForwardProfileWire {
        val name = normalizeText(item.name, 80)
        val bindHost = normalizeHost(item.bindHost)
        require(item.mode in setOf("local", "remote", "dynamicSocks5"))
        require(item.bindPort in 0..65535)
        require(item.createdAtUnix > 0 && item.updatedAtUnix >= item.createdAtUnix)
        val dynamic = item.mode == "dynamicSocks5"
        val destinationHost = if (dynamic) "" else normalizeHost(item.destinationHost)
        val destinationPort = if (dynamic) 0 else item.destinationPort.also { require(it in 1..65535) }
        return item.copy(
            id = canonicalUuid(item.id),
            assetId = canonicalUuid(item.assetId),
            name = name,
            bindHost = bindHost,
            destinationHost = destinationHost,
            destinationPort = destinationPort,
        )
    }

    private fun containsLiveState(root: JsonObject): Boolean {
        if (root.keys.any(forbiddenLiveFields::contains)) return true
        val profiles = root["profiles"]?.jsonArray ?: return false
        return profiles.any { element -> element.jsonObject.keys.any(forbiddenLiveFields::contains) }
    }

    private fun canonicalUuid(raw: String): String = UUID.fromString(raw.trim()).toString()

    private fun normalizeHost(raw: String): String = normalizeText(raw, 253).also { host ->
        require(host.none { it.isWhitespace() || it.isISOControl() })
    }

    private fun normalizeText(raw: String, maximum: Int): String = raw.trim().also { value ->
        require(value.isNotEmpty() && value.length <= maximum && value.none(Char::isISOControl))
    }
}
