package com.orbitterm.android.ui.design

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.ui.theme.OrbitTheme
import org.junit.Rule
import org.junit.Test

/**
 * Device-independent guardrails for the manual P2 accessibility matrix.
 *
 * These tests use the same Compose rendering path as the app but no account,
 * asset, terminal or network state. They do not replace TalkBack or real
 * split-screen validation; they prevent known layout regressions before that
 * manual pass starts.
 */
class P2AccessibilityLayoutRegressionTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun fontScaleTwoKeepsDangerConfirmationActionsReachable() {
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 2f)) {
                OrbitTheme(darkTheme = false, colorTheme = AppColorTheme.GlacierMint) {
                    Surface(modifier = Modifier.width(320.dp).height(640.dp)) {
                        OrbitConfirmationDialog(
                            title = "删除服务器？",
                            message = "此操作会移除本地配置，不会影响远程服务器。",
                            confirmLabel = "删除",
                            onConfirm = {},
                            onDismiss = {},
                            destructive = true,
                        )
                    }
                }
            }
        }

        compose.onNodeWithText("危险操作").assertIsDisplayed()
        compose.onNodeWithText("删除").assertIsDisplayed()
        compose.onNodeWithText("取消").assertIsDisplayed()
    }

    @Test
    fun landscapeWidthKeepsStatusAndTerminalThemeVisible() {
        compose.setContent {
            OrbitTheme(darkTheme = true, colorTheme = AppColorTheme.GlacierMint) {
                Surface(
                    modifier = Modifier.width(640.dp).height(320.dp),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    Column(
                        modifier = Modifier.fillMaxSize().padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        OrbitPageHeader(title = "终端工作台", subtitle = "已连接 · 硬件键盘可用")
                        OrbitStatusBadge("已连接", OrbitStatusTone.Success)
                        OrbitTerminalThemeSwatch(
                            label = "Dracula",
                            background = Color(0xFF282A36),
                            foreground = Color(0xFFF8F8F2),
                            ansiColors = listOf(Color(0xFFFF5555), Color(0xFF50FA7B), Color(0xFF8BE9FD)),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }

        compose.onNodeWithText("终端工作台").assertIsDisplayed()
        compose.onNodeWithText("已连接").assertIsDisplayed()
        compose.onNodeWithText("Dracula").assertIsDisplayed()
    }
}
