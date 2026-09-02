package com.orbitterm.android.ui

import com.orbitterm.android.app.SyncStatus
import com.orbitterm.android.domain.error.OrbitErrorCode
import com.orbitterm.android.domain.error.syncError
import com.orbitterm.android.app.RecentlyDeletedUiState
import com.orbitterm.android.sync.AssetOutboxResult
import com.orbitterm.android.sync.AssetSyncConflict
import com.orbitterm.android.sync.AssetSyncField
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncStatusPresentationTest {
    @Test
    fun `sync lifecycle uses stable mobile headlines`() {
        assertEquals("等待同步", SyncStatus.Idle.presentation().headline)
        assertEquals("等待网络", SyncStatus.AwaitingNetwork.presentation().headline)
        assertEquals("等待解锁", SyncStatus.AwaitingUnlock.presentation().headline)
        assertEquals("同步中", SyncStatus.Syncing.presentation().headline)
    }

    @Test
    fun `failure headline is stable while redacted detail remains available`() {
        val status = SyncStatus.Failed(
            syncError(OrbitErrorCode.NetworkUnavailable),
        ).presentation()
        assertEquals("同步失败", status.headline)
        assertTrue(status.isActionRequired)
        assertTrue(status.detail.isNotBlank())
        assertFalse(status.detail.contains("token", ignoreCase = true))
    }

    @Test
    fun `deferred work and conflicts cannot be presented as complete success`() {
        val deferred = SyncStatus.Succeeded(
            assetCount = 3,
            snippetCount = 2,
            outbox = AssetOutboxResult(deferred = 1),
        ).presentation()
        assertEquals(SyncPresentationPhase.FAILURE, deferred.phase)
        assertEquals("同步失败", deferred.headline)
        assertTrue(deferred.isActionRequired)

        val conflict = AssetSyncConflict(
            assetId = "asset",
            fields = setOf(AssetSyncField.Name),
            localSummary = "本机版本",
            remoteSummary = "云端版本",
        )
        val conflicted = SyncStatus.Succeeded(3, 2, AssetOutboxResult(conflicts = listOf(conflict))).presentation()
        assertEquals(SyncPresentationPhase.FAILURE, conflicted.phase)
        assertTrue(conflicted.detail.contains("1 项同步冲突等待处理"))
        assertEquals("检测到同步冲突", conflict.presentation().title)
        assertEquals("保留本地修改", conflict.presentation().keepLocalLabel)
        assertEquals("保留云端修改", conflict.presentation().keepCloudLabel)
    }

    @Test
    fun `blocked work is not described as a network retry`() {
        val presentation = SyncStatus.Succeeded(
            assetCount = 2,
            snippetCount = 1,
            outbox = AssetOutboxResult(blocked = 2),
        ).presentation()

        assertEquals(SyncPresentationPhase.FAILURE, presentation.phase)
        assertTrue(presentation.detail.contains("2 项已停止后台重试"))
        assertFalse(presentation.detail.contains("等待网络"))
    }

    @Test
    fun `recently deleted failure retains visible records and exposes retry`() {
        val state = RecentlyDeletedUiState(
            items = listOf(
                com.orbitterm.android.sync.RecentlyDeletedAssetSummary(
                    assetId = "asset",
                    displayName = "测试资产",
                    endpoint = "example.invalid:22",
                    deletedAt = null,
                    purgeAfter = null,
                    canRestore = true,
                ),
            ),
            error = "无法加载最近删除，请检查网络或登录状态。",
        ).presentation()
        assertEquals(RecentlyDeletedPresentationPhase.FAILED, state.phase)
        assertEquals("无法加载最近删除", state.headline)
        assertEquals("重试", state.refreshLabel)
        assertEquals("操作未完成，当前删除记录仍可查看。", state.staleContentMessage)
    }
}
