package com.orbitterm.android.ui

import com.orbitterm.android.app.SyncStatus

/** Stable brand vocabulary for sync headlines; diagnostic detail remains separate. */
internal enum class SyncPresentationPhase { IDLE, WAITING, BUSY, SUCCESS, FAILURE }

internal data class SyncStatusPresentation(
    val phase: SyncPresentationPhase,
    val headline: String,
    val detail: String,
    val isActionRequired: Boolean = false,
)

internal fun SyncStatus.presentation(): SyncStatusPresentation = when (this) {
    SyncStatus.Idle -> SyncStatusPresentation(SyncPresentationPhase.IDLE, "等待同步", "尚未开始同步")
    SyncStatus.AwaitingNetwork -> SyncStatusPresentation(SyncPresentationPhase.WAITING, "等待网络", "网络恢复后自动同步")
    SyncStatus.AwaitingUnlock -> SyncStatusPresentation(SyncPresentationPhase.WAITING, "等待解锁", "解锁后继续安全同步")
    SyncStatus.Syncing -> SyncStatusPresentation(SyncPresentationPhase.BUSY, "同步中", "正在同步加密数据")
    is SyncStatus.Succeeded -> {
        val needsAttention = outbox.deferred > 0 ||
            outbox.blocked > 0 ||
            outbox.waitingForAuthentication > 0 ||
            outbox.waitingForUnlock > 0 ||
            outbox.userActionRequired > 0 ||
            outbox.conflicts.isNotEmpty()
        SyncStatusPresentation(
            phase = if (needsAttention) SyncPresentationPhase.FAILURE else SyncPresentationPhase.SUCCESS,
            headline = if (needsAttention) "同步失败" else "同步完成",
            detail = buildString {
            append("已同步 $assetCount 项资产、$snippetCount 条命令片段")
            if (outbox.delivered > 0) append("；已发布 ${outbox.delivered} 项本地变更")
            if (outbox.deferred > 0) append("；${outbox.deferred} 项将在退避后重试")
            if (outbox.waitingForAuthentication > 0) append("；${outbox.waitingForAuthentication} 项等待重新登录")
            if (outbox.waitingForUnlock > 0) append("；${outbox.waitingForUnlock} 项等待重新解锁")
            val conflictCount = maxOf(outbox.userActionRequired, outbox.conflicts.size)
            if (conflictCount > 0) append("；$conflictCount 项同步冲突等待处理")
            if (outbox.blocked > 0) append("；${outbox.blocked} 项已停止后台重试")
            },
            isActionRequired = needsAttention,
        )
    }
    is SyncStatus.Failed -> SyncStatusPresentation(
        phase = SyncPresentationPhase.FAILURE,
        headline = "同步失败",
        detail = message,
        isActionRequired = true,
    )
}

internal data class SyncConflictPresentation(
    val title: String,
    val detail: String,
    val keepLocalLabel: String,
    val keepCloudLabel: String,
)

internal fun com.orbitterm.android.sync.AssetSyncConflict.presentation() = SyncConflictPresentation(
    title = "检测到同步冲突",
    detail = "冲突字段：${fields.joinToString { it.label }}\n\n本地修改：\n$localSummary\n\n云端修改：\n$remoteSummary",
    keepLocalLabel = "保留本地修改",
    keepCloudLabel = "保留云端修改",
)

internal enum class RecentlyDeletedPresentationPhase { LOADING, EMPTY, READY, FAILED }

internal data class RecentlyDeletedPresentation(
    val phase: RecentlyDeletedPresentationPhase,
    val headline: String,
    val detail: String,
    val refreshLabel: String,
    val refreshEnabled: Boolean,
    val staleContentMessage: String? = null,
)

internal fun com.orbitterm.android.app.RecentlyDeletedUiState.presentation(): RecentlyDeletedPresentation {
    val hasItems = items.isNotEmpty()
    return when {
        isLoading -> RecentlyDeletedPresentation(
            phase = RecentlyDeletedPresentationPhase.LOADING,
            headline = if (hasItems) "正在刷新最近删除" else "正在读取最近删除",
            detail = if (hasItems) "当前记录仍可查看" else "正在安全读取删除记录",
            refreshLabel = "刷新中…",
            refreshEnabled = false,
        )
        error != null -> RecentlyDeletedPresentation(
            phase = RecentlyDeletedPresentationPhase.FAILED,
            headline = "无法加载最近删除",
            detail = error,
            refreshLabel = "重试",
            refreshEnabled = mutatingAssetId == null,
            staleContentMessage = if (hasItems) "操作未完成，当前删除记录仍可查看。" else null,
        )
        !hasItems -> RecentlyDeletedPresentation(
            phase = RecentlyDeletedPresentationPhase.EMPTY,
            headline = "最近删除为空",
            detail = "删除的云端资产会在保留期内显示在这里",
            refreshLabel = "刷新",
            refreshEnabled = mutatingAssetId == null,
        )
        else -> RecentlyDeletedPresentation(
            phase = RecentlyDeletedPresentationPhase.READY,
            headline = "最近删除",
            detail = "共 ${items.size} 条删除记录",
            refreshLabel = "刷新",
            refreshEnabled = mutatingAssetId == null,
        )
    }
}
