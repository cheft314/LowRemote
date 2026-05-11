import UIKit
import SwiftUI

// MARK: - VideoTouchView (UIKit)

/// 视频区域的触摸处理视图
///
/// 支持两种模式（可运行时切换）：
///
/// **绝对模式（默认）**
///   触摸位置映射到 Mac 屏幕的归一化坐标 → mouseAbsolute(normX, normY)
///   适合精确点击 UI 元素，手感类似平板 / 触摸屏
///
/// **触控板模式**
///   复用 TouchpadView 完整手势集（相对移动 + 多指手势）
///   由右上角切换按钮控制
///
/// 叠加在 VideoSurface 之上，透明背景。
final class VideoTouchView: UIView {

    // MARK: - Public
    var onEvent: ((ControlEvent) -> Void)?
    /// true = 绝对坐标模式，false = 触控板（相对）模式
    var absoluteMode: Bool = true

    /// 视频实际在父视图中的 frame（含黑边后的真实视频区域）
    var videoFrame: CGRect = .zero

    // MARK: - Embedded touchpad (relative mode)
    private lazy var touchpadView: TouchpadView = {
        let v = TouchpadView(frame: bounds)
        v.backgroundColor = .clear
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.onEvent = { [weak self] ev in self?.onEvent?(ev) }
        return v
    }()

    // MARK: - Absolute-mode state
    private var isPressingLeft = false
    private let impactLight  = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    // Tap detection in absolute mode
    private var tapStartPt  = CGPoint.zero
    private var tapStartTime = Date()
    private let tapMs: TimeInterval = 0.220
    private let tapMovePt: CGFloat  = 10

    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor        = .clear
        isMultipleTouchEnabled = true
        impactLight.prepare(); impactMedium.prepare()
    }

    // MARK: - Mode switch

    func setAbsoluteMode(_ absolute: Bool) {
        absoluteMode = absolute
        if absolute {
            touchpadView.removeFromSuperview()
        } else {
            if touchpadView.superview == nil {
                addSubview(touchpadView)
                touchpadView.frame = bounds
            }
            touchpadView.backgroundColor = .clear
        }
        // 透传触摸
        isUserInteractionEnabled = true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !absoluteMode, let v = touchpadView.hitTest(
            convert(point, to: touchpadView), with: event) { return v }
        return super.hitTest(point, with: event)
    }

    // MARK: - Absolute mode touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard absoluteMode else { return }
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)
        tapStartPt   = pt
        tapStartTime = Date()

        // 长按 → 开始拖拽
        let norm = normalize(pt)
        guard norm != nil else { return }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard absoluteMode else { return }
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)

        guard let norm = normalize(pt) else { return }

        // 若开始移动超过阈值 → 触发绝对鼠标移动
        if dist(pt, tapStartPt) > tapMovePt {
            onEvent?(.mouseAbsolute(normX: Float(norm.x), normY: Float(norm.y)))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard absoluteMode else { return }
        guard let touch = touches.first else { return }
        let pt      = touch.location(in: self)
        let elapsed = Date().timeIntervalSince(tapStartTime)
        let moved   = dist(pt, tapStartPt)

        if elapsed < tapMs && moved < tapMovePt {
            // 单击：先移动到绝对位置，再点击
            if let norm = normalize(pt) {
                onEvent?(.mouseAbsolute(normX: Float(norm.x), normY: Float(norm.y)))
            }
            onEvent?(.mouseClick(.left))
            impactLight.impactOccurred()
        }

        if isPressingLeft {
            onEvent?(.mouseUp(.left))
            isPressingLeft = false
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard absoluteMode else { return }
        if isPressingLeft {
            onEvent?(.mouseUp(.left))
            isPressingLeft = false
        }
    }

    // MARK: - Helpers

    /// 将触摸点映射到视频区域的归一化坐标 [0,1]×[0,1]
    private func normalize(_ pt: CGPoint) -> CGPoint? {
        let vf = videoFrame.isEmpty ? bounds : videoFrame
        guard vf.width > 0, vf.height > 0 else { return nil }
        let nx = ((pt.x - vf.minX) / vf.width).clamped(0, 1)
        let ny = ((pt.y - vf.minY) / vf.height).clamped(0, 1)
        return CGPoint(x: nx, y: ny)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}

// MARK: - SwiftUI Wrapper

struct VideoTouchRepresentable: UIViewRepresentable {
    var onEvent: (ControlEvent) -> Void
    var absoluteMode: Bool
    var videoFrame: CGRect

    func makeUIView(context: Context) -> VideoTouchView {
        let v = VideoTouchView()
        v.onEvent      = onEvent
        v.absoluteMode = absoluteMode
        v.videoFrame   = videoFrame
        v.setAbsoluteMode(absoluteMode)
        return v
    }

    func updateUIView(_ uiView: VideoTouchView, context: Context) {
        uiView.onEvent      = onEvent
        uiView.videoFrame   = videoFrame
        if uiView.absoluteMode != absoluteMode {
            uiView.setAbsoluteMode(absoluteMode)
        }
    }
}
