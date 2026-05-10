import Foundation
import CoreGraphics

/// Parsed control event received over UDP.
///
/// String formats (per spec §5.2):
///   M:dx,dy        -> mouseMove(dx, dy)     // delta mode
///   MC:L           -> mouseClick(.left)
///   MC:R           -> mouseClick(.right)
///   MD:L           -> mouseDown(.left)
///   MU:L           -> mouseUp(.left)
///   MW:dy          -> mouseWheel(dy)
///   K:keyCode      -> keyPress(keyCode)
///   KC:mod,code    -> keyComboPress(mod, code)  (mod = cmd|ctrl|alt|shift)
///   T:text         -> typeText(text)
enum ControlEvent {
    case mouseMove(dx: Double, dy: Double)
    case mouseClick(MouseButton)
    case mouseDoubleClick(MouseButton)
    case mouseDown(MouseButton)
    case mouseUp(MouseButton)
    case mouseWheel(Int)
    case keyPress(CGKeyCode)
    case keyCombo(modifiers: CGEventFlags, keyCode: CGKeyCode)
    case typeText(String)

    enum MouseButton { case left, right }

    static func parse(_ s: String) -> ControlEvent? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let tag = String(s[..<colon])
        let args = String(s[s.index(after: colon)...])

        switch tag {
        case "M":
            let parts = args.split(separator: ",")
            guard parts.count == 2,
                  let dx = Double(parts[0]),
                  let dy = Double(parts[1]) else { return nil }
            return .mouseMove(dx: dx, dy: dy)

        case "MC":
            return button(from: args).map { .mouseClick($0) }

        case "MDC":
            return button(from: args).map { .mouseDoubleClick($0) }

        case "MD":
            return button(from: args).map { .mouseDown($0) }

        case "MU":
            return button(from: args).map { .mouseUp($0) }

        case "MW":
            if let dy = Int(args) { return .mouseWheel(dy) }
            return nil

        case "K":
            if let code = UInt16(args) { return .keyPress(CGKeyCode(code)) }
            return nil

        case "KC":
            let parts = args.split(separator: ",")
            guard parts.count == 2, let code = UInt16(parts[1]) else { return nil }
            var flags: CGEventFlags = []
            for modName in parts[0].split(separator: "+") {
                switch String(modName) {
                case "cmd": flags.insert(.maskCommand)
                case "ctrl": flags.insert(.maskControl)
                case "alt", "opt": flags.insert(.maskAlternate)
                case "shift": flags.insert(.maskShift)
                default: break
                }
            }
            return .keyCombo(modifiers: flags, keyCode: CGKeyCode(code))

        case "T":
            return .typeText(args)

        default:
            return nil
        }
    }

    private static func button(from s: String) -> MouseButton? {
        switch s {
        case "L": return .left
        case "R": return .right
        default: return nil
        }
    }
}
