package com.orbitterm.android.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.orbitterm.android.app.LocalStorageFailureKind
import com.orbitterm.android.app.LocalStorageRecoveryPresentation
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.ui.theme.OrbitTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class LocalStorageRecoveryComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun recoveryStateExplainsPreservationAndExposesOneRetryAction() {
        var retried = false
        compose.setContent {
            OrbitTheme(darkTheme = false, colorTheme = AppColorTheme.GlacierMint) {
                LocalStorageRecoveryScreen(
                    presentation = LocalStorageRecoveryPresentation(
                        LocalStorageFailureKind.SECURE_STORAGE_UNAVAILABLE,
                        "暂时无法访问安全存储",
                        "应用不会将此情况视为退出登录，也不会覆盖现有凭据。",
                    ),
                    onRetry = { retried = true },
                )
            }
        }

        compose.onNodeWithText("暂时无法访问安全存储")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        compose.onNodeWithText("应用不会将此情况视为退出登录，也不会覆盖现有凭据。")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        compose.onNodeWithText("重新检查").assertIsDisplayed().assertHasClickAction().performClick()
        compose.runOnIdle { assertTrue(retried) }
    }
}
