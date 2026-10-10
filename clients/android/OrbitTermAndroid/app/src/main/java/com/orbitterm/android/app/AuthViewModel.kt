package com.orbitterm.android.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.domain.auth.AuthSession
import com.orbitterm.android.data.local.OrbitTermDatabase
import com.orbitterm.android.security.SecureCredentialStore
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.sync.OrbitApi
import com.orbitterm.android.sync.AuthResponse
import com.orbitterm.android.sync.OrbitServiceFailure
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import javax.inject.Inject

data class AuthUiState(
    val session: AuthSession? = null,
    val isCheckingLocalStorage: Boolean = false,
    val localStorageRecovery: LocalStorageRecoveryPresentation? = null,
    val isLoading: Boolean = false,
    val error: String? = null,
    val isChangingPassword: Boolean = false,
    val loginPasswordFeedback: SecurityOperationFeedback? = null,
    val retryAfterSeconds: Int = 0,
)

@HiltViewModel
class AuthViewModel @Inject constructor(
    private val api: OrbitApi,
    private val secureStore: SecureCredentialStore,
    private val accountScopeController: AccountScopeController,
    private val terminalSessions: TerminalSessionController,
    private val applicationSync: ApplicationSyncCoordinator,
    private val database: OrbitTermDatabase,
    private val refreshCoordinator: AuthSessionRefreshCoordinator,
) : ViewModel() {
    private val mutableState = MutableStateFlow(AuthUiState(isCheckingLocalStorage = true))
    /** Invalidates login callbacks started before logout. */
    private var loginGeneration = 0L
    private var passwordChangeGeneration = 0L
    private var securityFeedbackRevision = 0L
    private var securityFeedbackJob: Job? = null
    private var cooldownJob: Job? = null
    private var storageCheckGeneration = 0L
    val uiState = mutableState.asStateFlow()

    init { retryLocalStorage() }

    fun retryLocalStorage() {
        val generation = ++storageCheckGeneration
        mutableState.value = mutableState.value.copy(
            isCheckingLocalStorage = true,
            localStorageRecovery = null,
            error = null,
        )
        viewModelScope.launch {
            checkLocalStorage(database, secureStore)
                .onSuccess { session ->
                    if (generation != storageCheckGeneration) return@onSuccess
                    session?.let { accountScopeController.activate(it.username) }
                    mutableState.value = AuthUiState(session = session)
                }
                .onFailure { error ->
                    if (generation != storageCheckGeneration) return@onFailure
                    val kind = LocalStorageRecoveryPolicy.classify(error)
                    mutableState.value = AuthUiState(
                        isCheckingLocalStorage = false,
                        localStorageRecovery = LocalStorageRecoveryPolicy.presentation(kind),
                    )
                }
        }
    }

    fun login(username: String, password: String) {
        if (mutableState.value.isLoading) return
        loginValidationError(username, password)?.let { message ->
            mutableState.value = mutableState.value.copy(error = message)
            return
        }
        val canonicalUsername = username.trim().lowercase()
        val retryAfter = secureStore.loginRetryAfterSeconds(canonicalUsername)
        if (retryAfter > 0) {
            mutableState.value = mutableState.value.copy(
                error = "登录尝试过于频繁，请在 $retryAfter 秒后重试。",
                retryAfterSeconds = retryAfter,
            )
            startCooldown(canonicalUsername)
            return
        }
        val generationAtRequestStart = ++loginGeneration
        mutableState.value = mutableState.value.copy(isLoading = true, error = null)
        viewModelScope.launch {
            runCatching {
                val response = withContext(Dispatchers.IO) { api.login(username.trim(), password) }
                sessionFromLoginResponse(canonicalUsername, response)
            }.onSuccess { session ->
                if (generationAtRequestStart != loginGeneration) return@onSuccess
                runCatching { secureStore.saveAuthSession(session) }
                    .onSuccess {
                        secureStore.clearLoginFailures(canonicalUsername)
                        cooldownJob?.cancel()
                        accountScopeController.activate(session.username)
                        mutableState.value = AuthUiState(session = session)
                    }
                    .onFailure { publishSecureStorageRecovery() }
            }.onFailure { error ->
                if (generationAtRequestStart != loginGeneration) return@onFailure
                val isCredentialFailure = (error as? OrbitServiceFailure)?.error?.code == OrbitErrorCode.AuthenticationFailed
                val delay = if (isCredentialFailure) secureStore.recordLoginFailure(canonicalUsername) else 0
                mutableState.value = AuthUiState(
                    error = if (delay > 0) "登录尝试过于频繁，请在 $delay 秒后重试。" else error.authFailureMessage("登录"),
                    retryAfterSeconds = delay,
                )
                if (delay > 0) startCooldown(canonicalUsername)
            }
        }
    }

    private fun startCooldown(username: String) {
        cooldownJob?.cancel()
        cooldownJob = viewModelScope.launch {
            while (true) {
                val remaining = secureStore.loginRetryAfterSeconds(username)
                mutableState.value = mutableState.value.copy(retryAfterSeconds = remaining)
                if (remaining <= 0) return@launch
                delay(1_000)
            }
        }
    }

    /** Registration follows the server's invite policy, then creates the same local session as login. */
    fun register(username: String, password: String, inviteCode: String) {
        val canonicalUsername = username.trim().lowercase()
        if (mutableState.value.isLoading) return
        val validationError = registrationValidationError(canonicalUsername, password, inviteCode)
        if (validationError != null) {
            mutableState.value = mutableState.value.copy(error = validationError)
            return
        }
        val generationAtRequestStart = ++loginGeneration
        mutableState.value = mutableState.value.copy(isLoading = true, error = null)
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) { api.register(canonicalUsername, password, inviteCode.trim()) }
                val response = withContext(Dispatchers.IO) { api.login(canonicalUsername, password) }
                sessionFromLoginResponse(canonicalUsername, response)
            }.onSuccess { session ->
                if (generationAtRequestStart != loginGeneration) return@onSuccess
                runCatching { secureStore.saveAuthSession(session) }
                    .onSuccess { accountScopeController.activate(session.username); mutableState.value = AuthUiState(session = session) }
                    .onFailure { publishSecureStorageRecovery() }
            }.onFailure { error ->
                if (generationAtRequestStart != loginGeneration) return@onFailure
                mutableState.value = AuthUiState(error = error.authFailureMessage("注册"))
            }
        }
    }

    fun logout() {
        loginGeneration += 1
        passwordChangeGeneration += 1
        securityFeedbackJob?.cancel()
        accountScopeController.scope.value?.let(applicationSync::onLockedOrLoggedOut)
        terminalSessions.closeAll()
        val activeSession = mutableState.value.session
        if (runCatching { secureStore.deleteAuthSession() }.isFailure) {
            publishSecureStorageRecovery(session = activeSession)
            return
        }
        accountScopeController.deactivate()
        mutableState.value = AuthUiState()
        if (activeSession != null) {
            val generation = loginGeneration
            viewModelScope.launch {
                runCatching { withContext(Dispatchers.IO) { api.logoutCurrent(activeSession.accessToken) } }
                    .onFailure {
                        if (generation == loginGeneration && mutableState.value.session == null) {
                            mutableState.value = mutableState.value.copy(
                                error = "已退出本机；服务端会话撤销未确认。联网后请重新登录并检查账户安全。",
                            )
                        }
                    }
            }
        }
    }

    /** Handles a server-side gate even when this session predates the login response flag. */
    fun requirePasswordChange() {
        val active = mutableState.value.session ?: return
        if (active.mustChangePassword) return
        runCatching {
            val current = secureStore.readAuthSessionChecked() ?: return
            if (current.username != active.username) return
            val updated = current.copy(mustChangePassword = true)
            if (secureStore.replaceAuthSessionIfCurrent(current, updated)) {
                mutableState.value = mutableState.value.copy(session = updated)
            }
        }.onFailure { publishSecureStorageRecovery(session = active) }
    }

    /** Capture before starting a remote security operation, not when its response arrives. */
    fun sessionGenerationSnapshot(): Long = loginGeneration

    /** Stores tokens returned by the atomic master-key rotation endpoint. */
    fun applyMasterKeyRotation(session: AuthSession, response: AuthResponse, expectedGeneration: Long): Boolean {
        // A background refresh may legitimately replace the access token while
        // the same account's rotation is in flight. Account-scope and rotation
        // generation fences reject logout/account-switch callbacks; requiring
        // the old token here would strand a valid rotation after token refresh.
        if (expectedGeneration != loginGeneration || !isCurrentAccount(session.username)) return false
        val nextAccess = response.accessTokenValue.takeIf(String::isNotBlank) ?: return false
        val nextRefresh = response.refresh_token?.takeIf(String::isNotBlank) ?: return false
        return runCatching {
            val current = secureStore.readAuthSessionChecked() ?: return false
            if (current.username != session.username || expectedGeneration != loginGeneration) return false
            val updated = current.copy(accessToken = nextAccess, refreshToken = nextRefresh)
            if (!secureStore.replaceAuthSessionIfCurrent(current, updated)) return false
            mutableState.value = mutableState.value.copy(session = updated, error = null)
        }.fold(
            onSuccess = { true },
            onFailure = {
                publishSecureStorageRecovery(session = session)
                false
            },
        )
    }

    fun changeLoginPassword(currentPassword: String, newPassword: String, confirmation: String) {
        val session = mutableState.value.session ?: return
        val current = mutableState.value
        if (current.isChangingPassword) return
        when {
            currentPassword.isBlank() || newPassword.isBlank() -> {
                publishLoginPasswordFeedback(SecurityOperationFeedbackKind.FAILURE, "请完整填写登录密码。")
                return
            }
            newPassword != confirmation -> {
                publishLoginPasswordFeedback(SecurityOperationFeedbackKind.FAILURE, "两次输入的新登录密码不一致。")
                return
            }
            currentPassword == newPassword -> {
                publishLoginPasswordFeedback(SecurityOperationFeedbackKind.FAILURE, "新登录密码不能与当前密码相同。")
                return
            }
        }
        val generationAtRequestStart = ++passwordChangeGeneration
        securityFeedbackJob?.cancel()
        mutableState.value = current.copy(isChangingPassword = true, loginPasswordFeedback = null)
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) { api.changePassword(session.accessToken, currentPassword, newPassword) }
            }.onSuccess { response ->
                if (generationAtRequestStart != passwordChangeGeneration || !isCurrentAccount(session.username)) return@onSuccess
                val nextAccess = response.accessTokenValue.takeIf(String::isNotBlank)
                val nextRefresh = response.refresh_token?.takeIf(String::isNotBlank)
                if (nextAccess == null || nextRefresh == null) {
                    mutableState.value = mutableState.value.copy(
                        isChangingPassword = false,
                        loginPasswordFeedback = nextSecurityFeedback(
                            SecurityOperationFeedbackKind.RECOVERY_REQUIRED,
                            "服务未返回有效会话，请重新登录。",
                        ),
                    )
                    return@onSuccess
                }
                val updated = AuthSession(
                    username = session.username,
                    accessToken = nextAccess,
                    refreshToken = nextRefresh,
                    mustChangePassword = false,
                )
                runCatching { secureStore.saveAuthSession(updated) }
                    .onSuccess {
                        mutableState.value = mutableState.value.copy(session = updated, isChangingPassword = false)
                        publishLoginPasswordFeedback(
                            SecurityOperationFeedbackKind.SUCCESS,
                            SecurityOperationPresentation.LOGIN_PASSWORD_SUCCESS,
                        )
                    }
                    .onFailure {
                        publishSecureStorageRecovery(session = updated)
                    }
            }.onFailure { error ->
                if (generationAtRequestStart != passwordChangeGeneration || !isCurrentAccount(session.username)) return@onFailure
                mutableState.value = mutableState.value.copy(
                    isChangingPassword = false,
                    loginPasswordFeedback = nextSecurityFeedback(
                        SecurityOperationFeedbackKind.FAILURE,
                        error.authFailureMessage("更新登录密码"),
                    ),
                )
            }
        }
    }

    private fun nextSecurityFeedback(
        kind: SecurityOperationFeedbackKind,
        message: String,
    ): SecurityOperationFeedback = SecurityOperationFeedback(kind, message, ++securityFeedbackRevision)

    private fun publishLoginPasswordFeedback(kind: SecurityOperationFeedbackKind, message: String) {
        securityFeedbackJob?.cancel()
        val feedback = nextSecurityFeedback(kind, message)
        mutableState.value = mutableState.value.copy(loginPasswordFeedback = feedback)
        val lifetime = feedback.autoDismissAfterMillis ?: return
        securityFeedbackJob = viewModelScope.launch {
            delay(lifetime)
            if (mutableState.value.loginPasswordFeedback?.revision == feedback.revision) {
                mutableState.value = mutableState.value.copy(loginPasswordFeedback = null)
            }
        }
    }

    /** Refreshes only a token that expires within one minute; refresh failures keep the current session usable. */
    suspend fun refreshSessionIfNeeded(session: AuthSession): AuthSession {
        val result = runCatching {
            withContext(Dispatchers.IO) { refreshCoordinator.refreshIfNeeded(session) }
        }
        result.exceptionOrNull()?.let { failure ->
            if (failure !is OrbitServiceFailure) publishSecureStorageRecovery(session = session)
            return session
        }
        val refreshed = result.getOrNull() ?: return session
        if (!isCurrentSession(session)) return session
        mutableState.value = mutableState.value.copy(session = refreshed)
        return refreshed
    }

    private fun isCurrentSession(expected: AuthSession): Boolean {
        val current = mutableState.value.session ?: return false
        return current.username == expected.username && current.accessToken == expected.accessToken
    }

    private fun isCurrentAccount(expectedUsername: String): Boolean =
        securityOperationBelongsToCurrentAccount(mutableState.value.session, expectedUsername)

    private fun publishSecureStorageRecovery(session: AuthSession? = null) {
        mutableState.value = AuthUiState(
            session = session,
            localStorageRecovery = LocalStorageRecoveryPolicy.presentation(
                LocalStorageFailureKind.SECURE_STORAGE_UNAVAILABLE,
            ),
        )
    }
}

