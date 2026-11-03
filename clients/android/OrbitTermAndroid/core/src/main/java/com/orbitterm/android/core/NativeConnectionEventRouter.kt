package com.orbitterm.android.core

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

sealed interface NativeSessionEvent {
    data class BaseConnectionLost(val baseSessionId: Long) : NativeSessionEvent
    data class TerminalClosed(val terminalChannelId: Long) : NativeSessionEvent
}

/** Never block the native SSH/terminal worker while delivering lifecycle events. */
internal class ConnectionEventPipeline {
    private val incoming = Channel<NativeSessionEvent>(Channel.UNLIMITED)
    val events: Flow<NativeSessionEvent> = incoming.receiveAsFlow()

    fun submit(sessionId: Long, code: String) {
        if (sessionId <= 0) return
        val event = when (code) {
            "ERR_CONNECTION_LOST" -> NativeSessionEvent.BaseConnectionLost(sessionId)
            "ERR_TERMINAL_CLOSED" -> NativeSessionEvent.TerminalClosed(sessionId)
            else -> return
        }
        incoming.trySend(event)
    }
}

/** JNI invokes this object from a native worker thread. It never carries host or credential data. */
object NativeConnectionEventRouter {
    private val pipeline = ConnectionEventPipeline()
    val events: Flow<NativeSessionEvent> = pipeline.events

    fun onConnectionEvent(sessionId: Long, code: String) = pipeline.submit(sessionId, code)
}
