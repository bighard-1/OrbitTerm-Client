package com.orbitterm.android.data.sync

import com.orbitterm.android.domain.assets.NetworkDeviceProfile
import com.orbitterm.android.domain.assets.ServerTransportProtocol
import com.orbitterm.android.domain.assets.JumpHostConfiguration
import kotlinx.serialization.Serializable

/**
 * The encrypted cross-platform sync payload defined by Portable Sync Protocol v1.
 * This DTO may contain secrets only while it is being encrypted or decrypted.
 */
@Serializable
data class PortableServerConfig(
    val id: String,
    val credentialID: String = id,
    val name: String,
    val group: String = "",
    val tags: List<String> = emptyList(),
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
    val savedAtUnix: Long,
    val jumpHost: PortableJumpHostConfig? = null,
) {
    fun validate(): PortableServerConfig {
        val normalizedId = id.trim().lowercase()
        val normalizedCredentialId = credentialID.trim().lowercase()
        require(normalizedId.isNotBlank()) { "id is required" }
        require(normalizedCredentialId.isNotBlank()) { "credentialID is required" }
        require(name.isNotBlank()) { "name is required" }
        require(host.isNotBlank()) { "host is required" }
        require(username.isNotBlank()) { "username is required" }
        require(port in 1..65535) { "port must be between 1 and 65535" }
        require(authMethod == "password" || authMethod == "key") { "unsupported authMethod" }
        require(transport == "ssh" || transport == "telnet" || transport == "rdp") { "unsupported transport" }
        val normalizedJumpHost = jumpHost?.validate()
        if (normalizedJumpHost != null) {
            require(transport == ServerTransportProtocol.ssh.name) { "jump host requires SSH transport" }
        }
        // Apple serializes UUID strings in upper case while Windows and
        // Android commonly use lower case. Stable sync identities and their
        // credential references are case-insensitive across all clients.
        return copy(
            id = normalizedId,
            credentialID = normalizedCredentialId,
            jumpHost = normalizedJumpHost,
        )
    }
}

/** Encrypted sync-only representation. Local Room rows retain metadata only. */
@Serializable
data class PortableJumpHostConfig(
    val credentialID: String,
    val host: String,
    val port: Int,
    val username: String,
    val authMethod: String,
    val allowPasswordFallback: Boolean = true,
    val password: String = "",
    val privateKeyContent: String = "",
    val privateKeyPassphrase: String = "",
) {
    fun validate(): PortableJumpHostConfig {
        val normalized = copy(
            credentialID = credentialID.trim().lowercase(),
            host = host.trim(),
            username = username.trim(),
        )
        normalized.toConfiguration().validate()
        require(password.isNotBlank() || privateKeyContent.isNotBlank()) { "jump host authentication is required" }
        return normalized
    }

    fun toConfiguration(): JumpHostConfiguration = JumpHostConfiguration(
        credentialID = credentialID.trim(),
        host = host.trim(),
        port = port,
        username = username.trim(),
        authMethod = authMethod,
        allowPasswordFallback = allowPasswordFallback,
    )
}
