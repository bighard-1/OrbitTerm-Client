package com.orbitterm.android.ui.design

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import com.orbitterm.android.ui.design.OrbitEmptyState
import com.orbitterm.android.ui.design.OrbitFeedbackBanner
import com.orbitterm.android.ui.design.OrbitConfirmationDialog
import org.junit.Rule
import org.junit.Test

class OrbitEmptyStateComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun noSessionStateKeepsRecoveryMessageVisible() {
        compose.setContent {
            OrbitEmptyState(
                title = "终端工作台",
                message = "暂无活动会话。请先在服务器页连接一台资产。",
            )
        }

        compose.onNodeWithText("终端工作台").assertIsDisplayed()
        compose.onNodeWithText("暂无活动会话。请先在服务器页连接一台资产。").assertIsDisplayed()
    }

    @Test
    fun dockerEmptyStateKeepsRecoveryMessageVisible() {
        compose.setContent {
            OrbitEmptyState(
                title = "未发现容器",
                message = "当前已连接服务器没有可管理的 Docker 容器。",
            )
        }

        compose.onNodeWithText("未发现容器").assertIsDisplayed()
        compose.onNodeWithText("当前已连接服务器没有可管理的 Docker 容器。").assertIsDisplayed()
    }

    @Test
    fun connectionAndSyncFailuresRemainReadable() {
        compose.setContent {
            androidx.compose.foundation.layout.Column {
                OrbitConfirmationDialog(
                    title = "连接未建立",
                    message = "连接超时。请检查网络、地址和防火墙。诊断代码：ssh_timeout。",
                    confirmLabel = "关闭",
                    onConfirm = {},
                    onDismiss = {},
                )
                OrbitFeedbackBanner(message = "同步失败，请检查网络和登录状态后重试。", isError = true)
            }
        }

        compose.onNodeWithText("连接未建立").assertIsDisplayed()
        compose.onNodeWithText("连接超时。请检查网络、地址和防火墙。诊断代码：ssh_timeout。").assertIsDisplayed()
        compose.onNodeWithText("同步失败，请检查网络和登录状态后重试。").assertIsDisplayed()
    }

    @Test
    fun feedbackAndEmptyStateExposeAssistiveSemantics() {
        compose.setContent {
            androidx.compose.foundation.layout.Column {
                OrbitEmptyState(title = "无活动会话", message = "请先连接服务器。")
                OrbitFeedbackBanner(message = "同步已完成", isError = false)
            }
        }

        compose.onNodeWithText("无活动会话")
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        compose.onNodeWithText("同步已完成")
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
    }

    @Test
    fun statusBadgeExposesTextualStateBeyondItsColor() {
        compose.setContent {
            OrbitStatusBadge("连接已阻断", OrbitStatusTone.Danger)
        }

        compose.onNodeWithText("连接已阻断").assertIsDisplayed()
        compose.onNodeWithContentDescription("状态：连接已阻断").assertIsDisplayed()
    }

    @Test
    fun destructiveConfirmationKeepsRiskAndRecoveryActionsVisible() {
        compose.setContent {
            OrbitConfirmationDialog(
                title = "删除服务器？",
                message = "此操作会移除本地配置，不会影响远程服务器。",
                confirmLabel = "删除",
                onConfirm = {},
                onDismiss = {},
                destructive = true,
            )
        }

        compose.onNodeWithText("危险操作").assertIsDisplayed()
        compose.onNodeWithText("删除").assertIsDisplayed()
        compose.onNodeWithText("取消").assertIsDisplayed()
    }
}
