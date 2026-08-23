package com.orbitterm.android.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp
import com.orbitterm.android.domain.settings.AppColorTheme

private data class ThemeSeed(
    val primary: Color,
    val secondary: Color,
    val darkBackground: Color,
    val darkSurface: Color,
    val darkSurfaceContainer: Color,
    val lightBackground: Color,
    val lightSurface: Color,
    val lightSurfaceContainer: Color,
    val darkOutline: Color,
    val lightOutline: Color,
)

/** RGB seeds mirror the five decorations in iOS AppThemePalette. */
private fun seed(theme: AppColorTheme): ThemeSeed = when (theme) {
    AppColorTheme.SkyCandy -> ThemeSeed(
        primary = Color(0xFF1261C2), secondary = Color(0xFF38A3DE),
        darkBackground = Color(0xFF0C1423), darkSurface = Color(0xFF111D31), darkSurfaceContainer = Color(0xFF182742),
        lightBackground = Color(0xFFF0F6FF), lightSurface = Color(0xFFFAFCFF), lightSurfaceContainer = Color(0xFFE2EFFD),
        darkOutline = Color(0xFF7385A3), lightOutline = Color(0xFF74839A),
    )
    AppColorTheme.EmeraldFlow -> ThemeSeed(
        primary = Color(0xFF08664D), secondary = Color(0xFF129477),
        darkBackground = Color(0xFF0A1717), darkSurface = Color(0xFF102120), darkSurfaceContainer = Color(0xFF18312D),
        lightBackground = Color(0xFFF0F8F5), lightSurface = Color(0xFFFAFDFC), lightSurfaceContainer = Color(0xFFE0F1EB),
        darkOutline = Color(0xFF78928C), lightOutline = Color(0xFF718780),
    )
    AppColorTheme.PeachDawn -> ThemeSeed(
        primary = Color(0xFF9C3333), secondary = Color(0xFFD46147),
        darkBackground = Color(0xFF1D1113), darkSurface = Color(0xFF29191B), darkSurfaceContainer = Color(0xFF3A2022),
        lightBackground = Color(0xFFFFF3EE), lightSurface = Color(0xFFFFFBF9), lightSurfaceContainer = Color(0xFFFFE5DB),
        darkOutline = Color(0xFFA98886), lightOutline = Color(0xFF907574),
    )
    AppColorTheme.LavenderMist -> ThemeSeed(
        primary = Color(0xFF613893), secondary = Color(0xFF875EBA),
        darkBackground = Color(0xFF15101E), darkSurface = Color(0xFF20192D), darkSurfaceContainer = Color(0xFF302242),
        lightBackground = Color(0xFFF6F1FF), lightSurface = Color(0xFFFFFBFF), lightSurfaceContainer = Color(0xFFECE1FB),
        darkOutline = Color(0xFF9686A7), lightOutline = Color(0xFF80718E),
    )
    AppColorTheme.GlacierMint -> ThemeSeed(
        primary = Color(0xFF066373), secondary = Color(0xFF149099),
        darkBackground = Color(0xFF09171B), darkSurface = Color(0xFF102226), darkSurfaceContainer = Color(0xFF183338),
        lightBackground = Color(0xFFEEFAFA), lightSurface = Color(0xFFFAFDFD), lightSurfaceContainer = Color(0xFFDDF1F1),
        darkOutline = Color(0xFF759296), lightOutline = Color(0xFF6F878B),
    )
}

fun appColorThemeAccent(theme: AppColorTheme): Color = seed(theme).primary

fun appColorThemeHighlight(theme: AppColorTheme): Color = seed(theme).secondary

private fun darkScheme(seed: ThemeSeed): ColorScheme = darkColorScheme(
    primary = seed.secondary,
    onPrimary = Color.White,
    primaryContainer = seed.primary,
    onPrimaryContainer = Color(0xFFF5FBFF),
    secondary = seed.secondary,
    background = seed.darkBackground,
    onBackground = Color(0xFFF0F5F7),
    surface = seed.darkSurface,
    onSurface = Color(0xFFF0F5F7),
    surfaceVariant = seed.darkSurfaceContainer,
    onSurfaceVariant = Color(0xFFC0CBCB),
    outline = seed.darkOutline,
    outlineVariant = seed.darkSurfaceContainer,
    error = Color(0xFFFF6B6B),
)

private fun lightScheme(seed: ThemeSeed): ColorScheme = lightColorScheme(
    primary = seed.primary,
    onPrimary = Color.White,
    primaryContainer = seed.lightSurfaceContainer,
    onPrimaryContainer = Color(0xFF101418),
    secondary = seed.secondary,
    background = seed.lightBackground,
    onBackground = Color(0xFF172021),
    surface = seed.lightSurface,
    onSurface = Color(0xFF172021),
    surfaceVariant = seed.lightSurfaceContainer,
    onSurfaceVariant = Color(0xFF536364),
    outline = seed.lightOutline,
    outlineVariant = seed.lightSurfaceContainer,
    error = Color(0xFFC62828),
)

/** Native type hierarchy: calm labels, decisive task titles, no imported brand font. */
private val OrbitTypography = Typography(
    displaySmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 34.sp,
        lineHeight = 40.sp,
        letterSpacing = (-0.5).sp,
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 26.sp,
        lineHeight = 32.sp,
        letterSpacing = (-0.3).sp,
    ),
    headlineSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp,
    ),
    titleSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
    ),
    bodyLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 15.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 13.sp, lineHeight = 19.sp),
    bodySmall = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 11.sp, lineHeight = 16.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, lineHeight = 18.sp),
    labelMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 11.sp, lineHeight = 15.sp),
)

@Composable
fun OrbitTheme(
    darkTheme: Boolean,
    colorTheme: AppColorTheme,
    content: @Composable () -> Unit,
) {
    val selectedSeed = seed(colorTheme)
    MaterialTheme(
        colorScheme = if (darkTheme) darkScheme(selectedSeed) else lightScheme(selectedSeed),
        typography = OrbitTypography,
        content = content,
    )
}
