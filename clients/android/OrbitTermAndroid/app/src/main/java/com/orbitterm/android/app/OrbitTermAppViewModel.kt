package com.orbitterm.android.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.orbitterm.android.domain.settings.AppSettingsRepository
import com.orbitterm.android.domain.settings.AppThemePreference
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.domain.settings.TerminalAppearance
import com.orbitterm.android.domain.settings.TerminalThemePreference
import com.orbitterm.android.domain.settings.MonitorRefreshInterval
import com.orbitterm.android.feature.terminal.TerminalSessionController
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.launch
import javax.inject.Inject

data class OrbitTermAppUiState(
    val destination: AppDestination = AppDestination.Servers,
    val appThemePreference: AppThemePreference = AppThemePreference.System,
    val appColorTheme: AppColorTheme = AppColorTheme.EmeraldFlow,
    val terminalAppearance: TerminalAppearance = TerminalAppearance(),
    val monitorRefreshInterval: MonitorRefreshInterval = MonitorRefreshInterval.FiveSeconds,
    val telnetEnabled: Boolean = false,
    val hasActiveTerminalSession: Boolean = false,
)

@HiltViewModel
class OrbitTermAppViewModel @Inject constructor(
    private val settingsRepository: AppSettingsRepository,
    private val terminalSessionController: TerminalSessionController,
) : ViewModel() {
    private val destination = MutableStateFlow(AppDestination.Servers)
    private val appearanceSettings = combine(
        settingsRepository.appThemePreference,
        settingsRepository.appColorTheme,
        settingsRepository.terminalAppearance,
        settingsRepository.monitorRefreshInterval,
    ) { themePreference, colorTheme, terminalAppearance, monitorRefreshInterval ->
        AppSettingsSnapshot(themePreference, colorTheme, terminalAppearance, monitorRefreshInterval)
    }
    private val settings = combine(appearanceSettings, settingsRepository.telnetEnabled) { appearance, telnetEnabled ->
        appearance.copy(telnetEnabled = telnetEnabled)
    }
    val uiState: StateFlow<OrbitTermAppUiState> = combine(
        destination,
        settings,
        terminalSessionController.activeSessions,
    ) { destination, settings, sessions ->
        OrbitTermAppUiState(
            destination = destination,
            appThemePreference = settings.themePreference,
            appColorTheme = settings.colorTheme,
            terminalAppearance = settings.terminalAppearance,
            monitorRefreshInterval = settings.monitorRefreshInterval,
            telnetEnabled = settings.telnetEnabled,
            hasActiveTerminalSession = sessions.isNotEmpty(),
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = OrbitTermAppUiState(),
    )

    fun selectDestination(destination: AppDestination) {
        this.destination.value = destination
    }

    fun setAppThemePreference(preference: AppThemePreference) {
        viewModelScope.launch {
            settingsRepository.setAppThemePreference(preference)
        }
    }

    fun setAppColorTheme(theme: AppColorTheme) {
        viewModelScope.launch { settingsRepository.setAppColorTheme(theme) }
    }

    fun setTerminalTheme(preference: TerminalThemePreference) {
        viewModelScope.launch { settingsRepository.setTerminalTheme(preference) }
    }

    fun setTerminalFontSize(fontSizeSp: Int) {
        viewModelScope.launch { settingsRepository.setTerminalFontSize(fontSizeSp) }
    }

    fun setMonitorRefreshInterval(interval: MonitorRefreshInterval) {
        viewModelScope.launch { settingsRepository.setMonitorRefreshInterval(interval) }
    }

    fun setTelnetEnabled(enabled: Boolean) {
        viewModelScope.launch { settingsRepository.setTelnetEnabled(enabled) }
    }
}

private data class AppSettingsSnapshot(
    val themePreference: AppThemePreference,
    val colorTheme: AppColorTheme,
    val terminalAppearance: TerminalAppearance,
    val monitorRefreshInterval: MonitorRefreshInterval,
    val telnetEnabled: Boolean = false,
)
