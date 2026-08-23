package com.orbitterm.android.domain.settings

import kotlinx.coroutines.flow.Flow
import com.orbitterm.android.domain.performance.RuntimeResourceBudget

enum class AppThemePreference {
    System,
    Light,
    Dark,
}

/** Shared with iOS AppThemeID; this changes application chrome, never terminal ANSI colors. */
enum class AppColorTheme(
    val displayName: String,
    val description: String,
) {
    SkyCandy("天空糖果", "清透蓝天与糖果感高光"),
    EmeraldFlow("翡翠流光", "沉稳翡翠与克制流光"),
    PeachDawn("蜜桃晨光", "柔和蜜桃与晨曦暖意"),
    LavenderMist("薰衣草雾", "安静薰衣草与雾面层次"),
    GlacierMint("冰川薄荷", "冰川青绿与清爽留白"),
}

/**
 * The terminal appearance is deliberately independent from the app's Material
 * theme. These identifiers mirror the presets available on iOS so a user can
 * use the same familiar terminal palette on either device.
 */
enum class TerminalThemePreference(
    val displayName: String,
    val backgroundArgb: Int,
    val foregroundArgb: Int,
    val ansi16: IntArray,
) {
    Dracula(
        "Dracula", 0xFF282A36.toInt(), 0xFFF8F8F2.toInt(), intArrayOf(
            0xFF282A36.toInt(), 0xFFFF5555.toInt(), 0xFF50FA7B.toInt(), 0xFFF1FA8C.toInt(),
            0xFF6272A4.toInt(), 0xFFFF79C6.toInt(), 0xFF8BE9FD.toInt(), 0xFFF8F8F2.toInt(),
            0xFF44475A.toInt(), 0xFFFF6E6E.toInt(), 0xFF69FFA0.toInt(), 0xFFFFFFAA.toInt(),
            0xFFBD93F9.toInt(), 0xFFFF92D5.toInt(), 0xFFAAFFFF.toInt(), 0xFFFFFFFF.toInt(),
        ),
    ),
    SolarizedDark(
        "Solarized Dark", 0xFF002B36.toInt(), 0xFF839496.toInt(), intArrayOf(
            0xFF073642.toInt(), 0xFFDC322F.toInt(), 0xFF859900.toInt(), 0xFFB58900.toInt(),
            0xFF268BD2.toInt(), 0xFFD33682.toInt(), 0xFF2AA198.toInt(), 0xFFEEE8D5.toInt(),
            0xFF002B36.toInt(), 0xFFCB4B16.toInt(), 0xFF586E75.toInt(), 0xFF657B83.toInt(),
            0xFF839496.toInt(), 0xFF6C71C4.toInt(), 0xFF93A1A1.toInt(), 0xFFFDF6E3.toInt(),
        ),
    ),
    Nord(
        "Nord", 0xFF2E3440.toInt(), 0xFFD8DEE9.toInt(), intArrayOf(
            0xFF3B4252.toInt(), 0xFFBF616A.toInt(), 0xFFA3BE8C.toInt(), 0xFFEBCB8B.toInt(),
            0xFF81A1C1.toInt(), 0xFFB48EAD.toInt(), 0xFF88C0D0.toInt(), 0xFFE5E9F0.toInt(),
            0xFF4C566A.toInt(), 0xFFBF616A.toInt(), 0xFFA3BE8C.toInt(), 0xFFEBCB8B.toInt(),
            0xFF81A1C1.toInt(), 0xFFB48EAD.toInt(), 0xFF8FBCBB.toInt(), 0xFFECEFF4.toInt(),
        ),
    ),
    Homebrew(
        "Homebrew", 0xFF000000.toInt(), 0xFF00FF66.toInt(), intArrayOf(
            0xFF000000.toInt(), 0xFF00DD00.toInt(), 0xFF00FF55.toInt(), 0xFF55FF55.toInt(),
            0xFF00AA00.toInt(), 0xFF00CC00.toInt(), 0xFF66FF99.toInt(), 0xFFAABBCC.toInt(),
            0xFF004400.toInt(), 0xFF33FF33.toInt(), 0xFF66FF66.toInt(), 0xFF99FF99.toInt(),
            0xFF008800.toInt(), 0xFF33CC00.toInt(), 0xFFBBFFCC.toInt(), 0xFFDDFFDD.toInt(),
        ),
    ),
}

data class TerminalAppearance(
    val theme: TerminalThemePreference = TerminalThemePreference.Dracula,
    val fontSizeSp: Int = 13,
)

enum class MonitorRefreshInterval(val seconds: Int) {
    TwoSeconds(RuntimeResourceBudget.MONITOR_MIN_REFRESH_SECONDS),
    FiveSeconds(5),
}

interface AppSettingsRepository {
    val appThemePreference: Flow<AppThemePreference>
    val appColorTheme: Flow<AppColorTheme>
    val terminalAppearance: Flow<TerminalAppearance>
    val monitorRefreshInterval: Flow<MonitorRefreshInterval>
    val telnetEnabled: Flow<Boolean>
    suspend fun setAppThemePreference(preference: AppThemePreference)
    suspend fun setAppColorTheme(theme: AppColorTheme)
    suspend fun setTerminalTheme(preference: TerminalThemePreference)
    suspend fun setTerminalFontSize(fontSizeSp: Int)
    suspend fun setMonitorRefreshInterval(interval: MonitorRefreshInterval)
    suspend fun setTelnetEnabled(enabled: Boolean)
}
