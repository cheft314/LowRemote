import Foundation
import CoreGraphics
import AppKit

/// Injects mouse/keyboard events into the macOS system via CGEvent.
///
/// 必须从主线程调用（由 UDPServer 的 DispatchQueue.main.async 保证）。
/// CGEvent.post(tap: .cghidEventTap) 需要辅助功能权限。
final class InputSimulator {

    // Remember whether we're mid-drag so ACTION_MOVE becomes leftMouseDragged.
    private var leftButtonDown = false

    /// The display currently being streamed; used to map touch coordinates
    /// correctly when the user has switched away from the main display.
    var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    func handleEvent(_ event: ControlEvent) {
        // 双重保险：强制在主线程执行
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handleEvent(event) }
            return
        }

        switch event {
        case .mouseMove(let dx, let dy):
            moveMouse(dx: dx, dy: dy)

        case .mouseClick(let btn):
            clickMouse(button: btn)

        case .mouseDoubleClick(let btn):
            doubleClickMouse(button: btn)

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
            // 先按下 modifier 标志再发 keyDown，松开时也要带 modifier，模拟真实键盘行为
            postKey(code: code, down: true, flags: modifiers)
            postKey(code: code, down: false, flags: modifiers)

        case .typeText(let text):
            typeText(text)
        }
    }

    // MARK: - Mouse

    private func currentCursor() -> CGPoint {
        // NSEvent.mouseLocation 是 AppKit 坐标（左下原点），转成 CG 坐标（左上原点）
        let loc = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 800
        return CGPoint(x: loc.x, y: screenH - loc.y)
    }

    private func moveMouse(dx: Double, dy: Double) {
        var point = currentCursor()
        point.x += CGFloat(dx)
        point.y += CGFloat(dy)

        // Clamp within the bounds of the active display (CG top-left origin).
        let displayBounds = CGDisplayBounds(activeDisplayID)
        // displayBounds is in CG global coordinates (y increases downward from primary top-left).
        let minX = displayBounds.minX
        let maxX = displayBounds.maxX - 1
        let minY = displayBounds.minY
        let maxY = displayBounds.maxY - 1
        point.x = max(minX, min(point.x, maxX))
        point.y = max(minY, min(point.y, maxY))

        let eventType: CGEventType = leftButtonDown ? .leftMouseDragged : .mouseMoved
        let mouseBtn: CGMouseButton = .left
        if let ev = CGEvent(mouseEventSource: nil,
                            mouseType: eventType,
                            mouseCursorPosition: point,
                            mouseButton: mouseBtn) {
            ev.post(tap: .cghidEventTap)
        }
    }

    private func clickMouse(button: ControlEvent.MouseButton) {
        postMouseButton(button: button, down: true, clickCount: 1)
        postMouseButton(button: button, down: false, clickCount: 1)
    }

    private func doubleClickMouse(button: ControlEvent.MouseButton) {
        // macOS requires clickCount=2 on the second down/up pair for a real double-click.
        postMouseButton(button: button, down: true, clickCount: 1)
        postMouseButton(button: button, down: false, clickCount: 1)
        postMouseButton(button: button, down: true, clickCount: 2)
        postMouseButton(button: button, down: false, clickCount: 2)
    }

    private func postMouseButton(button: ControlEvent.MouseButton, down: Bool, clickCount: Int64 = 1) {
        let point = currentCursor()
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let type: CGEventType
        switch (button, down) {
        case (.left, true):   type = .leftMouseDown
        case (.left, false):  type = .leftMouseUp
        case (.right, true):  type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        }
        if let ev = CGEvent(mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: cgButton) {
            ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
            ev.post(tap: .cghidEventTap)
        }
    }

    private func scrollWheel(dy: Int) {
        // CGEvent scrollWheelEvent2Source: wheel1 正值 = 向上滚动
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
            if !flags.isEmpty {
                ev.flags = flags
            }
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Unicode 文字注入 —— 通过 keyboardSetUnicodeString 绕过 keyCode 映射，
    /// 支持任意 Unicode（含中文）。
    /// 每次最多注入 16 个 UTF-16 码元，分段之间加 20ms 延迟，
    /// 防止系统事件队列溢出导致字符丢失。
    private func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }

        let chunkSize = 16
        var offset = 0
        while offset < utf16.count {
            let end = min(offset + chunkSize, utf16.count)
            let chunk = Array(utf16[offset..<end])

            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                chunk.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: base)
                    }
                }
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                chunk.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: base)
                    }
                }
                up.post(tap: .cghidEventTap)
            }

            offset = end
            if offset < utf16.count {
                // 20ms between chunks to let the input system digest events.
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }
}
