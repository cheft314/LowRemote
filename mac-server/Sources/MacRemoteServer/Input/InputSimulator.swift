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

    /// Display ID currently being streamed — set by AppDelegate when stream starts
    /// or the user switches screens.  Used to clamp touch/touchpad moves correctly.
    var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

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

        case .mouseDoubleClick(let btn):
            doubleClickMouse(button: btn)

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
        // Clamp to the bounds of the currently-streamed display so that
        // touch/touchpad events from the phone land on the correct screen.
        let bounds = CGDisplayBounds(activeDisplayID)
        guard !bounds.isNull, !bounds.isInfinite else { return p }
        return CGPoint(
            x: max(bounds.minX, min(p.x, bounds.maxX - 1)),
            y: max(bounds.minY, min(p.y, bounds.maxY - 1))
        )
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
        // Map normalized 0…1 coordinates onto the currently-streamed display.
        let bounds = CGDisplayBounds(activeDisplayID)
        guard !bounds.isNull else { return }
        let pt = clampToScreen(CGPoint(
            x: bounds.minX + CGFloat(normX) * bounds.width,
            y: bounds.minY + CGFloat(normY) * bounds.height
        ))
        let type: CGEventType = leftButtonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: pt,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func clickMouse(button: ControlEvent.MouseButton) {
        setMouseButton(button: button, down: true,  clickCount: 1)
        setMouseButton(button: button, down: false, clickCount: 1)
    }

    private func doubleClickMouse(button: ControlEvent.MouseButton) {
        // macOS requires clickCount=2 on the *second* down/up pair.
        setMouseButton(button: button, down: true,  clickCount: 1)
        setMouseButton(button: button, down: false, clickCount: 1)
        setMouseButton(button: button, down: true,  clickCount: 2)
        setMouseButton(button: button, down: false, clickCount: 2)
    }

    private func setMouseButton(button: ControlEvent.MouseButton, down: Bool,
                                 clickCount: Int64 = 1) {
        let pt = currentCursorCG()
        let cgBtn: CGMouseButton = (button == .left) ? .left : .right
        let type: CGEventType
        switch (button, down) {
        case (.left,  true):  type = .leftMouseDown;   leftButtonDown = true
        case (.left,  false): type = .leftMouseUp;     leftButtonDown = false
        case (.right, true):  type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        }
        guard let ev = CGEvent(mouseEventSource: nil,
                               mouseType: type,
                               mouseCursorPosition: pt,
                               mouseButton: cgBtn) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
        ev.post(tap: .cghidEventTap)
    }

    private func scrollWheel(wheel1: Int32, wheel2: Int32) {
        // 使用 .pixel 单位并放大倍数，确保滚动速度合理且方向正确。
        // .line 单位每次只发 ±1 行，速度太慢；.pixel 单位可以直接控制像素偏移量。
        // Android 传来的 wheel1/2 是 ±1（每个 tick），乘以 20 得到合理的像素速度。
        // 注意：CGEventPost(.cghidEventTap) 注入的事件绕过了系统"自然滚动"翻转，
        // 所以这里的符号就是最终效果：wheel1 > 0 = 内容向上滚。
        let pixelMultiplier: Int32 = 20
        CGEvent(scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: wheel1 * pixelMultiplier,
                wheel2: wheel2 * pixelMultiplier,
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

    /// Synthesise a pinch-to-zoom gesture using a CGEvent scroll with pixel deltas.
    /// We use scroll event field kCGScrollWheelEventPointDeltaAxis1/2 which
    /// Cocoa's event system translates into a magnify gesture for apps that
    /// listen to NSEventTypeMagnify, and also maps to system-level zoom in Safari,
    /// Preview etc.  This approach never touches NSEvent (avoids the crash on
    /// macOS 26 where kCGEventMagnify = 29 was removed from public CGEventType).
    ///
    /// Reliable, documented, no private API.
    private func postMagnify(scale: Float) {
        // Positive scale = zoom-in; negative = zoom-out.
        // We send a wheel event with modifier kCGEventFlagMaskCommand which
        // macOS interprets as "pinch" in most apps. This is the same mechanism
        // that Accessibility Zoom uses.
        // Better: use Ctrl+scroll which is the universal "zoom scroll" shortcut.
        let scrollDelta = Int32(scale * 300) // scale 0.05 → 15 lines
        guard let ev = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: scrollDelta,
                               wheel2: 0,
                               wheel3: 0) else { return }
        ev.flags = .maskControl  // Ctrl+scroll = zoom in virtually every Mac app
        ev.post(tap: .cghidEventTap)
    }

    private func postRotate(radians: Float) {
        // Rotation has no universal non-private equivalent.
        // Skip silently — rotation is a niche gesture; we don't want a crash.
        _ = radians
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

        // Inject in chunks of ≤16 UTF-16 code-units.
        // Sending all characters in one CGEvent pair causes the system event
        // queue to drop characters silently when the string is long.
        let chunkSize = 16
        var offset = 0
        while offset < utf16.count {
            let end   = min(offset + chunkSize, utf16.count)
            let chunk = Array(utf16[offset..<end])
            func post(_ down: Bool) {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                else { return }
                chunk.withUnsafeBufferPointer {
                    ev.keyboardSetUnicodeString(stringLength: chunk.count,
                                               unicodeString: $0.baseAddress!)
                }
                ev.post(tap: .cghidEventTap)
            }
            post(true); post(false)
            offset = end
            if offset < utf16.count {
                // 20 ms pause so the system event queue drains between chunks.
                Thread.sleep(forTimeInterval: 0.02)
            }
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
