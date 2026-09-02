package com.orbitterm.android

import android.os.Bundle
import android.content.Intent
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.orbitterm.android.app.AuthViewModel
import com.orbitterm.android.app.BackgroundLockDisposition
import com.orbitterm.android.app.BiometricPromptFailure
import com.orbitterm.android.app.MasterPasswordViewModel
import com.orbitterm.android.app.SyncViewModel
import com.orbitterm.android.app.OrbitTermAppViewModel
import com.orbitterm.android.app.SessionForegroundServiceController
import com.orbitterm.android.app.backgroundLockDisposition
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.domain.settings.AppThemePreference
import com.orbitterm.android.domain.support.AdministratorContactRepository
import com.orbitterm.android.ui.MainScreen
import com.orbitterm.android.ui.LoginScreen
import com.orbitterm.android.ui.MasterPasswordScreen
import com.orbitterm.android.ui.LocalStorageCheckingScreen
import com.orbitterm.android.ui.LocalStorageRecoveryScreen
import com.orbitterm.android.ui.theme.OrbitTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

@AndroidEntryPoint
class MainActivity : FragmentActivity() {
    @Inject lateinit var applicationSync: com.orbitterm.android.app.ApplicationSyncCoordinator
    @Inject lateinit var deepLinks: com.orbitterm.android.app.DeepLinkCoordinator
    @Inject lateinit var externalActivityLockCoordinator: com.orbitterm.android.app.ExternalActivityLockCoordinator
    @Inject lateinit var administratorContactRepository: AdministratorContactRepository
    @Inject lateinit var terminalSessions: TerminalSessionController
    @Inject lateinit var foregroundSessions: SessionForegroundServiceController

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The app can render terminal output, private keys, and decrypted asset metadata.
        // Protect screenshots, screen recording, and task-switcher previews at the host level.
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        handleIncomingIntent(intent)
        setContent {
            val appViewModel: OrbitTermAppViewModel = viewModel()
            val authViewModel: AuthViewModel = viewModel()
            val masterViewModel: MasterPasswordViewModel = viewModel()
            val syncViewModel: SyncViewModel = viewModel()
            val recentlyDeletedViewModel: com.orbitterm.android.app.RecentlyDeletedViewModel = viewModel()
            val syncStatus = syncViewModel.status.collectAsStateWithLifecycle().value
            val authState = authViewModel.uiState.collectAsStateWithLifecycle().value
            val masterState = masterViewModel.uiState.collectAsStateWithLifecycle().value
            val pendingDeepLink = deepLinks.pending.collectAsStateWithLifecycle().value
            val uiState = appViewModel.uiState.collectAsStateWithLifecycle().value
            val recentlyDeletedState = recentlyDeletedViewModel.uiState.collectAsStateWithLifecycle().value
            val administratorEmail = administratorContactRepository.administratorEmail.collectAsStateWithLifecycle().value
            LaunchedEffect(administratorContactRepository) {
                administratorContactRepository.refresh()
            }
            val isDark = when (uiState.appThemePreference) {
                AppThemePreference.System -> isSystemInDarkTheme()
                AppThemePreference.Light -> false
                AppThemePreference.Dark -> true
            }
            val lifecycleOwner = LocalLifecycleOwner.current
            val coroutineScope = rememberCoroutineScope()
            var biometricPromptAction by androidx.compose.runtime.remember {
                mutableStateOf(BiometricPromptAction.Unlock)
            }
            var biometricPromptActive by androidx.compose.runtime.remember { mutableStateOf(false) }
            var hostResumed by androidx.compose.runtime.remember {
                mutableStateOf(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
            }
            val biometricPrompt = androidx.compose.runtime.remember(masterViewModel) {
                BiometricPrompt(
                    this@MainActivity,
                    ContextCompat.getMainExecutor(this@MainActivity),
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                            biometricPromptActive = false
                            val cipher = result.cryptoObject?.cipher
                            if (cipher == null) {
                                masterViewModel.reportBiometricPromptFailure(BiometricPromptFailure.FAILED)
                                return
                            }
                            when (biometricPromptAction) {
                                BiometricPromptAction.Unlock -> masterViewModel.completeBiometricUnlock(cipher)
                                BiometricPromptAction.Enroll -> masterViewModel.completeBiometricEnrollment(cipher)
                            }
                        }

                        override fun onAuthenticationError(errorCode: Int, errorMessage: CharSequence) {
                            biometricPromptActive = false
                            masterViewModel.reportBiometricPromptFailure(errorCode.toBiometricPromptFailure())
                        }
                    },
                )
            }
            val startBiometricUnlock = {
                if (!biometricPromptActive) {
                    val cipher = masterViewModel.biometricUnlockCipher()
                    if (cipher != null) {
                        biometricPromptActive = true
                        biometricPromptAction = BiometricPromptAction.Unlock
                        biometricPrompt.authenticate(
                            BiometricPrompt.PromptInfo.Builder()
                                .setTitle("解锁 OrbitTerm")
                                .setSubtitle("验证身份后解密本机资产")
                                .setNegativeButtonText("使用主密码")
                                .build(),
                            BiometricPrompt.CryptoObject(cipher),
                        )
                    }
                }
            }

