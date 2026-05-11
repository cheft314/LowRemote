import SwiftUI
import AVFoundation
import Network

// MARK: - PermissionGuideView
//
// 首次启动时检测必要权限，引导用户授权：
//   1. 本地网络访问（无法主动请求，需用户同意弹窗）
//   2. 麦克风（可选，仅音频功能需要）
//
// 权限状态实时刷新（进入前台时重查）

struct PermissionGuideView: View {

    @Binding var isPresented: Bool
    @State private var micStatus:     AVAudioApplication.recordPermission = .undetermined
    @State private var networkStatus: NetworkStatus = .unknown

    enum NetworkStatus { case unknown, granted, denied }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.lrBgGradient.ignoresSafeArea()

                // 背景光晕
                Circle()
                    .fill(Color.lrAccent.opacity(0.10))
                    .frame(width: 280, height: 280)
                    .blur(radius: 70)
                    .offset(x: 60, y: -100)
                    .allowsHitTesting(false)

                VStack(spacing: 28) {
                    // 标题
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 48, weight: .medium))
                            .foregroundStyle(LinearGradient.lrAccentGradient)
                        Text("应用权限")
                            .font(.lrLargeTitle)
                            .foregroundStyle(Color.lrTextPrimary)
                        Text("LowRemote 需要以下权限才能正常使用")
                            .font(.lrBody)
                            .foregroundStyle(Color.lrTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    // 权限列表
                    VStack(spacing: 12) {
                        PermissionRow(
                            icon:    "wifi",
                            title:   "本地网络",
                            desc:    "用于 mDNS 发现和连接局域网内的 Mac",
                            status:  networkStatus == .granted ? .granted : .required,
                            onRequest: { requestNetworkPermission() }
                        )

                        PermissionRow(
                            icon:    "mic.fill",
                            title:   "麦克风",
                            desc:    "可选：将手机麦克风音频传输到 Mac",
                            status:  micPermissionStatus(),
                            onRequest: { requestMicPermission() }
                        )
                    }

                    // 说明
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.lrTextTertiary)
                        Text("如果弹窗未出现，请前往「设置」→「LowRemote」手动开启")
                            .font(.lrCaption)
                            .foregroundStyle(Color.lrTextTertiary)
                    }
                    .padding(12)
                    .liquidGlass(cornerRadius: 10, borderOpacity: 0.5)

                    Spacer()

                    // 继续按钮
                    Button {
                        isPresented = false
                    } label: {
                        Text("继续使用")
                            .font(.lrButton)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(LinearGradient.lrAccentGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Color.lrAccent.opacity(0.4), radius: 10, x: 0, y: 4)
                    }

                    // 设置跳转
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("前往系统设置")
                            .font(.lrCaption)
                            .foregroundStyle(Color.lrAccent)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .onAppear { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshStatus()
        }
    }

    // MARK: - Status helpers

    private func micPermissionStatus() -> PermissionRow.Status {
        switch micStatus {
        case .granted:      return .granted
        case .denied:       return .denied
        case .undetermined: return .required
        @unknown default:   return .required
        }
    }

    // MARK: - Actions

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                micStatus = AVAudioApplication.shared.recordPermission
            }
        }
    }

    private func requestNetworkPermission() {
        // 触发本地网络弹窗：尝试 UDP 连接本机触发系统权限提示
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                networkStatus = path.status == .satisfied ? .granted : .denied
            }
            monitor.cancel()
        }
        monitor.start(queue: DispatchQueue(label: "net.check"))
    }

    private func refreshStatus() {
        micStatus = AVAudioApplication.shared.recordPermission
    }
}

// MARK: - PermissionRow

private struct PermissionRow: View {

    enum Status {
        case required   // 未申请
        case granted    // 已授权
        case denied     // 已拒绝
        case optional   // 可选权限
    }

    let icon:      String
    let title:     String
    let desc:      String
    let status:    Status
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // 图标
            ZStack {
                Circle()
                    .fill(iconBg)
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            // 文字
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.lrBodyMedium)
                    .foregroundStyle(Color.lrTextPrimary)
                Text(desc)
                    .font(.lrCaption)
                    .foregroundStyle(Color.lrTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // 状态/按钮
            statusBadge
        }
        .padding(14)
        .liquidGlass(cornerRadius: 14, tint: status == .denied ? Color.lrRed : .clear)
    }

    private var iconBg: Color {
        switch status {
        case .granted:  return .lrGreen.opacity(0.15)
        case .denied:   return .lrRed.opacity(0.15)
        default:        return .lrAccent.opacity(0.12)
        }
    }

    private var iconColor: Color {
        switch status {
        case .granted:  return .lrGreen
        case .denied:   return .lrRed
        default:        return .lrAccent
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.lrGreen)

        case .denied:
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.lrButtonSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.lrRed)
            .clipShape(Capsule())

        case .required:
            Button("允许", action: onRequest)
                .font(.lrButtonSmall)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(LinearGradient.lrAccentGradient)
                .clipShape(Capsule())

        case .optional:
            Text("可选")
                .font(.lrCaption)
                .foregroundStyle(Color.lrTextTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassButton(cornerRadius: 8)
        }
    }
}
