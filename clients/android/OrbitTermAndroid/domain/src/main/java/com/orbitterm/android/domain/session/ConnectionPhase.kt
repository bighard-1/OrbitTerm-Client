package com.orbitterm.android.domain.session

/**
 * The only source of truth for a session's connection lifecycle.
 *
 * UI must render this model directly and must not infer connection state from
 * status text, a native handle, or a collection of booleans.
 */
sealed interface ConnectionPhase {
    data object Idle : ConnectionPhase
    data object Resolving : ConnectionPhase
    data object Connecting : ConnectionPhase
    data object Handshaking : ConnectionPhase
    data object AwaitingHostKeyDecision : ConnectionPhase
    data object Authenticating : ConnectionPhase
    data object OpeningTerminal : ConnectionPhase
    data object Connected : ConnectionPhase
    data class Reconnecting(val attempt: Int, val nextRetryAtEpochMillis: Long) : ConnectionPhase
    data object Disconnecting : ConnectionPhase
    data class Disconnected(val reason: DisconnectReason) : ConnectionPhase
    data class Blocked(val reason: BlockReason) : ConnectionPhase
    data class Failed(
        val error: ConnectionError,
        val retryable: Boolean,
        /** Stable native protocol code only; never includes credentials or host data. */
        val diagnosticCode: String? = null,
    ) : ConnectionPhase
    data object Cancelled : ConnectionPhase
}

enum class DisconnectReason {
    UserRequested,
    NetworkLost,
    KeepAliveTimedOut,
    AppStopped,
    RemoteClosed,
}

enum class BlockReason {
    UnsupportedTransport,
    HostKeyChanged,
    HostKeyRevoked,
    HostKeyUnsupported,
    TrustStoreFailure,
}

enum class ConnectionError {
    AuthenticationFailed,
    AuthenticationTimedOut,
    NetworkUnavailable,
    TimedOut,
    NativeBridgeUnavailable,
    Unknown,
}
