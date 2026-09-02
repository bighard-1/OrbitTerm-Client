package com.orbitterm.android.domain.sync

import com.orbitterm.android.domain.error.OrbitError
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/** Stable HTTP-to-sync contract shared with Apple. Response bodies are never inspected. */
object SyncHttpResponsePolicy {
    const val MAX_RETRY_AFTER_SECONDS = 3_600L

    fun error(
        statusCode: Int,
        retryAfterHeader: String?,
        now: Instant = Instant.now(),
        authenticationErrorCode: OrbitErrorCode = OrbitErrorCode.AuthenticationExpired,
    ): OrbitError {
        require(authenticationErrorCode in setOf(
            OrbitErrorCode.AuthenticationFailed,
            OrbitErrorCode.AuthenticationExpired,
            OrbitErrorCode.RemoteRequestRejected,
        ))
        val retryAfter = parseRetryAfter(retryAfterHeader, now)
        return when {
            statusCode == 401 -> syncError(authenticationErrorCode)
            statusCode == 408 -> syncError(OrbitErrorCode.NetworkTimeout, retryAfter)
            statusCode == 425 || statusCode == 429 -> syncError(OrbitErrorCode.RemoteRateLimited, retryAfter)
            statusCode in 500..599 -> syncError(OrbitErrorCode.RemoteServiceUnavailable, retryAfter)
            statusCode in 400..499 -> syncError(OrbitErrorCode.RemoteRequestRejected)
            else -> syncError(OrbitErrorCode.Unknown)
        }
    }

    fun parseRetryAfter(rawValue: String?, now: Instant = Instant.now()): Long? {
        val value = rawValue?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val seconds = value.toLongOrNull() ?: runCatching {
            ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().epochSecond - now.epochSecond
        }.getOrNull() ?: return null
        if (seconds <= 0) return null
        return seconds.coerceAtMost(MAX_RETRY_AFTER_SECONDS)
    }
}
