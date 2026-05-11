import SwiftUI
import UIKit

// MARK: - RemoteView
//
// 主控制页，支持三种布局自适应：
//   iPhone 竖屏  → 上视频 + 中快捷键 + 下触控板（3区纵向）
//   iPhone 横屏  → 左视频60% + 右(快捷键上45% + 触控板下55%)
//   iPad 横屏    → 左视频70% + 右控制区30%（宽松间距）
//
// Liquid Glass UI 设计：
//   • 全屏深黑背景 + 光晕装饰
//   • 所有控件使用 .liquidGlass / .glassButton 修饰
//   • 顶部状态栏浮层：连接信息 + 帧率 + 设置按钮
//   • 右侧设置抽屉（SettingsPanelView）

struct RemoteView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // MARK: - State
    @State private var showSettings     = false
    @State private var videoSurfaceView: VideoSurfaceView? = nil
    @State private var sensitivity:     CGFloat = 1.2
    @State private var dragLockEnabled  = false
    @State private var scrollModeEnabled = false
    @State private var absoluteMode     = true    // 视频区默认：绝对坐标模式（避免与右侧触控板重叠）
    @State private var showFilePicker   = false
    @State private var videoFrame       = CGRect.zero

    // HUD 自动隐藏
    @State private var hudVisible       = true
    @State private var hudTimer: Timer? = nil

    private var session: RemoteSession { appState.session }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 背景
                Color.black.ignoresSafeArea()

                // 布局选择
                if isPad(geo) || isLandscape(geo) {
                    landscapeLayout(geo)
                } else {
                    portraitLayout(geo)
                }

                // 顶部 HUD（悬浮层）
                VStack {
                    if hudVisible {
                        topHUD
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                }
                .animation(.spring(bounce: 0.1), value: hudVisible)

                // 设置面板
                if showSettings {
                    SettingsPanelView(
                        isPresented:     $showSettings,
                        sensitivity:     $sensitivity,
                        dragLockEnabled:  $dragLockEnabled,
                        scrollModeEnabled: $scrollModeEnabled,
                        absoluteMode:    $absoluteMode,
                        onSendFiles:     { showFilePicker = true }
                    )
                    .ignoresSafeArea()
                    .zIndex(10)
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onTapGesture { resetHudTimer() }
        .sheet(isPresented: $showFilePicker) { filePickerSheet }
        .toastOverlay(message: Binding(
            get: { appState.toastMessage },
            set: { appState.toastMessage = $0 }
        ))
        .onAppear {
            session.setVideoView(videoSurfaceView)
            resetHudTimer()
        }
        .onDisappear { hudTimer?.invalidate() }
        .onChange(of: session.state) { _, s in
            if s == .disconnected { appState.toastMessage = "连接已断开" }
        }
    }

    // MARK: - Landscape / iPad Layout

    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        let videoWeight: CGFloat = isPad(geo) ? 0.68 : 0.60

        return HStack(spacing: 0) {
            // ── 左侧：视频区 ──────────────────────────────────────────────
            ZStack {
                videoArea(geo: geo)
            }
            .frame(width: geo.size.width * videoWeight)

            // 分割线
            Rectangle()
                .fill(Color.lrDivider)
                .frame(width: 1)
                .padding(.vertical, 12)

            // ── 右侧：控制区 ──────────────────────────────────────────────
            VStack(spacing: 0) {
                // 右上：快捷键区（45%）
                ShortcutKeyboardView(onEvent: { session.sendEvent($0) })
                    .frame(height: geo.size.height * 0.44)
                    .padding(.horizontal, 4)
                    .padding(.top, 56) // 为 HUD 留空

                Divider()
                    .background(Color.lrDivider)
                    .padding(.horizontal, 12)

                // 右下：触控板区（55%）
                TouchpadRepresentable(
                    onEvent:          { session.sendEvent($0) },
                    sensitivity:      sensitivity,
                    dragLockEnabled:  dragLockEnabled,
                    scrollModeEnabled: scrollModeEnabled
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Portrait Layout (iPhone)

    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        let totalH = geo.size.height
        let videoH  = totalH * 0.38
        let keyH    = totalH * 0.28
        let padH    = totalH - videoH - keyH

        return VStack(spacing: 0) {
            // 上：视频区
            ZStack {
                videoArea(geo: geo)
            }
            .frame(height: videoH)

            Divider().background(Color.lrDivider)

            // 中：快捷键 + 输入
            ShortcutKeyboardView(onEvent: { session.sendEvent($0) })
                .frame(height: keyH)
                .padding(.horizontal, 4)

            Divider().background(Color.lrDivider)

            // 下：触控板
            TouchpadRepresentable(
                onEvent:          { session.sendEvent($0) },
                sensitivity:      sensitivity,
                dragLockEnabled:  dragLockEnabled,
                scrollModeEnabled: scrollModeEnabled
            )
            .frame(height: padH)
            .padding(8)
        }
        .padding(.top, 50)  // 为 HUD 留空
    }

    // MARK: - Video Area

    private func videoArea(geo: GeometryProxy) -> some View {
        ZStack {
            // 视频渲染层
            VideoSurface(
                remoteSize: Binding(
                    get: { session.remoteResolution ?? CGSize(width: 1920, height: 1080) },
                    set: { _ in }
                ),
                onViewReady: { view in
                    videoSurfaceView = view
                    session.setVideoView(view)
                }
            )
            .background(Color.black)

            // 触摸处理层（叠加在视频上）
            VideoTouchRepresentable(
                onEvent:      { session.sendEvent($0) },
                absoluteMode: absoluteMode,
                videoFrame:   videoFrame
            )

            // 视频区模式切换按钮（左下角）
            VStack {
                Spacer()
                HStack {
                    videaModeToggle
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Video Mode Toggle

    private var videaModeToggle: some View {
        Button {
            withAnimation(.spring(bounce: 0.2)) { absoluteMode.toggle() }
            appState.showToast(absoluteMode ? "触屏模式：点击直达" : "触控板模式：相对移动")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: absoluteMode ? "cursorarrow" : "hand.point.up.left.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(absoluteMode ? "触屏" : "触控板")
                    .font(.lrButtonSmall)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .liquidGlass(cornerRadius: 20, borderOpacity: 0.6, shadowRadius: 6)
        }
    }

    // MARK: - Top HUD

    private var topHUD: some View {
        HStack(spacing: 12) {
            // 连接状态指示
            connectionStatus

            Spacer()

            // 帧率
            fpsIndicator

            // 设置按钮
            settingsButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.lrDivider)
                .frame(height: 0.5)
        }
        .padding(.top, topSafeArea)
    }

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            // 绿色脉冲点
            ZStack {
                Circle()
                    .fill(Color.lrGreen.opacity(0.3))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(Color.lrGreen)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(deviceName)
                    .font(.lrBodyMedium)
                    .foregroundStyle(Color.lrTextPrimary)
                    .lineLimit(1)
                if let res = session.remoteResolution {
                    Text("\(Int(res.width)) × \(Int(res.height))")
                        .font(.lrMono)
                        .foregroundStyle(Color.lrTextTertiary)
                }
            }
        }
    }

    private var fpsIndicator: some View {
        Text("\(session.fps) fps")
            .font(.lrMono)
            .foregroundStyle(Color.lrAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassButton(cornerRadius: 8, isActive: false)
    }

    private var settingsButton: some View {
        Button {
            withAnimation(.spring(bounce: 0.15)) { showSettings.toggle() }
            resetHudTimer()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.lrTextPrimary)
                .frame(width: 36, height: 36)
                .glassButton(cornerRadius: 9)
        }
    }

    // MARK: - File Picker Sheet

    private var filePickerSheet: some View {
        FileTransferView { urls in
            session.sendFiles(urls: urls)
            showFilePicker = false
        }
    }

    // MARK: - HUD Auto-hide

    private func resetHudTimer() {
        hudTimer?.invalidate()
        withAnimation { hudVisible = true }
        hudTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.4)) { hudVisible = false }
        }
    }

    // MARK: - Helpers

    private var deviceName: String {
        session.screens.first(where: { $0.id == session.currentScreen })?.name
            ?? "Mac"
    }

    private var topSafeArea: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top) ?? 44
    }

    private func isPad(_ geo: GeometryProxy) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private func isLandscape(_ geo: GeometryProxy) -> Bool {
        geo.size.width > geo.size.height
    }
}
