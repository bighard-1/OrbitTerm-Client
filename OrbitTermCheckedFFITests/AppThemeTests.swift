import XCTest
import SwiftUI

@MainActor
final class AppThemeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "AppThemeTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
        defaults = nil
    }

    func testThemeIDsAreCompleteAndRecoverFromUnknownStorage() {
        XCTAssertEqual(AppThemeID.allCases.count, 5)
        XCTAssertEqual(Set(AppThemeID.allCases.map(\.rawValue)), Set(["sky-candy", "emerald-flow", "peach-dawn", "lavender-mist", "glacier-mint"]))
        XCTAssertEqual(AppThemeID.resolved("unknown"), .emeraldFlow)
        XCTAssertTrue(AppThemeID.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    func testThemePersistenceAndModePersistence() {
        let manager = AppThemeManager(userDefaults: defaults)
        manager.selectTheme(.lavenderMist)
        manager.selectMode(.dark)
        XCTAssertEqual(defaults.string(forKey: AppThemeManager.themeStorageKey), "lavender-mist")
        XCTAssertEqual(AppThemeManager(userDefaults: defaults).selectedTheme, .lavenderMist)
        XCTAssertEqual(AppThemeManager(userDefaults: defaults).appearanceMode, .dark)
    }

    func testInvalidStoredValuesFallBackWithoutClearingAppearance() {
        defaults.set("old-theme", forKey: AppThemeManager.themeStorageKey)
        defaults.set("bad-mode", forKey: AppThemeManager.modeStorageKey)
        let manager = AppThemeManager(userDefaults: defaults)
        XCTAssertEqual(manager.selectedTheme, .emeraldFlow)
        XCTAssertEqual(manager.appearanceMode, .system)
    }

    func testSecurityIsIndependentAndAccessible() {
        let security = SecuritySemanticPalette()
        XCTAssertEqual(security.connectionBlocked, security.danger)
        for theme in AppThemeID.allCases {
            let palette = AppThemePalette.make(theme: theme, colorScheme: .light)
            XCTAssertNotEqual(security.danger, palette.accentPrimary)
            XCTAssertGreaterThanOrEqual(palette.textPrimary.contrastRatio(with: palette.surfaceReadable), 4.5)
            XCTAssertGreaterThanOrEqual(palette.textOnAccent.contrastRatio(with: palette.accentPrimary), 4.5)
        }
        XCTAssertFalse(security.presentation(for: .danger).symbol.isEmpty)
        XCTAssertFalse(security.presentation(for: .danger).label.isEmpty)
    }

    func testThemeTokensTintChromeSurfacesWithoutChangingSecurityRoles() {
        let security = SecuritySemanticPalette()

        for scheme in [ColorScheme.light, .dark] {
            let palettes = AppThemeID.allCases.map {
                AppThemePalette.make(theme: $0, colorScheme: scheme)
            }

            XCTAssertEqual(Set(palettes.map(\.pageBackground)).count, AppThemeID.allCases.count)
            XCTAssertEqual(Set(palettes.map(\.surfaceReadable)).count, AppThemeID.allCases.count)
            XCTAssertEqual(Set(palettes.map(\.surfaceInput)).count, AppThemeID.allCases.count)
            XCTAssertEqual(Set(palettes.map(\.borderGlass)).count, AppThemeID.allCases.count)
            XCTAssertTrue(palettes.allSatisfy {
                $0.textPrimary.contrastRatio(with: $0.surfaceReadable) >= 4.5
            })
            XCTAssertTrue(palettes.allSatisfy {
                $0.surfaceGlass.opacity == 1 && $0.surfaceGlassStrong.opacity == 1
            })
        }

        XCTAssertEqual(security.connectionBlocked, security.danger)
        XCTAssertEqual(security.presentation(for: .warning).color, security.warning)
        XCTAssertEqual(security.presentation(for: .danger).color, security.danger)
    }

    func testApplicationStorageIsNeverTerminalStorage() {
        let terminalStorageKey = "orbitterm.terminal.theme.id"
        XCTAssertNotEqual(AppThemeManager.themeStorageKey, terminalStorageKey)
        XCTAssertEqual(AppThemeManager.themeStorageKey, "orbitterm.appearance.theme.id")
        XCTAssertEqual(terminalStorageKey, "orbitterm.terminal.theme.id")
    }

#if os(macOS)
    func testWorkstationShortcutPreferencesPersistAndRejectUnsafeConflicts() {
        let shortcutDefaults = UserDefaults(suiteName: "WorkstationShortcutPreferencesTests.\(UUID().uuidString)")!
        defer { shortcutDefaults.removePersistentDomain(forName: shortcutDefaults.volatileDomainNames.first ?? "") }
        let preferences = WorkstationShortcutPreferences(defaults: shortcutDefaults)

        XCTAssertEqual(
            WorkstationShortcutAction.allCases.map(preferences.shortcut(for:)).count,
            WorkstationShortcutAction.allCases.count
        )
        XCTAssertEqual(preferences.assign(.command("g", shift: true), to: .focusServerSearch), .accepted)
        XCTAssertEqual(preferences.shortcut(for: .focusServerSearch), .command("g", shift: true))
        XCTAssertEqual(
            WorkstationShortcutPreferences(defaults: shortcutDefaults).shortcut(for: .focusServerSearch),
            .command("g", shift: true)
        )
        XCTAssertEqual(preferences.assign(.command("n"), to: .newTab), .duplicate(.addServer))
        XCTAssertEqual(preferences.assign(.command("q"), to: .newTab), .reserved)
        preferences.reset(.focusServerSearch)
        XCTAssertEqual(preferences.shortcut(for: .focusServerSearch), .command("k"))
    }
#endif

    func testSFTPTransferSemanticsRemainIndependentFromAppTheme() {
        XCTAssertEqual(SFTPTransferSemanticRole.inProgress.securityKind, .information)
        XCTAssertEqual(SFTPTransferSemanticRole.success.securityKind, .success)
        XCTAssertEqual(SFTPTransferSemanticRole.warning.securityKind, .warning)
        XCTAssertEqual(SFTPTransferSemanticRole.failure.securityKind, .danger)
        XCTAssertNil(SFTPTransferSemanticRole.cancelled.securityKind)
        XCTAssertEqual(SFTPTransferSemanticRole.transferState(isDone: false, progress: 0.4), .inProgress)
        XCTAssertEqual(SFTPTransferSemanticRole.transferState(isDone: true, progress: 1), .success)
        XCTAssertEqual(SFTPTransferSemanticRole.transferState(isDone: true, progress: 0), .failure)

        let security = SecuritySemanticPalette()
        let reference = AppThemePalette.make(theme: .skyCandy, colorScheme: .light)
        XCTAssertEqual(
            SFTPTransferSemanticRole.failure.themeColor(in: security, fallback: reference),
            security.danger
        )
        XCTAssertEqual(
            SFTPTransferSemanticRole.cancelled.themeColor(in: security, fallback: reference),
            reference.textSecondary
        )
        XCTAssertNotEqual(
            AppThemePalette.make(theme: .skyCandy, colorScheme: .light).accentPrimary,
            AppThemePalette.make(theme: .emeraldFlow, colorScheme: .light).accentPrimary
        )
    }

    func testDockerPresentationSemanticsRemainIndependentFromAppTheme() {
        XCTAssertEqual(DockerContainerPresentationState.resolve(isRunning: true), .running)
        XCTAssertEqual(DockerContainerPresentationState.resolve(isRunning: false), .stopped)
        XCTAssertEqual(DockerContainerPresentationState.running.securityKind, .success)
        XCTAssertNil(DockerContainerPresentationState.stopped.securityKind)
        XCTAssertEqual(DockerConnectionPresentationState.connecting.securityKind, .information)
        XCTAssertEqual(DockerConnectionPresentationState.unavailable.securityKind, .warning)
        XCTAssertEqual(DockerConnectionPresentationState.connected.securityKind, .success)
        XCTAssertNil(DockerConnectionPresentationState.disconnected.securityKind)

        let security = SecuritySemanticPalette()
        for theme in AppThemeID.allCases {
            let palette = AppThemePalette.make(theme: theme, colorScheme: .dark)
            XCTAssertEqual(
                DockerContainerPresentationState.running.themeColor(in: security, fallback: palette),
                security.success
            )
            XCTAssertEqual(
                DockerConnectionPresentationState.unavailable.themeColor(in: security, fallback: palette),
                security.warning
            )
            XCTAssertEqual(
                DockerContainerPresentationState.stopped.themeColor(in: security, fallback: palette),
                palette.textSecondary
            )
        }
    }

    func testDockerPausedPresentationRetainsIndependentWarningSemantics() {
        XCTAssertEqual(DockerContainerPresentationState.resolve(isRunning: true, isPaused: false), .running)
        XCTAssertEqual(DockerContainerPresentationState.resolve(isRunning: false, isPaused: true), .paused)
        XCTAssertEqual(DockerContainerPresentationState.paused.securityKind, .warning)
        XCTAssertEqual(DockerContainerPresentationState.paused.label, "已暂停")
        XCTAssertEqual(DockerContainerPresentationState.resolve(isRunning: false, isPaused: false), .stopped)
    }

    func testMonitorPresentationSemanticsPreserveExistingCPUZones() {
        XCTAssertEqual(MonitorMetricPresentationLevel.existingCPUZone("normal"), .normal)
        XCTAssertEqual(MonitorMetricPresentationLevel.existingCPUZone("warning"), .warning)
        XCTAssertEqual(MonitorMetricPresentationLevel.existingCPUZone("alert"), .critical)
        XCTAssertEqual(MonitorMetricPresentationLevel.warning.securityKind, .warning)
        XCTAssertEqual(MonitorMetricPresentationLevel.critical.securityKind, .danger)
        XCTAssertNil(MonitorMetricPresentationLevel.normal.securityKind)

        let security = SecuritySemanticPalette()
        for theme in AppThemeID.allCases {
            let palette = AppThemePalette.make(theme: theme, colorScheme: .light)
            XCTAssertEqual(MonitorMetricPresentationLevel.warning.themeColor(in: security, fallback: palette), security.warning)
            XCTAssertEqual(MonitorMetricPresentationLevel.critical.themeColor(in: security, fallback: palette), security.danger)
            XCTAssertEqual(MonitorMetricPresentationLevel.unavailable.themeColor(in: security, fallback: palette), palette.textSecondary)
        }
    }

    func testAssetConnectionTestPresentationUsesTypedBooleansAndSecuritySemantics() {
        XCTAssertEqual(AssetConnectionTestPresentation.resolve(isTesting: false, isVerified: false), .idle)
        XCTAssertEqual(AssetConnectionTestPresentation.resolve(isTesting: true, isVerified: true), .testing)
        XCTAssertEqual(AssetConnectionTestPresentation.resolve(isTesting: false, isVerified: true), .verified)
        XCTAssertEqual(AssetConnectionTestPresentation.testing.securityKind, .information)
        XCTAssertEqual(AssetConnectionTestPresentation.verified.securityKind, .success)
        XCTAssertNil(AssetConnectionTestPresentation.idle.securityKind)

        let security = SecuritySemanticPalette()
        for theme in AppThemeID.allCases {
            let palette = AppThemePalette.make(theme: theme, colorScheme: .light)
            XCTAssertEqual(
                AssetConnectionTestPresentation.testing.themeColor(in: security, fallback: palette),
                security.information
            )
            XCTAssertEqual(
                AssetConnectionTestPresentation.verified.themeColor(in: security, fallback: palette),
                security.success
            )
            XCTAssertEqual(
                AssetConnectionTestPresentation.idle.themeColor(in: security, fallback: palette),
                palette.textSecondary
            )
        }
    }

    func testAccessibilityPresentationKeepsThemeAndSecurityResponsibilitiesSeparate() {
        XCTAssertEqual(AppAccessibilityPresentation.borderWidth(for: .standard), 1)
        XCTAssertEqual(AppAccessibilityPresentation.borderWidth(for: .increased), 2)
        XCTAssertFalse(AppAccessibilityPresentation.usesOpaqueSurface(reduceTransparency: false))
        XCTAssertTrue(AppAccessibilityPresentation.usesOpaqueSurface(reduceTransparency: true))
        XCTAssertTrue(AppAccessibilityPresentation.usesDecorativeMotion(reduceMotion: false))
        XCTAssertFalse(AppAccessibilityPresentation.usesDecorativeMotion(reduceMotion: true))
        XCTAssertFalse(AppAccessibilityPresentation.needsNonColorStatusAffordance(differentiateWithoutColor: false))
        XCTAssertTrue(AppAccessibilityPresentation.needsNonColorStatusAffordance(differentiateWithoutColor: true))

        let security = SecuritySemanticPalette()
        for theme in AppThemeID.allCases {
            let palette = AppThemePalette.make(theme: theme, colorScheme: .dark)
            XCTAssertNotEqual(palette.textPrimary, palette.surfaceReadable)
            XCTAssertNotEqual(palette.focusRing, palette.surfaceInput)
            XCTAssertEqual(security.presentation(for: .success).label, "成功")
            XCTAssertEqual(security.presentation(for: .warning).label, "注意")
            XCTAssertEqual(security.presentation(for: .danger).label, "错误")
            XCTAssertEqual(security.presentation(for: .information).label, "提示")
        }
    }
}