internal fun sessionFromLoginResponse(username: String, response: AuthResponse): AuthSession {
    val access = response.accessTokenValue.takeIf(String::isNotBlank)
    val refresh = response.refresh_token?.takeIf(String::isNotBlank)
    if (access == null || refresh == null) {
        throw OrbitServiceFailure(syncError(OrbitErrorCode.RemoteProtocolViolation))
    }
    return AuthSession(username, access, refresh, response.must_change_password)
}

private fun Throwable.authFailureMessage(action: String): String {
    val error = (this as? OrbitServiceFailure)?.error ?: syncError(OrbitErrorCode.Unknown)
    if (action == "登录" && error.code == OrbitErrorCode.AuthenticationFailed) {
        return "邮箱账号或登录密码不正确，请检查后重试。"
    }
    return "${action}失败：${error.userMessage()} 诊断代码：${error.diagnosticCode}。"
}

internal fun registrationValidationError(username: String, password: String, inviteCode: String): String? = when {
    !username.matches(Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")) -> "请输入有效的邮箱账号。"
    password.length < 12 ||
        password.none(Char::isUpperCase) ||
        password.none(Char::isLowerCase) ||
        password.none(Char::isDigit) ||
        password.none { !it.isLetterOrDigit() && !it.isWhitespace() } ->
        "密码至少 12 位，并包含大小写字母、数字和特殊字符。"
    inviteCode.isBlank() -> "请输入管理员提供的邀请码。"
    else -> null
}

internal fun loginValidationError(username: String, password: String): String? = when {
    username.isBlank() -> "请输入邮箱账号。"
    !username.trim().matches(Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")) ->
        "请输入有效的邮箱账号，例如 name@example.com。"
    password.isEmpty() -> "请输入登录密码。"
    else -> null
}
