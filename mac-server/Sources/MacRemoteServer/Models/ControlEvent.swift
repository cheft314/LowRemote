import Foundation
import CoreGraphics

/// Parsed control event received over UDP from the Android client.
///
/// See Android ControlEvent.kt for the canonical wire-format documentation.
enum ControlEvent {

    // Mouse
    case mouseMove(dx: Double, dy: Double)           // M:dx,dy
    case mouseAbsolute(normX: Float, normY: Float)   // MA:nx,ny
    case mouseClick(MouseButton)                     // MC:L/R
    case mouseDoubleClick(MouseButton)               // MDC:L/R
    case mouseDown(MouseButton)                      // MD:L/R
    case mouseUp(MouseButton)                        // MU:L/R
    case mouseWheel(Int)                             // MW:dy
    case mouseWheelH(Int)                            // MWH:dx

    // Gestures
    case magnify(Float)                              // GZ:scale
    case rotate(Float)                               // GR:angle
    case missionControl                              // GME:
    case appExpose                                   // GAD:
    case switchDesktop(DesktopDir)                   // GSD:L/R
    case fourFingerSwipeH(DesktopDir)               // G4H:L/R
    case fourFingerSwipeV(VDir)                     // G4V:U/D
    case launchpad                                   // GLP:
    case showDesktop                                 // GDT:

    // Keyboard
    case keyPress(CGKeyCode)                         // K:code
    case keyCombo(modifiers: String, keyCode: CGKeyCode) // KC:mods,code
    case typeText(String)                            // T:text

    enum MouseButton { case left, right }
    enum DesktopDir  { case left, right }
    enum VDir        { case up, down }

    // MARK: - Parse

    static func parse(_ s: String) -> ControlEvent? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let tag  = String(s[..<colon])
        let args = String(s[s.index(after: colon)...])

        switch tag {
        // ── Mouse ──────────────────────────────────────────────────────────
        case "M":
            let p = args.split(separator: ",")
            guard p.count == 2, let dx = Double(p[0]), let dy = Double(p[1]) else { return nil }
            return .mouseMove(dx: dx, dy: dy)

        case "MA":
            let p = args.split(separator: ",")
            guard p.count == 2, let nx = Float(p[0]), let ny = Float(p[1]) else { return nil }
            return .mouseAbsolute(normX: nx, normY: ny)

        case "MC": return btn(args).map { .mouseClick($0) }
        case "MDC": return btn(args).map { .mouseDoubleClick($0) }
        case "MD": return btn(args).map { .mouseDown($0) }
        case "MU": return btn(args).map { .mouseUp($0) }
        case "MW": return Int(args).map { .mouseWheel($0) }
        case "MWH": return Int(args).map { .mouseWheelH($0) }

        // ── Gestures ───────────────────────────────────────────────────────
        case "GZ": return Float(args).map { .magnify($0) }
        case "GR": return Float(args).map { .rotate($0) }
        case "GME": return .missionControl
        case "GAD": return .appExpose
        case "GSD": return args == "L" ? .switchDesktop(.left) : .switchDesktop(.right)
        case "G4H": return args == "L" ? .fourFingerSwipeH(.left) : .fourFingerSwipeH(.right)
        case "G4V": return args == "U" ? .fourFingerSwipeV(.up) : .fourFingerSwipeV(.down)
        case "GLP": return .launchpad
        case "GDT": return .showDesktop

        // ── Keyboard ───────────────────────────────────────────────────────
        case "K":
            guard let code = UInt16(args) else { return nil }
            return .keyPress(CGKeyCode(code))

        case "KC":
            let p = args.split(separator: ",")
            guard p.count == 2, let code = UInt16(p[1]) else { return nil }
            return .keyCombo(modifiers: String(p[0]), keyCode: CGKeyCode(code))

        case "T":
            return .typeText(args)

        default:
            return nil
        }
    }

    private static func btn(_ s: String) -> MouseButton? {
        switch s { case "L": return .left; case "R": return .right; default: return nil }
    }
}
