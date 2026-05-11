import SwiftUI

// MARK: - LowRemote 色彩系统（与 Android Colors.kt 对齐，iOS 端扩展）

extension Color {
    // ── 基础色板 ─────────────────────────────────────────────────────────────
    /// 最深背景：#09090E
    static let lrBackground    = Color(red: 0.035, green: 0.035, blue: 0.055)
    /// 卡片背景：#0D0E14
    static let lrSurface       = Color(red: 0.051, green: 0.055, blue: 0.078)
    /// 卡片次级：#13141C
    static let lrSurface2      = Color(red: 0.075, green: 0.078, blue: 0.110)

    // ── 主色（蓝）────────────────────────────────────────────────────────────
    /// 主蓝：#4F8EF7
    static let lrAccent        = Color(red: 0.310, green: 0.557, blue: 0.969)
    /// 深蓝：#3A6FD8
    static let lrAccentDark    = Color(red: 0.228, green: 0.435, blue: 0.847)
    /// 浅蓝（按下态）：#6FA6FA
    static let lrAccentLight   = Color(red: 0.435, green: 0.651, blue: 0.980)

    // ── 辅助色 ────────────────────────────────────────────────────────────────
    /// 紫色：#8B6FE8
    static let lrPurple        = Color(red: 0.545, green: 0.435, blue: 0.910)
    /// 成功绿：#34C759
    static let lrGreen         = Color(red: 0.204, green: 0.780, blue: 0.349)
    /// 警告橙：#FF9F0A
    static let lrOrange        = Color(red: 1.000, green: 0.624, blue: 0.039)
    /// 错误红：#FF453A
    static let lrRed           = Color(red: 1.000, green: 0.271, blue: 0.227)

    // ── 文字色 ────────────────────────────────────────────────────────────────
    static let lrTextPrimary   = Color.white
    static let lrTextSecondary = Color.white.opacity(0.60)
    static let lrTextTertiary  = Color.white.opacity(0.35)

    // ── 分割线 ────────────────────────────────────────────────────────────────
    static let lrDivider       = Color.white.opacity(0.08)

    // ── Liquid Glass 专用 ─────────────────────────────────────────────────────
    /// 玻璃边框高光
    static let lrGlassBorder   = Color.white.opacity(0.18)
    /// 玻璃内部高光
    static let lrGlassHighlight = Color.white.opacity(0.06)
}

// MARK: - UIColor 便捷扩展

extension UIColor {
    static let lrBackground  = UIColor(red: 0.035, green: 0.035, blue: 0.055, alpha: 1)
    static let lrSurface     = UIColor(red: 0.051, green: 0.055, blue: 0.078, alpha: 1)
    static let lrAccent      = UIColor(red: 0.310, green: 0.557, blue: 0.969, alpha: 1)
}

// MARK: - 渐变预设

extension LinearGradient {
    /// 主色渐变：蓝 → 紫（对角）
    static let lrAccentGradient = LinearGradient(
        colors: [.lrAccent, .lrPurple],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )
    /// 背景渐变：深黑 → 略浅
    static let lrBgGradient = LinearGradient(
        colors: [Color(red: 0.030, green: 0.030, blue: 0.050),
                 Color(red: 0.055, green: 0.058, blue: 0.085)],
        startPoint: .top,
        endPoint:   .bottom
    )
    /// 玻璃高光（从左上角发散）
    static let lrGlassHighlight = LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0)],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )
}
