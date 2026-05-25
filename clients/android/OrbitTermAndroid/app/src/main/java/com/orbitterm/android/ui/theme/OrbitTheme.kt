package com.orbitterm.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val DarkScheme: ColorScheme = darkColorScheme(
    primary = Color(0xFF49A7FF),
    secondary = Color(0xFF80CBC4),
    background = Color(0xFF0B1020),
    surface = Color(0xFF151B2E),
    error = Color(0xFFFF6B6B)
)

private val LightScheme: ColorScheme = lightColorScheme(
    primary = Color(0xFF006BCF),
    secondary = Color(0xFF00695C),
    background = Color(0xFFF3F7FB),
    surface = Color(0xFFFFFFFF),
    error = Color(0xFFC62828)
)

@Composable
fun OrbitTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkScheme else LightScheme, content = content)
}
