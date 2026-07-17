import XCTest

@MainActor
final class TerminalThemeIsolationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "OrbitTerm.TerminalThemeIsolationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testApplicationThemeNeverWritesTerminalThemePreference() {
        XCTAssertNotEqual(AppThemeManager.themeStorageKey, TerminalThemeManager.storageKey)
        for appTheme in AppThemeID.allCases {
            defaults.set("nord", forKey: TerminalThemeManager.storageKey)
            let manager = AppThemeManager(userDefaults: defaults)
            manager.selectTheme(appTheme)
            XCTAssertEqual(defaults.string(forKey: TerminalThemeManager.storageKey), "nord")
            XCTAssertEqual(defaults.string(forKey: AppThemeManager.themeStorageKey), appTheme.rawValue)
        }
    }

    func testApplicationThemeSwitchesDoNotChangeProductionTerminalPalettes() {
        let baselines = TerminalThemeManager.presets.map { TerminalThemeManager.theme(for: $0.id) }
        let manager = AppThemeManager(userDefaults: defaults)
        for appTheme in AppThemeID.allCases {
            manager.selectTheme(appTheme)
            for baseline in baselines {
                let current = TerminalThemeManager.theme(for: baseline.id)
                XCTAssertEqual(current.id, baseline.id)
                XCTAssertEqual(current.name, baseline.name)
                XCTAssertEqual(current.background, baseline.background)
                XCTAssertEqual(current.foreground, baseline.foreground)
                XCTAssertEqual(current.ansi16.count, baseline.ansi16.count)
                XCTAssertEqual(current.ansi16, baseline.ansi16)
            }
        }
    }

    func testProductionTerminalCatalogRemainsStable() {
        XCTAssertEqual(TerminalThemeManager.presets.count, 4)
        XCTAssertEqual(TerminalThemeManager.presets.map(\.id), ["dracula", "solarized-dark", "nord", "homebrew"])
        XCTAssertTrue(TerminalThemeManager.presets.allSatisfy { $0.ansi16.count == 16 })
        XCTAssertEqual(TerminalThemeManager.theme(for: "invalid-theme-id").id, TerminalThemeManager.presets[0].id)
    }

    func testEveryProductionThemeKeepsReadableDefaultTextWithoutUsingAppThemeTokens() {
        for theme in TerminalThemeManager.presets {
            XCTAssertTrue(
                TerminalThemeReadability.hasReadableDefaultText(theme),
                "\(theme.name) default terminal foreground must remain readable against its own background"
            )
        }
    }
}
