package com.orbitterm.android.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.orbitterm.android.domain.session.*
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.feature.terminal.TerminalKeyRecoveryDialog
import com.orbitterm.android.feature.terminal.TerminalKeyRescueReview
import com.orbitterm.android.ui.theme.OrbitTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class TerminalKeyRecoveryComposeTest {
    @Test fun rescueReportExposesSafetyStateWithoutRawContentOrActions() {
        val report = TerminalKeyRescueReview("fixture", TerminalKeyRescuePlatform.Android, false,
            TerminalKeyRescueStorageMatch.Different,
            listOf(TerminalKeyRescueSourceReview(2, 99, TerminalKeyRescueSourceStatus.ProtectedUnreadable)))
        compose.setContent { OrbitTheme(false, AppColorTheme.GlacierMint) { Column { TerminalKeyRescueReview(report) } } }
        compose.onNodeWithTag("terminal_rescue_review").assertExists()
        compose.onNodeWithText("账户归属：与当前账户不一致，请勿用于当前账户修复").assertExists()
        compose.onNodeWithText("当前存储：已发生变化，需要重新导出或重新评估").assertExists()
        compose.onNodeWithText("本设备无法解密或验证；可能密钥不可用或密文损坏").assertExists()
        compose.onNodeWithText("确认合并到当前账户").assertDoesNotExist()
    }
    @Test fun repairPreviewShowsBoundedDiagnosisWithoutPayloadOrWriteAction() {
        val preview = TerminalKeyRepairPreview(TerminalKeyRepairSource.AndroidLegacy,
            items = listOf(TerminalKeyRepairItem(0, "…11111111", "bad\\u{202E}name", "Future", 19,
                listOf(TerminalKeyRepairIssue.InvalidLabel, TerminalKeyRepairIssue.InvalidSection),
                TerminalKeyRepairDisposition.ManualCorrectionRequired, 0, true)), protectedSourcePresent = true)
        val report = TerminalKeyRescueReview("fixture", TerminalKeyRescuePlatform.Android, true,
            TerminalKeyRescueStorageMatch.Exact,
            listOf(TerminalKeyRescueSourceReview(3, 99, TerminalKeyRescueSourceStatus.ContractRejected)), preview)
        compose.setContent { OrbitTheme(false, AppColorTheme.GlacierMint) { Column { TerminalKeyRescueReview(report) } } }
        compose.onNodeWithTag("terminal_repair_preview").assertExists()
        compose.onNodeWithText("项目 1 · 需要人工修正").assertExists()
        compose.onNodeWithText("发送内容：19 UTF-8 字节（内容不展示）").assertExists()
        compose.onNodeWithText("private-command", substring = true).assertDoesNotExist()
        compose.onNodeWithText("写回", substring = true).assertExists()
        compose.onNodeWithText("确认修复", substring = true).assertDoesNotExist()
    }
    @Test fun explicitDecisionProducesOnlyAReadOnlySecondConfirmationPreview() {
        val preview = TerminalKeyRepairPreview(TerminalKeyRepairSource.AndroidLegacy,
            items = listOf(TerminalKeyRepairItem(0, "…11111111", "Enter", "Common", 2,
                emptyList(), TerminalKeyRepairDisposition.KeepUnchanged, 0, true)))
        val report = TerminalKeyRescueReview("fixture", TerminalKeyRescuePlatform.Android, true,
            TerminalKeyRescueStorageMatch.Exact,
            listOf(TerminalKeyRescueSourceReview(3, 99, TerminalKeyRescueSourceStatus.ValidLegacyLibrary)), preview)
        compose.setContent { OrbitTheme(false, AppColorTheme.GlacierMint) { Column { TerminalKeyRescueReview(report) } } }
        compose.onNodeWithTag("terminal_repair_decision_draft").assertExists()
        compose.onNodeWithText("生成二次确认清单").assertIsNotEnabled()
        compose.onNodeWithTag("terminal_repair_keep_0").performClick()
        compose.onNodeWithText("生成二次确认清单").assertIsEnabled().performClick()
        compose.onNodeWithTag("terminal_repair_confirmation_preview").assertExists()
        compose.onNodeWithText("当前仍没有写回、替换或清库入口。", substring = true).assertExists()
        compose.onNodeWithText("确认修复", substring = true).assertDoesNotExist()
    }
    @Test fun rescueModeNeverOffersImportOrMergeAndStillRequiresConfirmedPassword() {
        val repository = Repository()
        compose.setContent { OrbitTheme(false, AppColorTheme.GlacierMint) {
            TerminalKeyRecoveryDialog(repository, documents, rescueOnly = true) {}
        } }
        compose.onNodeWithText("原始配置加密救援").assertExists()
        compose.onNodeWithText("选择恢复文件").assertDoesNotExist()
        compose.onNodeWithText("解密并预览").assertDoesNotExist()
        compose.onNodeWithText("确认合并到当前账户").assertDoesNotExist()
        compose.onNodeWithText("加密并导出文件").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("选择救援文件").performScrollTo().assertIsEnabled()
        compose.onNodeWithText("解密并核验").performScrollTo().assertIsNotEnabled()
    }
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val documents = object : com.orbitterm.android.core.DocumentInteractionCoordinator {
        override fun beginDocumentInteraction() {}
    }
    private class Repository : TerminalKeyUsageRepository {
        val token = MutableStateFlow<String?>("fixture")
        override val recoveryAccessTokens = token
        override fun recoveryAccessToken() = token.value
        override fun recoveryAccessValid(token: String) = this.token.value == token
        override val usageCounts = flowOf(emptyMap<String, Int>())
        override val customKeys = flowOf(emptyList<TerminalCustomKey>())
        override suspend fun recordUse(keyLabel: String) {}
        override suspend fun saveCustomKey(key: TerminalCustomKey) {}
        override suspend fun deleteCustomKey(id: String) {}
    }
    @Test fun exportRequiresConfirmedPasswordAndImportCannotCommitWithoutPreview() {
        val repository = Repository()
        compose.setContent { OrbitTheme(false, AppColorTheme.GlacierMint) { TerminalKeyRecoveryDialog(repository, documents) {} } }
        compose.onNodeWithText("加密并导出文件").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("terminal_recovery_password").performScrollTo()
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Password)).performTextInput("test-only-12345")
        compose.onNodeWithText("加密并导出文件").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("terminal_recovery_confirm_password").performScrollTo().performTextInput("test-only-12345")
        compose.onNodeWithText("加密并导出文件").performScrollTo().assertIsEnabled()
        compose.onNodeWithText("解密并预览").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("确认合并到当前账户").assertDoesNotExist()
    }
    @Test fun lockDismissesRecoverySessionInsteadOfReusingPassword() {
        val repository = Repository()
        var closed = false
        compose.setContent { OrbitTheme(false, AppColorTheme.GlacierMint) { TerminalKeyRecoveryDialog(repository, documents) { closed = true } } }
        compose.onNodeWithTag("terminal_recovery_password").performScrollTo().performTextInput("test-only-12345")
        compose.runOnIdle { repository.token.value = null }
        compose.waitForIdle()
        compose.runOnIdle { assertTrue(closed) }
        compose.onNodeWithTag("terminal_recovery_password").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, androidx.compose.ui.text.AnnotatedString("")))
    }
}
