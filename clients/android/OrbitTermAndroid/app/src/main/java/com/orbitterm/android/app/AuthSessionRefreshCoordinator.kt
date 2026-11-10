package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AuthSession
import com.orbitterm.android.security.SecureCredentialStore
import com.orbitterm.android.sync.AuthResponse
import com.orbitterm.android.sync.OrbitApi
import com.orbitterm.android.sync.OrbitServiceFailure
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

/** One refresh lane shared by foreground requests and WorkManager in this process. */
@Singleton
class AuthSessionRefreshCoordinator @Inject constructor(
    secureStore: SecureCredentialStore,
    api: OrbitApi,
) {
    private val gate = RefreshSessionGate(
        read = secureStore::readAuthSessionChecked,
        replace = secureStore::replaceAuthSessionIfCurrent,
        refresh = api::refresh,
    )

    suspend fun refreshIfNeeded(expected: AuthSession): AuthSession? = gate.refreshIfNeeded(expected)
}

internal class RefreshSessionGate(
    private val read: () -> AuthSession?,
    private val replace: (AuthSession, AuthSession) -> Boolean,
    private val refresh: suspend (String) -> AuthResponse,
) {
    private val mutex = Mutex()

    suspend fun refreshIfNeeded(expected: AuthSession): AuthSession? = mutex.withLock {
        val current = read() ?: return@withLock null
        if (current.username != expected.username) return@withLock null
        // A different login, password change or earlier refresh won. Use the
        // durable winner; never submit the spent token from the caller.
        if (current != expected || !current.accessToken.isExpiringSoon()) return@withLock current
        val refreshToken = current.refreshToken
            ?: throw OrbitServiceFailure(syncError(OrbitErrorCode.AuthenticationExpired))
        val response = refresh(refreshToken)
        val nextAccess = response.accessTokenValue.takeIf(String::isNotBlank)
            ?: throw OrbitServiceFailure(syncError(OrbitErrorCode.RemoteProtocolViolation))
        val nextRefresh = response.refresh_token?.takeIf(String::isNotBlank)
            ?: throw OrbitServiceFailure(syncError(OrbitErrorCode.RemoteProtocolViolation))
        val updated = current.copy(
            accessToken = nextAccess,
            refreshToken = nextRefresh,
            mustChangePassword = response.must_change_password,
        )
        if (replace(current, updated)) updated else read()
    }
}

internal fun String.isExpiringSoon(nowUnixSeconds: Long = System.currentTimeMillis() / 1_000): Boolean = runCatching {
    val payload = split('.')[1]
    val decoded = String(Base64.getUrlDecoder().decode(payload), Charsets.UTF_8)
    Json.parseToJsonElement(decoded).jsonObject["exp"]?.toString()?.toLongOrNull()
        ?.let { it <= nowUnixSeconds + 60 }
        ?: false
}.getOrDefault(false)
