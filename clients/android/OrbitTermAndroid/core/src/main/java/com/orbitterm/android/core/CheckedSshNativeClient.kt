package com.orbitterm.android.core

import android.content.Context
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.ServerAuthMethod
import com.orbitterm.android.domain.assets.ServerCredentials
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

sealed interface CheckedSshConnectResult {
    data class Connected(val baseSessionId: Long) : CheckedSshConnectResult
    data class HostKeyChallenge(
        val challengeId: String,
        val host: String,
        val port: Int,
        val keyAlgorithm: String,
        val fingerprintSha256: String,
    ) : CheckedSshConnectResult
    data class Blocked(val reasonCode: String) : CheckedSshConnectResult
    data class Failure(
        val code: String,
        val retryable: Boolean,
        val detailCode: String? = null,
    ) : CheckedSshConnectResult
}

@Singleton
class CheckedSshNativeClient @Inject constructor(
    @param:ApplicationContext private val context: Context,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun connect(
        asset: ServerAsset,
        credentials: ServerCredentials,
        jumpHostCredentials: ServerCredentials? = null,
    ): CheckedSshConnectResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) {
            return CheckedSshConnectResult.Failure("native_bridge_unavailable", retryable = false)
        }
        val effectiveCredentials = credentials.forAuthMethod(asset.authMethod, asset.allowPasswordFallback)
        val jump = asset.jumpHost
        val effectiveJumpCredentials = jump?.let {
            jumpHostCredentials?.forJumpHostAuthMethod(it.authMethod, it.allowPasswordFallback)
                ?: return CheckedSshConnectResult.Failure("jump_credentials_unavailable", retryable = false)
        }
        val requestId = UUID.randomUUID().toString()
        val response = runCatching {
            if (jump == null) {
                OrbitCoreBridge.orbitCheckedSshConnect(
                    host = asset.host, port = asset.port, username = asset.username,
                    password = effectiveCredentials.password, privateKey = effectiveCredentials.privateKeyContent,
                    privateKeyPassphrase = effectiveCredentials.privateKeyPassphrase,
                    allowPasswordFallback = asset.allowPasswordFallback,
                    knownHostsPath = knownHostsFile().absolutePath, requestId = requestId,
                )
            } else {
                OrbitCoreBridge.orbitCheckedSshConnectViaJump(
                    host = asset.host, port = asset.port, username = asset.username,
                    password = effectiveCredentials.password, privateKey = effectiveCredentials.privateKeyContent,
                    privateKeyPassphrase = effectiveCredentials.privateKeyPassphrase,
                    allowPasswordFallback = asset.allowPasswordFallback,
                    jumpHost = jump.host, jumpPort = jump.port, jumpUsername = jump.username,
                    jumpPassword = effectiveJumpCredentials!!.password,
                    jumpPrivateKey = effectiveJumpCredentials.privateKeyContent,
                    jumpPrivateKeyPassphrase = effectiveJumpCredentials.privateKeyPassphrase,
                    jumpAllowPasswordFallback = jump.allowPasswordFallback,
                    knownHostsPath = knownHostsFile().absolutePath, requestId = requestId,
                )
            }
        }.getOrElse {
            return CheckedSshConnectResult.Failure("native_bridge_failed", retryable = false)
        }
        return parseConnectResponse(response, requestId)
    }

    fun trustChallenge(challengeId: String): CheckedSshConnectResult.Failure? {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) {
            return CheckedSshConnectResult.Failure("native_bridge_unavailable", retryable = false)
        }
        val response = runCatching {
            OrbitCoreBridge.orbitAcceptHostKeyAndPersist(challengeId, knownHostsFile().absolutePath)
        }.getOrElse {
            return CheckedSshConnectResult.Failure("native_bridge_failed", retryable = false)
        }
        val envelope = parseEnvelope(response) ?: return CheckedSshConnectResult.Failure("invalid_native_response", false)
        return if (envelope.kind == "host_key_trust_persisted") null else envelope.failure()
    }

    fun rejectChallenge(challengeId: String) {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) return
        runCatching { OrbitCoreBridge.orbitRejectHostKeyChallenge(challengeId) }
    }

    fun disconnect(baseSessionId: Long): Boolean {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || baseSessionId <= 0) return false
        val requestId = UUID.randomUUID().toString()
        val response = runCatching {
            OrbitCoreBridge.orbitDisconnectCheckedSsh(baseSessionId, requestId)
        }.getOrNull() ?: return false
        val envelope = parseEnvelope(response) ?: return false
        return envelope.requestId == requestId &&
            envelope.kind == "ssh_disconnect_completed" &&
            envelope.data.long("base_session_id") == baseSessionId
    }

    private fun parseConnectResponse(response: String, requestId: String): CheckedSshConnectResult {
        val envelope = parseEnvelope(response)
            ?: return CheckedSshConnectResult.Failure("invalid_native_response", retryable = false)
        if (envelope.requestId != requestId) {
            return CheckedSshConnectResult.Failure("uncorrelated_native_response", retryable = false)
        }
        return when (envelope.kind) {
            // The checked-connect protocol names the pooled verified handle
            // `session_id`. `base_session_id` is used by later channel APIs.
            "connected" -> envelope.data.long("session_id")?.let(CheckedSshConnectResult::Connected)
                ?: CheckedSshConnectResult.Failure("invalid_connected_response", false)
            "host_key_challenge" -> envelope.data.toChallenge()
                ?: CheckedSshConnectResult.Failure("invalid_host_key_challenge", false)
            "host_key_blocked" -> CheckedSshConnectResult.Blocked(
                envelope.data.string("reason_code") ?: "host_key_blocked",
            )
            else -> envelope.failure()
        }
    }

    private fun knownHostsFile(): File {
        val securityDirectory = File(context.filesDir, "security")
        check(securityDirectory.exists() || securityDirectory.mkdirs()) { "known hosts directory unavailable" }
        return File(securityDirectory, "known_hosts")
    }

    private fun parseEnvelope(raw: String): NativeEnvelope? = runCatching {
        val root = json.parseToJsonElement(raw).jsonObject
        val schemaVersion = root.long("schema_version") ?: return null
        if (schemaVersion != 1L) return null
        NativeEnvelope(
            requestId = root.string("request_id") ?: return null,
            kind = root.string("kind") ?: return null,
            // Error envelopes intentionally use `"data": null`; do not turn a
            // valid native failure into an unhelpful JSON parsing failure.
            data = root["data"] as? JsonObject ?: JsonObject(emptyMap()),
            error = root["error"] as? JsonObject,
        )
    }.getOrNull()

    private data class NativeEnvelope(
        val requestId: String,
        val kind: String,
        val data: JsonObject,
        val error: JsonObject?,
    ) {
        fun failure(): CheckedSshConnectResult.Failure = CheckedSshConnectResult.Failure(
            code = error?.string("code") ?: "native_operation_failed",
            retryable = error?.get("retryable")?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: false,
            detailCode = error?.string("detail_code"),
        )
    }
}

