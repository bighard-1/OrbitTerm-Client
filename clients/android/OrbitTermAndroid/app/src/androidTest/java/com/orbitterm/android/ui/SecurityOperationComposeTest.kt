package com.orbitterm.android.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.orbitterm.android.app.SecurityOperationFeedback
import com.orbitterm.android.app.SecurityOperationFeedbackKind
import com.orbitterm.android.app.SecurityOperationPresentation
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.theme.OrbitTheme
import org.junit.Rule
import org.junit.Test

class SecurityOperationComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun scopedFeedbackAndLogoutConfirmationAreAccessible() {
        val loginSuccess = SecurityOperationFeedback(
            SecurityOperationFeedbackKind.SUCCESS,
            SecurityOperationPresentation.LOGIN_PASSWORD_SUCCESS,
            1,
        )
        val masterFailure = SecurityOperationFeedback(
            SecurityOperationFeedbackKind.RECOVERY_REQUIRED,
            "云端主密码已轮换，但本机更新待完成；请勿退出应用并重试。",
            2,
        )
        compose.setContent {
            OrbitTheme(darkTheme = false, colorTheme = AppColorTheme.GlacierMint) {
                var showLogoutConfirmation by remember { mutableStateOf(false) }
                Column {
                    OrbitFeedbackBanner(loginSuccess.message, loginSuccess.isError)
                    OrbitFeedbackBanner(masterFailure.message, masterFailure.isError)
                    androidx.compose.material3.Button(onClick = { showLogoutConfirmation = true }) {
                        androidx.compose.material3.Text(SecurityOperationPresentation.LOGOUT_CONFIRM)
                    }
                }
                if (showLogoutConfirmation) {
                    OrbitConfirmationDialog(
                        title = SecurityOperationPresentation.LOGOUT_TITLE,
                        message = SecurityOperationPresentation.LOGOUT_MESSAGE,
                        confirmLabel = SecurityOperationPresentation.LOGOUT_CONFIRM,
                        onConfirm = {},
                        onDismiss = { showLogoutConfirmation = false },
                        destructive = true,
                    )
                }
            }
        }

        compose.onNodeWithText(SecurityOperationPresentation.LOGIN_PASSWORD_SUCCESS)
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        compose.onNodeWithText(masterFailure.message)
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        compose.onNodeWithText(SecurityOperationPresentation.LOGOUT_CONFIRM).assertHasClickAction().performClick()
        compose.onNodeWithText(SecurityOperationPresentation.LOGOUT_TITLE).assertIsDisplayed()
        compose.onNodeWithText("取消").assertHasClickAction()
    }
}