            LaunchedEffect(
                authState.session?.username,
                masterState.isConfigured,
                masterState.isUnlocked,
                masterState.biometricEnabled,
                hostResumed,
            ) {
                if (
                    authState.session != null &&
                    masterState.isConfigured &&
                    !masterState.isUnlocked &&
                    masterState.biometricEnabled &&
                    hostResumed
                ) {
                    delay(500)
                    startBiometricUnlock()
                }
            }

            DisposableEffect(lifecycleOwner) {
                val observer = LifecycleEventObserver { _, event ->
                    when (event) {
                        Lifecycle.Event.ON_RESUME -> {
                            hostResumed = true
                            val documentInteractionExpired = externalActivityLockCoordinator.resumeHost(
                                DOCUMENT_INTERACTION_LOCK_GRACE_MILLIS,
                            )
                            foregroundSessions.appForegrounded()
                            if (documentInteractionExpired) masterViewModel.lock()
                        }
                        Lifecycle.Event.ON_STOP -> {
                            hostResumed = false
                            when (backgroundLockDisposition(
                                isChangingConfigurations = isChangingConfigurations,
                                isDocumentInteractionPending = externalActivityLockCoordinator.isDocumentInteractionPending(),
                            )) {
                                BackgroundLockDisposition.IGNORE_CONFIGURATION_CHANGE -> Unit
                                BackgroundLockDisposition.DEFER_FOR_DOCUMENT_INTERACTION -> {
                                    if (terminalSessions.activeSessions.value.isNotEmpty()) {
                                        foregroundSessions.appBackgrounded()
                                    }
                                    coroutineScope.launch {
                                        delay(DOCUMENT_INTERACTION_LOCK_GRACE_MILLIS)
                                        if (externalActivityLockCoordinator.isDocumentInteractionExpired(DOCUMENT_INTERACTION_LOCK_GRACE_MILLIS)) {
                                            masterViewModel.lock()
                                        }
                                    }
                                }
                                BackgroundLockDisposition.LOCK_NOW -> masterViewModel.lock()
                            }
                        }
                        else -> Unit
                    }
                }
                lifecycleOwner.lifecycle.addObserver(observer)
                onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
            }

