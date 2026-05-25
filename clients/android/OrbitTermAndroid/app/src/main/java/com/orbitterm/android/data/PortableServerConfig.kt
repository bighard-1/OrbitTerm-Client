package com.orbitterm.android.data

import kotlinx.serialization.Serializable

@Serializable
enum class ServerAuthMethod { password, key }

@Serializable
enum class ServerTransportProtocol { ssh, telnet }

@Serializable
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
    generic
}

@Serializable
data class PortableServerConfig(
    val id: String,
    val credentialID: String = id,
    val name: String,
    val group: String = "",
    val host: String,
    val port: Int,
    val username: String,
    val authMethod: String,
    val transport: String = ServerTransportProtocol.ssh.name,
    val networkDeviceProfile: String = NetworkDeviceProfile.auto.name,
    val allowPasswordFallback: Boolean = true,
    val password: String = "",
    val privateKeyContent: String = "",
    val privateKeyPassphrase: String = "",
    val keyReference: String = "",
    val savedAtUnix: Long
) {
    fun validate(): PortableServerConfig {
        require(id.isNotBlank()) { "id is required" }
        require(name.isNotBlank()) { "name is required" }
        require(host.isNotBlank()) { "host is required" }
        require(username.isNotBlank()) { "username is required" }
        require(port in 1..65535) { "port must be between 1 and 65535" }
        require(authMethod == "password" || authMethod == "key") { "unsupported authMethod" }
        require(transport == "ssh" || transport == "telnet") { "unsupported transport" }
        return this
    }
}

@Serializable
data class ServerAsset(
    val id: String,
    val credentialID: String,
    val name: String,
    val group: String,
    val host: String,
    val port: Int,
    val username: String,
    val authMethod: String,
    val transport: String,
    val networkDeviceProfile: String,
    val allowPasswordFallback: Boolean,
    val createdAtUnix: Long
)

@Serializable
data class ServerCredentials(
    val password: String = "",
    val privateKeyContent: String = "",
    val privateKeyPassphrase: String = ""
)
