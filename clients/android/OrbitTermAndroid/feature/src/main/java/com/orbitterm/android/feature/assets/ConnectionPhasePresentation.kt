package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.session.ConnectionPhase

/** Stable mobile headline; protocol-specific guidance belongs in dialog detail. */
internal fun ConnectionPhase.presentationHeadline(): String = when (this) {
    ConnectionPhase.Idle -> "未连接"
    ConnectionPhase.Resolving,
    ConnectionPhase.Connecting,
    ConnectionPhase.Handshaking,
    ConnectionPhase.Authenticating,
    ConnectionPhase.OpeningTerminal -> "连接中"
    ConnectionPhase.AwaitingHostKeyDecision -> "等待确认"
    ConnectionPhase.Connected -> "已连接"
    is ConnectionPhase.Reconnecting -> "重连中"
    ConnectionPhase.Disconnecting,
    is ConnectionPhase.Disconnected -> "已断开"
    is ConnectionPhase.Blocked -> "连接已阻止"
    is ConnectionPhase.Failed -> "连接失败"
    ConnectionPhase.Cancelled -> "连接已取消"
}
