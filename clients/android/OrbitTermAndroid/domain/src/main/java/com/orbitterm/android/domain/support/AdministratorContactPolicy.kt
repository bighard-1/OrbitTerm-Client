package com.orbitterm.android.domain.support

import java.util.Locale

/** A contact address, never an arbitrary mailto URL or URI query. */
object AdministratorContactPolicy {
    const val DEFAULT_EMAIL = "orbitterm@163.com"
    const val SUBJECT = "OrbitTerm 反馈"
    const val UNAVAILABLE_MESSAGE = "未找到可用的邮件应用，可复制邮箱后发送。"

    fun validatedEmail(raw: String): String? {
        if (raw.length > 254 || raw.any { it.code > 127 }) return null
        val parts = raw.split('@')
        if (parts.size != 2) return null
        val local = parts[0]
        val domain = parts[1].lowercase(Locale.ROOT)
        if (local.isEmpty() || local.length > 64 || !local.matches(Regex("[A-Za-z0-9._+\\-]+")) ||
            local.startsWith('.') || local.endsWith('.') || ".." in local) return null
        val labels = domain.split('.')
        if (labels.size < 2 || labels.any {
                it.isEmpty() || it.length > 63 || it.startsWith('-') || it.endsWith('-') ||
                    !it.matches(Regex("[a-z0-9-]+"))
            }) return null
        return "$local@$domain"
    }

    fun emailOrDefault(candidate: String?): String = candidate?.let(::validatedEmail) ?: DEFAULT_EMAIL
}
