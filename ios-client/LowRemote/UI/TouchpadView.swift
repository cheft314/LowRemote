import UIKit
import SwiftUI

// MARK: - TouchpadView (UIKit)

/// 触控板视图，完整对齐 Android TouchpadView.kt 的所有手势
///
/// 手势表
/// ───────────────────────────────────────────────────────
/// 1指 移动        → 鼠标相对移动 (MouseMove dx,dy)
/// 1指 单击        → 左键单击  (<220ms, <8dp travel)
/// 1指 双击        → 左键双击
/// 1指 三击        → 左键三击（选段落）
/// 1指 长按+移动   → 拖拽锁定 (dragLock模式)
/// 2指 单击        → 右键单击
/// 2指 拖动        → 滚动（velocity-proportional，带惯性）
/// 3指 上划        → Mission Control
/// 3指 下划        → App Exposé
/// 3指 左/右划     → 切换 Space
/// 4指 上/下/左/右  → 对应 4 指手势
/// 5指 捏合        → Launchpad
/// 5指 张开        → 显示桌面
/// ───────────────────────────────────────────────────────
final class TouchpadView: UIView {

    // MARK: - Config constants (对齐 Android)
    private static let tapMs:          TimeInterval = 0.220
    private static let doubleTapMs:    TimeInterval = 0.380
    private static let longPressMs:    TimeInterval = 0.450
    private static let tapMovePt:      CGFloat      = 8
    private static let mfSwipePt:      CGFloat      = 18
    private static let scrollScale:    CGFloat      = 2.5
    private static let scrollMaxPx:    Int          = 80
    private static let flingDecay:     CGFloat      = 0.82
    private static let flingMinPx:     CGFloat      = 1.5
    private static let twoTapMs:       TimeInterval = 0.180
    private static let twoTapMovePt:   CGFloat      = 6

    // MARK: - Public
    var onEvent:          ((ControlEvent) -> Void)?
    var sensitivity:      CGFloat = 1.2
    var dragLockEnabled:  Bool    = false
    var scrollModeEnabled: Bool   = false

    // MARK: - Touch state
    private enum TwoMode { case undecided, scroll }

    private var fingerCount   = 0
    private var gestureStart  = Date()
    private var dragActive    = false
    private var multiHandled  = false

    // 1指
    private var sfStartPt = CGPoint.zero
    private var sfLastPt  = CGPoint.zero

    // 双击链
    private var prevTapTime = Date.distantPast; private var prevTapPt = CGPoint.zero
    private var lastTapTime = Date.distantPast; private var lastTapPt = CGPoint.zero

    // 2指
    private var tfMode      = TwoMode.undecided
    private var tfLastMid   = CGPoint.zero
    private var tfTotalMove: CGFloat = 0
    private var flingVelX: CGFloat = 0
    private var flingVelY: CGFloat = 0
    private var flingTimer: CADisplayLink?

    // 多指(3/4/5)
    private var mfStartMid  = CGPoint.zero
    private var mfStartSpan: CGFloat = 0
    private var mfFired     = false

    // Haptic
    private let impactLight  = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy  = UIImpactFeedbackGenerator(style: .heavy)

    // MARK: - Init
    override init(frame: CGRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        backgroundColor = UIColor(red: 0.05, green: 0.055, blue: 0.078, alpha: 1)
        layer.cornerRadius = 12
        layer.borderWidth  = 1.5
        isMultipleTouchEnabled = true
        impactLight.prepare(); impactMedium.prepare(); impactHeavy.prepare()
        updateBorderGradient()
    }

    // MARK: - Drawing

    private var gradientLayer: CAGradientLayer?

    private func updateBorderGradient() {
        gradientLayer?.removeFromSuperlayer()
        let mask = CAShapeLayer()
        mask.path        = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                         cornerRadius: 11.25).cgPath
        mask.fillColor   = UIColor.clear.cgColor
        mask.strokeColor = UIColor.white.cgColor
        mask.lineWidth   = 1.5

