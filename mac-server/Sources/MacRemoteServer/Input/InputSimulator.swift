import Foundation
import CoreGraphics
import AppKit

/// Injects mouse, keyboard and trackpad-gesture events into the macOS system.
///
/// All calls MUST arrive on the main thread (enforced by UDPServer's
/// DispatchQueue.main.async dispatch).  CGEvent.post(tap:.cghidEventTap)
/// and NSEvent.init(…) both require the main run-loop.
final class InputSimulator {

    private var leftButtonDown = false

    // Cache the last known cursor position for absolute-mode moves.
    // We read it via NSEvent.mouseLocation (AppKit bottom-origin → converted).
    private func currentCursorCG() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let h   = NSScreen.main?.frame.height ?? 800
        return CGPoint(x: loc.x, y: h - loc.y)
    }

    func handleEvent(_ event: ControlEvent) {
        assert(Thread.isMainThread,
               "InputSimulator must be called on the main thread")
        switch event {
        // ── Mouse delta ────────────────────────────────────────────────────
        case .mouseMove(let dx, let dy):
            moveMouse(dx: dx, dy: dy)

        case .mouseAbsolute(let nx, let ny):
            moveMouseAbsolute(normX: nx, normY: ny)

        case .mouseClick(let btn):
            clickMouse(button: btn)

        case .mouseDown(let btn):
            setMouseButton(button: btn, down: true)

        case .mouseUp(let btn):
            setMouseButton(button: btn, down: false)

        case .mouseWheel(let dy):
            scrollWheel(wheel1: Int32(dy), wheel2: 0)

        case .mouseWheelH(let dx):
            scrollWheel(wheel1: 0, wheel2: Int32(dx))

        // ── Gestures ───────────────────────────────────────────────────────
        case .magnify(let scale):
            postMagnify(scale: scale)

        case .rotate(let angle):
            postRotate(radians: angle)

        case .missionControl:
            postThreeFingerSwipe(dy: 1)

        case .appExpose:
            postThreeFingerSwipe(dy: -1)

        case .switchDesktop(let dir):
            postThreeFingerSwipe(dx: dir == .right ? -1 : 1)

        case .fourFingerSwipeH(let dir):
            postFourFingerSwipe(dx: dir == .right ? 1.0 : -1.0, dy: 0)

        case .fourFingerSwipeV(let dir):
            postFourFingerSwipe(dx: 0, dy: dir == .up ? 1.0 : -1.0)

        case .launchpad:
            postKeyCombo(keyCode: 160, flags: []) // F-key for Launchpad is device-specific
            // More reliable: simulate the system gesture event
            postFiveFingerPinch(expanding: false)

        case .showDesktop:
            postFiveFingerPinch(expanding: true)

        // ── Keyboard ───────────────────────────────────────────────────────
        case .keyPress(let code):
            postKey(code: CGKeyCode(code), down: true,  flags: [])
            postKey(code: CGKeyCode(code), down: false, flags: [])

        case .keyCombo(let mods, let code):
            let flags = parseMods(mods)
            postKey(code: CGKeyCode(code), down: true,  flags: flags)
            postKey(code: CGKeyCode(code), down: false, flags: flags)

        case .typeText(let text):
            typeText(text)
        }
    }

    // MARK: - Mouse helpers

    private func clampToScreen(_ p: CGPoint) -> CGPoint {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return p }
        // Build bounding rect in CG coordinates (top-origin)
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for s in screens {
            let h = NSScreen.main?.frame.height ?? s.frame.height
            let cgRect = CGRect(x: s.frame.minX, y: h - s.frame.maxY,
                                width: s.frame.width, height: s.frame.height)
            minX = min(minX, cgRect.minX); maxX = max(maxX, cgRect.maxX)
            minY = min(minY, cgRect.minY); maxY = max(maxY, cgRect.maxY)
        }
        return CGPoint(x: max(minX, min(p.x, maxX - 1)),
                       y: max(minY, min(p.y, maxY - 1)))
    }

    private func moveMouse(dx: Double, dy: Double) {
        var pt = currentCursorCG()
        pt.x += CGFloat(dx)
        pt.y += CGFloat(dy)
        pt = clampToScreen(pt)
        let type: CGEventType = leftButtonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: pt,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func moveMouseAbsolute(normX: Float, normY: Float) {
        guard let screen = NSScreen.main else { return }
        let scrW = screen.frame.width
        let scrH = screen.frame.height
        // normX/Y are 0…1 mapping to Mac's full screen in CG coords
        let pt = clampToScreen(CGPoint(x: CGFloat(normX) * scrW,
                                       y: CGFloat(normY) * scrH))
        let type: CGEventType = leftButtonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: pt,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func clickMouse(button: ControlEvent.MouseButton) {
        setMouseButton(button: button, down: true)
        setMouseButton(button: button, down: false)
    }

    private func setMouseButton(button: ControlEvent.MouseButton, down: Bool) {
        let pt = currentCursorCG()
        let cgBtn: CGMouseButton = (button == .left) ? .left : .right
        let type: CGEventType
        switch (button, down) {
        case (.left,  true):  type = .leftMouseDown;   leftButtonDown = true
        case (.left,  false): type = .leftMouseUp;     leftButtonDown = false
        case (.right, true):  type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        }
        CGEvent(mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: pt,
                mouseButton: cgBtn)?.post(tap: .cghidEventTap)
    }

    private func scrollWheel(wheel1: Int32, wheel2: Int32) {
        CGEvent(scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: wheel1,
                wheel2: wheel2,
                wheel3: 0)?.post(tap: .cghidEventTap)
    }

    // MARK: - Gesture helpers
    //
    // macOS gesture events are NSEvent subtype kIOHIDEventTypeGesture.
    // The cleanest way to synthesise them without private API is via
    // CGEvent with type=.gesture and the appropriate CGEventField values,
    // but the gesture-specific fields are not exposed in public headers.
    //
    // Practical alternative: use NSEvent.otherEvent(with:) to post scroll
    // and magnification events, which Cocoa recognises as trackpad gestures.

    private func postMagnify(scale: Float) {
        // NSEventTypeMagnify = 30
        guard let ev = NSEvent.otherEvent(
            with: NSEvent.EventType(rawValue: 30)!,
            location: mouseLocationForNS(),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) else { return }
        // magnification is stored via the magnification property but we can't
        // set it via otherEvent; use CGEvent approach instead.
        postCGMagnify(scale: CGFloat(scale))
    }

    private func postCGMagnify(scale: CGFloat) {
        // kCGEventMagnify = 29
        guard let ev = CGEvent(source: nil) else { return }
        ev.type = CGEventType(rawValue: 29) ?? .null
        // CGEventField for magnification value = 113 (kCGScrollWheelEventPointDeltaAxis1 neighbour)
        // This is the documented public value:
        // kCGEventMagnification = 113 in CGEventField (available since 10.5 but not in Swift headers)
        ev.setDoubleValueField(CGEventField(rawValue: 113)!, value: Double(scale))
        ev.post(tap: .cghidEventTap)
    }

    private func postRotate(radians: Float) {
        // kCGEventRotate = 18
        guard let ev = CGEvent(source: nil) else { return }
        ev.type = CGEventType(rawValue: 18) ?? .null
        // kCGEventRotation = 114
        ev.setDoubleValueField(CGEventField(rawValue: 114)!, value: Double(radians))
        ev.post(tap: .cghidEventTap)
    }

    /// Three-finger swipe gesture (dx/dy are -1, 0, or 1 direction indicators).
    private func postThreeFingerSwipe(dx: Int = 0, dy: Int = 0) {
        // Simulate three-finger swipe using a scroll event with phase + momentum.
        // macOS Mission Control / spaces are triggered by NSEvent scroll with
        // phase .began/.ended and large delta from a "trackpad" source.
        // The most reliable approach without private API is using CGEvent
        // kCGScrollWheelEventScrollPhase.
        //
        // For spaces switching, macOS listens to kCGEventScrollWheel with:
        //   - source subtype = kCGEventSourceStateHIDSystemState (trackpad)
        //   - ScrollPhase = 1 (began), then 4 (ended)
        //   - pointDeltaAxis1 or axis2 set
        //
        // In practice the simplest reliable cross-version method is keyboard shortcuts:
        let flags: CGEventFlags = [.maskControl]
        if dy > 0 {
            // Mission Control = Ctrl+Up
            postKey(code: 126, down: true, flags: flags)
            postKey(code: 126, down: false, flags: flags)
        } else if dy < 0 {
            // App Exposé = Ctrl+Down (requires enabling in System Settings)
            postKey(code: 125, down: true, flags: flags)
            postKey(code: 125, down: false, flags: flags)
        } else if dx > 0 {
            // Switch left (previous space) = Ctrl+Left
            postKey(code: 123, down: true, flags: flags)
            postKey(code: 123, down: false, flags: flags)
        } else if dx < 0 {
            // Switch right (next space) = Ctrl+Right
            postKey(code: 124, down: true, flags: flags)
            postKey(code: 124, down: false, flags: flags)
        }
    }

    private func postFourFingerSwipe(dx: Double, dy: Double) {
        // Four-finger left/right = switch between full-screen apps (same as 3-finger on Magic Trackpad)
        // Use Ctrl+Arrow same as three-finger
        postThreeFingerSwipe(dx: dx > 0 ? 1 : (dx < 0 ? -1 : 0),
                             dy: dy > 0 ? 1 : (dy < 0 ? -1 : 0))
    }

    private func postFiveFingerPinch(expanding: Bool) {
        if expanding {
            // Show Desktop = F11 (or Exposé shortcut) – use Mission Control display-desktop
            postKey(code: 103, down: true,  flags: []) // F11
            postKey(code: 103, down: false, flags: [])
        } else {
            // Launchpad = no standard key; use F4 which many Macs map to Launchpad
            postKey(code: 118, down: true,  flags: []) // F4
            postKey(code: 118, down: false, flags: [])
        }
    }

    private func mouseLocationForNS() -> NSPoint {
        return NSEvent.mouseLocation
    }

    // MARK: - Keyboard helpers

    private func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        postKey(code: keyCode, down: true,  flags: flags)
        postKey(code: keyCode, down: false, flags: flags)
    }

    private func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        if !flags.isEmpty { ev.flags = flags }
        ev.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }
        func makeEvent(_ down: Bool) -> CGEvent? {
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
        }
        if let ev = makeEvent(true) {
            utf16.withUnsafeBufferPointer {
                ev.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: $0.baseAddress!)
            }
            ev.post(tap: .cghidEventTap)
        }
        if let ev = makeEvent(false) {
            utf16.withUnsafeBufferPointer {
                ev.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: $0.baseAddress!)
            }
            ev.post(tap: .cghidEventTap)
        }
    }

    private func parseMods(_ s: String) -> CGEventFlags {
        var f: CGEventFlags = []
        for part in s.split(separator: "+") {
            switch part {
            case "cmd":   f.insert(.maskCommand)
            case "ctrl":  f.insert(.maskControl)
            case "alt", "opt": f.insert(.maskAlternate)
            case "shift": f.insert(.maskShift)
            default: break
            }
        }
        return f
    }
}
