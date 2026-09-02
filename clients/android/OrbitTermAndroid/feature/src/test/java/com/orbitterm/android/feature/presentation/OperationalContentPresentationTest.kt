package com.orbitterm.android.feature.presentation

import org.junit.Assert.assertEquals
import org.junit.Test

class OperationalContentPresentationTest {
    @Test
    fun monitorUsesStablePriorityAndVocabulary() {
        assertEquals("正在加载监控", OperationalContentPresentationMapper.monitor(true, false, true, null).headline)
        assertEquals("暂无监控数据", OperationalContentPresentationMapper.monitor(false, false, true, null).headline)
        assertEquals("采样已暂停", OperationalContentPresentationMapper.monitor(false, true, false, null).headline)
        assertEquals("监控中", OperationalContentPresentationMapper.monitor(false, true, true, null).headline)
        assertEquals("监控读取失败", OperationalContentPresentationMapper.monitor(true, true, true, "安全错误").headline)
    }

    @Test
    fun sftpUsesStableLoadingEmptyFailedAndReadyVocabulary() {
        assertEquals("正在加载目录", OperationalContentPresentationMapper.sftp(true, false, null).headline)
        assertEquals("此目录为空", OperationalContentPresentationMapper.sftp(false, false, null).headline)
        assertEquals("SFTP 操作失败", OperationalContentPresentationMapper.sftp(false, true, "权限不足").headline)
        assertEquals("目录已就绪", OperationalContentPresentationMapper.sftp(false, true, null).headline)
    }

    @Test
    fun dockerUsesStableLoadingEmptyFailedAndReadyVocabulary() {
        assertEquals("正在加载容器", OperationalContentPresentationMapper.docker(true, false, null).headline)
        assertEquals("暂无容器", OperationalContentPresentationMapper.docker(false, false, null).headline)
        assertEquals("Docker 操作失败", OperationalContentPresentationMapper.docker(false, true, "连接中断").headline)
        assertEquals("容器已就绪", OperationalContentPresentationMapper.docker(false, true, null).headline)
    }

    @Test
    fun refreshActionsExposeRetryBusyAndStaleContentSemantics() {
        val failed = OperationalContentPresentationMapper.refreshAction(
            OperationalModuleKind.SFTP,
            OperationalContentPhase.FAILED,
            isRefreshing = false,
            hasContent = true,
        )
        assertEquals("重试", failed.refreshLabel)
        assertEquals("重试刷新目录", failed.refreshContentDescription)
        assertEquals("操作未完成，当前目录列表仍可查看。", failed.staleContentMessage)

        val refreshing = OperationalContentPresentationMapper.refreshAction(
            OperationalModuleKind.DOCKER,
            OperationalContentPhase.READY,
            isRefreshing = true,
            hasContent = true,
        )
        assertEquals("刷新中…", refreshing.refreshLabel)
        assertEquals(false, refreshing.refreshEnabled)
        assertEquals(true, refreshing.showsRefreshProgress)
        assertEquals(null, refreshing.staleContentMessage)
    }

    @Test
    fun monitorSamplingActionUsesPauseAndResumeVocabulary() {
        assertEquals("暂停采样", OperationalContentPresentationMapper.monitorSamplingLabel(true))
        assertEquals("恢复采样", OperationalContentPresentationMapper.monitorSamplingLabel(false))
    }

    @Test
    fun successFeedbackExpiresButFailureRemainsUntilRecovery() {
        assertEquals(
            4_000L,
            OperationalFeedbackPolicy.lifetime(OperationalFeedbackKind.SUCCESS).autoDismissAfterMillis,
        )
        assertEquals(
            null,
            OperationalFeedbackPolicy.lifetime(OperationalFeedbackKind.FAILURE).autoDismissAfterMillis,
        )
    }
}
