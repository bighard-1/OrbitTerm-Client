package com.orbitterm.android.feature.terminal

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
import org.junit.Test

class TerminalReconnectAccessibilityComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun reconnectActionCommunicatesAvailabilityAndFailureToAssistiveTech() {
        compose.setContent {
            MaterialTheme {
                TerminalReconnectAction(reconnecting = false, onReconnect = {})
                TerminalReconnectFailure("重新连接失败：网络不可用。")
            }
        }

        compose.onNodeWithTag("terminal_reconnect_action")
            .assertIsDisplayed()
            .assertHasClickAction()
        compose.onNodeWithText("重新连接失败：网络不可用。")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
    }

    @Test
    fun reconnectActionIsUnavailableWhileAReconnectIsAlreadyRunning() {
        compose.setContent {
            MaterialTheme {
                TerminalReconnectAction(reconnecting = true, onReconnect = {})
            }
        }

        compose.onNodeWithTag("terminal_reconnect_action")
            .assertIsDisplayed()
            .assertIsNotEnabled()
    }
}