private fun JsonObject.toChallenge(): CheckedSshConnectResult.HostKeyChallenge? {
    val challengeId = string("challenge_id") ?: return null
    val host = string("normalized_host") ?: string("host") ?: return null
    val port = long("port")?.toInt() ?: return null
    val keyAlgorithm = string("key_algorithm") ?: return null
    val fingerprint = string("fingerprint_sha256") ?: return null
    return CheckedSshConnectResult.HostKeyChallenge(challengeId, host, port, keyAlgorithm, fingerprint)
}

private fun JsonObject.string(key: String): String? = get(key)?.jsonPrimitive?.content

private fun JsonObject.long(key: String): Long? = string(key)?.toLongOrNull()

/** Prevent stale credentials from a previously selected authentication method. */
internal fun ServerCredentials.forAuthMethod(
    rawMethod: String,
    allowPasswordFallback: Boolean,
): ServerCredentials = when (
    enumValues<ServerAuthMethod>().firstOrNull { it.name == rawMethod }
) {
    ServerAuthMethod.password -> ServerCredentials(password = password)
    ServerAuthMethod.key, null -> ServerCredentials(
        password = if (allowPasswordFallback) password else "",
        privateKeyContent = privateKeyContent,
        privateKeyPassphrase = privateKeyPassphrase,
    )
}

/** A jump private key may explicitly fall back to its separately entered password. */
private fun ServerCredentials.forJumpHostAuthMethod(
    rawMethod: String,
    allowPasswordFallback: Boolean,
): ServerCredentials = when (enumValues<ServerAuthMethod>().firstOrNull { it.name == rawMethod }) {
    ServerAuthMethod.password -> ServerCredentials(password = password)
    ServerAuthMethod.key, null -> ServerCredentials(
        password = if (allowPasswordFallback) password else "",
        privateKeyContent = privateKeyContent,
        privateKeyPassphrase = privateKeyPassphrase,
    )
}
