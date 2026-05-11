import SwiftUI
import UIKit

@main
struct LowRemoteApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Root 路由

struct RootView: View {

    @Environment(AppState.self) private var appState
    @State private var showPermissionGuide = false

    var body: some View {
        ZStack {
            // 主内容路由
            Group {
                if appState.session.state == .connected {
                    RemoteView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal:   .move(edge: .leading).combined(with: .opacity)
                        ))
                } else {
                    DeviceListView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal:   .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(.spring(bounce: 0.15, blendDuration: 0.2),
                        value: appState.session.state)
        }
        .onAppear {
            if !appState.permissionGuideShown {
                showPermissionGuide = true
            }
        }
        // iPad 外接键盘：全局 hardware key commands
        .background(HardwareKeyboardHandler { event in
            appState.session.sendEvent(event)
        })
        // 权限引导 sheet
        .sheet(isPresented: $showPermissionGuide, onDismiss: {
            appState.permissionGuideShown = true
        }) {
            PermissionGuideView(isPresented: $showPermissionGuide)
        }
    }
}

// MARK: - iPad 外接键盘处理

/// UIKit responder 桥接：捕获硬件键盘事件并转换为 ControlEvent
private struct HardwareKeyboardHandler: UIViewRepresentable {
    let onEvent: (ControlEvent) -> Void

    func makeUIView(context: Context) -> KeyboardView {
        let v = KeyboardView()
        v.onEvent = onEvent
        return v
    }

    func updateUIView(_ uiView: KeyboardView, context: Context) {
        uiView.onEvent = onEvent
    }
}

final class KeyboardView: UIView, UIKeyInput {

    var onEvent: ((ControlEvent) -> Void)?

    var hasText: Bool { false }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    private static let keyCommandSpecs: [(input: String, modifiers: UIKeyModifierFlags, code: UInt16, title: String)] = [
        ("c",   .command,  MacKeyCode.c,       "复制"),
        ("v",   .command,  MacKeyCode.v,       "粘贴"),
        ("z",   .command,  MacKeyCode.z,       "撤销"),
        ("x",   .command,  MacKeyCode.x,       "剪切"),
        ("a",   .command,  MacKeyCode.a,       "全选"),
        ("f",   .command,  MacKeyCode.f,       "查找"),
        ("\t",  .command,  MacKeyCode.tab,     "切换应用"),
        (" ",   .command,  MacKeyCode.space,   "Spotlight"),
        (UIKeyCommand.inputEscape, [], MacKeyCode.escape, "取消"),
        (UIKeyCommand.inputUpArrow,    [], MacKeyCode.upArrow,    "上"),
        (UIKeyCommand.inputDownArrow,  [], MacKeyCode.downArrow,  "下"),
        (UIKeyCommand.inputLeftArrow,  [], MacKeyCode.leftArrow,  "左"),
        (UIKeyCommand.inputRightArrow, [], MacKeyCode.rightArrow, "右"),
    ]

    private static let keyCodeLookup: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for spec in KeyboardView.keyCommandSpecs {
            map[KeyboardView.lookupKey(spec.modifiers, spec.input)] = spec.code
        }
        return map
    }()

    private static func lookupKey(_ modifiers: UIKeyModifierFlags, _ input: String) -> String {
        "\(modifiers.rawValue)|\(input)"
    }

    // 构建 key commands：覆盖常用快捷键
    override var keyCommands: [UIKeyCommand]? {
        Self.keyCommandSpecs.map { spec in
            UIKeyCommand(
                title: spec.title,
                image: nil,
                action: #selector(handleKey(_:)),
                input: spec.input,
                modifierFlags: spec.modifiers,
                propertyList: nil
            )
        }
    }

    @objc private func handleKey(_ command: UIKeyCommand) {
        let mods = command.modifierFlags
        guard let input = command.input else { return }
        let key = Self.lookupKey(mods, input)
        guard let code = Self.keyCodeLookup[key] else { return }

        let event: ControlEvent
        if mods.contains(UIKeyModifierFlags.command) {
            event = .keyCombo(mods: "cmd", code: code)
        } else {
            event = .keyPress(code)
        }
        onEvent?(event)
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        onEvent?(.typeText(text))
    }

    func deleteBackward() {
        onEvent?(.keyPress(MacKeyCode.delete))
    }
}
