import XCTest

final class TerminalCustomKeyEditorUITests: XCTestCase {
    private func launch(largeText: Bool = false, failWrite: Bool = false, conflict: Bool = false, corrupt: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-orbitTermUITest", "-orbitTermUITestState", "terminal_custom_keys"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if failWrite { app.launchArguments += ["-orbitTermUITestKeyWriteFailure"] }
        if conflict { app.launchArguments += ["-orbitTermUITestKeyConflict"] }
        if corrupt { app.launchArguments += ["-orbitTermUITestKeyCorrupt"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["自定义按键"].waitForExistence(timeout: 8))
        // Lists virtualize off-screen rows at accessibility sizes; the layout
        // test below scrolls before asserting that the add action is reachable.
        return app
    }

    func testCorruptLibraryOffersOnlyReadOnlyRescueAndNeverImportOrReset() {
        let app = launch(corrupt: true)
        XCTAssertFalse(app.buttons["terminal.customKeys.recovery"].exists)
        app.buttons["terminal.customKeys.rescue"].tap()
        XCTAssertTrue(app.navigationBars["原始配置加密救援"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["选择恢复文件"].exists)
        XCTAssertFalse(app.buttons["terminal.recovery.preview"].exists)
        XCTAssertFalse(app.buttons["terminal.recovery.commit"].exists)
        XCTAssertFalse(app.buttons["terminal.recovery.export"].isEnabled)
        XCTAssertTrue(app.buttons["选择救援文件"].exists)
        XCTAssertFalse(app.buttons["terminal.rescue.inspect"].isEnabled)
        app.buttons["关闭"].tap()
        app.buttons["重试读取"].tap()
        XCTAssertTrue(app.buttons["terminal.customKeys.rescue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["terminal.customKeys.add.common"].exists)
    }

    func testRecoveryRequiresIndependentConfirmedPasswordAndPickerCancellationDoesNotWrite() {
        let app = launch()
        app.buttons["terminal.customKeys.recovery"].tap()
        let export = app.buttons["terminal.recovery.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertFalse(export.isEnabled)
        let password = app.secureTextFields["terminal.recovery.password"]
        password.tap(); password.typeText("test-only-12345")
        XCTAssertFalse(export.isEnabled)
        let confirm = app.secureTextFields["terminal.recovery.confirmPassword"]
        confirm.tap(); confirm.typeText("test-only-12345")
        XCTAssertTrue(export.isEnabled)
        // Opening Files does not grant permission to import or commit anything.
        let picker = app.buttons["选择恢复文件"]
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        picker.tap()
        // Files uses the simulator's system language, not the app's Chinese copy.
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertFalse(app.buttons["terminal.recovery.commit"].exists)
        XCTAssertFalse(app.buttons["terminal.recovery.preview"].isEnabled)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["terminal.customKeys.recovery"].waitForExistence(timeout: 5))
    }

    func testConflictRequiresChoiceAndConfirmationBeforeKeepingVersion() {
        let app = launch(conflict: true)
        XCTAssertFalse(app.buttons["编辑按键：ConflictKey"].exists)
        app.buttons["terminal.customKeys.conflict.11111111-1111-1111-1111-111111111111"].tap()
        let apply = app.buttons["terminal.customKeys.resolveApply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        app.buttons["terminal.customKeys.keep.0"].tap()
        apply.tap()
        XCTAssertTrue(app.alerts["确认处理冲突？"].waitForExistence(timeout: 3))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(apply.exists)
        apply.tap()
        app.alerts.buttons["确认保留"].tap()
        XCTAssertTrue(app.buttons["编辑按键：ConflictKey"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["terminal.customKeys.conflict.11111111-1111-1111-1111-111111111111"].exists)
    }

    func testConflictDeleteAndReadRetryKeepDeterministicState() {
        let app = launch(conflict: true)
        app.buttons["terminal.customKeys.conflict.11111111-1111-1111-1111-111111111111"].tap()
        let delete = app.buttons["terminal.customKeys.resolveDelete"]
        for _ in 0..<4 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        app.buttons["terminal.customKeys.resolveApply"].tap()
        app.alerts.buttons["确认删除"].tap()
        XCTAssertTrue(app.buttons["terminal.customKeys.add.common"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["编辑按键：ConflictKey"].exists)
        app.buttons["重试读取"].tap()
        XCTAssertFalse(app.buttons["terminal.customKeys.conflict.11111111-1111-1111-1111-111111111111"].exists)
    }

    func testFailedConflictResolutionKeepsVersionsAndCanRetryRead() {
        let app = launch(failWrite: true, conflict: true)
        let row = app.buttons["terminal.customKeys.conflict.11111111-1111-1111-1111-111111111111"]
        row.tap()
        app.buttons["terminal.customKeys.keep.0"].tap()
        app.buttons["terminal.customKeys.resolveApply"].tap()
        app.alerts.buttons["确认保留"].tap()
        XCTAssertFalse(app.buttons["terminal.customKeys.resolveApply"].isEnabled)
        app.buttons["取消"].tap()
        app.buttons["重试读取"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["编辑按键：ConflictKey"].exists)
    }

    func testAddEditCancelDeleteAndUndoWithoutSendingTerminalInput() {
        let app = launch()
        app.buttons["terminal.customKeys.add.common"].tap()
        let name = app.textFields["terminal.customKeys.label"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("CtrlR")
        // SwiftUI's vertical TextField has different legacy/modern AX types on
        // iOS 26. Match its stable identifier instead of assuming UITextView.
        let payload = app.descendants(matching: .any)["terminal.customKeys.payload"].firstMatch
        XCTAssertTrue(payload.waitForExistence(timeout: 5))
        payload.tap(); payload.typeText("\\x12")
        app.buttons["terminal.customKeys.save"].tap()
        let row = app.buttons["编辑按键：CtrlR"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertEqual(app.descendants(matching: .any)["terminal.customKeys.payload"].firstMatch.value as? String, "\\x12")
        app.buttons["取消"].tap()
        row.swipeLeft()
        app.buttons["删除"].tap()
        XCTAssertFalse(row.exists)
        app.buttons["terminal.customKeys.undo"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testInvalidDraftStaysOpenAndReturnPayloadWarns() {
        let app = launch()
        app.buttons["terminal.customKeys.add.common"].tap()
        app.buttons["terminal.customKeys.save"].tap()
        XCTAssertTrue(app.staticTexts["terminal.customKeys.error"].waitForExistence(timeout: 5))
        let name = app.textFields["terminal.customKeys.label"]
        name.tap(); name.typeText("Enter")
        let payload = app.descendants(matching: .any)["terminal.customKeys.payload"].firstMatch
        payload.tap(); payload.typeText("\\r")
        XCTAssertTrue(app.staticTexts["terminal.customKeys.returnWarning"].exists)
        XCTAssertEqual(name.value as? String, "Enter")
        app.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["编辑按键：Enter"].exists)
    }

    func testLargestAccessibilityTextRetainsAddAndEditorControls() {
        let app = launch(largeText: true)
        let add = app.buttons["terminal.customKeys.add.common"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(app.textFields["terminal.customKeys.label"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["terminal.customKeys.save"].isHittable)
        XCTAssertTrue(app.buttons["取消"].isHittable)
    }

    func testWriteFailureKeepsDraftAndBlocksDuplicateSubmit() {
        let app = launch(failWrite: true)
        app.buttons["terminal.customKeys.add.common"].tap()
        let name = app.textFields["terminal.customKeys.label"]
        name.tap(); name.typeText("Retained")
        let payload = app.descendants(matching: .any)["terminal.customKeys.payload"].firstMatch
        payload.tap(); payload.typeText("\\t")
        app.buttons["terminal.customKeys.save"].tap()
        XCTAssertTrue(app.staticTexts["terminal.customKeys.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Retained")
        XCTAssertEqual(payload.value as? String, "\\t")
        XCTAssertFalse(app.buttons["terminal.customKeys.save"].isEnabled)
    }
}
