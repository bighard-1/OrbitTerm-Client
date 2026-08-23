package com.orbitterm.android.core

import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class LocalTunnelLease(val tunnelId: Long, val bindHost: String, val bindPort: Int)

sealed interface CheckedPortForwardResult {
    data class Started(val lease: LocalTunnelLease) : CheckedPortForwardResult
    data object Stopped : CheckedPortForwardResult
    data class Failure(val code: String) : CheckedPortForwardResult
}

@Singleton
class CheckedPortForwardNativeClient @Inject constructor() {
    private val json = Json { ignoreUnknownKeys = true }

    fun start(baseSessionId: Long, bindPort: Int, destinationHost: String, destinationPort: Int): CheckedPortForwardResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) return CheckedPortForwardResult.Failure("native_bridge_unavailable")
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching {
            OrbitCoreBridge.orbitStartCheckedLocalTunnel(baseSessionId, "127.0.0.1", bindPort, destinationHost, destinationPort, requestId)
        }.getOrElse { return CheckedPortForwardResult.Failure("native_bridge_failed") }
        return decode(raw, requestId, started = true)
    }

    fun stop(tunnelId: Long): CheckedPortForwardResult {
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching { OrbitCoreBridge.orbitStopCheckedLocalTunnel(tunnelId, requestId) }
            .getOrElse { return CheckedPortForwardResult.Failure("native_bridge_failed") }
        return decode(raw, requestId, started = false)
    }

    private fun decode(raw: String, requestId: String, started: Boolean): CheckedPortForwardResult {
        val root = runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
            ?: return CheckedPortForwardResult.Failure("invalid_native_response")
        if (root.text("request_id") != requestId) return CheckedPortForwardResult.Failure("uncorrelated_native_response")
        val expected = if (started) "local_tunnel_started" else "local_tunnel_stopped"
        if (root.text("kind") != expected) return CheckedPortForwardResult.Failure(
            root["error"]?.jsonObject?.text("code") ?: "native_operation_failed",
        )
        if (!started) return CheckedPortForwardResult.Stopped
        val data = root["data"]?.jsonObject ?: return CheckedPortForwardResult.Failure("invalid_native_response")
        return CheckedPortForwardResult.Started(LocalTunnelLease(
            tunnelId = data.text("tunnel_id")?.toLongOrNull() ?: return CheckedPortForwardResult.Failure("invalid_native_response"),
            bindHost = data.text("bind_host") ?: return CheckedPortForwardResult.Failure("invalid_native_response"),
            bindPort = data.text("bind_port")?.toIntOrNull() ?: return CheckedPortForwardResult.Failure("invalid_native_response"),
        ))
    }
}

private fun kotlinx.serialization.json.JsonObject.text(key: String): String? = get(key)?.jsonPrimitive?.content
