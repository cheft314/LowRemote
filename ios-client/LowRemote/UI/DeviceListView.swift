import SwiftUI

// MARK: - DeviceListView

struct DeviceListView: View {

    @Environment(AppState.self) private var appState
    @State private var discovery  = MdnsDiscovery()
    @State private var discovered: [RemoteDevice] = []
    @State private var isScanning = false

    @State private var showManualEntry  = false
    @State private var showEditHost: RemoteDevice? = nil
    @State private var selectedFps = 60

    // 手动输入
    @State private var manualHost = ""
    @State private var manualPort = "8890"
    @State private var manualName = "我的 Mac"

    private var session: RemoteSession { appState.session }
    private var store:   SavedHostsStore { appState.hostsStore }

    // MARK: - Body

    var body: some View {
        ZStack {
            // 背景渐变
            LinearGradient.lrBgGradient
                .ignoresSafeArea()

            // 背景装饰光晕
            backgroundGlow

            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    if session.state == .connecting {
                        connectingBanner
                    }
                    discoveredSection
                    savedSection
                    manualAddButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .toastOverlay(message: Binding(
            get: { appState.toastMessage },
            set: { appState.toastMessage = $0 }
        ))
        .onAppear  { startScan() }
        .onDisappear { discovery.stopDiscovery() }
        .sheet(isPresented: $showManualEntry) { manualEntrySheet }
        .sheet(item: $showEditHost)           { editHostSheet($0) }
    }

    // MARK: - Background Glow

    private var backgroundGlow: some View {
        ZStack {
            Circle()
                .fill(Color.lrAccent.opacity(0.12))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: -80, y: -120)
            Circle()
                .fill(Color.lrPurple.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: 100, y: 200)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            HStack {
                // App 图标 + 名称
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient.lrAccentGradient)
                            .frame(width: 52, height: 52)
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LowRemote")
                            .font(.lrTitle)
                            .foregroundStyle(.lrTextPrimary)
                        Text("局域网 Mac 远程控制")
                            .font(.lrCaption)
                            .foregroundStyle(.lrTextSecondary)
                    }
                }
                Spacer()
                // 刷新按钮
                Button { startScan() } label: {
                    Image(systemName: isScanning ? "antenna.radiowaves.left.and.right" : "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.lrAccent)
                        .frame(width: 40, height: 40)
                        .glassButton(cornerRadius: 12)
                        .symbolEffect(.pulse, isActive: isScanning)
                }
            }

            // FPS 选择器
            fpsSelector
        }
    }

    private var fpsSelector: some View {
        HStack(spacing: 0) {
            ForEach([30, 60, 120], id: \.self) { fps in
                Button {
                    withAnimation(.spring(bounce: 0.2)) { selectedFps = fps }
                } label: {
                    Text("\(fps) fps")
                        .font(.lrButtonSmall)
                        .foregroundStyle(selectedFps == fps ? .white : .lrTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selectedFps == fps {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LinearGradient.lrAccentGradient)
                            }
                        }
                }
            }
        }
        .padding(4)
        .liquidGlass(cornerRadius: 12, shadowRadius: 6)
    }

    // MARK: - Connecting Banner

    private var connectingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.lrAccent)
            Text("正在连接…")
                .font(.lrBodyMedium)
                .foregroundStyle(.lrTextSecondary)
            Spacer()
            Button("取消") { session.disconnect() }
                .font(.lrButton)
                .foregroundStyle(.lrRed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlass(cornerRadius: 12, tint: .lrOrange)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Discovered Devices

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "wifi",
                title: "自动发现",
                subtitle: isScanning ? "正在扫描局域网…" : "已发现 \(discovered.count) 台设备"
            )

            if discovered.isEmpty {
                emptyDiscoveredCard
            } else {
                VStack(spacing: 8) {
                    ForEach(discovered) { device in
                        DeviceRow(
                            device: device,
                            isSaved: store.hosts.contains { $0.host == device.host },
                            onConnect: { connectTo(device) },
                            onSave:    { store.add(device); appState.showToast("已保存 \(device.name)") }
                        )
                    }
                }
            }
        }
    }

    private var emptyDiscoveredCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 28))
                .foregroundStyle(.lrTextTertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text("未发现设备")
                    .font(.lrBodyMedium)
                    .foregroundStyle(.lrTextSecondary)
                Text("请确保 Mac 已启动 LowRemote Server，且在同一局域网")
                    .font(.lrCaption)
                    .foregroundStyle(.lrTextTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 14, borderOpacity: 0.6)
    }

    // MARK: - Saved Hosts

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "bookmark.fill", title: "已保存", subtitle: "\(store.hosts.count) 台")

            if store.hosts.isEmpty {
                Text("连接后可保存主机，方便下次快速连接")
                    .font(.lrCaption)
                    .foregroundStyle(.lrTextTertiary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.hosts) { device in
                        DeviceRow(
                            device: device,
                            isSaved: true,
                            onConnect: { connectTo(device) },
                            onSave:    nil,
                            onEdit:    { showEditHost = device },
                            onDelete:  { store.remove(device) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Manual Add Button

    private var manualAddButton: some View {
        Button { showManualEntry = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.lrAccent)
                Text("手动输入 IP 地址")
                    .font(.lrButton)
                    .foregroundStyle(.lrAccent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .liquidGlass(cornerRadius: 14, borderOpacity: 0.7, tint: .lrAccent)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.lrAccent)
            Text(title)
                .font(.lrTitle2)
                .foregroundStyle(.lrTextPrimary)
            Spacer()
            Text(subtitle)
                .font(.lrCaption)
                .foregroundStyle(.lrTextTertiary)
        }
    }

    // MARK: - Sheets

    private var manualEntrySheet: some View {
        ManualHostSheet(
            name: $manualName,
            host: $manualHost,
            port: $manualPort
        ) { device in
            store.add(device)
            connectTo(device)
            showManualEntry = false
        }
    }

    private func editHostSheet(_ device: RemoteDevice) -> some View {
        EditHostSheet(device: device) { updated in
            store.update(updated)
            showEditHost = nil
        }
    }

    // MARK: - Actions

    private func startScan() {
        discovered.removeAll()
        isScanning = true
        discovery.onDeviceFound = { dev in
            withAnimation(.spring(bounce: 0.2)) {
                if !discovered.contains(where: { $0.host == dev.host }) {
                    discovered.append(dev)
                }
            }
        }
        discovery.onDeviceLost = { dev in
            withAnimation { discovered.removeAll { $0.host == dev.host } }
        }
        discovery.startDiscovery()
        // 3s 后停止扫描动画（扫描仍在后台运行）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            isScanning = false
        }
    }

    private func connectTo(_ device: RemoteDevice) {
        session.connect(device: device, fps: selectedFps)
    }
}

// MARK: - DeviceRow

private struct DeviceRow: View {
    let device:    RemoteDevice
    let isSaved:   Bool
    let onConnect: () -> Void
    var onSave:    (() -> Void)?
    var onEdit:    (() -> Void)?
    var onDelete:  (() -> Void)?

    @State private var pressed = false

    var body: some View {
        HStack(spacing: 14) {
            // 设备图标
            ZStack {
                Circle()
                    .fill(Color.lrAccent.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.lrAccent)
            }

            // 名称 + IP
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.lrBodyMedium)
                    .foregroundStyle(.lrTextPrimary)
                    .lineLimit(1)
                Text("\(device.host):\(device.tcpPort)")
                    .font(.lrMono)
                    .foregroundStyle(.lrTextTertiary)
            }

            Spacer()

            // 操作按钮组
            HStack(spacing: 8) {
                if let onSave = onSave, !isSaved {
                    iconButton("bookmark", color: .lrAccent, action: onSave)
                }
                if let onEdit = onEdit {
                    iconButton("pencil", color: .lrTextSecondary, action: onEdit)
                }
                if let onDelete = onDelete {
                    iconButton("trash", color: .lrRed, action: onDelete)
                }
                // 连接按钮
                Button(action: onConnect) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("连接")
                            .font(.lrButtonSmall)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(LinearGradient.lrAccentGradient)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .liquidGlass(cornerRadius: 14)
        .scaleEffect(pressed ? 0.98 : 1.0)
        .animation(.spring(bounce: 0.3), value: pressed)
    }

    private func iconButton(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .glassButton(cornerRadius: 8)
        }
    }
}

