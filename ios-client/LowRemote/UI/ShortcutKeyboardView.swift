import SwiftUI

// MARK: - ShortcutKeyboardView
//
// 快捷键区 + 文字输入，完整对齐 Android ShortcutKeyboard.kt

struct ShortcutKeyboardView: View {

    var onEvent: (ControlEvent) -> Void

    @State private var inputText     = ""
    @FocusState private var inputFocused: Bool

    // MARK: - 快捷键数据模型

    struct ShortcutKey: Identifiable {
        let id    = UUID()
        let label: String
        let icon:  String?
        let event: ControlEvent
    }

    // MARK: - 三行快捷键定义（完整对齐 Android）

    private let row1: [ShortcutKey] = [
        ShortcutKey(label: "⌘C", icon: "doc.on.doc",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.c)),
        ShortcutKey(label: "⌘V", icon: "doc.on.clipboard",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.v)),
        ShortcutKey(label: "⌘Z", icon: "arrow.uturn.backward",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.z)),
        ShortcutKey(label: "⌘X", icon: "scissors",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.x)),
        ShortcutKey(label: "⌘A", icon: "checkmark.square",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.a)),
    ]

    private let row2: [ShortcutKey] = [
        ShortcutKey(label: "⌘⇥",  icon: "rectangle.2.swap",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.tab)),
        ShortcutKey(label: "⌘⎵",  icon: "magnifyingglass",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.space)),
        ShortcutKey(label: "⎋",   icon: "escape",
                    event: .keyPress(MacKeyCode.escape)),
        ShortcutKey(label: "⏎",   icon: "return",
                    event: .keyPress(MacKeyCode.return)),
        ShortcutKey(label: "⌫",   icon: "delete.left",
                    event: .keyPress(MacKeyCode.delete)),
    ]

    private let row3: [ShortcutKey] = [
        ShortcutKey(label: "↑",   icon: "arrow.up",
                    event: .keyPress(MacKeyCode.upArrow)),
        ShortcutKey(label: "↓",   icon: "arrow.down",
                    event: .keyPress(MacKeyCode.downArrow)),
        ShortcutKey(label: "←",   icon: "arrow.left",
                    event: .keyPress(MacKeyCode.leftArrow)),
        ShortcutKey(label: "→",   icon: "arrow.right",
                    event: .keyPress(MacKeyCode.rightArrow)),
        ShortcutKey(label: "⌘F",  icon: "magnifyingglass.circle",
                    event: .keyCombo(mods: "cmd", code: MacKeyCode.f)),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 6) {
            keyRow(row1)
            keyRow(row2)
            keyRow(row3)
            textInputArea
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Key Row

    private func keyRow(_ keys: [ShortcutKey]) -> some View {
        HStack(spacing: 5) {
            ForEach(keys) { key in
                KeyButton(key: key, onEvent: onEvent)
            }
        }
    }

    // MARK: - Text Input

    private var textInputArea: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.lrAccent)

                TextField("输入文字发送到 Mac…", text: $inputText)
                    .font(.lrBody)
                    .foregroundStyle(Color.lrTextPrimary)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { sendText() }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if !inputText.isEmpty {
                    Button { inputText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.lrTextTertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlass(cornerRadius: 10)

            Button(action: sendText) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(inputText.isEmpty ? Color.lrTextTertiary : .white)
                    .frame(width: 38, height: 38)
                    .background(
                        inputText.isEmpty
                            ? AnyShapeStyle(Color.white.opacity(0.07))
                            : AnyShapeStyle(LinearGradient.lrAccentGradient)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(inputText.isEmpty)
        }
    }

    // MARK: - Actions

    private func sendText() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onEvent(.typeText(t))
        inputText    = ""
        inputFocused = false
    }
}

// MARK: - KeyButton

private struct KeyButton: View {
    let key:     ShortcutKeyboardView.ShortcutKey
    let onEvent: (ControlEvent) -> Void
    @State private var isPressed = false

    var body: some View {
        Button {
            onEvent(key.event)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Group {
                if let icon = key.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text(key.label)
                        .font(.lrButtonSmall)
                }
            }
            .foregroundStyle(isPressed ? Color.white : Color.lrTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .glassButton(cornerRadius: 8, isActive: isPressed)
        }
        .buttonStyle(PressButtonStyle(isPressed: $isPressed))
    }
}

// MARK: - Press Button Style

private struct PressButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(duration: 0.12, bounce: 0.3), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, v in isPressed = v }
    }
}
