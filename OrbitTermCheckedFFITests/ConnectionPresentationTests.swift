import XCTest

final class ConnectionPresentationTests: XCTestCase {
    private func map(lease: Bool = false, channel: Bool = false, connected: Bool = false, requiresLease: Bool = true, awaiting: Bool = false, phase: ConnectionPresentationPhase? = nil) -> ConnectionPresentation {
        ConnectionPresentationMapper.map(.init(hasVerifiedLease: lease, hasTerminalChannel: channel, isConnected: connected, requiresVerifiedLease: requiresLease, isAwaitingHostKeyDecision: awaiting, explicitPhase: phase))
    }

    func testPresentationMapsReliableConnectionInputs() {
        XCTAssertEqual(map().phase, .idle)
        XCTAssertEqual(map(phase: .connecting).phase, .connecting)
        XCTAssertEqual(map(phase: .reconnecting).phase, .reconnecting)
        XCTAssertEqual(map(awaiting: true).phase, .awaitingHostKeyDecision)
        XCTAssertEqual(map(lease: true).phase, .openingTerminal)
        XCTAssertEqual(map(lease: true, channel: true, connected: true).phase, .connected)
        XCTAssertEqual(map(phase: .blocked).phase, .blocked)
        XCTAssertEqual(map(phase: .failed).phase, .failed)
        XCTAssertEqual(map(phase: .cancelled).phase, .cancelled)
    }

    func testPresentationHasAccessibleTextAndDistinctBlockedRole() {
        let blocked = map(phase: .blocked)
        let connected = map(lease: true, channel: true, connected: true)
        XCTAssertFalse(blocked.label.isEmpty); XCTAssertFalse(blocked.systemImage.isEmpty)
        XCTAssertNotEqual(blocked.label, connected.label)
        XCTAssertEqual(blocked.semanticRole, .blocked)
    }

    func testTypedHostKeySnapshotAndAdapterPriority() {
        let blocked = ConnectionPresentationAdapter.input(.init(hasVerifiedSessionLease: true, hasTerminalChannel: true, isSessionUsable: true, isConnectOperationInProgress: true, wasConnectionLost: false, hostKey: .blocked(.changed)))
        XCTAssertEqual(ConnectionPresentationMapper.map(blocked).phase, .blocked)
        let awaiting = ConnectionPresentationAdapter.input(.init(hasVerifiedSessionLease: false, hasTerminalChannel: false, isSessionUsable: false, isConnectOperationInProgress: true, wasConnectionLost: false, hostKey: .awaitingDecision))
        XCTAssertEqual(ConnectionPresentationMapper.map(awaiting).phase, .awaitingHostKeyDecision)
        let lost = ConnectionPresentationAdapter.input(.init(hasVerifiedSessionLease: true, hasTerminalChannel: true, isSessionUsable: false, isConnectOperationInProgress: false, wasConnectionLost: true, hostKey: .none))
        XCTAssertEqual(ConnectionPresentationMapper.map(lost).phase, .disconnected)
    }

