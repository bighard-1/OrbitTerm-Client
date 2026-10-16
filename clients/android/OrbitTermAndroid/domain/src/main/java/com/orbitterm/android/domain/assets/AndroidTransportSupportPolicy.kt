package com.orbitterm.android.domain.assets

/**
 * SSH is always available through the checked core. Telnet is exposed only
 * after an explicit, persisted plaintext-risk confirmation. RDP metadata is
 * synchronized and editable on mobile, but session execution is desktop-only.
 */
object AndroidTransportSupportPolicy {
    fun allowsCheckedConnection(
        transport: String,
        telnetEnabled: Boolean = false,
    ): Boolean =
        transport == ServerTransportProtocol.ssh.name ||
            (transport == ServerTransportProtocol.telnet.name && telnetEnabled)

    fun compatibilityLabel(transport: String): String = when (transport) {
        ServerTransportProtocol.ssh.name -> "SSH"
        ServerTransportProtocol.telnet.name -> "TELNET · 明文连接"
        ServerTransportProtocol.rdp.name -> "RDP · 已同步，仅桌面端可连接"
        else -> "未知传输协议 · Android 不支持连接"
    }

    const val unsupportedConnectionMessage =
        "此协议尚未启用或当前版本无法安全连接。Telnet 需先确认明文风险；RDP 资产会保留并同步，仅桌面端可连接。"
}
