package com.lowremote.ui.theme

import androidx.compose.ui.graphics.Color

// ── Base palette ──────────────────────────────────────────────────────────────
val Background      = Color(0xFF09090E)   // near-black, faint blue tint
val SurfaceL1       = Color(0xFF111118)   // card / elevated surface
val SurfaceL2       = Color(0xFF1A1A24)   // nested / second-level surface
val SurfaceL3       = Color(0xFF222232)   // third-level / hover

// ── Brand ──────────────────────────────────────────────────────────────────────
val Accent          = Color(0xFF4F8EF7)   // electric blue — primary action
val AccentDim       = Color(0xFF2A5FB0)   // pressed / inactive accent
val AccentGlow      = Color(0x334F8EF7)   // glow / highlight overlay

val Purple          = Color(0xFF8B6FE8)   // secondary accent
val PurpleDim       = Color(0xFF5A4799)

// ── Semantic ───────────────────────────────────────────────────────────────────
val OnlineGreen     = Color(0xFF3DD68C)   // connected indicator
val WarningAmber    = Color(0xFFF5A623)   // warning
val ErrorRed        = Color(0xFFE05252)   // destructive / error
val ErrorRedDim     = Color(0xFF8B2E2E)

// ── Text ───────────────────────────────────────────────────────────────────────
val TextPrimary     = Color(0xFFF0F0F8)   // titles, body
val TextSecondary   = Color(0xFF9090A8)   // subtitles, captions
val TextTertiary    = Color(0xFF505065)   // hints, placeholders
val TextDisabled    = Color(0xFF353548)

// ── Borders / dividers ────────────────────────────────────────────────────────
val BorderSubtle    = Color(0x14FFFFFF)   // 8% white — card outline
val BorderDefault   = Color(0x22FFFFFF)   // 13% white — interactive border
val BorderActive    = Color(0x55FFFFFF)   // 33% white — focused border

// ── Key / button surfaces ─────────────────────────────────────────────────────
val KeySurface      = Color(0xFF1E1E2E)   // shortcut key background
val KeySurfaceActive= Color(0xFF263356)   // pressed / toggled key
val KeyBorder       = Color(0x1AFFFFFF)   // key outline
