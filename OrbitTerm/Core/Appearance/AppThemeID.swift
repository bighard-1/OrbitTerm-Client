import SwiftUI

enum AppThemeID: String, CaseIterable, Identifiable, Codable {
    case skyCandy = "sky-candy"
    case emeraldFlow = "emerald-flow"
    case peachDawn = "peach-dawn"
    case lavenderMist = "lavender-mist"
    case glacierMint = "glacier-mint"

    static let defaultTheme: AppThemeID = .emeraldFlow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .skyCandy: "天空糖果"
        case .emeraldFlow: "翡翠流光"
        case .peachDawn: "蜜桃晨光"
        case .lavenderMist: "薰衣草雾"
        case .glacierMint: "冰川薄荷"
        }
    }

    var themeDescription: String {
        switch self {
        case .skyCandy: "清透蓝天与糖果感高光"
        case .emeraldFlow: "沉稳翡翠与克制流光"
        case .peachDawn: "柔和蜜桃与晨曦暖意"
        case .lavenderMist: "安静薰衣草与雾面层次"
        case .glacierMint: "冰川青绿与清爽留白"
        }
    }

    static func resolved(_ rawValue: String?) -> AppThemeID {
        rawValue.flatMap(AppThemeID.init(rawValue:)) ?? defaultTheme
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolved(_ rawValue: String?) -> AppearanceMode {
        rawValue.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}