// MARK: - ManualHostSheet

private struct ManualHostSheet: View {
    @Binding var name: String
    @Binding var host: String
    @Binding var port: String
    let onAdd: (RemoteDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    enum Field { case name, host, port }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.lrBgGradient.ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        glassField("设备名称", text: $name, icon: "desktopcomputer",
                                   focus: $focusedField, field: .name)
                        glassField("IP 地址", text: $host, icon: "network",
                                   focus: $focusedField, field: .host,
                                   keyboard: .decimalPad)
                        glassField("TCP 端口", text: $port, icon: "number",
                                   focus: $focusedField, field: .port,
                                   keyboard: .numberPad)
                    }
                    .padding(.top, 8)

                    Button {
                        guard !host.isEmpty else { return }
                        let device = RemoteDevice(
                            name: name.isEmpty ? "Mac" : name,
                            host: host,
                            tcpPort: UInt16(port) ?? 8890,
                            udpPort: 8891
                        )
                        onAdd(device)
                    } label: {
                        Text("添加并连接")
                            .font(.lrButton)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(LinearGradient.lrAccentGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(host.isEmpty)
                    .opacity(host.isEmpty ? 0.5 : 1)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("手动添加主机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.lrAccent)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func glassField(
        _ placeholder: String, text: Binding<String>,
        icon: String,
        focus: FocusState<Field?>.Binding,
        field: Field,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.lrAccent)
                .frame(width: 24)
            TextField(placeholder, text: text)
                .font(.lrBody)
                .foregroundStyle(.lrTextPrimary)
                .focused(focus, equals: field)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .liquidGlass(cornerRadius: 12)
    }
}

// MARK: - EditHostSheet

private struct EditHostSheet: View {
    let device:   RemoteDevice
    let onSave:   (RemoteDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var port: String

    init(device: RemoteDevice, onSave: @escaping (RemoteDevice) -> Void) {
        self.device = device; self.onSave = onSave
        _name = State(initialValue: device.name)
        _host = State(initialValue: device.host)
        _port = State(initialValue: String(device.tcpPort))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.lrBgGradient.ignoresSafeArea()
                VStack(spacing: 16) {
                    Group {
                        editField("名称", text: $name, icon: "desktopcomputer")
                        editField("IP 地址", text: $host, icon: "network")
                        editField("端口", text: $port, icon: "number")
                    }
                    .padding(.top, 8)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("编辑主机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(.lrAccent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(RemoteDevice(id: device.id, name: name, host: host,
                                            tcpPort: UInt16(port) ?? device.tcpPort,
                                            udpPort: device.udpPort))
                    }
                    .font(Font.lrButton)
                    .foregroundStyle(.lrAccent)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func editField(_ placeholder: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.lrAccent)
                .frame(width: 22)
            TextField(placeholder, text: text)
                .font(.lrBody)
                .foregroundStyle(.lrTextPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .liquidGlass(cornerRadius: 12)
    }
}
