package com.orbitterm.android.feature.sftp

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class SftpStateAccessibilityComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun activeTransferExposesProgressCancellationAndFailureRecoveryToAssistiveTech() {
        var cancelCount = 0
        var retryCount = 0
        compose.setContent {
            MaterialTheme {
                SftpBrowser(
                    state = SftpUiState(
                        path = "/var/log",
                        transfer = SftpTransferUiState(
                            label = "下载系统日志",
                            detail = "正在通过安全 SFTP 通道传输…",
                            transferredBytes = 512 * 1024,
                            totalBytes = 1024 * 1024,
                        ),
                        activeTransferRequestId = "request-1",
                        canCancelTransfer = true,
                        error = "文件传输失败：目标位置不可写。",
                        retryTransferLabel = "下载系统日志",
                    ),
                    modifier = androidx.compose.ui.Modifier,
                    onRefresh = {}, onParent = {}, onNavigatePath = {}, onDirectoryOpened = {}, onFileOpened = {},
                    onCreateDirectory = {}, onCreateFile = {}, onRename = { _, _ -> }, onRemove = {},
                    onBatchRemove = {}, onChmod = { _, _ -> }, onUpload = {}, onDownload = {},
                    onDownloadAsZip = {}, onShareAsZip = {}, onRetryLastTransfer = { retryCount += 1 },
                    onCancelActiveTransfer = { cancelCount += 1 }, onCancelQueuedTransfer = {},
                    onResumeTransferQueue = {}, onDismissTransferMessage = {}, onDismissTextDocument = {},
                    onEditTextDocument = {}, onSaveTextDocument = {},
                )
            }
        }

        compose.onNodeWithText("下载系统日志 · 50%").assertIsDisplayed()
        compose.onNodeWithText("512.0 KB / 1.0 MB").assertIsDisplayed()
        compose.onNodeWithText("取消传输").assertIsDisplayed().assertHasClickAction().performClick()
        compose.onNodeWithText("重试下载系统日志").assertIsDisplayed().assertHasClickAction().performClick()
        compose.onNodeWithText("文件传输失败：目标位置不可写。")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        assertEquals(1, cancelCount)
        assertEquals(1, retryCount)
    }

    @Test
    fun cancellationAndPausedQueueKeepRecoveryActionsReachable() {
        var resumeCount = 0
        var removedId: String? = null
        compose.setContent {
            MaterialTheme {
                SftpBrowser(
                    state = SftpUiState(
                        transfer = SftpTransferUiState("上传备份", "正在请求取消，当前分块完成后将停止…"),
                        activeTransferRequestId = "request-2",
                        canCancelTransfer = true,
                        cancellationRequested = true,
                        queuedTransfers = listOf(SftpQueuedTransferUiState("queued-1", "数据库备份")),
                        queuePaused = true,
                        transferMessage = "上传备份已取消",
                    ),
                    modifier = androidx.compose.ui.Modifier,
                    onRefresh = {}, onParent = {}, onNavigatePath = {}, onDirectoryOpened = {}, onFileOpened = {},
                    onCreateDirectory = {}, onCreateFile = {}, onRename = { _, _ -> }, onRemove = {},
                    onBatchRemove = {}, onChmod = { _, _ -> }, onUpload = {}, onDownload = {},
                    onDownloadAsZip = {}, onShareAsZip = {}, onRetryLastTransfer = {}, onCancelActiveTransfer = {},
                    onCancelQueuedTransfer = { removedId = it }, onResumeTransferQueue = { resumeCount += 1 },
                    onDismissTransferMessage = {}, onDismissTextDocument = {}, onEditTextDocument = {}, onSaveTextDocument = {},
                )
            }
        }

        compose.onNodeWithText("正在取消…").assertIsDisplayed()
        compose.onNodeWithText("继续队列").assertIsDisplayed().assertHasClickAction().performClick()
        compose.onNodeWithText("移除").assertIsDisplayed().assertHasClickAction().performClick()
        compose.onNodeWithText("上传备份已取消")
            .assertIsDisplayed()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        assertEquals(1, resumeCount)
        assertEquals("queued-1", removedId)
    }
}
