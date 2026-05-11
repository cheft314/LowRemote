package com.lowremote.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val DarkColorScheme = darkColorScheme(
    primary          = Accent,
    onPrimary        = Background,
    primaryContainer = AccentDim,
    onPrimaryContainer = TextPrimary,

    secondary        = Purple,
    onSecondary      = Background,
    secondaryContainer = PurpleDim,
    onSecondaryContainer = TextPrimary,

    background       = Background,
    onBackground     = TextPrimary,

    surface          = SurfaceL1,
    onSurface        = TextPrimary,
    surfaceVariant   = SurfaceL2,
    onSurfaceVariant = TextSecondary,

    outline          = BorderDefault,
    outlineVariant   = BorderSubtle,

    error            = ErrorRed,
    onError          = Background,
    errorContainer   = ErrorRedDim,
)

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColorScheme,
        typography  = AppTypography,
        shapes      = AppShapes,
        content     = content,
    )
}
