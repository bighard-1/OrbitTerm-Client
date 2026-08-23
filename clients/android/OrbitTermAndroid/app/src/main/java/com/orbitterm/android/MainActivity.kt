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
import com.orbitterm.android.app.MasterPasswordViewModel
import com.orbitterm.android.app.SyncViewModel
import com.orbitterm.android.app.OrbitTermAppViewModel
import com.orbitterm.android.app.SessionForegroundServiceController
import com.orbitterm.android.feature.terminal.TerminalSessionController
import com.orbitterm.android.domain.settings.AppThemePreference
import com.orbitterm.android.domain.support.AdministratorContactRepository
import com.orbitterm.android.ui.MainScreen
import com.orbitterm.android.ui.LoginScreen
import com.orbitterm.android.ui.MasterPasswordScreen
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
        deepLinks.handle(intent?.data)
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
            val biometricPrompt = androidx.compose.runtime.remember(masterViewModel) {
                BiometricPrompt(
                    this@MainActivity,
                    ContextCompat.getMainExecutor(this@MainActivity),
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                            val cipher = result.cryptoObject?.cipher
                            if (cipher == null) {
                                masterViewModel.reportBiometricError("生物识别结果无效，请使用主密码解锁。")
                                return
                            }
                            when (biometricPromptAction) {
                                BiometricPromptAction.Unlock -> masterViewModel.completeBiometricUnlock(cipher)
                                BiometricPromptAction.Enroll -> masterViewModel.completeBiometricEnrollment(cipher)
                            }
                        }

                        override fun onAuthenticationError(errorCode: Int, errorMessage: CharSequence) {
                            if (errorCode != BiometricPrompt.ERROR_USER_CANCELED && errorCode != BiometricPrompt.ERROR_NEGATIVE_BUTTON) {
                                masterViewModel.reportBiometricError(errorMessage.toString())
                            }
                        }
                    },
                )
            }
            val startBiometricUnlock = {
                val cipher = masterViewModel.biometricUnlockCipher()
                if (cipher == null) {
                    masterViewModel.reportBiometricError("生物识别密钥不可用，请使用主密码解锁后重新启用。")
                } else {
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

            DisposableEffect(lifecycleOwner) {
                val observer = LifecycleEventObserver { _, event ->
                    when (event) {
                        Lifecycle.Event.ON_RESUME -> {
                            externalActivityLockCoordinator.resumeHost()
                            foregroundSessions.appForegrounded()
                        }
                        Lifecycle.Event.ON_STOP -> if (!isChangingConfigurations) {
                            if (terminalSessions.activeSessions.value.isNotEmpty()) {
                                // A visible foreground notification keeps the already-verified
                                // native channels alive. Explicit lock/logout still closes them.
                                foregroundSessions.appBackgrounded()
                            } else if (externalActivityLockCoordinator.isDocumentInteractionPending()) {
                                coroutineScope.launch {
                                    delay(DOCUMENT_INTERACTION_LOCK_GRACE_MILLIS)
                                    if (externalActivityLockCoordinator.isDocumentInteractionExpired(DOCUMENT_INTERACTION_LOCK_GRACE_MILLIS)) {
                                        masterViewModel.lock()
                                    }
                                }
                            } else {
                                masterViewModel.lock()
                            }
                        }
                        else -> Unit
                    }
                }
                lifecycleOwner.lifecycle.addObserver(observer)
                onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
            }

            OrbitTheme(darkTheme = isDark, colorTheme = uiState.appColorTheme) {
                if (authState.session == null) LoginScreen(
                    isLoading = authState.isLoading,
                    error = authState.error,
                    onLogin = authViewModel::login,
                    onRegister = authViewModel::register,
                )
                else if (!masterState.isUnlocked) MasterPasswordScreen(
                    configured = masterState.isConfigured,
                    biometricEnabled = masterState.biometricEnabled,
                    error = masterState.error,
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
                    securityError = masterState.error ?: authState.securityError,
                    onToggleBiometric = {
                        if (masterState.biometricEnabled) {
                            masterViewModel.disableBiometricUnlock()
                        } else if (BiometricManager.from(this@MainActivity)
                                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
                        ) {
                            val cipher = masterViewModel.biometricEnrollmentCipher()
                            if (cipher == null) {
                                masterViewModel.reportBiometricError("无法准备生物识别，请先确认已录入指纹或安全级别人脸。")
                            } else {
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
                            masterViewModel.reportBiometricError("此设备未配置可用的强生物识别方式。")
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
        setIntent(intent)
        deepLinks.handle(intent.data)
    }

    private companion object {
        const val DOCUMENT_INTERACTION_LOCK_GRACE_MILLIS = 2 * 60 * 1_000L
    }
}

private enum class BiometricPromptAction { Unlock, Enroll }
