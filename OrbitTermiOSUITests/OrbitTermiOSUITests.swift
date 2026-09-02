import XCTest

final class OrbitTermiOSUITests: XCTestCase {
    /// iPad's floating tab bar exposes a legacy and a modern accessibility
    /// representation for the same visible item. The first match is the
    /// interactive control; using the collection directly is ambiguous.
    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    private func launch(_ state: String, usesLargestAccessibilityText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ORBITTERM_UI_TEST_STATE"] = state
        app.launchArguments = ["-orbitTermUITest", "-orbitTermUITestState", state]
        if usesLargestAccessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    func testUnauthenticatedLaunchShowsAuthenticationRoot() {
        let app = launch("unauthenticated")
        XCTAssertTrue(app.staticTexts["OrbitTerm"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["服务器"].exists)
    }

    func testLockedLaunchShowsMasterPasswordRootWithoutWorkspace() {
        let app = launch("authenticated_locked")
        XCTAssertTrue(app.staticTexts["设置主密码"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["还没有服务器"].exists)
    }

    func testUnlockedLaunchShowsWorkspaceRoot() {
        let app = launch("authenticated_unlocked")
        XCTAssertTrue(app.staticTexts["还没有服务器"].waitForExistence(timeout: 5))
    }

    func testUnlockedLaunchNavigatesAcrossSafeWorkspaceTabs() {
        let app = launch("authenticated_unlocked")

        XCTAssertTrue(tabButton("会话", in: app).waitForExistence(timeout: 5))
        tabButton("会话", in: app).tap()
        XCTAssertTrue(app.staticTexts["暂无活动会话"].waitForExistence(timeout: 5))

        let returnToServers = app.buttons["返回服务器"]
        XCTAssertTrue(returnToServers.waitForExistence(timeout: 5))
        XCTAssertFalse(returnToServers.label.isEmpty)
        returnToServers.tap()
        XCTAssertTrue(app.staticTexts["还没有服务器"].waitForExistence(timeout: 5))

        tabButton("会话", in: app).tap()
        XCTAssertTrue(app.staticTexts["暂无活动会话"].waitForExistence(timeout: 5))

        tabButton("SFTP", in: app).tap()
        XCTAssertTrue(app.navigationBars["SFTP"].waitForExistence(timeout: 5))

        tabButton("Docker", in: app).tap()
        XCTAssertTrue(app.navigationBars["Docker 管理"].waitForExistence(timeout: 5))

        tabButton("个人中心", in: app).tap()
        XCTAssertTrue(app.navigationBars["个人中心"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["账户与安全"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["运维工具"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["帮助与信息"].waitForExistence(timeout: 5))
    }

    func testCriticalRootsAndTabsExposeReadableAccessibilityLabels() {
        let signedOut = launch("unauthenticated")
        let productName = signedOut.staticTexts["OrbitTerm"]
        XCTAssertTrue(productName.waitForExistence(timeout: 5))
        XCTAssertFalse(productName.label.isEmpty)
        signedOut.terminate()

        let locked = launch("authenticated_locked")
        let masterPassword = locked.staticTexts["设置主密码"]
        XCTAssertTrue(masterPassword.waitForExistence(timeout: 5))
        XCTAssertFalse(masterPassword.label.isEmpty)
        locked.terminate()

        let workspace = launch("authenticated_unlocked")
        for title in ["服务器", "会话", "SFTP", "Docker", "个人中心"] {
            let tab = tabButton(title, in: workspace)
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "缺少可访问的 \(title) 导航控件")
            XCTAssertFalse(tab.label.isEmpty, "\(title) 导航控件缺少可访问名称")
        }
    }

    func testAuthenticationAndMasterPasswordInputsAreAccessibleWithoutCredentials() {
        let auth = launch("unauthenticated")
        let register = auth.buttons["注册"]
        XCTAssertTrue(register.waitForExistence(timeout: 5))
        XCTAssertFalse(register.label.isEmpty)
        register.tap()

        XCTAssertTrue(auth.buttons["注册并登录"].waitForExistence(timeout: 5))
        XCTAssertTrue(auth.textFields["邮箱账号"].waitForExistence(timeout: 5))
        XCTAssertTrue(auth.secureTextFields["密码"].waitForExistence(timeout: 5))
        XCTAssertTrue(auth.textFields["管理员提供的邀请码"].waitForExistence(timeout: 5))
        auth.terminate()

        let locked = launch("authenticated_locked")
        let masterPassword = locked.secureTextFields["主密码"]
        XCTAssertTrue(masterPassword.waitForExistence(timeout: 5))
        XCTAssertEqual(masterPassword.placeholderValue, "主密码")
        XCTAssertTrue(locked.secureTextFields["确认主密码"].exists)
        XCTAssertTrue(locked.buttons["保存并解锁"].exists)
    }

    func testAuthenticationAndMasterPasswordFormsRemainSeparatelyReachableAtLargestTextSize() {
        let auth = launch("unauthenticated", usesLargestAccessibilityText: true)
        let email = auth.textFields["邮箱账号"]
        let password = auth.secureTextFields["密码"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(email.frame.height, 0)
        XCTAssertGreaterThan(password.frame.height, 0)
        XCTAssertLessThanOrEqual(email.frame.maxY, password.frame.minY, "最大辅助字号下，账户与密码输入框不得重叠")
        auth.terminate()

        let locked = launch("authenticated_locked", usesLargestAccessibilityText: true)
        let masterPassword = locked.secureTextFields["主密码"]
        let confirmation = locked.secureTextFields["确认主密码"]
        XCTAssertTrue(masterPassword.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(masterPassword.frame.maxY, confirmation.frame.minY, "最大辅助字号下，主密码输入框不得重叠")
        XCTAssertTrue(locked.buttons["保存并解锁"].isHittable)
    }

    func testOperationalFailuresExposeRetryRetainedContentAndTransientSuccessLifetime() {
        let app = launch("operational_states")
        XCTAssertTrue(app.navigationBars["操作状态回归"].waitForExistence(timeout: 5))

        // The success contract is intentionally short lived. Capture it before
        // the exhaustive failure-state assertions consume that four-second window.
        let success = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "容器操作已完成。")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 2))

        for title in ["监控读取失败", "SFTP 操作失败", "Docker 操作失败"] {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        }
        for retryLabel in ["重试刷新监控", "重试刷新目录", "重试刷新容器"] {
            let retry = app.buttons[retryLabel]
            XCTAssertTrue(retry.waitForExistence(timeout: 5), "缺少 \(retryLabel)")
            XCTAssertTrue(retry.isEnabled)
        }
        for retained in [
            "操作未完成，正在显示上次成功的监控数据。",
            "操作未完成，当前目录列表仍可查看。",
            "操作未完成，正在显示上次成功的容器列表。"
        ] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", retained)).firstMatch.waitForExistence(timeout: 5))
        }

        let busy = app.buttons["正在刷新监控"]
        XCTAssertTrue(busy.waitForExistence(timeout: 5))
        XCTAssertFalse(busy.isEnabled)
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: success
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 6), .completed)
        XCTAssertTrue(app.staticTexts["监控读取失败"].exists, "失败提示不得自动消失")
    }

    func testSyncRecoveryStatesExposeParityActionsAndTransientQueueFeedback() {
        let app = launch("sync_recovery_states")
        XCTAssertTrue(app.navigationBars["同步与恢复状态回归"].waitForExistence(timeout: 5))

        let queued = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "恢复已加入后台队列，联网后自动完成。")
        ).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 2))

        for message in [
            "等待网络：网络恢复后自动同步",
            "等待解锁：解锁后继续安全同步",
            "同步失败：资产已同步；1 项等待网络恢复后重试",
            "无法加载最近删除，请检查网络或登录状态。 操作未完成，当前删除记录仍可查看。"
        ] {
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch.waitForExistence(timeout: 5),
                "缺少状态：\(message)"
            )
        }
        for action in ["重试同步", "保留本地修改", "保留云端修改", "重试最近删除"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "缺少操作：\(action)")
        }
        XCTAssertTrue(app.staticTexts["检测到同步冲突"].waitForExistence(timeout: 5))

        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: queued
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 6), .completed)
        XCTAssertTrue(app.buttons["重试同步"].exists, "失败恢复操作不得自动消失")
    }

    func testAccountSecurityStatesKeepRecoveryVisibleAndConfirmLogout() {
        let loginSuccessMessage = "已更新登录密码；其他设备需要重新登录。"
        let loginBusyLabel = "正在更新登录密码…"
        let masterBusyLabel = "正在轮换主密码…"
        let biometricBusyLabel = "正在验证…"
        let biometricRecoveryMessage = "生物识别密钥已失效，请使用主密码解锁后重新启用。"
        let logoutLabel = "退出登录"
        let logoutTitle = "退出登录？"
        let app = launch("account_security_states")
        XCTAssertTrue(app.navigationBars["账户安全状态回归"].waitForExistence(timeout: 5))

        let success = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", loginSuccessMessage)
        ).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 2))

        let recovery = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "云端主密码已轮换，但本机更新待完成；请勿退出应用并重试。")
        ).firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        let biometricRecovery = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", biometricRecoveryMessage)
        ).firstMatch
        XCTAssertTrue(biometricRecovery.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[loginBusyLabel].isEnabled)
        XCTAssertFalse(app.buttons[masterBusyLabel].isEnabled)
        XCTAssertFalse(app.buttons[biometricBusyLabel].isEnabled)

        app.buttons[logoutLabel].firstMatch.tap()
        XCTAssertTrue(app.alerts[logoutTitle].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.buttons["取消"].exists)
        app.alerts.buttons["取消"].tap()

        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: success
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 6), .completed)
        XCTAssertTrue(recovery.exists, "主密码恢复提示不得自动消失")
        XCTAssertTrue(biometricRecovery.exists, "生物识别失效提示不得自动消失")
    }

    /// Device metrics are exported by XCTest into the `.xcresult` bundle. The
    /// signed release lane retains that bundle as private evidence; this test
    /// has no account, Keychain or network dependency.
    func testUnlockedWorkspaceLaunchProducesDeviceMetrics() {
        let metrics: [XCTMetric] = [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]

        measure(metrics: metrics) {
            let app = launch("authenticated_unlocked")
            XCTAssertTrue(app.staticTexts["还没有服务器"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
}
