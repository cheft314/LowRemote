import Foundation

/// 控制事件枚举，完整对齐 Android ControlEvent.kt 和 Mac InputSimulator.swift
enum ControlEvent {

    // MARK: - Mouse
    enum Button { case left, right }

    case mouseMove(dx: Float, dy: Float)
    case mouseAbsolute(normX: Float, normY: Float)
    case mouseClick(Button)
    case mouseDoubleClick(Button)
    case mouseTripleClick(Button)
    case mouseDown(Button)
    case mouseUp(Button)
    case mouseWheel(dy: Int)
    case mouseWheelH(dx: Int)
    case scrollPixels(x: Int, y: Int)

    // MARK: - Gestures
    enum SwipeDirection { case left, right, up, down }
    case missionControl
    case appExpose
    case switchDesktop(SwipeDirection)
    case fourFingerSwipeH(SwipeDirection)
    case fourFingerSwipeV(SwipeDirection)
    case launchpad
    case showDesktop

    // MARK: - Keyboard
    case keyPress(UInt16)
    case keyCombo(mods: String, code: UInt16)
    case typeText(String)

    // MARK: - Serialize → wire string
    /// 与 Android ControlEvent.serialize() 完全对齐
    func serialize() -> String {
        switch self {
        case .mouseMove(let dx, let dy):
            return "M:\(format(dx)),\(format(dy))"
        case .mouseAbsolute(let nx, let ny):
            return "MA:\(format(nx)),\(format(ny))"
        case .mouseClick(let btn):
            return "MC:\(btn == .left ? "L" : "R")"
        case .mouseDoubleClick(let btn):
            return "MDC:\(btn == .left ? "L" : "R")"
        case .mouseTripleClick(let btn):
            return "MTC:\(btn == .left ? "L" : "R")"
        case .mouseDown(let btn):
            return "MD:\(btn == .left ? "L" : "R")"
        case .mouseUp(let btn):
            return "MU:\(btn == .left ? "L" : "R")"
        case .mouseWheel(let dy):
            return "MW:\(dy)"
        case .mouseWheelH(let dx):
            return "MWH:\(dx)"
        case .scrollPixels(let x, let y):
            return "SP:\(x),\(y)"
        case .missionControl:
            return "GS:MC"
        case .appExpose:
            return "GS:AE"
        case .switchDesktop(let dir):
            return "GS:SD:\(dirStr(dir))"
        case .fourFingerSwipeH(let dir):
            return "GS:4H:\(dirStr(dir))"
        case .fourFingerSwipeV(let dir):
            return "GS:4V:\(dirStr(dir))"
        case .launchpad:
            return "GS:LP"
        case .showDesktop:
            return "GS:DESK"
        case .keyPress(let code):
            return "K:\(code)"
        case .keyCombo(let mods, let code):
            return "KC:\(mods),\(code)"
        case .typeText(let text):
            return "T:\(text)"
        }
    }

    private func format(_ v: Float) -> String {
        String(format: "%.2f", v)
    }
    private func dirStr(_ d: SwipeDirection) -> String {
        switch d {
        case .left:  return "L"
        case .right: return "R"
        case .up:    return "U"
        case .down:  return "D"
        }
    }
}
