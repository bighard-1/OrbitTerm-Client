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
