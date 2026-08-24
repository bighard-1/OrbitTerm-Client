package com.orbitterm.android.domain.assets

import com.orbitterm.android.domain.remote.RemoteDesktopRuntimeCapability

/**
 * SSH is always available through the checked core. Telnet is exposed only
 * after an explicit, persisted plaintext-risk confirmation.
 */
object AndroidTransportSupportPolicy {
    fun allowsCheckedConnection(
        transport: String,
        telnetEnabled: Boolean = false,
        remoteDesktopCapability: RemoteDesktopRuntimeCapability = RemoteDesktopRuntimeCapability.unavailable,
    ): Boolean =
        transport == ServerTransportProtocol.ssh.name ||
            (transport == ServerTransportProtocol.telnet.name && telnetEnabled) ||
            (transport == ServerTransportProtocol.rdp.name &&
                remoteDesktopCapability == RemoteDesktopRuntimeCapability.available)

    fun compatibilityLabel(
        transport: String,
        remoteDesktopCapability: RemoteDesktopRuntimeCapability = RemoteDesktopRuntimeCapability.unavailable,
    ): String = when (transport) {
        ServerTransportProtocol.ssh.name -> "SSH"
        ServerTransportProtocol.telnet.name -> "TELNET · 明文连接"
        ServerTransportProtocol.rdp.name -> if (remoteDesktopCapability == RemoteDesktopRuntimeCapability.available) {
            "RDP · FreeRDP 安全连接"
        } else {
            "RDP · 已同步，当前 Android 版本暂不支持连接"
        }
        else -> "未知传输协议 · Android 不支持连接"
    }

    const val unsupportedConnectionMessage =
        "此协议尚未启用或当前版本无法安全连接。Telnet 需先确认明文风险；RDP 资产会保留并同步，不会被误作 SSH。"
}
