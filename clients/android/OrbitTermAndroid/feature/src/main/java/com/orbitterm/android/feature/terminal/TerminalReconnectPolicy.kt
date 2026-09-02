package com.orbitterm.android.feature.terminal

internal enum class TerminalReconnectAvailability {
    AVAILABLE,
    WAITING_FOR_NETWORK,
    RECONNECTING,
}

internal object TerminalReconnectPolicy {
    fun availability(isNetworkUsable: Boolean, reconnecting: Boolean): TerminalReconnectAvailability =
        when {
            reconnecting -> TerminalReconnectAvailability.RECONNECTING
            !isNetworkUsable -> TerminalReconnectAvailability.WAITING_FOR_NETWORK
            else -> TerminalReconnectAvailability.AVAILABLE
        }

    fun canReconnect(isNetworkUsable: Boolean, reconnecting: Boolean): Boolean =
        availability(isNetworkUsable, reconnecting) == TerminalReconnectAvailability.AVAILABLE

    fun accessibilityLabel(isNetworkUsable: Boolean, reconnecting: Boolean): String =
        when (availability(isNetworkUsable, reconnecting)) {
            TerminalReconnectAvailability.AVAILABLE -> "重新连接当前会话"
            TerminalReconnectAvailability.WAITING_FOR_NETWORK -> "等待网络恢复后重新连接"
            TerminalReconnectAvailability.RECONNECTING -> "正在重新连接当前会话"
        }
}
