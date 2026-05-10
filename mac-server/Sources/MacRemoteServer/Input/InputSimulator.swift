import Foundation
import CoreGraphics
import AppKit

/// Injects mouse, keyboard and trackpad-gesture events into the macOS system.
///
/// All calls MUST arrive on the main thread (enforced by UDPServer's
/// DispatchQueue.main.async dispatch).
final class InputSimulator {

    private var leftButtonDown = false

    // Serial queue for text injection — guarantees multiple rapid `T:` events
    // are processed in order without interleaving, and keeps the Thread.sleep
    // pauses off the main thread.
    private let textQueue = DispatchQueue(label: "LowRemote.InputSimulator.text")

    // Accumulated pinch scale for Cmd+=/Cmd+- batching.
    // Each magnify event only carries a small delta (~0.005); we batch until
    // the accumulated change crosses a threshold then fire one keystroke.
    private var pinchAccum: Float = 0

    /// Cache the last known cursor position for absolute-mode moves.
    /// Flip formula: CG_y = primaryScreenHeight - AppKit_y
    private func currentCursorCG() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: loc.x, y: primaryH - loc.y)
    }

    /// Display ID currently being streamed — set by AppDelegate when stream starts
    /// or the user switches screens.
    var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    func handleEvent(_ event: ControlEvent) {
        assert(Thread.isMainThread,
               "InputSimulator must be called on the main thread")
        switch event {
        // ── Mouse ──────────────────────────────────────────────────────────
        case .mouseMove(let dx, let dy):        moveMouse(dx: dx, dy: dy)
        case .mouseAbsolute(let nx, let ny):    moveMouseAbsolute(normX: nx, normY: ny)
        case .mouseClick(let btn):              clickMouse(button: btn)
        case .mouseDoubleClick(let btn):        doubleClickMouse(button: btn)
        case .mouseTripleClick(let btn):        tripleClickMouse(button: btn)
        case .mouseDown(let btn):               setMouseButton(button: btn, down: true)
        case .mouseUp(let btn):                 setMouseButton(button: btn, down: false)
        case .mouseWheel(let dy):               scrollWheel(wheel1: Int32(dy), wheel2: 0)
        case .mouseWheelH(let dx):              scrollWheel(wheel1: 0, wheel2: Int32(dx))
        case .scrollPixels(let x, let y):       scrollPixels(x: Int32(x), y: Int32(y))

        // ── Gestures ───────────────────────────────────────────────────────
        case .magnify(let scale):               postMagnify(scale: scale)
        case .rotate(let angle):                postRotate(radians: angle)
        case .missionControl:                   openMissionControl()
        case .appExpose:                        appExpose()
        case .switchDesktop(let dir):           switchSpace(right: dir == .right)
        case .fourFingerSwipeH(let dir):        switchSpace(right: dir == .right)
        case .fourFingerSwipeV(let dir):
            if dir == .up { openMissionControl() } else { showDesktop() }
        case .launchpad:                        openLaunchpad()
        case .showDesktop:                      showDesktop()

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

    // MARK: - Mouse helpers ─────────────────────────────────────────────────

    private func clampToScreen(_ p: CGPoint) -> CGPoint {
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
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func moveMouseAbsolute(normX: Float, normY: Float) {
        let bounds = CGDisplayBounds(activeDisplayID)
        guard !bounds.isNull else { return }
        let pt = clampToScreen(CGPoint(
            x: bounds.minX + CGFloat(normX) * bounds.width,
            y: bounds.minY + CGFloat(normY) * bounds.height
        ))
        let type: CGEventType = leftButtonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func clickMouse(button: ControlEvent.MouseButton) {
        setMouseButton(button: button, down: true,  clickCount: 1)
        setMouseButton(button: button, down: false, clickCount: 1)
    }

    private func doubleClickMouse(button: ControlEvent.MouseButton) {
        setMouseButton(button: button, down: true,  clickCount: 1)
        setMouseButton(button: button, down: false, clickCount: 1)
        setMouseButton(button: button, down: true,  clickCount: 2)
        setMouseButton(button: button, down: false, clickCount: 2)
    }

    private func tripleClickMouse(button: ControlEvent.MouseButton) {
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
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: pt, mouseButton: cgBtn) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
        ev.post(tap: .cghidEventTap)
    }

    private func scrollWheel(wheel1: Int32, wheel2: Int32) {
        let pixelMultiplier: Int32 = 20
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: wheel1 * pixelMultiplier,
                wheel2: wheel2 * pixelMultiplier,
                wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func scrollPixels(x: Int32, y: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: y, wheel2: x, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Gesture helpers ────────────────────────────────────────────────
    //
    // IMPORTANT: we do NOT use NSEvent.otherEvent(with:) for magnify/swipe —
    // Apple's implementation asserts that the type is one of
    // {.applicationDefined, .systemDefined, .appKitDefined, .periodic}
    // and will crash the app if given .magnify or .swipe.  The public API is
    // therefore not usable for synthesising those gestures.
    //
    // Instead we fall back to the most reliable cross-app mechanism:
    //   • Pinch-zoom → Cmd+= / Cmd+-  (works in Finder, Browser, Preview,
    //                                   Photos, Mail, Xcode, VS Code, Office,
    //                                   and nearly every Mac app)
    //   • 3-finger left/right → Ctrl+← / Ctrl+→  (Mission Control "Move left
    //     / right a space" default shortcut — enabled out of the box)
    //   • 3-finger up         → Mission Control.app via NSWorkspace
    //   • 3-finger down       → Ctrl+↓ (App Exposé, default shortcut)
    //   • 5-finger spread     → fn+F11 (Show Desktop)
    //   • 5-finger pinch      → Launchpad.app via NSWorkspace

    /// Pinch-to-zoom.  We accumulate small scale deltas until they cross a
    /// threshold, then fire a single Cmd+=/Cmd+- keystroke.  This is the
    /// most reliable cross-app zoom mechanism — every Mac app that supports
    /// zooming binds it to Cmd+Plus/Cmd+Minus.
    private func postMagnify(scale: Float) {
        guard scale != 0 else { return }
        pinchAccum += scale
        // Threshold: every ~0.12 of accumulated scale fires one keystroke.
        // This gives a smooth zoom that roughly matches native trackpad feel.
        let threshold: Float = 0.12
        while pinchAccum >= threshold {
            // Cmd+=  (key code 24 is "=" on the US keyboard)
            postKey(code: 24, down: true,  flags: .maskCommand)
            postKey(code: 24, down: false, flags: .maskCommand)
            pinchAccum -= threshold
        }
        while pinchAccum <= -threshold {
            // Cmd+-  (key code 27 is "-")
            postKey(code: 27, down: true,  flags: .maskCommand)
            postKey(code: 27, down: false, flags: .maskCommand)
            pinchAccum += threshold
        }
    }

    private func postRotate(radians: Float) {
        // No universal reliable non-private equivalent. Ignore.
        _ = radians
    }

    /// Mission Control — used by 3-finger swipe up AND by the "程序堆叠"
    /// shortcut button.  Opens the Mission Control application which is the
    /// official, system-sanctioned way to trigger the Spaces/Exposé overlay.
    private func openMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.open(url)
    }

    /// App Exposé — 3-finger swipe down.  Uses the default Ctrl+↓ shortcut
    /// which is enabled by default on macOS.
    private func appExpose() {
        postKey(code: 125, down: true,  flags: .maskControl) // ↓ = 125
        postKey(code: 125, down: false, flags: .maskControl)
    }

    /// Switch full-screen application / space (3-finger or 4-finger horizontal
    /// swipe).  Uses the default Ctrl+← / Ctrl+→ keyboard shortcut which is
    /// enabled by default in System Settings → Keyboard → Keyboard Shortcuts
    /// → Mission Control → "Move left/right a space".
    private func switchSpace(right: Bool) {
        let code: CGKeyCode = right ? 124 : 123  // → = 124, ← = 123
        postKey(code: code, down: true,  flags: .maskControl)
        postKey(code: code, down: false, flags: .maskControl)
    }

    /// Launchpad — a Mac app that shows all installed apps as an iOS-like
    /// grid of icons.
    ///
    /// NOTE: As of macOS 26 Tahoe, Apple removed Launchpad.  On those
    /// versions the binary does not exist, and `NSWorkspace.open` will fail
    /// silently.  We detect this and fall back to opening Spotlight (via
    /// Cmd+Space) which is Apple's intended replacement.
    private func openLaunchpad() {
        let url = URL(fileURLWithPath: "/System/Applications/Launchpad.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            // macOS 26+ — Launchpad is gone. Open Spotlight as a replacement.
            // Cmd+Space is the standard shortcut.
            postKey(code: 49 /* Space */, down: true,  flags: .maskCommand)
            postKey(code: 49,              down: false, flags: .maskCommand)
        }
    }

    /// Show Desktop — five-finger spread (or the "显示桌面" shortcut button).
    /// Uses fn+F11 which is the macOS default key binding for "Show Desktop"
    /// under System Settings → Keyboard → Keyboard Shortcuts → Mission Control.
    private func showDesktop() {
        // F11 = keyCode 103 + fn flag = "Show Desktop"
        let fn: CGEventFlags = .maskSecondaryFn
        postKey(code: 103, down: true,  flags: fn)
        postKey(code: 103, down: false, flags: fn)
    }

    // MARK: - Keyboard helpers ───────────────────────────────────────────────

    private func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        else { return }
        if !flags.isEmpty { ev.flags = flags }
        ev.post(tap: .cghidEventTap)
    }

    /// Inject Unicode text through CGEvent.
    ///
    /// Dispatched to a dedicated SERIAL queue so that:
    ///   1. Multiple rapid `T:` events are processed in order (no interleaving).
    ///   2. The Thread.sleep pauses between chunks never block the main
    ///      thread — which would otherwise stall every other UDP event.
    private func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }

        textQueue.async {
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
                    // 15 ms between chunks — HID event queue drains cleanly.
                    Thread.sleep(forTimeInterval: 0.015)
                }
            }
        }
    }

    private func parseMods(_ s: String) -> CGEventFlags {
        var f: CGEventFlags = []
        for part in s.split(separator: "+") {
            switch part {
            case "cmd":         f.insert(.maskCommand)
            case "ctrl":        f.insert(.maskControl)
            case "alt", "opt":  f.insert(.maskAlternate)
            case "shift":       f.insert(.maskShift)
            default: break
            }
        }
        return f
    }
}
