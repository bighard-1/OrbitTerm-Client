package com.orbitterm.android.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import com.orbitterm.android.app.SyncStatus
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.sync.AssetOutboxResult
import com.orbitterm.android.ui.theme.OrbitTheme
import org.junit.Rule
import org.junit.Test

class SyncRecoveryComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun waitingPartialFailureAndRetainedRecentlyDeletedExposeAccessibleRecovery() {
        val recentFailure = com.orbitterm.android.app.RecentlyDeletedUiState(
            items = listOf(
                com.orbitterm.android.sync.RecentlyDeletedAssetSummary(
                    assetId = "asset",
                    displayName = "固定测试资产",
                    endpoint = "example.invalid:22",
                    deletedAt = null,
                    purgeAfter = null,
                    canRestore = true,
                ),
            ),
            error = "无法加载最近删除，请检查网络或登录状态。",
        ).presentation()

        compose.setContent {
            OrbitTheme(darkTheme = false, colorTheme = AppColorTheme.GlacierMint) {
                Column {
                    SyncStatusFeedback(SyncStatus.AwaitingNetwork, onRetry = {})
                    SyncStatusFeedback(SyncStatus.AwaitingUnlock, onRetry = {})
                    SyncStatusFeedback(
                        SyncStatus.Succeeded(3, 2, AssetOutboxResult(deferred = 1)),
                        onRetry = {},
                    )
                    RecentlyDeletedFeedback(
                        presentation = recentFailure,
                        successMessage = null,
                        onDismissSuccess = {},
                    )
                }
            }
        }

        compose.onNodeWithText("等待网络：网络恢复后自动同步").assertIsDisplayed()
        compose.onNodeWithText("等待解锁：解锁后继续安全同步").assertIsDisplayed()
        compose.onNodeWithText("同步失败：已同步 3 项资产、2 条命令片段；1 项将在退避后重试")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        compose.onNodeWithText("重试同步").assertIsDisplayed().assertHasClickAction()
        compose.onNodeWithText("无法加载最近删除，请检查网络或登录状态。 操作未完成，当前删除记录仍可查看。")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
    }

    @Test
    fun successFeedbackExpiresAfterFourSecondsWhileFailurePersists() {
        compose.mainClock.autoAdvance = false
        val failure = RecentlyDeletedPresentation(
            phase = RecentlyDeletedPresentationPhase.FAILED,
            headline = "无法加载最近删除",
            detail = "读取失败。",
            refreshLabel = "重试",
            refreshEnabled = true,
            staleContentMessage = null,
        )
        compose.setContent {
            OrbitTheme(darkTheme = true, colorTheme = AppColorTheme.GlacierMint) {
                Column {
                    SyncStatusFeedback(
                        SyncStatus.Succeeded(1, 1, AssetOutboxResult()),
                        onRetry = {},
                    )
                    RecentlyDeletedFeedback(
                        presentation = failure,
                        successMessage = "恢复已加入后台队列，联网后自动完成。",
                        onDismissSuccess = {},
                    )
                }
            }
        }

        compose.onNodeWithText("同步完成：已同步 1 项资产、1 条命令片段").assertIsDisplayed()
        compose.onNodeWithText("恢复已加入后台队列，联网后自动完成。").assertIsDisplayed()
        compose.onNodeWithText("读取失败。").assertIsDisplayed()
        compose.mainClock.advanceTimeBy(4_001)
        compose.waitForIdle()
        compose.onAllNodesWithText("同步完成：已同步 1 项资产、1 条命令片段").assertCountEquals(0)
        compose.onAllNodesWithText("恢复已加入后台队列，联网后自动完成。").assertCountEquals(0)
        compose.onNodeWithText("读取失败。").assertIsDisplayed()
    }
}
