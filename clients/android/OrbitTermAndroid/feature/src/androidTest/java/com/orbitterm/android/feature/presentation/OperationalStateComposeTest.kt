package com.orbitterm.android.feature.presentation

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import com.orbitterm.android.ui.design.OrbitStatusLine
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class OperationalStateComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun failedModulesExposeVisibleRetryAndRetainedContentMessages() {
        var retryCount = 0
        compose.setContent {
            MaterialTheme {
                Column {
                    OperationalModuleKind.entries.forEach { module ->
                        val content = when (module) {
                            OperationalModuleKind.MONITOR -> OperationalContentPresentationMapper.monitor(
                                isLoading = false,
                                hasData = true,
                                isPolling = true,
                                failureDetail = "监控请求超时。",
                            )
                            OperationalModuleKind.SFTP -> OperationalContentPresentationMapper.sftp(
                                isLoading = false,
                                hasItems = true,
                                failureDetail = "目录读取超时。",
                            )
                            OperationalModuleKind.DOCKER -> OperationalContentPresentationMapper.docker(
                                isLoading = false,
                                hasContainers = true,
                                failureDetail = "容器读取超时。",
                            )
                        }
                        val action = OperationalContentPresentationMapper.refreshAction(
                            module = module,
                            phase = content.phase,
                            isRefreshing = false,
                            hasContent = true,
                        )
                        OrbitStatusLine(label = content.headline, isActive = false)
                        OperationalFailureFeedback(content = content, action = action)
                        OperationalRefreshAction(
                            presentation = action,
                            onRefresh = { retryCount += 1 },
                        )
                    }
                }
            }
        }

        listOf("监控读取失败", "SFTP 操作失败", "Docker 操作失败").forEach {
            compose.onNodeWithText(it).assertIsDisplayed()
        }
        listOf(
            "操作未完成，正在显示上次成功的监控数据。",
            "操作未完成，当前目录列表仍可查看。",
            "操作未完成，正在显示上次成功的容器列表。",
        ).forEach { retainedMessage ->
            compose.onNodeWithText(retainedMessage, substring = true).assertIsDisplayed()
        }
        listOf("重试刷新监控", "重试刷新目录", "重试刷新容器").forEach { label ->
            compose.onNodeWithContentDescription(label)
                .assertIsDisplayed()
                .assertHasClickAction()
                .performClick()
        }
        assertEquals(3, retryCount)
    }

    @Test
    fun busyRefreshIsDisabledAndSuccessExpiresWhileFailurePersists() {
        compose.mainClock.autoAdvance = false
        val busy = OperationalContentPresentationMapper.refreshAction(
            module = OperationalModuleKind.MONITOR,
            phase = OperationalContentPhase.READY,
            isRefreshing = true,
            hasContent = true,
        )
        compose.setContent {
            MaterialTheme {
                var successMessage by remember { mutableStateOf<String?>("容器操作已完成。") }
                Column {
                    OperationalRefreshAction(presentation = busy, onRefresh = {})
                    successMessage?.let { message ->
                        OperationalTransientSuccessFeedback(
                            message = message,
                            onDismiss = { dismissed ->
                                if (successMessage == dismissed) successMessage = null
                            },
                        )
                    }
                    val failure = OperationalContentPresentationMapper.sftp(
                        isLoading = false,
                        hasItems = true,
                        failureDetail = "目录读取失败。",
                    )
                    OperationalFailureFeedback(
                        content = failure,
                        action = OperationalContentPresentationMapper.refreshAction(
                            module = OperationalModuleKind.SFTP,
                            phase = failure.phase,
                            isRefreshing = false,
                            hasContent = true,
                        ),
                    )
                }
            }
        }

        compose.onNodeWithContentDescription("正在刷新监控").assertIsNotEnabled()
        compose.onNodeWithText("刷新中…").assertIsDisplayed()
        compose.onNodeWithText("容器操作已完成。").assertIsDisplayed()
        compose.mainClock.advanceTimeBy(OperationalFeedbackPolicy.SUCCESS_VISIBLE_MILLIS + 1)
        compose.waitForIdle()
        compose.onAllNodesWithText("容器操作已完成。").assertCountEquals(0)
        compose.onNodeWithText("目录读取失败。", substring = true).assertIsDisplayed()
    }
}
