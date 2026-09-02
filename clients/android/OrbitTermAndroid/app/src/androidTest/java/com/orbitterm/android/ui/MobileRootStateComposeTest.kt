package com.orbitterm.android.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.ui.theme.OrbitTheme
import org.junit.Rule
import org.junit.Test

/** Mirrors the iOS root-state UI checks without touching credentials or network state. */
class MobileRootStateComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun authenticationRootKeepsBrandHeadingFieldsAndRecoveryFeedbackAccessible() {
        compose.setContent {
            OrbitTheme(darkTheme = false, colorTheme = AppColorTheme.GlacierMint) {
                LoginScreen(
                    isLoading = false,
                    error = "登录失败，请检查账号、密码和网络。",
                    retryAfterSeconds = 0,
                    onLogin = { _, _ -> },
                    onRegister = { _, _, _ -> },
                )
            }
        }

        compose.onNodeWithText("OrbitTerm")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        compose.onNodeWithText("邮箱账号").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("密码").performScrollTo().assertIsDisplayed()
        compose.onAllNodesWithText("登录").assertCountEquals(2)
        compose.onNodeWithText("登录失败，请检查账号、密码和网络。")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        compose.onNodeWithText("已阅读并同意").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("查看法律条款").performScrollTo().assertIsDisplayed().assertHasClickAction()

        compose.onNodeWithText("注册").performScrollTo().performClick()
        compose.onNodeWithText("查看法律条款").performScrollTo().assertIsDisplayed().assertHasClickAction()
    }

    @Test
    fun lockedRootKeepsMasterPasswordActionsAndSecurityFeedbackAccessible() {
        compose.setContent {
            OrbitTheme(darkTheme = true, colorTheme = AppColorTheme.GlacierMint) {
                MasterPasswordScreen(
                    configured = true,
                    biometricEnabled = true,
                    error = "主密码不正确。",
                    onSubmit = { _, _ -> },
                    onBiometricUnlock = {},
                )
            }
        }

        compose.onNodeWithText("验证主密码")
            .performScrollTo()
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        compose.onNodeWithText("输入主密码").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("验证并解锁").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("使用生物识别解锁").performScrollTo().assertIsDisplayed().assertHasClickAction()
        compose.onNodeWithText("主密码不正确。")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
    }

    @Test
    fun biometricPromptBusyStatePreventsDuplicateSubmission() {
        compose.setContent {
            OrbitTheme(darkTheme = false, colorTheme = AppColorTheme.GlacierMint) {
                MasterPasswordScreen(
                    configured = true,
                    biometricEnabled = true,
                    biometricAuthenticating = true,
                    error = null,
                    onSubmit = { _, _ -> },
                    onBiometricUnlock = {},
                )
            }
        }

        compose.onNodeWithText("正在验证…")
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsNotEnabled()
    }
}
