package com.orbitterm.android.ui.design

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties

/** Semantic feedback roles. Their meaning never changes with an app accent theme. */
enum class OrbitStatusTone {
    Neutral,
    Information,
    Success,
    Warning,
    Danger,
}

@Immutable
data class OrbitStatusColors(
    val container: Color,
    val content: Color,
    val indicator: Color,
)

/**
 * Central status-color contract for application surfaces.
 *
 * ANSI terminal colors deliberately do not use these values; terminal palettes
 * are an independent user preference and must retain their original meaning.
 */
@Composable
fun orbitStatusColors(tone: OrbitStatusTone): OrbitStatusColors {
    val colors = MaterialTheme.colorScheme
    val darkSurface = colors.background.luminance() < 0.5f
    return when (tone) {
        OrbitStatusTone.Neutral -> OrbitStatusColors(
            container = colors.surfaceVariant,
            content = colors.onSurfaceVariant,
            indicator = colors.outline,
        )
        OrbitStatusTone.Information -> OrbitStatusColors(
            container = colors.primaryContainer,
            content = colors.onPrimaryContainer,
            indicator = colors.primary,
        )
        OrbitStatusTone.Success -> OrbitStatusColors(
            container = if (darkSurface) Color(0xFF12392A) else Color(0xFFDDF6E7),
            content = if (darkSurface) Color(0xFFB9F3D0) else Color(0xFF0B5130),
            indicator = if (darkSurface) Color(0xFF72D99B) else Color(0xFF18784A),
        )
        OrbitStatusTone.Warning -> OrbitStatusColors(
            container = if (darkSurface) Color(0xFF493600) else Color(0xFFFFF1C9),
            content = if (darkSurface) Color(0xFFFFDEA0) else Color(0xFF694B00),
            indicator = if (darkSurface) Color(0xFFFFC76B) else Color(0xFF9A6800),
        )
        OrbitStatusTone.Danger -> OrbitStatusColors(
            container = colors.errorContainer,
            content = colors.onErrorContainer,
            indicator = colors.error,
        )
    }
}

