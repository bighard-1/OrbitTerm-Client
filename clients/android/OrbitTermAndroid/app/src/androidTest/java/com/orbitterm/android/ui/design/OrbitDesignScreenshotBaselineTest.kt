package com.orbitterm.android.ui.design

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.ui.theme.OrbitTheme
import java.nio.ByteBuffer
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

private const val BASELINE_WIDTH = 320
private const val BASELINE_HEIGHT = 640

/**
 * Screenshot fingerprints intentionally use fixed, data-free design states.
 *
 * This is a fixed-canvas visual baseline: it excludes status/navigation bars
 * and normalizes Compose density before hashing. A rendering change gives a
 * clear re-record signal instead of silently accepting visual drift.
 */
class OrbitDesignScreenshotBaselineTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun lightStatusAndTerminalSwatchMatchBaseline() {
        compose.setContent { FixedBaselineCanvas { OrbitDesignRegressionPanel(darkTheme = false, destructiveDialog = false) } }
        assertEquals(LIGHT_BASELINE, captureContentFingerprint())
    }

    @Test
    fun darkDangerConfirmationMatchesBaseline() {
        compose.setContent { FixedBaselineCanvas { OrbitDesignRegressionPanel(darkTheme = true, destructiveDialog = true) } }
        assertEquals(DARK_DANGER_BASELINE, captureContentFingerprint())
    }

    private fun captureContentFingerprint(): String {
        compose.waitForIdle()
        val contentView = compose.activity.findViewById<View>(android.R.id.content)
        check(contentView.width >= BASELINE_WIDTH && contentView.height >= BASELINE_HEIGHT) {
            "Baseline viewport is smaller than ${BASELINE_WIDTH}x${BASELINE_HEIGHT}: ${contentView.width}x${contentView.height}"
        }
        val content = Bitmap.createBitmap(BASELINE_WIDTH, BASELINE_HEIGHT, Bitmap.Config.ARGB_8888)
        contentView.draw(Canvas(content))
        val pixels = IntArray(content.width * content.height)
        content.getPixels(pixels, 0, content.width, 0, 0, content.width, content.height)
        val bytes = ByteBuffer.allocate(pixels.size * Int.SIZE_BYTES)
        pixels.forEach(bytes::putInt)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes.array())
            .joinToString(separator = "") { "%02x".format(it) }
        return "${content.width}x${content.height}:$digest"
    }

    companion object {
        // Re-record only after a reviewed visual change on the fixed baseline canvas.
        private const val LIGHT_BASELINE = "320x640:15b0518786781f6fcdf1e7e07b7e57054b415039d2e636684c25436c01824b55"
        private const val DARK_DANGER_BASELINE = "320x640:31fe7ecc1fb6b11778b0c160b75ab9bdf74bd2a5985519d7698b4bc42e4194a8"
    }
}

@Composable
private fun FixedBaselineCanvas(content: @Composable () -> Unit) {
    // Keep pixels and text scale deterministic across emulator resolutions.
    CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 1f)) {
        Box(Modifier.size(BASELINE_WIDTH.dp, BASELINE_HEIGHT.dp)) { content() }
    }
}

@Composable
private fun OrbitDesignRegressionPanel(darkTheme: Boolean, destructiveDialog: Boolean) {
    OrbitTheme(darkTheme = darkTheme, colorTheme = AppColorTheme.GlacierMint) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OrbitPageHeader(title = "服务器", subtitle = "已保存 2 台服务器")
                OrbitSectionCard(title = "连接状态", subtitle = "安全状态与操作反馈") {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OrbitStatusBadge("已连接", OrbitStatusTone.Success)
                        OrbitStatusBadge("需要注意", OrbitStatusTone.Warning)
                    }
                    OrbitFeedbackBanner(
                        message = if (destructiveDialog) "操作前请确认影响范围" else "同步已完成",
                        isError = destructiveDialog,
                    )
                    OrbitTerminalThemeSwatch(
                        label = "Dracula",
                        background = Color(0xFF282A36),
                        foreground = Color(0xFFF8F8F2),
                        ansiColors = listOf(
                            Color(0xFFFF5555), Color(0xFF50FA7B), Color(0xFFF1FA8C), Color(0xFF6272A4),
                            Color(0xFFFF79C6), Color(0xFF8BE9FD), Color(0xFFF8F8F2), Color(0xFFBD93F9),
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        if (destructiveDialog) {
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
