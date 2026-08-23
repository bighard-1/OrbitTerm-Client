package com.orbitterm.android.domain.assets

import kotlinx.serialization.Serializable

enum class ServerAuthMethod { password, key }

enum class ServerTransportProtocol { ssh, telnet, rdp }

enum class NetworkDeviceProfile {
    auto,
    huaweiVRP,
    h3cComware,
    ciscoIOS,
    ciscoASA,
    juniperJunos,
    fortinetFortiGate,
    paloAltoPANOS,
    mikrotikRouterOS,
    ruijie,
    sangfor,
    hillstone,
    checkPoint,
    f5BIGIP,
    generic,
}

/** Metadata safe to persist in Room and render in the asset list. */
data class ServerAsset(
    val id: String,
    val credentialID: String,
    val name: String,
    val group: String,
    /** User-visible, non-sensitive search metadata. */
    val tags: List<String> = emptyList(),
    val host: String,
    val port: Int,
    val username: String,
    val authMethod: String,
    val transport: String,
    val networkDeviceProfile: String,
    val allowPasswordFallback: Boolean,
    /** Optional one-hop SSH route; its credential is stored separately in Android Keystore. */
    val jumpHost: JumpHostConfiguration? = null,
    val createdAtUnix: Long,
)

/** Metadata for one checked SSH ProxyJump hop. Never contains authentication material. */
@Serializable
data class JumpHostConfiguration(
    val credentialID: String,
    val host: String,
    val port: Int = 22,
    val username: String,
    val authMethod: String,
    val allowPasswordFallback: Boolean = true,
) {
    fun validate(): JumpHostConfiguration {
        require(credentialID.isNotBlank()) { "jump credential ID is required" }
        require(host.isNotBlank()) { "jump host is required" }
        require(username.isNotBlank()) { "jump username is required" }
        require(port in 1..65_535) { "jump port must be between 1 and 65535" }
        require(authMethod == ServerAuthMethod.password.name || authMethod == ServerAuthMethod.key.name) {
            "unsupported jump authentication method"
        }
        return this
    }
}

/** Sensitive values. This type must never be written to Room or application logs. */
@Serializable
data class ServerCredentials(
    val password: String = "",
    val privateKeyContent: String = "",
    val privateKeyPassphrase: String = "",
)
