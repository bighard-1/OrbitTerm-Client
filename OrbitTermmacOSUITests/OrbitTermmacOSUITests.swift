import XCTest

final class OrbitTermmacOSUITests: XCTestCase {
    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ORBITTERM_UI_TEST_STATE"] = state
        app.launchArguments = ["-orbitTermUITest", "-orbitTermUITestState", state]
        app.launch()
        return app
    }

    func testWindowLaunchShowsAuthenticationRootForSignedOutAccount() {
        let app = launch("unauthenticated")
        XCTAssertTrue(app.staticTexts["OrbitTerm"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["添加服务器"].exists)
    }

    func testWindowLaunchShowsLockedRootForAuthenticatedAccount() {
        let app = launch("authenticated_locked")
        XCTAssertTrue(app.staticTexts["设置主密码"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["添加服务器"].exists)
    }

    func testWindowLaunchShowsWorkspaceForUnlockedAccount() {
        let app = launch("authenticated_unlocked")
        XCTAssertTrue(app.buttons["添加服务器"].waitForExistence(timeout: 5))
    }

    func testCriticalWindowRootsExposeReadableAccessibilityLabels() {
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
        let addServer = workspace.buttons["添加服务器"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        XCTAssertFalse(addServer.label.isEmpty)
    }

    func testAuthenticationAndMasterPasswordInputsExposeSecureControls() {
        let auth = launch("unauthenticated")
        XCTAssertTrue(auth.buttons["注册"].waitForExistence(timeout: 5))
        auth.buttons["注册"].tap()
        XCTAssertTrue(auth.buttons["注册并登录"].waitForExistence(timeout: 5))
        XCTAssertTrue(auth.textFields["邮箱账号"].waitForExistence(timeout: 5))
        XCTAssertTrue(auth.secureTextFields["密码"].waitForExistence(timeout: 5))
        auth.terminate()

        let locked = launch("authenticated_locked")
        let masterPassword = locked.secureTextFields["主密码"]
        XCTAssertTrue(masterPassword.waitForExistence(timeout: 5))
        XCTAssertEqual(masterPassword.placeholderValue, "主密码")
        XCTAssertTrue(locked.secureTextFields["确认主密码"].exists)
    }
}
