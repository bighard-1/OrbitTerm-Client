package com.orbitterm.android.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.security.SecureCredentialStore
import com.orbitterm.android.sync.AuthResponse
import com.orbitterm.android.sync.MasterPasswordRotationRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

data class MasterPasswordUiState(
    val isConfigured: Boolean,
    val isUnlocked: Boolean = false,
    val biometricEnabled: Boolean = false,
    val isRotating: Boolean = false,
    val hasPendingLocalCommit: Boolean = false,
    val error: String? = null,
)

@HiltViewModel
class MasterPasswordViewModel @Inject constructor(
    private val secureStore: SecureCredentialStore,
    private val accountScopeController: AccountScopeController,
    private val terminalSessions: TerminalSessionController,
    private val rotationRepository: MasterPasswordRotationRepository,
    private val applicationSync: ApplicationSyncCoordinator,
) : ViewModel() {
    private var unlockedMasterPassword: String? = null
    private val mutableState = MutableStateFlow(MasterPasswordUiState(isConfigured = false))
    val uiState = mutableState.asStateFlow()
    init {
        viewModelScope.launch {
            accountScopeController.scope.collect { scope ->
                unlockedMasterPassword = null
                mutableState.value = MasterPasswordUiState(
                    isConfigured = scope?.let { secureStore.hasMasterPassword(it.storageId) } ?: false,
                    biometricEnabled = scope?.let { secureStore.isBiometricUnlockEnabled(it.storageId) } ?: false,
                    hasPendingLocalCommit = scope?.let {
                        secureStore.hasAcceptedStagedMasterPasswordRotation(it.storageId)
                    } ?: false,
                )
            }
        }
    }
    fun submit(password: String, confirmation: String) {
        val current = mutableState.value
        val scope = accountScopeController.scope.value ?: run {
            mutableState.value = current.copy(error = "当前账户未就绪，请重新登录。")
            return
        }
        if (!current.isConfigured && password != confirmation) { mutableState.value = current.copy(error = "两次输入不一致。"); return }
        if (password.isBlank()) return
        if (!current.isConfigured) {
            runCatching { secureStore.setupMasterPassword(scope.storageId, password) }
                .onSuccess {
                    unlockedMasterPassword = password
                    applicationSync.onUnlocked(scope)
                    mutableState.value = MasterPasswordUiState(true, true)
                }
                .onFailure { mutableState.value = current.copy(error = "无法设置主密码。") }
        } else {
            val master = secureStore.verifyAndReadMasterPassword(scope.storageId, password)
            mutableState.value = if (master != null) {
                unlockedMasterPassword = master
                applicationSync.onUnlocked(scope)
                current.copy(isUnlocked = true, error = null)
            } else current.copy(error = "主密码不正确。")
        }
    }
    fun readUnlockedMasterPassword(): String? = unlockedMasterPassword

    fun disableBiometricUnlock() = updateBiometric(enabled = false)

    fun biometricEnrollmentCipher(): javax.crypto.Cipher? {
        val scope = accountScopeController.scope.value ?: return null
        if (unlockedMasterPassword == null) {
            mutableState.value = mutableState.value.copy(error = "请先使用主密码解锁后再启用生物识别。")
            return null
        }
        return secureStore.biometricEnrollmentCipher(scope.storageId)
    }

    fun completeBiometricEnrollment(cipher: javax.crypto.Cipher) {
        val scope = accountScopeController.scope.value ?: return
        val master = unlockedMasterPassword ?: return
        runCatching { secureStore.completeBiometricEnrollment(scope.storageId, master, cipher) }
            .onSuccess { mutableState.value = mutableState.value.copy(biometricEnabled = true, error = null) }
            .onFailure {
                secureStore.invalidateBiometricUnlock(scope.storageId)
                mutableState.value = mutableState.value.copy(
                    biometricEnabled = false,
                    error = "生物识别启用失败，请重新验证指纹或安全级别人脸。",
                )
            }
    }

    fun biometricUnlockCipher(): javax.crypto.Cipher? {
        val scope = accountScopeController.scope.value ?: return null
        val cipher = secureStore.biometricUnlockCipher(scope.storageId)
        if (cipher == null && mutableState.value.biometricEnabled) {
            // Android invalidates biometric-bound Keystore keys when the
            // enrolled biometric set changes. This is expected OS behaviour,
            // but leaving the toggle enabled causes every later login to fail
            // with no recovery path. Fail closed and require one manual unlock
            // before the user explicitly re-enables biometrics.
            secureStore.invalidateBiometricUnlock(scope.storageId)
            mutableState.value = mutableState.value.copy(
                biometricEnabled = false,
                error = "生物识别密钥已失效，请使用主密码解锁后重新启用。",
            )
        }
        return cipher
    }

    fun completeBiometricUnlock(cipher: javax.crypto.Cipher) {
        val scope = accountScopeController.scope.value ?: return
        val master = secureStore.readMasterPasswordAfterBiometric(scope.storageId, cipher)
        if (master == null) {
            secureStore.invalidateBiometricUnlock(scope.storageId)
            mutableState.value = mutableState.value.copy(
                biometricEnabled = false,
                error = "生物识别密钥已失效，请使用主密码解锁后重新启用。",
            )
        } else {
            unlockedMasterPassword = master
            applicationSync.onUnlocked(scope)
            mutableState.value = mutableState.value.copy(isUnlocked = true, error = null)
        }
    }

    fun reportBiometricError(message: String) {
        mutableState.value = mutableState.value.copy(error = message)
    }

    /**
     * The remote endpoint receives a complete, atomically replaced ciphertext
     * snapshot. A staged local record remains until that endpoint succeeds.
     */
    fun rotateMasterPassword(
        currentPassword: String,
        newPassword: String,
        confirmation: String,
        currentLoginPassword: String,
        accessToken: String,
        onSessionRotated: (AuthResponse) -> Boolean,
    ) {
        val scope = accountScopeController.scope.value ?: return
        val current = mutableState.value
        if (current.isRotating) return
        when {
            current.hasPendingLocalCommit -> {
                mutableState.value = current.copy(error = "请先完成上一次主密码的本机更新。")
                return
            }
            newPassword.isBlank() || currentLoginPassword.isBlank() -> {
                mutableState.value = current.copy(error = "请完整填写当前登录密码和新主密码。")
                return
            }
            newPassword != confirmation -> {
                mutableState.value = current.copy(error = "两次输入的新主密码不一致。")
                return
            }
            newPassword == currentPassword -> {
                mutableState.value = current.copy(error = "新主密码不能与当前主密码相同。")
                return
            }
            secureStore.verifyAndReadMasterPassword(scope.storageId, currentPassword) == null -> {
                mutableState.value = current.copy(error = "当前主密码不正确。")
                return
            }
        }
        mutableState.value = current.copy(isRotating = true, error = null)
        viewModelScope.launch {
            val remoteAccepted = runCatching {
                withContext(Dispatchers.IO) {
                    secureStore.stageMasterPasswordRotation(scope.storageId, newPassword)
                    rotationRepository.rotate(
                        accessToken,
                        currentPassword,
                        newPassword,
                        currentLoginPassword,
                        scope
                    )
                }
            }
            remoteAccepted.onSuccess { response ->
                if (accountScopeController.scope.value != scope) return@onSuccess
                runCatching {
                    withContext(Dispatchers.IO) {
                        secureStore.markStagedMasterPasswordRotationAccepted(scope.storageId)
                    }
                    check(onSessionRotated(response)) { "无法安全保存新的登录会话。" }
                    withContext(Dispatchers.IO) {
                        secureStore.commitStagedMasterPasswordRotation(scope.storageId)
                    }
                }.onSuccess {
                    unlockedMasterPassword = newPassword
                    mutableState.value = mutableState.value.copy(
                        isRotating = false,
                        biometricEnabled = false,
                        hasPendingLocalCommit = false,
                        error = null,
                    )
                }.onFailure {
                    // The server already committed atomically. Keep the staged
                    // encrypted replacement for recovery rather than reverting.
                    unlockedMasterPassword = newPassword
                    mutableState.value = mutableState.value.copy(
                        isRotating = false,
                        hasPendingLocalCommit = secureStore.hasAcceptedStagedMasterPasswordRotation(scope.storageId),
                        error = "云端主密码已轮换，但本机更新待完成；请勿退出应用并重试。",
                    )
                }
            }.onFailure {
                if (accountScopeController.scope.value != scope) return@onFailure
                // A timeout after submission is indistinguishable from a server
                // commit whose response was lost. Keep the encrypted staged
                // record; a later retry can safely replace it, but discarding it
                // could make a committed cloud rotation unrecoverable.
                mutableState.value = mutableState.value.copy(
                    isRotating = false,
                    error = "主密码轮换未确认完成，请保持当前会话并重试。",
                )
            }
        }
    }

    /**
     * Finishes only a rotation that has a persisted remote-accepted marker.
     * An ambiguous timeout is intentionally not eligible for this path.
     */
    fun finishPendingLocalCommit() {
        val scope = accountScopeController.scope.value ?: return
        val current = mutableState.value
        if (current.isRotating || !current.hasPendingLocalCommit) return
        mutableState.value = current.copy(isRotating = true, error = null)
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val stagedPassword = secureStore.readAcceptedStagedMasterPassword(scope.storageId)
                        ?: error("accepted staged master password missing")
                    secureStore.commitStagedMasterPasswordRotation(scope.storageId)
                    stagedPassword
                }
            }.onSuccess { stagedPassword ->
                if (accountScopeController.scope.value != scope) return@onSuccess
                unlockedMasterPassword = stagedPassword
                applicationSync.onUnlocked(scope)
                mutableState.value = mutableState.value.copy(
                    isConfigured = true,
                    isUnlocked = true,
                    biometricEnabled = false,
                    isRotating = false,
                    hasPendingLocalCommit = false,
                    error = null,
                )
            }.onFailure {
                if (accountScopeController.scope.value != scope) return@onFailure
                mutableState.value = mutableState.value.copy(
                    isRotating = false,
                    hasPendingLocalCommit = secureStore.hasAcceptedStagedMasterPasswordRotation(scope.storageId),
                    error = "本机主密码更新仍未完成，请保持当前登录并再次重试。",
                )
            }
        }
    }

    private fun updateBiometric(enabled: Boolean) {
        val scope = accountScopeController.scope.value ?: return
        val master = unlockedMasterPassword ?: run {
            mutableState.value = mutableState.value.copy(error = "请先使用主密码解锁后再修改生物识别设置。")
            return
        }
        if (enabled) {
            mutableState.value = mutableState.value.copy(error = "请完成系统生物识别验证。")
            return
        }
        runCatching { secureStore.disableBiometricUnlock(scope.storageId, master) }.onSuccess {
            mutableState.value = mutableState.value.copy(biometricEnabled = enabled, error = null)
        }.onFailure {
            mutableState.value = mutableState.value.copy(error = "无法更新生物识别设置。")
        }
    }

    /** Clears the in-memory secret when the account session ends or the task is locked. */
    fun lock() {
        accountScopeController.scope.value?.let(applicationSync::onLockedOrLoggedOut)
        unlockedMasterPassword = null
        terminalSessions.closeAll()
        mutableState.value = mutableState.value.copy(isUnlocked = false, error = null)
    }
}
