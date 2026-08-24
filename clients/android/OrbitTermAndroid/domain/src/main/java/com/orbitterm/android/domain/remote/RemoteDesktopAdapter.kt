package com.orbitterm.android.domain.remote

import java.util.UUID
import kotlinx.coroutines.flow.Flow

enum class RemoteDesktopTargetPlatform { windows, linux, macos;
    val isSupported: Boolean get() = this == windows || this == linux
}

enum class RemoteDesktopSessionPhase {
    starting, authenticating, awaitingUserDecision, connected, reconnecting, disconnected, failed, closed
}

enum class RemoteDesktopFailureKind {
    engineUnavailable, invalidTarget, certificateRejected, authenticationFailed,
    networkUnavailable, timedOut, protocolError, cancelled, unknown
}

class RemoteDesktopAdapterException(val kind: RemoteDesktopFailureKind) : Exception(kind.name)

data class RemoteDesktopConnectionProfile(
    val assetId: UUID,
    val host: String,
    val port: Int,
    val targetPlatform: RemoteDesktopTargetPlatform,
    val credentialId: UUID,
    val requireNla: Boolean = true,
) {
    init {
        if (host.isBlank() || port !in 1..65535 || !targetPlatform.isSupported) {
            throw RemoteDesktopAdapterException(RemoteDesktopFailureKind.invalidTarget)
        }
    }
}

data class RemoteDesktopSessionUpdate(
    val phase: RemoteDesktopSessionPhase,
    val failure: RemoteDesktopFailureKind? = null,
    val requiresCertificateDecision: Boolean = false,
)

enum class RemoteDesktopRuntimeCapability { available, unavailable }

interface RemoteDesktopEngineSession {
    val updates: Flow<RemoteDesktopSessionUpdate>
    suspend fun reconnect()
    suspend fun setFullScreen(enabled: Boolean)
    suspend fun close()
}

interface RemoteDesktopEngineAdapter {
    val capability: RemoteDesktopRuntimeCapability
    suspend fun open(profile: RemoteDesktopConnectionProfile): RemoteDesktopEngineSession
}

/** Fail-closed until the audited FreeRDP runtime is packaged for Android. */
class DeferredFreeRdpAdapter : RemoteDesktopEngineAdapter {
    override val capability = RemoteDesktopRuntimeCapability.unavailable

    override suspend fun open(profile: RemoteDesktopConnectionProfile): RemoteDesktopEngineSession {
        @Suppress("UNUSED_VARIABLE") val validatedProfile = profile
        throw RemoteDesktopAdapterException(RemoteDesktopFailureKind.engineUnavailable)
    }
}

class RemoteDesktopSessionStateMachine {
    var phase: RemoteDesktopSessionPhase = RemoteDesktopSessionPhase.starting
        private set

    fun transitionTo(next: RemoteDesktopSessionPhase): Boolean {
        if (next !in allowedTransitions.getValue(phase)) return false
        phase = next
        return true
    }

    private companion object {
        val allowedTransitions = mapOf(
            RemoteDesktopSessionPhase.starting to setOf(RemoteDesktopSessionPhase.authenticating, RemoteDesktopSessionPhase.awaitingUserDecision, RemoteDesktopSessionPhase.failed, RemoteDesktopSessionPhase.closed),
            RemoteDesktopSessionPhase.authenticating to setOf(RemoteDesktopSessionPhase.awaitingUserDecision, RemoteDesktopSessionPhase.connected, RemoteDesktopSessionPhase.reconnecting, RemoteDesktopSessionPhase.failed, RemoteDesktopSessionPhase.closed),
            RemoteDesktopSessionPhase.awaitingUserDecision to setOf(RemoteDesktopSessionPhase.authenticating, RemoteDesktopSessionPhase.connected, RemoteDesktopSessionPhase.reconnecting, RemoteDesktopSessionPhase.failed, RemoteDesktopSessionPhase.closed),
            RemoteDesktopSessionPhase.connected to setOf(RemoteDesktopSessionPhase.reconnecting, RemoteDesktopSessionPhase.disconnected, RemoteDesktopSessionPhase.failed, RemoteDesktopSessionPhase.closed),
            RemoteDesktopSessionPhase.reconnecting to setOf(RemoteDesktopSessionPhase.authenticating, RemoteDesktopSessionPhase.awaitingUserDecision, RemoteDesktopSessionPhase.connected, RemoteDesktopSessionPhase.disconnected, RemoteDesktopSessionPhase.failed, RemoteDesktopSessionPhase.closed),
            RemoteDesktopSessionPhase.disconnected to setOf(RemoteDesktopSessionPhase.reconnecting, RemoteDesktopSessionPhase.closed),
            RemoteDesktopSessionPhase.failed to setOf(RemoteDesktopSessionPhase.reconnecting, RemoteDesktopSessionPhase.closed),
            RemoteDesktopSessionPhase.closed to emptySet(),
        )
    }
}
