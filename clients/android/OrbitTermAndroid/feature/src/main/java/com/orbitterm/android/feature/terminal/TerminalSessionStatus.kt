package com.orbitterm.android.feature.terminal

enum class TerminalSessionConnectionState { Connected, Disconnected }

internal fun terminalFailureClosesSession(code: String): Boolean =
    code == "session_closed" || code == "session_not_found"

/** A live-session headline never uses the ambiguous marketing term “在线”. */
internal fun terminalSessionStatusLabel(
    state: TerminalSessionConnectionState,
    reconnecting: Boolean,
    sessionCount: Int,
): String {
    val headline = when {
        reconnecting -> "重连中"
        state == TerminalSessionConnectionState.Connected -> "已连接"
        else -> "已断开"
    }
    return "$headline · $sessionCount 个会话"
}
