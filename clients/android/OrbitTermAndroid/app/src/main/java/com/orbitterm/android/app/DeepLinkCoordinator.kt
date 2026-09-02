package com.orbitterm.android.app

import android.net.Uri
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.orbitterm.android.domain.deeplink.ServerDeepLink

/** Holds one validated in-process deep link until the account is unlocked. */
@Singleton
class DeepLinkCoordinator @Inject constructor() {
    private val mutablePending = MutableStateFlow<ServerDeepLink?>(null)
    val pending = mutablePending.asStateFlow()

    fun handle(uri: Uri?): Boolean {
        val parsed = uri?.let { ServerDeepLinkParser.parse(it.toString()) } ?: return false
        mutablePending.value = parsed
        return true
    }

    fun consume() { mutablePending.value = null }
}

object ServerDeepLinkParser {
    fun parse(raw: String): ServerDeepLink? = runCatching { URI(raw) }.getOrNull()?.let { uri ->
        when (uri.scheme?.lowercase()) {
            "ssh" -> parseSsh(uri)
            "orbitterm" -> parseOrbitTerm(uri)
            else -> null
        }
    }

    private fun parseSsh(uri: URI): ServerDeepLink? {
        val host = safeCompactField(uri.host, MAX_HOST_LENGTH) ?: return null
        if (uri.userInfo?.contains(':') == true) return null
        val username = uri.userInfo?.let { safeCompactField(it, MAX_USERNAME_LENGTH) }
            ?: if (uri.userInfo == null) "root" else return null
        val port = uri.port.takeIf { it != -1 } ?: 22
        return build(host, port, username, null)
    }

    private fun parseOrbitTerm(uri: URI): ServerDeepLink? {
        val route = (uri.host ?: uri.path?.trim('/') ?: "").lowercase()
        if (route.isNotEmpty() && route != "connect") return null
        val query = uri.rawQuery.queryParameters()
        if (query.keys.any(CREDENTIAL_QUERY_KEYS::contains)) return null
        val host = safeCompactField(query["host"] ?: uri.host, MAX_HOST_LENGTH) ?: return null
        val rawUsername = query["username"] ?: query["user"]
        val username = rawUsername?.let { safeCompactField(it, MAX_USERNAME_LENGTH) }
            ?: if (rawUsername == null) "root" else return null
        val rawPort = query["port"]
        val port = if (rawPort == null) 22 else rawPort.toIntOrNull() ?: return null
        val rawName = query["name"]
        val name = if (rawName == null) null else safeDisplayName(rawName, MAX_NAME_LENGTH) ?: return null
        return build(host, port, username, name)
    }

    private fun build(host: String, port: Int, username: String, name: String?): ServerDeepLink? {
        if (port !in 1..65_535) return null
        return ServerDeepLink(host, port, username, name?.takeIf(String::isNotBlank) ?: "$host:$port")
    }

    private fun safeCompactField(value: String?, maxLength: Int): String? {
        val normalized = safeDisplayName(value, maxLength) ?: return null
        return normalized.takeIf { it.isNotEmpty() && it.none(Char::isWhitespace) }
    }

    private fun safeDisplayName(value: String?, maxLength: Int): String? {
        val normalized = value?.trim() ?: return null
        return normalized.takeIf { it.length <= maxLength && it.none(Char::isISOControl) }
    }

    private fun String?.queryParameters(): Map<String, String> {
        if (isNullOrBlank()) return emptyMap()
        return buildMap {
            split('&').forEach { part ->
            val delimiter = part.indexOf('=')
            val rawName = if (delimiter < 0) part else part.substring(0, delimiter)
            val rawValue = if (delimiter < 0) "" else part.substring(delimiter + 1)
            runCatching {
                URLDecoder.decode(rawName, StandardCharsets.UTF_8.name()).lowercase() to
                    URLDecoder.decode(rawValue, StandardCharsets.UTF_8.name())
            }.getOrNull()?.let { (name, value) -> putIfAbsent(name, value) }
            }
        }
    }

    private const val MAX_HOST_LENGTH = 253
    private const val MAX_USERNAME_LENGTH = 128
    private const val MAX_NAME_LENGTH = 80
    private val CREDENTIAL_QUERY_KEYS = setOf(
        "password",
        "passphrase",
        "privatekey",
        "private_key",
        "token",
        "accesstoken",
        "access_token",
    )
}