            OrbitTheme(darkTheme = isDark, colorTheme = uiState.appColorTheme) {
                if (authState.isCheckingLocalStorage) LocalStorageCheckingScreen()
                else if (authState.localStorageRecovery != null) LocalStorageRecoveryScreen(
                    presentation = authState.localStorageRecovery,
                    onRetry = authViewModel::retryLocalStorage,
                )
                else if (authState.session == null) LoginScreen(
                    isLoading = authState.isLoading,
                    error = authState.error,
                    retryAfterSeconds = authState.retryAfterSeconds,
                    onLogin = authViewModel::login,
                    onRegister = authViewModel::register,
                )
                else if (!masterState.isUnlocked) MasterPasswordScreen(
                    configured = masterState.isConfigured,
                    biometricEnabled = masterState.biometricEnabled,
                    biometricAuthenticating = biometricPromptActive,
                    error = masterState.error ?: masterState.biometricFeedback?.message,
                    onSubmit = masterViewModel::submit,
                    onBiometricUnlock = startBiometricUnlock,
                )
                else MainScreen(
                    uiState,
                    appViewModel::selectDestination,
                    deepLink = pendingDeepLink,
                    onDeepLinkConsumed = deepLinks::consume,
                    appViewModel::setAppThemePreference,
                    appViewModel::setAppColorTheme,
                    appViewModel::setTerminalTheme,
                    appViewModel::setTerminalFontSize,
                    appViewModel::setMonitorRefreshInterval,
                    appViewModel::setTelnetEnabled,
                    accountName = authState.session.username,
                    administratorEmail = administratorEmail,
                    onLogout = {
                        recentlyDeletedViewModel.clear()
                        masterViewModel.lock()
                        authViewModel.logout()
                    },
                    onLock = masterViewModel::lock,
                    biometricEnabled = masterState.biometricEnabled,
                    biometricFeedback = masterState.biometricFeedback,
                    loginPasswordFeedback = authState.loginPasswordFeedback,
                    masterPasswordFeedback = masterState.rotationFeedback,
                    onToggleBiometric = {
                        if (masterState.biometricEnabled) {
                            masterViewModel.disableBiometricUnlock()
                        } else if (BiometricManager.from(this@MainActivity)
                                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
                        ) {
                            val cipher = masterViewModel.biometricEnrollmentCipher()
                            if (cipher != null && !biometricPromptActive) {
                                biometricPromptActive = true
                                biometricPromptAction = BiometricPromptAction.Enroll
                                biometricPrompt.authenticate(
                                    BiometricPrompt.PromptInfo.Builder()
                                        .setTitle("启用生物识别解锁")
                                        .setSubtitle("验证指纹或安全级别人脸后保护主密码")
                                        .setNegativeButtonText("取消")
                                        .build(),
                                    BiometricPrompt.CryptoObject(cipher),
                                )
                            }
                        } else {
                            masterViewModel.reportBiometricPromptFailure(BiometricPromptFailure.UNAVAILABLE)
                        }
                    },
                    isChangingLoginPassword = authState.isChangingPassword,
                    onChangeLoginPassword = authViewModel::changeLoginPassword,
                    isRotatingMasterPassword = masterState.isRotating,
                    hasPendingMasterPasswordCommit = masterState.hasPendingLocalCommit,
                    onFinishPendingMasterPasswordCommit = masterViewModel::finishPendingLocalCommit,
                    onRotateMasterPassword = { currentMaster, newMaster, confirmation, loginPassword ->
                        authState.session?.let { session ->
                            masterViewModel.rotateMasterPassword(
                                currentPassword = currentMaster,
                                newPassword = newMaster,
                                confirmation = confirmation,
                                currentLoginPassword = loginPassword,
                                accessToken = session.accessToken,
                                onSessionRotated = { response -> authViewModel.applyMasterKeyRotation(session, response) },
                            )
                        }
                    },
                    syncStatus = syncStatus,
                    onRetrySync = {
                        applicationSync.requestNow()
                    },
                    onRetryBlockedSync = applicationSync::retryBlockedOutbox,
                    onDiscardBlockedSync = applicationSync::discardBlockedOutbox,
                    onResolveConflict = { conflict, keepLocal ->
                    authState.session?.let { session ->
                        coroutineScope.launch {
                            val active = authViewModel.refreshSessionIfNeeded(session)
                            masterViewModel.readUnlockedMasterPassword()?.let { master ->
                                applicationSync.resolveConflict(conflict, keepLocal, active.accessToken, master)
                            }
                        }
                    }
                    },
                    recentlyDeletedState = recentlyDeletedState,
                    onLoadRecentlyDeleted = {
                        coroutineScope.launch {
                            val active = authViewModel.refreshSessionIfNeeded(authState.session)
                            masterViewModel.readUnlockedMasterPassword()?.let { master ->
                                recentlyDeletedViewModel.load(active, master)
                            }
                        }
                    },
                    onRestoreRecentlyDeleted = { assetId ->
                        coroutineScope.launch {
                            val active = authViewModel.refreshSessionIfNeeded(authState.session)
                            masterViewModel.readUnlockedMasterPassword()?.let { master ->
                                recentlyDeletedViewModel.restore(assetId, active, master)
                            }
                        }
                    },
                    onPurgeRecentlyDeleted = { assetId ->
                        coroutineScope.launch {
                            val active = authViewModel.refreshSessionIfNeeded(authState.session)
                            masterViewModel.readUnlockedMasterPassword()?.let { master ->
                                recentlyDeletedViewModel.purge(assetId, active, master)
                            }
                        }
                    },
                    onDismissRecentlyDeletedFeedback = recentlyDeletedViewModel::dismissFeedback,
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(source: Intent?) {
        deepLinks.handle(source?.data)
        // Do not leave a host/username-bearing external URL attached to the
        // Activity or recent-task base intent after it has been parsed into the
        // bounded in-memory review model.
        setIntent(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
    }

    private companion object {
        const val DOCUMENT_INTERACTION_LOCK_GRACE_MILLIS = 2 * 60 * 1_000L
    }
}

private enum class BiometricPromptAction { Unlock, Enroll }

private fun Int.toBiometricPromptFailure(): BiometricPromptFailure = when (this) {
    BiometricPrompt.ERROR_USER_CANCELED,
    BiometricPrompt.ERROR_NEGATIVE_BUTTON,
    BiometricPrompt.ERROR_CANCELED -> BiometricPromptFailure.CANCELLED
    BiometricPrompt.ERROR_LOCKOUT,
    BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> BiometricPromptFailure.LOCKED_OUT
    BiometricPrompt.ERROR_HW_NOT_PRESENT,
    BiometricPrompt.ERROR_HW_UNAVAILABLE,
    BiometricPrompt.ERROR_NO_BIOMETRICS,
    BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL -> BiometricPromptFailure.UNAVAILABLE
    else -> BiometricPromptFailure.FAILED
}
