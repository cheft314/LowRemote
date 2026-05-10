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
    // We read it via NSEvent.mouseLocation (AppKit bottom-left origin) and
    // convert to CG coordinates (top-left origin, Y increases downward).
    //
    // The flip formula is: CG_y = primaryScreenHeight - AppKit_y
    // where primaryScreenHeight = CGDisplayBounds(CGMainDisplayID()).height.
    // This is the ONLY correct value to use — NSScreen.main can change when
    // the user moves the menu bar to a secondary display, causing wrong Y.
    private func currentCursorCG() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: loc.x, y: primaryH - loc.y)
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

        case .mouseTripleClick(let btn):
            tripleClickMouse(button: btn)

        case .mouseDown(let btn):
            setMouseButton(button: btn, down: true)

        case .mouseUp(let btn):
            setMouseButton(button: btn, down: false)

        case .mouseWheel(let dy):
            scrollWheel(wheel1: Int32(dy), wheel2: 0)

        case .mouseWheelH(let dx):
            scrollWheel(wheel1: 0, wheel2: Int32(dx))

        case .scrollPixels(let x, let y):
            // Direct pixel scroll — no multiplier needed, value already scaled on Android.
            // wheel1 > 0 = scroll UP; x/y follow the same sign convention.
            scrollPixels(x: Int32(x), y: Int32(y))

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
        // Clamp to the bounds of the currently-streamed display.
        // CGDisplayBounds uses the CG global coordinate system:
        //   • Primary display: origin (0,0) at top-left, Y increases downward
        //   • Secondary display to the right: minX = primaryW, minY = 0
        //   • Secondary display below:        minX = 0,       minY = primaryH
        // So clamping to (minX…maxX-1, minY…maxY-1) is always correct.
        let b = CGDisplayBounds(activeDisplayID)
        guard !b.isNull, !b.isInfinite, b.width > 0, b.height > 0 else { return p }
        return CGPoint(
            x: max(b.minX, min(p.x, b.maxX - 1)),
            y: max(b.minY, min(p.y, b.maxY - 1))
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

    private func tripleClickMouse(button: ControlEvent.MouseButton) {
        // clickCount=3 selects a full line in most macOS text editors.
        setMouseButton(button: button, down: true,  clickCount: 1)
        setMouseButton(button: button, down: false, clickCount: 1)
        setMouseButton(button: button, down: true,  clickCount: 2)
        setMouseButton(button: button, down: false, clickCount: 2)
        setMouseButton(button: button, down: true,  clickCount: 3)
        setMouseButton(button: button, down: false, clickCount: 3)
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

    private func scrollPixels(x: Int32, y: Int32) {
        // Pixel-accurate scroll from TouchpadView's velocity-proportional calculation.
        // wheel1 = vertical (positive = scroll UP content)
        // wheel2 = horizontal (positive = scroll LEFT content)
        CGEvent(scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: y,
                wheel2: x,
                wheel3: 0)?.post(tap: .cghidEventTap)
    }

    // MARK: - Gesture helpers
    //
    // Strategy: use NSEvent.otherEvent(with:) to inject real trackpad gesture
    // events.  These are the same event types AppKit delivers from a physical
    // Magic Trackpad and are recognised system-wide without any private API.
    //
    // References:
    //   • NSEvent.EventType.magnify  (.magnify, subtype 0x1D)
    //   • NSEvent.EventType.swipe    (.swipe,   subtype 0x1B)
    //   • NSEvent.otherEvent(with:location:modifierFlags:timestamp:
    //                        windowNumber:context:subtype:data1:data2:)
    //
    // Location: we use the *current cursor position* converted back to
    // AppKit coordinates (origin bottom-left) so the gesture lands on
    // whatever the cursor is hovering over.

    // ── Pinch-to-zoom ──────────────────────────────────────────────────────────
    //
    // NSEvent magnify: data1 = magnification as a fixed-point Int
    //   positive = zoom in, negative = zoom out
    //   The value is in units of 1/65536 (like CGFloat * 65536).
    //   A typical pinch spread of 0.1 (10%) → data1 = 6554.
    //
    // We emit three events: began (data2=1), changed (data2=4), ended (data2=8).
    // Most apps only need the "changed" event, but Safari/Preview need the
    // began/ended pair to correctly start/stop their zoom animation.
    private func postMagnify(scale: Float) {
        guard scale != 0 else { return }
        let loc   = nsEventLocation()
        let win   = NSApplication.shared.mainWindow?.windowNumber ?? 0
        let ts    = ProcessInfo.processInfo.systemUptime
        let mag   = Int(scale * 65536.0)   // fixed-point magnification

        // Phase constants: 1=NSEventPhaseBegan, 4=NSEventPhaseChanged, 8=NSEventPhaseEnded
        let phases: [(Int, Int)] = [(1, 0), (4, mag), (8, 0)]
        for (phase, d1) in phases {
            guard let ev = NSEvent.otherEvent(
                with: .magnify,
                location: loc,
                modifierFlags: [],
                timestamp: ts,
                windowNumber: win,
                context: nil,
                subtype: 0,
                data1: d1,
                data2: phase
            ) else { continue }
            NSApplication.shared.postEvent(ev, atStart: false)
        }
    }

    private func postRotate(radians: Float) {
        // Rotation has no universal reliable non-private equivalent.
        // Skip silently — rotation is a niche gesture.
        _ = radians
    }

    // ── Three-finger swipe (full-screen app switch / Mission Control) ──────────
    //
    // NSEvent swipe: data1 encodes the direction as a fixed-point unit vector.
    //   Right swipe → previous full-screen app:  data1 = +65536 (x = +1.0)
    //   Left  swipe → next     full-screen app:  data1 = -65536 (x = -1.0)
    //   Up    swipe → Mission Control:           data2 = +65536 (y = +1.0)
    //   Down  swipe → App Exposé:               data2 = -65536 (y = -1.0)
    //
    // This is the same event a real Magic Trackpad sends, so it works without
    // any special System Settings configuration.
    private func postThreeFingerSwipe(dx: Int = 0, dy: Int = 0) {
        let loc = nsEventLocation()
        let win = NSApplication.shared.mainWindow?.windowNumber ?? 0
        let ts  = ProcessInfo.processInfo.systemUptime

        // swipe data1 = x component (fixed-point), data2 = y component (fixed-point)
        let d1 = dx * 65536   // right=+65536, left=-65536
        let d2 = dy * 65536   // up=+65536, down=-65536

        guard let ev = NSEvent.otherEvent(
            with: .swipe,
            location: loc,
            modifierFlags: [],
            timestamp: ts,
            windowNumber: win,
            context: nil,
            subtype: 0,
            data1: d1,
            data2: d2
        ) else { return }
        NSApplication.shared.postEvent(ev, atStart: false)
    }

    private func postFourFingerSwipe(dx: Double, dy: Double) {
        // Four-finger = same semantics as three-finger on Magic Trackpad
        postThreeFingerSwipe(
            dx: dx > 0 ? 1 : (dx < 0 ? -1 : 0),
            dy: dy > 0 ? 1 : (dy < 0 ? -1 : 0)
        )
    }

    // ── Launchpad / Show Desktop ────────────────────────────────────────────────
    //
    // Five-finger pinch = Launchpad.  Five-finger spread = Show Desktop.
    // There is no public non-keyboard API for these, but the keyboard shortcuts
    // (F4 / Mission Control) are reliable when the user has them configured.
    // As a fallback we also try the CGEvent-based approach used by Accessibility.
    private func postFiveFingerPinch(expanding: Bool) {
        if expanding {
            // Show Desktop: Mission Control "show desktop" keyboard shortcut = F11
            // (Users can reassign in System Settings → Keyboard → Shortcuts)
            postKey(code: 103, down: true,  flags: []) // F11
            postKey(code: 103, down: false, flags: [])
        } else {
            // Launchpad: default F4 on most Macs
            postKey(code: 118, down: true,  flags: []) // F4
            postKey(code: 118, down: false, flags: [])
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    /// Current cursor position in AppKit window coordinates (origin = bottom-left
    /// of the *screen*, not the window — suitable for NSEvent.otherEvent location).
    private func nsEventLocation() -> NSPoint {
        // NSEvent.mouseLocation is already in screen AppKit coords (bottom-left origin).
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

        // Inject Unicode text via CGEvent on a BACKGROUND thread so we never
        // block the main thread (which would stall all subsequent event delivery).
        //
        // CGEvent(keyboardEventSource:) does NOT require the main thread — only
        // CGEvent.post(tap:.cghidEventTap) needs an active run-loop, but that
        // requirement is satisfied by any thread that calls it while the app's
        // CFRunLoop is spinning (which it always is for a menu-bar app).
        //
        // We send up to 8 UTF-16 code-units per CGEvent pair and space them
        // 15 ms apart so the system event queue never overflows.
        DispatchQueue.global(qos: .userInteractive).async {
            let chunkSize = 8
            var offset = 0
            while offset < utf16.count {
                let end   = min(offset + chunkSize, utf16.count)
                let chunk = Array(utf16[offset..<end])

                func post(_ down: Bool) {
                    guard let ev = CGEvent(keyboardEventSource: nil,
                                          virtualKey: 0,
                                          keyDown: down) else { return }
                    chunk.withUnsafeBufferPointer { ptr in
                        ev.keyboardSetUnicodeString(stringLength: chunk.count,
                                                   unicodeString: ptr.baseAddress!)
                    }
                    ev.post(tap: .cghidEventTap)
                }

                post(true)
                post(false)
                offset = end

                if offset < utf16.count {
                    // 15 ms between chunks — enough for the HID event queue to drain
                    // without blocking the main thread at all.
                    Thread.sleep(forTimeInterval: 0.015)
                }
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