/** Shared native workbench language. It deliberately contains no navigation or business state. */
@Composable
fun OrbitPageHeader(
    title: String,
    subtitle: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(
            modifier = Modifier.weight(1f).semantics { heading() },
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(title, style = MaterialTheme.typography.headlineMedium)
            Text(
                subtitle,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        action?.let {
            Spacer(Modifier.width(12.dp))
            it()
        }
    }
}

@Composable
fun OrbitSectionCard(
    title: String,
    subtitle: String? = null,
    icon: ImageVector? = null,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = CardDefaults.outlinedCardBorder(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            content = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (icon != null) {
                        Surface(
                            color = MaterialTheme.colorScheme.primaryContainer,
                            shape = RoundedCornerShape(14.dp),
                        ) {
                            Icon(
                                imageVector = icon,
                                contentDescription = null,
                                modifier = Modifier.padding(9.dp),
                                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                    }
                    Column {
                        Text(title, style = MaterialTheme.typography.titleMedium)
                        subtitle?.let {
                            Text(
                                text = it,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
                content()
            },
        )
    }
}

@Composable
fun OrbitStatusLine(
    label: String,
    isActive: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = orbitStatusColors(if (isActive) OrbitStatusTone.Success else OrbitStatusTone.Neutral)
    Row(
        modifier = modifier.semantics {
            stateDescription = if (isActive) "状态：活跃" else "状态：未活跃"
        },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .background(colors.indicator, CircleShape),
        )
        Spacer(Modifier.width(8.dp))
        Text(label, color = colors.content, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
fun OrbitStatusBadge(
    label: String,
    tone: OrbitStatusTone,
    modifier: Modifier = Modifier,
) {
    val colors = orbitStatusColors(tone)
    Surface(
        modifier = modifier.semantics { contentDescription = "状态：$label" },
        color = colors.container,
        contentColor = colors.content,
        shape = RoundedCornerShape(10.dp),
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@Composable
fun OrbitFeedbackBanner(
    message: String,
    isError: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = orbitStatusColors(if (isError) OrbitStatusTone.Danger else OrbitStatusTone.Success)
    Surface(
        modifier = modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite },
        shape = RoundedCornerShape(16.dp),
        color = colors.container,
    ) {
        Text(
            text = message,
            modifier = Modifier
                .semantics { liveRegion = LiveRegionMode.Polite }
                .padding(horizontal = 16.dp, vertical = 12.dp),
            color = colors.content,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

/** A real ANSI palette preview; it does not emulate terminal chrome or output. */
@Composable
fun OrbitTerminalThemeSwatch(
    label: String,
    background: Color,
    foreground: Color,
    ansiColors: List<Color>,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val padding = if (compact) 8.dp else 12.dp
    val swatchSize = if (compact) 8.dp else 12.dp
    Surface(
        modifier = modifier.semantics { contentDescription = "$label 终端主题预览" },
        color = background,
        contentColor = foreground,
        shape = RoundedCornerShape(if (compact) 10.dp else 14.dp),
    ) {
        Column(
            modifier = Modifier.padding(padding),
            verticalArrangement = Arrangement.spacedBy(if (compact) 5.dp else 8.dp),
        ) {
            if (!compact) Text(label, style = MaterialTheme.typography.labelMedium)
            Text(
                text = "$ echo orbit",
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                style = MaterialTheme.typography.labelSmall,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ansiColors.take(8).forEach { color ->
                    Box(
                        modifier = Modifier
                            .size(swatchSize)
                            .background(color, RoundedCornerShape(3.dp)),
                    )
                }
            }
        }
    }
}

@Composable
fun OrbitEmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            title,
            modifier = Modifier.semantics { heading() },
            style = MaterialTheme.typography.headlineSmall,
        )
        Text(
            message,
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
fun OrbitConfirmationDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
) {
    val dangerColors = if (destructive) orbitStatusColors(OrbitStatusTone.Danger) else null
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = MaterialTheme.typography.titleLarge) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (destructive) OrbitStatusBadge(label = "危险操作", tone = OrbitStatusTone.Danger)
                Text(message, style = MaterialTheme.typography.bodyMedium)
            }
        },
        confirmButton = {
            if (dangerColors != null) {
                Button(
                    onClick = onConfirm,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = dangerColors.container,
                        contentColor = dangerColors.content,
                    ),
                ) { Text(confirmLabel) }
            } else {
                TextButton(onClick = onConfirm) { Text(confirmLabel) }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
        shape = RoundedCornerShape(28.dp),
        containerColor = MaterialTheme.colorScheme.surface,
    )
}

/** Standard form dialog for local mutations. Callers keep ownership of validation and state. */
@Composable
fun OrbitFormDialog(
    title: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    confirmEnabled: Boolean = true,
    dismissEnabled: Boolean = true,
    destructive: Boolean = false,
    usePlatformDefaultWidth: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val dangerColors = if (destructive) orbitStatusColors(OrbitStatusTone.Danger) else null
    AlertDialog(
        modifier = modifier,
        onDismissRequest = { if (dismissEnabled) onDismiss() },
        title = { Text(title, style = MaterialTheme.typography.titleLarge) },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (destructive) OrbitStatusBadge(label = "危险操作", tone = OrbitStatusTone.Danger)
                content()
            }
        },
        confirmButton = {
            if (dangerColors != null) {
                Button(
                    onClick = onConfirm,
                    enabled = confirmEnabled,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = dangerColors.container,
                        contentColor = dangerColors.content,
                    ),
                ) { Text(confirmLabel) }
            } else {
                TextButton(onClick = onConfirm, enabled = confirmEnabled) { Text(confirmLabel) }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = dismissEnabled) { Text("取消") }
        },
        shape = RoundedCornerShape(28.dp),
        containerColor = MaterialTheme.colorScheme.surface,
        properties = DialogProperties(usePlatformDefaultWidth = usePlatformDefaultWidth),
    )
}
