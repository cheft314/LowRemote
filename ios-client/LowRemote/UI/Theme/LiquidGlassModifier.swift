import SwiftUI

// MARK: - Liquid Glass 效果修饰器
//
// 策略：
//   iOS 26+  → 使用系统原生 .glassEffect() API（如可用时通过版本检测启用）
//   iOS 17-25 → ultraThinMaterial + 自定义高光边框 + 阴影模拟 Liquid Glass

// MARK: - 主修饰符

struct LiquidGlassModifier: ViewModifier {
    var cornerRadius:  CGFloat
    var borderOpacity: Double
    var shadowRadius:  CGFloat
    var tint:          Color

    init(
        cornerRadius:  CGFloat = 16,
        borderOpacity: Double  = 1.0,
        shadowRadius:  CGFloat = 12,
        tint:          Color   = .clear
    ) {
        self.cornerRadius  = cornerRadius
        self.borderOpacity = borderOpacity
        self.shadowRadius  = shadowRadius
        self.tint          = tint
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // 1. 毛玻璃材质底层
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // 2. 色调叠加（可选）
                    if tint != .clear {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.08))
                    }

                    // 3. 顶部高光（折射模拟）
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient.lrGlassHighlight)

                    // 4. 内阴影（深度感）
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.15))
                        .blur(radius: 2)
                        .padding(1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // 5. 边框：渐变高光
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.35 * borderOpacity),
                                Color.white.opacity(0.08 * borderOpacity),
                                Color.lrAccent.opacity(0.20 * borderOpacity),
                            ],
                            startPoint: .topLeading,
                            endPoint:   .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            }
            .shadow(color: Color.black.opacity(0.35), radius: shadowRadius, x: 0, y: 4)
    }
}

// MARK: - 按钮专用玻璃修饰符

struct GlassButtonModifier: ViewModifier {
    var cornerRadius: CGFloat
    var isActive:     Bool
    var accentColor:  Color

    init(cornerRadius: CGFloat = 10, isActive: Bool = false, accentColor: Color = .lrAccent) {
        self.cornerRadius = cornerRadius
        self.isActive     = isActive
        self.accentColor  = accentColor
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isActive
                          ? accentColor.opacity(0.25)
                          : Color.white.opacity(0.07))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? accentColor.opacity(0.55)
                            : Color.white.opacity(0.13),
                        lineWidth: 1.0
                    )
            }
    }
}

// MARK: - iOS 26 原生检测 (预留)

struct NativeGlassModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // iOS 26 原生 Liquid Glass
            // content.glassEffect(in: .rect(cornerRadius: cornerRadius))
            // 注：上方 API 在 Xcode 26 beta SDK 才可用，当前用模拟方案
            content.modifier(LiquidGlassModifier(cornerRadius: cornerRadius))
        } else {
            content.modifier(LiquidGlassModifier(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - View 扩展（便捷调用）

extension View {
    /// 标准 Liquid Glass 卡片效果
    func liquidGlass(
        cornerRadius:  CGFloat = 16,
        borderOpacity: Double  = 1.0,
        shadowRadius:  CGFloat = 12,
        tint:          Color   = .clear
    ) -> some View {
        modifier(LiquidGlassModifier(
            cornerRadius:  cornerRadius,
            borderOpacity: borderOpacity,
            shadowRadius:  shadowRadius,
            tint:          tint
        ))
    }

    /// 玻璃按钮效果
    func glassButton(
        cornerRadius: CGFloat = 10,
        isActive:     Bool    = false,
        accentColor:  Color   = .lrAccent
    ) -> some View {
        modifier(GlassButtonModifier(
            cornerRadius: cornerRadius,
            isActive:     isActive,
            accentColor:  accentColor
        ))
    }

    /// 自适应原生/模拟 Liquid Glass
    func adaptiveLiquidGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(NativeGlassModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Toast 修饰符

struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        ZStack {
            content
            if let msg = message {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.lrBodyMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .liquidGlass(cornerRadius: 24, shadowRadius: 8)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(bounce: 0.2), value: msg)
            }
        }
    }
}

extension View {
    func toastOverlay(message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
