package com.orbitterm.android.domain.assets

/**
 * SSH is always available through the checked core. Telnet is exposed only
 * after an explicit, persisted plaintext-risk confirmation.
 */
object AndroidTransportSupportPolicy {
    fun allowsCheckedConnection(transport: String, telnetEnabled: Boolean = false): Boolean =
        transport == ServerTransportProtocol.ssh.name ||
            (transport == ServerTransportProtocol.telnet.name && telnetEnabled)

    fun compatibilityLabel(transport: String): String = when (transport) {
        ServerTransportProtocol.ssh.name -> "SSH"
        ServerTransportProtocol.telnet.name -> "TELNET · 明文连接"
        else -> "未知传输协议 · Android 不支持连接"
    }

    const val unsupportedConnectionMessage =
        "此协议尚未启用或无法安全连接。Telnet 需先在设置中确认明文传输风险。"
}
