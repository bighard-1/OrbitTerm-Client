package com.orbitterm.android.app

data class ActiveSessionNotificationText(
    val privateTitle: String,
    val privateDetail: String,
    val publicTitle: String,
    val publicDetail: String,
)

/** Contains no account, host, username, path, command, output or credential. */
internal fun activeSessionNotificationText(sessionCount: Int): ActiveSessionNotificationText {
    val safeCount = sessionCount.coerceAtLeast(1)
    return ActiveSessionNotificationText(
        privateTitle = "OrbitTerm 正在保持受保护会话",
        privateDetail = "$safeCount 个已验证会话正在运行",
        publicTitle = "OrbitTerm 后台任务正在运行",
        publicDetail = "返回应用查看详情",
    )
}
