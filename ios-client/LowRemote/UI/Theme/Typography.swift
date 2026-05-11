import SwiftUI

// MARK: - 字体系统

extension Font {
    // 展示级
    static let lrLargeTitle  = Font.system(size: 34, weight: .bold,   design: .rounded)
    static let lrTitle       = Font.system(size: 22, weight: .bold,   design: .rounded)
    static let lrTitle2      = Font.system(size: 17, weight: .semibold, design: .rounded)
    // 正文
    static let lrBody        = Font.system(size: 15, weight: .regular, design: .default)
    static let lrBodyMedium  = Font.system(size: 15, weight: .medium,  design: .default)
    // 辅助
    static let lrCaption     = Font.system(size: 12, weight: .regular, design: .default)
    static let lrCaption2    = Font.system(size: 11, weight: .regular, design: .default)
    // 按钮
    static let lrButton      = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let lrButtonSmall = Font.system(size: 12, weight: .semibold, design: .rounded)
    // 数码/技术信息（等宽）
    static let lrMono        = Font.system(size: 13, weight: .regular,  design: .monospaced)
}