    func testCheckedSSHFactoryUsesOnlyReliableLeaseAndChannelFields() {
        XCTAssertEqual(ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: false, hasTerminalChannel: false, isSessionUsable: false).phase, .idle)
        XCTAssertEqual(ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: true, hasTerminalChannel: false, isSessionUsable: false).phase, .openingTerminal)
        XCTAssertEqual(ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: true, hasTerminalChannel: true, isSessionUsable: true).phase, .connected)
    }

    func testVisibleVocabularyAndConnectionTruthRemainStable() {
        XCTAssertEqual(map(phase: .connecting).label, "连接中")
        XCTAssertEqual(map(phase: .reconnecting).label, "重连中")
        XCTAssertEqual(map(lease: true, channel: true, connected: true, phase: .connected).label, "已连接")
        XCTAssertEqual(map(phase: .disconnected).label, "已断开")
        XCTAssertEqual(map(phase: .failed).label, "连接失败")

        // A stale typed phase must never override missing native session evidence.
        XCTAssertEqual(map(lease: true, channel: false, connected: true, phase: .connected).phase, .openingTerminal)
        XCTAssertNotEqual(map(lease: true, channel: false, connected: true, phase: .connected).label, "已连接")
        XCTAssertEqual(map(requiresLease: false, phase: .openingTerminal).label, "连接中")
        XCTAssertEqual(map(channel: true, connected: true, requiresLease: false, phase: .connected).label, "已连接")
    }

    func testSyncPresentationUsesStableHeadlineAndSeparateDetail() {
        XCTAssertEqual(SyncPresentationState.idle.headline, "等待同步")
        XCTAssertEqual(SyncPresentationState.make(.awaitingNetwork, detail: "网络恢复后自动同步").headline, "等待网络")
        XCTAssertEqual(SyncPresentationState.make(.awaitingUnlock, detail: "解锁后继续安全同步").headline, "等待解锁")
        XCTAssertEqual(SyncPresentationState.make(.syncing, detail: "正在同步加密数据").headline, "同步中")
        XCTAssertEqual(SyncPresentationState.make(.succeeded, detail: "已同步").headline, "同步完成")
        XCTAssertEqual(SyncPresentationState.make(.failed, detail: "网络不可用").headline, "同步失败")
        XCTAssertEqual(SyncPresentationState.make(.failed, detail: "网络不可用").detail, "网络不可用")
    }

    func testCompletedAssetPullDoesNotHideAuxiliarySyncFailure() {
        let complete = SyncPresentationState.afterCompletedPull(
            detail: "全部同步完成",
            auxiliaryFailureDetails: []
        )
        XCTAssertEqual(complete.phase, .succeeded)
        XCTAssertEqual(complete.detail, "全部同步完成")

        let partial = SyncPresentationState.afterCompletedPull(
            detail: "资产同步完成",
            auxiliaryFailureDetails: ["SSH 密钥库将在下次重试", "端口映射配置将在下次重试"]
        )
        XCTAssertEqual(partial.phase, .failed)
        XCTAssertEqual(partial.headline, "同步失败")
        XCTAssertEqual(partial.detail, "资产已同步；SSH 密钥库将在下次重试；端口映射配置将在下次重试")
    }

    func testSyncConflictAndRecentlyDeletedRecoveryUseSharedMobileVocabulary() {
        XCTAssertEqual(SyncConflictPresentation.title, "检测到同步冲突")
        XCTAssertEqual(SyncConflictPresentation.keepLocalLabel, "保留本地修改")
        XCTAssertEqual(SyncConflictPresentation.keepCloudLabel, "保留云端修改")

        let retainedFailure = RecentlyDeletedPresentationMapper.make(
            isLoading: false,
            itemCount: 2,
            failureDetail: "无法加载最近删除，请检查网络或登录状态。",
            isMutating: false
        )
        XCTAssertEqual(retainedFailure.phase, .failed)
        XCTAssertEqual(retainedFailure.headline, "无法加载最近删除")
        XCTAssertEqual(retainedFailure.refreshLabel, "重试")
        XCTAssertEqual(retainedFailure.staleContentMessage, "操作未完成，当前删除记录仍可查看。")
        XCTAssertTrue(retainedFailure.refreshEnabled)

        XCTAssertEqual(
            RecentlyDeletedPresentationMapper.successMessage(action: "恢复", queued: true),
            "恢复已加入后台队列，联网后自动完成。"
        )
        XCTAssertEqual(
            RecentlyDeletedPresentationMapper.successMessage(action: "永久删除", queued: false),
            "资产已永久删除。"
        )
    }

    func testSecurityOperationFeedbackAndLogoutVocabularyRemainAligned() {
        let success = SecurityOperationFeedback(
            kind: .success,
            message: SecurityOperationPresentation.loginPasswordSuccess
        )
        let failure = SecurityOperationFeedback(kind: .failure, message: "更新失败")
        let recovery = SecurityOperationFeedback(kind: .recoveryRequired, message: "需要恢复")

        XCTAssertFalse(success.isFailure)
        XCTAssertEqual(success.autoDismissAfterNanoseconds, 4_000_000_000)
        XCTAssertTrue(failure.isFailure)
        XCTAssertNil(failure.autoDismissAfterNanoseconds)
        XCTAssertTrue(recovery.isFailure)
        XCTAssertNil(recovery.autoDismissAfterNanoseconds)
        XCTAssertEqual(SecurityOperationPresentation.logoutTitle, "退出登录？")
        XCTAssertEqual(SecurityOperationPresentation.logoutConfirm, "退出登录")
        XCTAssertEqual(
            SecurityOperationPresentation.masterPasswordSuccess,
            "已完成主密码轮换；其他设备需要重新登录并使用新主密码解锁。"
        )
    }

    func testBiometricLifecycleUsesStableFailClosedVocabulary() {
        XCTAssertNil(SecurityOperationPresentation.biometricFailure(.cancelled))
        XCTAssertEqual(
            SecurityOperationPresentation.biometricFailure(.lockedOut)?.message,
            SecurityOperationPresentation.biometricLockedOut
        )
        XCTAssertEqual(
            SecurityOperationPresentation.biometricFailure(.unavailable)?.kind,
            .recoveryRequired
        )
        XCTAssertEqual(
            SecurityOperationPresentation.biometricFailure(.invalidated)?.message,
            "生物识别密钥已失效，请使用主密码解锁后重新启用。"
        )
        XCTAssertEqual(SecurityOperationPresentation.biometricBusy, "正在验证…")
    }

    func testOperationalModulesUseTheSameStableStateVocabularyAsAndroid() {
        XCTAssertEqual(OperationalContentPresentationMapper.monitor(isLoading: true, hasData: false, isPolling: true, failureDetail: nil).headline, "正在加载监控")
        XCTAssertEqual(OperationalContentPresentationMapper.monitor(isLoading: false, hasData: true, isPolling: false, failureDetail: nil).headline, "采样已暂停")
        XCTAssertEqual(OperationalContentPresentationMapper.monitor(isLoading: false, hasData: true, isPolling: true, failureDetail: "读取失败").headline, "监控读取失败")

        XCTAssertEqual(OperationalContentPresentationMapper.sftp(isLoading: true, hasItems: false, failureDetail: nil).headline, "正在加载目录")
        XCTAssertEqual(OperationalContentPresentationMapper.sftp(isLoading: false, hasItems: false, failureDetail: nil).headline, "此目录为空")
        XCTAssertEqual(OperationalContentPresentationMapper.sftp(isLoading: false, hasItems: true, failureDetail: "权限不足").headline, "SFTP 操作失败")

        XCTAssertEqual(OperationalContentPresentationMapper.docker(isLoading: true, hasContainers: false, failureDetail: nil).headline, "正在加载容器")
        XCTAssertEqual(OperationalContentPresentationMapper.docker(isLoading: false, hasContainers: false, failureDetail: nil).headline, "暂无容器")
        XCTAssertEqual(OperationalContentPresentationMapper.docker(isLoading: false, hasContainers: true, failureDetail: "连接中断").headline, "Docker 操作失败")
    }

    func testOperationalRefreshAndSamplingActionsMatchAndroid() {
        let failed = OperationalContentPresentationMapper.refreshAction(
            module: .sftp,
            phase: .failed,
            isRefreshing: false,
            hasContent: true
        )
        XCTAssertEqual(failed.refreshLabel, "重试")
        XCTAssertEqual(failed.refreshAccessibilityLabel, "重试刷新目录")
        XCTAssertEqual(failed.staleContentMessage, "操作未完成，当前目录列表仍可查看。")

        let refreshing = OperationalContentPresentationMapper.refreshAction(
            module: .docker,
            phase: .ready,
            isRefreshing: true,
            hasContent: true
        )
        XCTAssertEqual(refreshing.refreshLabel, "刷新中…")
        XCTAssertFalse(refreshing.refreshEnabled)
        XCTAssertTrue(refreshing.showsRefreshProgress)
        XCTAssertNil(refreshing.staleContentMessage)
        XCTAssertEqual(OperationalContentPresentationMapper.monitorSamplingLabel(isPolling: true), "暂停采样")
        XCTAssertEqual(OperationalContentPresentationMapper.monitorSamplingLabel(isPolling: false), "恢复采样")
        XCTAssertEqual(
            OperationalFeedbackPolicy.lifetime(kind: .success).autoDismissAfterNanoseconds,
            4_000_000_000
        )
        XCTAssertNil(OperationalFeedbackPolicy.lifetime(kind: .failure).autoDismissAfterNanoseconds)
    }

#if os(macOS)
    func testRemoteDesktopPresentationDoesNotRequireAnSSHLeaseOrTerminalChannel() {
        XCTAssertEqual(
            ConnectionPresentationAdapter.remoteDesktop(phase: .connected).phase,
            .connected
        )
        XCTAssertEqual(
            ConnectionPresentationAdapter.remoteDesktop(phase: .awaitingUserDecision).label,
            "等待确认远程桌面证书"
        )
        XCTAssertEqual(
            ConnectionPresentationAdapter.remoteDesktop(phase: .failed).semanticRole,
            .danger
        )
    }
#endif
}
