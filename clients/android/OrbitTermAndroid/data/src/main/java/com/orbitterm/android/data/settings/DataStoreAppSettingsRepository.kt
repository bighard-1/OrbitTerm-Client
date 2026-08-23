package com.orbitterm.android.data.settings

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.orbitterm.android.domain.settings.AppSettingsRepository
import com.orbitterm.android.domain.settings.AppThemePreference
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.domain.settings.TerminalAppearance
import com.orbitterm.android.domain.settings.TerminalThemePreference
import com.orbitterm.android.domain.settings.MonitorRefreshInterval
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

private val Context.appSettingsDataStore by preferencesDataStore(name = "app_settings")

@Singleton
class DataStoreAppSettingsRepository @Inject constructor(
    @param:ApplicationContext private val context: Context,
) : AppSettingsRepository {
    override val appThemePreference: Flow<AppThemePreference> = context.appSettingsDataStore.data.map { preferences ->
        preferences[Keys.appTheme]?.toThemePreference() ?: AppThemePreference.System
    }

    override val appColorTheme: Flow<AppColorTheme> = context.appSettingsDataStore.data.map { preferences ->
        preferences[Keys.appColorTheme]?.toAppColorTheme() ?: AppColorTheme.EmeraldFlow
    }

    override val terminalAppearance: Flow<TerminalAppearance> = context.appSettingsDataStore.data.map { preferences ->
        TerminalAppearance(
            theme = preferences[Keys.terminalTheme]?.toTerminalThemePreference()
                ?: TerminalThemePreference.Dracula,
            fontSizeSp = preferences[Keys.terminalFontSize]?.coerceIn(MIN_TERMINAL_FONT_SIZE, MAX_TERMINAL_FONT_SIZE)
                ?: DEFAULT_TERMINAL_FONT_SIZE,
        )
    }

    override val monitorRefreshInterval: Flow<MonitorRefreshInterval> = context.appSettingsDataStore.data.map { preferences ->
        preferences[Keys.monitorRefreshInterval]?.toMonitorRefreshInterval() ?: MonitorRefreshInterval.FiveSeconds
    }

    override val telnetEnabled: Flow<Boolean> = context.appSettingsDataStore.data.map { preferences ->
        preferences[Keys.telnetEnabled] ?: false
    }

    override suspend fun setAppThemePreference(preference: AppThemePreference) {
        context.appSettingsDataStore.edit { preferences ->
            preferences[Keys.appTheme] = preference.name
        }
    }

    override suspend fun setAppColorTheme(theme: AppColorTheme) {
        context.appSettingsDataStore.edit { preferences ->
            preferences[Keys.appColorTheme] = theme.name
        }
    }

    override suspend fun setTerminalTheme(preference: TerminalThemePreference) {
        context.appSettingsDataStore.edit { preferences ->
            preferences[Keys.terminalTheme] = preference.name
        }
    }

    override suspend fun setTerminalFontSize(fontSizeSp: Int) {
        context.appSettingsDataStore.edit { preferences ->
            preferences[Keys.terminalFontSize] = fontSizeSp.coerceIn(MIN_TERMINAL_FONT_SIZE, MAX_TERMINAL_FONT_SIZE)
        }
    }

    override suspend fun setMonitorRefreshInterval(interval: MonitorRefreshInterval) {
        context.appSettingsDataStore.edit { preferences ->
            preferences[Keys.monitorRefreshInterval] = interval.name
        }
    }

    override suspend fun setTelnetEnabled(enabled: Boolean) {
        context.appSettingsDataStore.edit { preferences ->
            preferences[Keys.telnetEnabled] = enabled
        }
    }

    private object Keys {
        val appTheme: Preferences.Key<String> = stringPreferencesKey("app_theme")
        val appColorTheme: Preferences.Key<String> = stringPreferencesKey("app_color_theme")
        val terminalTheme: Preferences.Key<String> = stringPreferencesKey("terminal_theme")
        val terminalFontSize: Preferences.Key<Int> = androidx.datastore.preferences.core.intPreferencesKey("terminal_font_size")
        val monitorRefreshInterval: Preferences.Key<String> = stringPreferencesKey("monitor_refresh_interval")
        val telnetEnabled: Preferences.Key<Boolean> = booleanPreferencesKey("telnet_enabled")
    }

    private companion object {
        const val MIN_TERMINAL_FONT_SIZE = 8
        const val MAX_TERMINAL_FONT_SIZE = 24
        const val DEFAULT_TERMINAL_FONT_SIZE = 13
    }
}

private fun String.toThemePreference(): AppThemePreference =
    AppThemePreference.entries.firstOrNull { it.name == this } ?: AppThemePreference.System

private fun String.toAppColorTheme(): AppColorTheme =
    AppColorTheme.entries.firstOrNull { it.name == this } ?: AppColorTheme.EmeraldFlow

private fun String.toTerminalThemePreference(): TerminalThemePreference =
    TerminalThemePreference.entries.firstOrNull { it.name == this } ?: TerminalThemePreference.Dracula

private fun String.toMonitorRefreshInterval(): MonitorRefreshInterval =
    MonitorRefreshInterval.entries.firstOrNull { it.name == this } ?: MonitorRefreshInterval.FiveSeconds
