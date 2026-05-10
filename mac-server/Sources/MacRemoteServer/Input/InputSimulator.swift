import Foundation
import CoreGraphics
import AppKit

/// Injects mouse/keyboard events into the macOS system via CGEvent.
///
/// Requires the host process to have the Accessibility permission granted.
/// Mouse movement uses delta mode (accumulates onto the current cursor
/// position), which gives trackpad-like feel on the phone side.
final class InputSimulator {

    // Remember whether we're mid-drag so ACTION_MOVE becomes leftMouseDragged.
    private var leftButtonDown = false

    func handleEvent(_ event: ControlEvent) {
        switch event {
        case .mouseMove(let dx, let dy):
            moveMouse(dx: dx, dy: dy)

        case .mouseClick(let btn):
            let type = btn == .left ? CGMouseButton.left : CGMouseButton.right
            clickMouse(button: type)

        case .mouseDown(let btn):
            postMouseButton(button: btn, down: true)
            if btn == .left { leftButtonDown = true }

        case .mouseUp(let btn):
            postMouseButton(button: btn, down: false)
            if btn == .left { leftButtonDown = false }

        case .mouseWheel(let dy):
            scrollWheel(dy: dy)

        case .keyPress(let code):
            postKey(code: code, down: true, flags: [])
            postKey(code: code, down: false, flags: [])

        case .keyCombo(let modifiers, let code):
            postKey(code: code, down: true, flags: modifiers)
            postKey(code: code, down: false, flags: modifiers)

        case .typeText(let text):
            typeText(text)
        }
    }

    // MARK: - Mouse

    private func currentCursor() -> CGPoint {
        // NSEvent.mouseLocation is in AppKit (bottom-origin) coordinates; convert.
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) })
                    ?? NSScreen.main else {
            return CGPoint(x: loc.x, y: loc.y)
        }
        // Flip Y so we're in CG (top-origin) coordinates.
        let y = screen.frame.maxY - loc.y
        return CGPoint(x: loc.x, y: y)
    }

    private func moveMouse(dx: Double, dy: Double) {
        var point = currentCursor()
        point.x += CGFloat(dx)
        point.y += CGFloat(dy)

        // Clamp to the union of all screens so we can't push the cursor off-screen
        // (which CG would silently refuse).
        let unionFrame = NSScreen.screens.reduce(CGRect.zero) { acc, screen in
            acc.union(screen.frame)
        }
        if !unionFrame.isEmpty {
            let maxX = unionFrame.maxX - 1
            let maxY = unionFrame.maxY - 1
            point.x = min(max(point.x, unionFrame.minX), maxX)
            point.y = min(max(point.y, unionFrame.minY), maxY)
        }

        let type: CGEventType = leftButtonDown ? .leftMouseDragged : .mouseMoved
        let button: CGMouseButton = leftButtonDown ? .left : .left // irrelevant for .mouseMoved
        if let ev = CGEvent(mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: button) {
            ev.post(tap: .cghidEventTap)
        }
    }

    private func clickMouse(button: CGMouseButton) {
        postMouseButton(button: button == .left ? .left : .right, down: true)
        postMouseButton(button: button == .left ? .left : .right, down: false)
    }

    private func postMouseButton(button: ControlEvent.MouseButton, down: Bool) {
        let point = currentCursor()
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let type: CGEventType
        switch (button, down) {
        case (.left, true):  type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        }
        if let ev = CGEvent(mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: cgButton) {
            ev.post(tap: .cghidEventTap)
        }
    }

    private func scrollWheel(dy: Int) {
        if let ev = CGEvent(scrollWheelEvent2Source: nil,
                            units: .line,
                            wheelCount: 1,
                            wheel1: Int32(dy),
                            wheel2: 0,
                            wheel3: 0) {
            ev.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard

    private func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        if let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) {
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Best-effort Unicode text injection by setting the key event's unicode string.
    /// Works for plain text typing (including CJK characters) in most apps.
    private func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }

        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            utf16.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                }
            }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            utf16.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                }
            }
            up.post(tap: .cghidEventTap)
        }
    }
}
