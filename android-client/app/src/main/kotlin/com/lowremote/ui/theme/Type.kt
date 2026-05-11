package com.lowremote.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val AppTypography = Typography(
    // Large screen titles
    headlineLarge = TextStyle(
        fontWeight = FontWeight.Bold,
        fontSize   = 28.sp,
        lineHeight = 34.sp,
        color      = TextPrimary,
    ),
    headlineMedium = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize   = 22.sp,
        lineHeight = 28.sp,
        color      = TextPrimary,
    ),
    headlineSmall = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize   = 18.sp,
        lineHeight = 24.sp,
        color      = TextPrimary,
    ),
    // Section labels / card titles
    titleLarge = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize   = 16.sp,
        lineHeight = 22.sp,
        color      = TextPrimary,
    ),
    titleMedium = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize   = 14.sp,
        lineHeight = 20.sp,
        color      = TextPrimary,
        letterSpacing = 0.1.sp,
    ),
    titleSmall = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize   = 12.sp,
        lineHeight = 16.sp,
        color      = TextSecondary,
        letterSpacing = 0.5.sp,
    ),
    // Body text
    bodyLarge = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize   = 15.sp,
        lineHeight = 22.sp,
        color      = TextPrimary,
    ),
    bodyMedium = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize   = 13.sp,
        lineHeight = 19.sp,
        color      = TextSecondary,
    ),
    bodySmall = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize   = 11.sp,
        lineHeight = 16.sp,
        color      = TextTertiary,
    ),
    // Labels on buttons, chips
    labelLarge = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize   = 13.sp,
        lineHeight = 18.sp,
        color      = TextPrimary,
        letterSpacing = 0.2.sp,
    ),
    labelMedium = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize   = 11.sp,
        lineHeight = 15.sp,
        color      = TextSecondary,
        letterSpacing = 0.4.sp,
    ),
    labelSmall = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize   = 10.sp,
        lineHeight = 14.sp,
        color      = TextTertiary,
        letterSpacing = 0.5.sp,
    ),
)
