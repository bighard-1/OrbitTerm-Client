package com.orbitterm.android.feature.presentation

enum class OperationalContentPhase {
    LOADING,
    EMPTY,
    PAUSED,
    FAILED,
    READY,
}

enum class OperationalModuleKind {
    MONITOR,
    SFTP,
    DOCKER,
}

data class OperationalContentPresentation(
    val phase: OperationalContentPhase,
    val headline: String,
    val detail: String,
)

data class OperationalActionPresentation(
    val refreshLabel: String,
    val refreshContentDescription: String,
    val refreshEnabled: Boolean,
    val showsRefreshProgress: Boolean,
    val staleContentMessage: String?,
)

enum class OperationalFeedbackKind {
    SUCCESS,
    FAILURE,
}

data class OperationalFeedbackLifetime(
    val autoDismissAfterMillis: Long?,
)

object OperationalFeedbackPolicy {
    const val SUCCESS_VISIBLE_MILLIS = 4_000L

    fun lifetime(kind: OperationalFeedbackKind): OperationalFeedbackLifetime =
        OperationalFeedbackLifetime(
            autoDismissAfterMillis = when (kind) {
                OperationalFeedbackKind.SUCCESS -> SUCCESS_VISIBLE_MILLIS
                OperationalFeedbackKind.FAILURE -> null
            },
        )
}

object OperationalContentPresentationMapper {
    fun monitor(
        isLoading: Boolean,
        hasData: Boolean,
        isPolling: Boolean,
        failureDetail: String?,
    ): OperationalContentPresentation = when {
        failureDetail != null -> OperationalContentPresentation(
            OperationalContentPhase.FAILED,
            "监控读取失败",
            failureDetail,
        )
        !isPolling -> OperationalContentPresentation(
            OperationalContentPhase.PAUSED,
            "采样已暂停",
            "开始采样后将继续更新系统指标。",
        )
        isLoading && !hasData -> OperationalContentPresentation(
            OperationalContentPhase.LOADING,
            "正在加载监控",
            "正在通过当前已验证 SSH 会话采样。",
        )
        !hasData -> OperationalContentPresentation(
            OperationalContentPhase.EMPTY,
            "暂无监控数据",
            "采样完成后，CPU、内存、磁盘与网络信息会显示在这里。",
        )
        else -> OperationalContentPresentation(
            OperationalContentPhase.READY,
            "监控中",
            "系统指标会按设定间隔持续更新。",
        )
    }

    fun sftp(
        isLoading: Boolean,
        hasItems: Boolean,
        failureDetail: String?,
    ): OperationalContentPresentation = when {
        failureDetail != null -> OperationalContentPresentation(
            OperationalContentPhase.FAILED,
            "SFTP 操作失败",
            failureDetail,
        )
        isLoading && !hasItems -> OperationalContentPresentation(
            OperationalContentPhase.LOADING,
            "正在加载目录",
            "正在通过当前已验证 SSH 会话读取目录。",
        )
        !hasItems -> OperationalContentPresentation(
            OperationalContentPhase.EMPTY,
            "此目录为空",
            "可在此目录新建文件、目录或上传文件。",
        )
        else -> OperationalContentPresentation(
            OperationalContentPhase.READY,
            "目录已就绪",
            "可浏览或管理当前目录内容。",
        )
    }

    fun docker(
        isLoading: Boolean,
        hasContainers: Boolean,
        failureDetail: String?,
    ): OperationalContentPresentation = when {
        failureDetail != null -> OperationalContentPresentation(
            OperationalContentPhase.FAILED,
            "Docker 操作失败",
            failureDetail,
        )
        isLoading && !hasContainers -> OperationalContentPresentation(
            OperationalContentPhase.LOADING,
            "正在加载容器",
            "正在通过当前已验证 SSH 会话读取容器状态。",
        )
        !hasContainers -> OperationalContentPresentation(
            OperationalContentPhase.EMPTY,
            "暂无容器",
            "当前已连接服务器没有可管理的 Docker 容器。",
        )
        else -> OperationalContentPresentation(
            OperationalContentPhase.READY,
            "容器已就绪",
            "可查看状态、日志并执行容器操作。",
        )
    }

    fun refreshAction(
        module: OperationalModuleKind,
        phase: OperationalContentPhase,
        isRefreshing: Boolean,
        hasContent: Boolean,
    ): OperationalActionPresentation {
        val moduleLabel = when (module) {
            OperationalModuleKind.MONITOR -> "监控"
            OperationalModuleKind.SFTP -> "目录"
            OperationalModuleKind.DOCKER -> "容器"
        }
        val isRetry = phase == OperationalContentPhase.FAILED
        val staleMessage = if (isRetry && hasContent) {
            when (module) {
                OperationalModuleKind.MONITOR -> "操作未完成，正在显示上次成功的监控数据。"
                OperationalModuleKind.SFTP -> "操作未完成，当前目录列表仍可查看。"
                OperationalModuleKind.DOCKER -> "操作未完成，正在显示上次成功的容器列表。"
            }
        } else null
        return OperationalActionPresentation(
            refreshLabel = when {
                isRefreshing -> "刷新中…"
                isRetry -> "重试"
                else -> "刷新"
            },
            refreshContentDescription = when {
                isRefreshing -> "正在刷新$moduleLabel"
                isRetry -> "重试刷新$moduleLabel"
                else -> "刷新$moduleLabel"
            },
            refreshEnabled = !isRefreshing,
            showsRefreshProgress = isRefreshing,
            staleContentMessage = staleMessage,
        )
    }

    fun monitorSamplingLabel(isPolling: Boolean): String = if (isPolling) "暂停采样" else "恢复采样"
}
