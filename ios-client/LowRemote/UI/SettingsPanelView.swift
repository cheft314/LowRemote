import SwiftUI

// MARK: - SettingsPanelView
//
// 从右侧滑入的设置抽屉，包含：
// - 帧率切换
// - 显示器切换
// - 音频开关（Mac音/麦克风）
// - 触控板灵敏度
// - 拖拽锁 / 滚动模式
// - 触控模式（绝对/相对）
// - 文件发送
// - 断开连接

struct SettingsPanelView: View {

    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    @Binding var sensitivity:      CGFloat
    @Binding var dragLockEnabled:  Bool
    @Binding var scrollModeEnabled: Bool
    @Binding var absoluteMode:     Bool

    var onSendFiles: () -> Void

    private var session: RemoteSession { appState.session }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .trailing) {
            // 半透明遮罩
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            // 面板本体
            panel
                .frame(width: panelWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .animation(.spring(bounce: 0.15), value: isPresented)
    }

    // MARK: - Panel

    private var panel: some View {
        ZStack {
            // 背景
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            // 高光边
            Rectangle()
                .fill(LinearGradient.lrGlassHighlight)
                .ignoresSafeArea()

            // 左边框
            HStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Color.lrAccent.opacity(0.5), Color.lrPurple.opacity(0.3)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 1)
                    .ignoresSafeArea()
                Spacer()
            }

            // 内容
            ScrollView {
                VStack(spacing: 0) {
                    panelHeader
                    Divider().background(Color.lrDivider).padding(.horizontal, 20)
                    contentStack
                }
            }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.lrTitle)
                    .foregroundStyle(.lrTextPrimary)
                if let dev = session.screens.first(where: { $0.id == session.currentScreen }) {
                    Text(dev.name)
                        .font(.lrCaption)
                        .foregroundStyle(.lrAccent)
                }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.lrTextTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    // MARK: - Content

    private var contentStack: some View {
        VStack(spacing: 20) {
            fpsSection
            if session.screens.count > 1 { screensSection }
            audioSection
            touchpadSection
            controlModeSection
            fileSection
            disconnectSection
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 40)
    }

    // MARK: - FPS Section

    private var fpsSection: some View {
        SettingsSection(title: "视频帧率", icon: "film") {
            HStack(spacing: 0) {
                ForEach([30, 60, 120], id: \.self) { fps in
                    Button {
                        withAnimation(.spring(bounce: 0.2)) { session.changeFps(fps) }
                    } label: {
                        Text("\(fps)")
                            .font(.lrButtonSmall)
                            .foregroundStyle(session.fps == fps ? .white : .lrTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background {
                                if session.fps == fps {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(LinearGradient.lrAccentGradient)
                                }
                            }
                    }
                }
            }
            .padding(4)
            .liquidGlass(cornerRadius: 10)
        }
    }

    // MARK: - Screens Section

    private var screensSection: some View {
        SettingsSection(title: "显示器", icon: "display.2") {
            VStack(spacing: 6) {
                ForEach(session.screens) { screen in
                    Button {
                        session.switchScreen(screen.id)
                    } label: {
                        HStack {
                            Image(systemName: session.currentScreen == screen.id
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(session.currentScreen == screen.id
                                                 ? .lrAccent : .lrTextTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(screen.name)
                                    .font(.lrBodyMedium)
                                    .foregroundStyle(.lrTextPrimary)
                                Text("\(screen.width) × \(screen.height)")
                                    .font(.lrMono)
                                    .foregroundStyle(.lrTextTertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .glassButton(cornerRadius: 10,
                                     isActive: session.currentScreen == screen.id)
                    }
                }
            }
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        SettingsSection(title: "音频", icon: "speaker.wave.2") {
            VStack(spacing: 8) {
                ToggleRow(
                    title: "Mac 系统音频",
                    subtitle: "接收 Mac 的声音到本机",
                    icon: "speaker.wave.2.fill",
                    isOn: Binding(
                        get: { !session.audioEnabled },  // 系统音与麦克风互斥，默认开
                        set: { _ in }
                    )
                )
                Divider().background(Color.lrDivider)
                ToggleRow(
                    title: "麦克风",
                    subtitle: "将本机麦克风传到 Mac",
                    icon: "mic.fill",
                    isOn: Binding(
                        get: { session.audioEnabled },
                        set: { session.setAudioEnabled($0) }
                    )
                )
            }
            .padding(12)
            .liquidGlass(cornerRadius: 12)
        }
    }

    // MARK: - Touchpad Section

    private var touchpadSection: some View {
        SettingsSection(title: "触控板", icon: "hand.point.up.left") {
            VStack(spacing: 10) {
                // 灵敏度
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("移动灵敏度")
                            .font(.lrCaption)
                            .foregroundStyle(.lrTextSecondary)
                        Spacer()
                        Text(String(format: "%.1f", sensitivity))
                            .font(.lrMono)
                            .foregroundStyle(.lrAccent)
                    }
                    Slider(value: $sensitivity, in: 0.5...3.0, step: 0.1)
                        .tint(.lrAccent)
                }

                Divider().background(Color.lrDivider)

                ToggleRow(title: "拖拽锁定",
                          subtitle: "长按后移动可拖拽窗口",
                          icon: "lock.open",
                          isOn: $dragLockEnabled)

                Divider().background(Color.lrDivider)

                ToggleRow(title: "单指滚动模式",
                          subtitle: "单指上下滑动变为滚动",
                          icon: "scroll",
                          isOn: $scrollModeEnabled)
            }
            .padding(12)
            .liquidGlass(cornerRadius: 12)
        }
    }

    // MARK: - Control Mode

    private var controlModeSection: some View {
        SettingsSection(title: "视频区操作", icon: "cursorarrow.click") {
            VStack(spacing: 0) {
                controlModeOption(
                    title: "绝对坐标模式",
                    subtitle: "点哪里鼠标就到哪里",
                    icon: "cursorarrow",
                    isSelected: absoluteMode
                ) { absoluteMode = true }

                Divider().background(Color.lrDivider).padding(.horizontal, 12)

                controlModeOption(
                    title: "触控板模式",
                    subtitle: "相对移动，支持多指手势",
                    icon: "hand.point.up.left.fill",
                    isSelected: !absoluteMode
                ) { absoluteMode = false }
            }
            .liquidGlass(cornerRadius: 12)
        }
    }

    private func controlModeOption(title: String, subtitle: String,
                                    icon: String, isSelected: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? .lrAccent : .lrTextTertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.lrBodyMedium)
                        .foregroundStyle(isSelected ? .lrTextPrimary : .lrTextSecondary)
                    Text(subtitle)
                        .font(.lrCaption2)
                        .foregroundStyle(.lrTextTertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.lrAccent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - File Section

    private var fileSection: some View {
        SettingsSection(title: "文件传输", icon: "arrow.up.doc") {
            Button(action: { onSendFiles(); close() }) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.lrAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发送文件到 Mac")
                            .font(.lrBodyMedium)
                            .foregroundStyle(.lrTextPrimary)
                        Text("文件将保存到 ~/Downloads")
                            .font(.lrCaption2)
                            .foregroundStyle(.lrTextTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.lrTextTertiary)
                }
                .padding(12)
                .liquidGlass(cornerRadius: 12)
            }

            // 传输进度
            if let progress = session.fileTransferProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("传输中…")
                            .font(.lrCaption)
                            .foregroundStyle(.lrTextSecondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.lrMono)
                            .foregroundStyle(.lrAccent)
                    }
                    ProgressView(value: progress)
                        .tint(.lrAccent)
                }
                .padding(12)
                .liquidGlass(cornerRadius: 12, tint: .lrAccent)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    // MARK: - Disconnect

    private var disconnectSection: some View {
        Button {
            session.disconnect()
            close()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                Text("断开连接")
                    .font(.lrButton)
            }
            .foregroundStyle(.lrRed)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .liquidGlass(cornerRadius: 14, tint: .lrRed)
        }
    }

    // MARK: - Helpers

    private func close() {
        withAnimation(.spring(bounce: 0.15)) { isPresented = false }
    }

    private var panelWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.82, 360)
    }
}

// MARK: - Reusable subviews

private struct SettingsSection<Content: View>: View {
    let title:   String
    let icon:    String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.lrAccent)
                Text(title)
                    .font(.lrCaption)
                    .foregroundStyle(.lrTextTertiary)
                    .textCase(.uppercase)
                    .kerning(0.5)
            }
            content
        }
    }
}

private struct ToggleRow: View {
    let title:    String
    let subtitle: String
    let icon:     String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? .lrAccent : .lrTextTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.lrBodyMedium)
                    .foregroundStyle(.lrTextPrimary)
                Text(subtitle)
                    .font(.lrCaption2)
                    .foregroundStyle(.lrTextTertiary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.lrAccent)
        }
    }
}
