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

        // 夹在所有屏幕的联合区域内
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        // 注意：CGRect 里 y 还是 AppKit bottom-origin，这里 point.y 已经是 CG top-origin
        // 简化处理：只夹 x
        if !union.isNull {
            point.x = max(0, min(point.x, union.maxX - 1))
            // 对 y：CG top-origin，0 是顶部，maxH-1 是底部
            let maxH = NSScreen.main?.frame.height ?? 800
            point.y = max(0, min(point.y, maxH - 1))
        }

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
        postMouseButton(button: button, down: true)
        postMouseButton(button: button, down: false)
    }

    private func postMouseButton(button: ControlEvent.MouseButton, down: Bool) {
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