        let grad = CAGradientLayer()
        grad.frame      = bounds
        grad.colors     = [UIColor(red: 0.31, green: 0.56, blue: 0.97, alpha: 1).cgColor,
                           UIColor(red: 0.54, green: 0.44, blue: 0.91, alpha: 1).cgColor]
        grad.startPoint = .zero
        grad.endPoint   = CGPoint(x: 1, y: 1)
        grad.mask       = mask
        layer.addSublayer(grad)
        gradientLayer = grad
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer?.frame = bounds
        (gradientLayer?.mask as? CAShapeLayer)?.path =
            UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                         cornerRadius: 11.25).cgPath
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // 拖拽激活时：蓝色半透明填充
        if dragActive {
            ctx.setFillColor(UIColor(red: 0.31, green: 0.56, blue: 0.97, alpha: 0.15).cgColor)
            UIBezierPath(roundedRect: bounds, cornerRadius: 12).fill()
        }

        // 提示文字
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor.white.withAlphaComponent(0.35),
        ]
        let line1: String
        let line2: String
        if dragActive {
            line1 = "🔒  拖拽中"
            line2 = ""
        } else {
            line1 = dragLockEnabled ? "长按后拖动可移动窗口" : "开启拖拽：长按后拖动"
            line2 = scrollModeEnabled ? "滚动模式：单指上下滚动" : "双指滑动滚动页面"
        }

        let lineH: CGFloat = 18
        let cx = bounds.midX
        let cy = bounds.midY
        (line1 as NSString).draw(
            at: CGPoint(x: cx - (line1 as NSString).size(withAttributes: attr).width / 2,
                        y: cy - lineH),
            withAttributes: attr)
        if !line2.isEmpty {
            (line2 as NSString).draw(
                at: CGPoint(x: cx - (line2 as NSString).size(withAttributes: attr).width / 2,
                            y: cy + 2),
                withAttributes: attr)
        }
    }

    // MARK: - Touch dispatch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? touches
        let count = all.count

        if count == 1 {
            fingerCount       = 1
            multiHandled      = false
            gestureStart      = Date()
            let pt            = touches.first!.location(in: self)
            sfStartPt = pt; sfLastPt = pt
            stopFling()
        } else if count == 2 {
            fingerCount = 2
            tfMode      = .undecided
            tfTotalMove = 0
            tfLastMid   = midpoint(event!)
            stopFling()
            if dragActive { fireDragUp(); dragActive = false; setNeedsDisplay() }
        } else if count == 3 || count == 4 {
            fingerCount = count
            mfStartMid  = midpointAll(event!)
            mfFired     = false
        } else if count == 5 {
            fingerCount = count
            mfStartSpan = spanAll(event!)
            mfFired     = false
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let ev = event else { return }
        switch fingerCount {
        case 1:    handleOneMove(ev)
        case 2:    handleTwoMove(ev)
        case 3, 4: handleMultiMove(ev, fingers: fingerCount)
        case 5:    handleFiveMove(ev)
        default: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let ev = event else { return }
        let remaining = (ev.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled })?.count ?? 0

        if fingerCount >= 2 && remaining < fingerCount {
            let fired = evaluateMultiUp(fingers: fingerCount, event: ev)
            if fired { multiHandled = true }

            // 2指松开 → 触发惯性滚动
            if fingerCount == 2 && tfMode == .scroll {
                startFlingIfNeeded()
            }
            fingerCount = remaining
        }

        if remaining == 0 && fingerCount == 1 {
            let elapsed = Date().timeIntervalSince(gestureStart)
            let moved   = dist(sfStartPt, sfLastPt)
            if !multiHandled && !dragActive && elapsed < Self.tapMs && moved < Self.tapMovePt {
                fireTap()
            } else if dragActive {
                fireDragUp(); dragActive = false; setNeedsDisplay()
            }
            fingerCount  = 0
            multiHandled = false
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if dragActive { fireDragUp(); dragActive = false; setNeedsDisplay() }
        stopFling()
        fingerCount = 0; multiHandled = false
    }

    // MARK: - 1指

    private func handleOneMove(_ event: UIEvent) {
        guard let touch = event.allTouches?.first else { return }
        let pt  = touch.location(in: self)
        let dx  = pt.x - sfLastPt.x
        let dy  = pt.y - sfLastPt.y

        // 滚动模式：单指纵向滚动
        if scrollModeEnabled {
            sfLastPt = pt
            guard dy != 0 else { return }
            let py = Int((dy * Self.scrollScale).clamped(-Self.scrollMaxPx, Self.scrollMaxPx))
            if py != 0 { onEvent?(.scrollPixels(x: 0, y: py)) }
            return
        }

        // 拖拽锁：长按后激活
        let elapsed = Date().timeIntervalSince(gestureStart)
        if dragLockEnabled && !dragActive && elapsed >= Self.longPressMs
            && dist(pt, sfStartPt) < Self.tapMovePt * 4 {
            dragActive = true
            impactHeavy.impactOccurred()
            onEvent?(.mouseDown(.left))
            setNeedsDisplay()
        }

        sfLastPt = pt
        guard dx != 0 || dy != 0 else { return }
        onEvent?(.mouseMove(dx: Float(dx * sensitivity), dy: Float(dy * sensitivity)))
    }

    // MARK: - 2指

    private func handleTwoMove(_ event: UIEvent) {
        let mid  = midpoint(event)
        let dX   = mid.x - tfLastMid.x
        let dY   = mid.y - tfLastMid.y

        if tfMode == .undecided {
            tfTotalMove += hypot(dX, dY)
            if tfTotalMove > 4 { tfMode = .scroll }
        }

        if tfMode == .scroll {
            let pyRaw = dY * Self.scrollScale
            let pxRaw = dX * Self.scrollScale
            let py = Int(pyRaw.clamped(-Self.scrollMaxPx, Self.scrollMaxPx))
            let px = Int(pxRaw.clamped(-Self.scrollMaxPx, Self.scrollMaxPx))
            if py != 0 || px != 0 { onEvent?(.scrollPixels(x: px, y: py)) }
            flingVelX = pxRaw * 0.9
            flingVelY = pyRaw * 0.9
        }
        tfLastMid = mid
    }

    // MARK: - 多指(3/4)

    private func handleMultiMove(_ event: UIEvent, fingers: Int) {
        guard !mfFired else { return }
        let mid = midpointAll(event)
        let dX  = mid.x - mfStartMid.x
        let dY  = mid.y - mfStartMid.y
        let d   = hypot(dX, dY)
        guard d >= Self.mfSwipePt else { return }

        mfFired = true
        let horiz = abs(dX) > abs(dY)
        impactMedium.impactOccurred()

        if fingers == 3 {
            if horiz {
                onEvent?(.switchDesktop(dX < 0 ? .left : .right))
            } else if dY < 0 {
                onEvent?(.missionControl)
            } else {
                onEvent?(.appExpose)
            }
        } else { // 4
            if horiz {
                onEvent?(.fourFingerSwipeH(dX < 0 ? .left : .right))
            } else {
                onEvent?(.fourFingerSwipeV(dY < 0 ? .up : .down))
            }
        }
    }

    // MARK: - 5指

    private func handleFiveMove(_ event: UIEvent) {
        guard !mfFired else { return }
        let span    = spanAll(event)
        guard mfStartSpan > 0 else { return }
        let ratio   = span / mfStartSpan
        if ratio < 0.62 {
            mfFired = true
            impactHeavy.impactOccurred()
            onEvent?(.launchpad)
        } else if ratio > 1.48 {
            mfFired = true
            impactHeavy.impactOccurred()
            onEvent?(.showDesktop)
        }
    }

    // MARK: - 多指松开判断

    private func evaluateMultiUp(fingers: Int, event: UIEvent) -> Bool {
        guard fingers == 2 else { return false }
        let elapsed = Date().timeIntervalSince(gestureStart)
        if tfMode == .undecided
            && elapsed < Self.twoTapMs
            && tfTotalMove < Self.twoTapMovePt {
            onEvent?(.mouseClick(.right))
            impactLight.impactOccurred()
            lastTapTime = .distantPast; prevTapTime = .distantPast
            return true
        }
        return false
    }

    // MARK: - 单击链 (1/2/3连击)

    private func fireTap() {
        let now   = Date()
        let gap1  = now.timeIntervalSince(lastTapTime)
        let gap2  = now.timeIntervalSince(prevTapTime)
        let near1 = dist(sfStartPt, lastTapPt) < Self.tapMovePt * 3
        let near2 = dist(sfStartPt, prevTapPt) < Self.tapMovePt * 3

        if gap1 < Self.doubleTapMs && near1
            && gap2 < Self.doubleTapMs * 2 && near2
            && lastTapTime > Date.distantPast && prevTapTime > Date.distantPast {
            // 三击
            onEvent?(.mouseTripleClick(.left))
            impactLight.impactOccurred()
            lastTapTime = .distantPast; prevTapTime = .distantPast
        } else if gap1 < Self.doubleTapMs && near1 && lastTapTime > Date.distantPast {
            // 双击
            onEvent?(.mouseDoubleClick(.left))
            impactLight.impactOccurred()
            prevTapTime = lastTapTime; prevTapPt = lastTapPt
            lastTapTime = now;         lastTapPt = sfStartPt
        } else {
            // 单击
            onEvent?(.mouseClick(.left))
            impactLight.impactOccurred()
            prevTapTime = lastTapTime; prevTapPt = lastTapPt
            lastTapTime = now;         lastTapPt = sfStartPt
        }
    }

    private func fireDragUp() {
        onEvent?(.mouseUp(.left))
    }

    // MARK: - Fling / 惯性滚动

    private func startFlingIfNeeded() {
        guard abs(flingVelX) > Self.flingMinPx || abs(flingVelY) > Self.flingMinPx else { return }
        stopFling()
        let link = CADisplayLink(target: self, selector: #selector(flingTick))
        link.add(to: .main, forMode: .common)
        flingTimer = link
    }

    @objc private func flingTick() {
        if abs(flingVelX) < Self.flingMinPx && abs(flingVelY) < Self.flingMinPx {
            stopFling(); return
        }
        let px = Int(flingVelX); let py = Int(flingVelY)
        if px != 0 || py != 0 { onEvent?(.scrollPixels(x: px, y: py)) }
        flingVelX *= Self.flingDecay
        flingVelY *= Self.flingDecay
    }

    private func stopFling() {
        flingTimer?.invalidate(); flingTimer = nil
        flingVelX = 0; flingVelY = 0
    }

    // MARK: - Geometry

    private func midpoint(_ event: UIEvent) -> CGPoint {
        let t = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }
            ?? []
        guard t.count >= 2 else { return .zero }
        let a = t[t.startIndex].location(in: self)
        let b = t[t.index(after: t.startIndex)].location(in: self)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func midpointAll(_ event: UIEvent) -> CGPoint {
        let t = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }
            ?? []
        guard !t.isEmpty else { return .zero }
        var sx: CGFloat = 0; var sy: CGFloat = 0
        for touch in t { let p = touch.location(in: self); sx += p.x; sy += p.y }
        return CGPoint(x: sx / CGFloat(t.count), y: sy / CGFloat(t.count))
    }

    private func spanAll(_ event: UIEvent) -> CGFloat {
        let t = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }
            ?? []
        guard !t.isEmpty else { return 0 }
        let mid = midpointAll(event)
        var s: CGFloat = 0
        for touch in t { s += dist(touch.location(in: self), mid) }
        return s / CGFloat(t.count)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - Comparable clamp

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

// MARK: - SwiftUI Wrapper

struct TouchpadRepresentable: UIViewRepresentable {
    var onEvent: (ControlEvent) -> Void
    var sensitivity: CGFloat
    var dragLockEnabled: Bool
    var scrollModeEnabled: Bool

    func makeUIView(context: Context) -> TouchpadView {
        let v = TouchpadView()
        v.onEvent          = onEvent
        v.sensitivity      = sensitivity
        v.dragLockEnabled  = dragLockEnabled
        v.scrollModeEnabled = scrollModeEnabled
        return v
    }

    func updateUIView(_ uiView: TouchpadView, context: Context) {
        uiView.onEvent          = onEvent
        uiView.sensitivity      = sensitivity
        uiView.dragLockEnabled  = dragLockEnabled
        uiView.scrollModeEnabled = scrollModeEnabled
    }
}
