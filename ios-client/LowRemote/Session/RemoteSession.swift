import Foundation
import UIKit
import SwiftUI

/// 远程会话生命周期管理，完整对齐 Android RemoteSession.kt
///
/// 负责：TCP 控制通道、UDP 视频接收、帧重组、解码、音频双向、文件传输、心跳
@Observable
final class RemoteSession {

    // MARK: - State

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
    }

    private(set) var state:            State          = .idle
    private(set) var remoteResolution: CGSize?        = nil
    private(set) var fps:              Int            = 60
    private(set) var screens:          [ScreenInfo]   = []
    private(set) var currentScreen:    Int            = 0
    private(set) var audioEnabled:     Bool           = false
    private(set) var fileTransferProgress: Double?    = nil   // 0.0-1.0，nil=空闲

    struct ScreenInfo: Identifiable {
        let id:     Int
        let name:   String
        let width:  Int
        let height: Int
    }

    // MARK: - Components

    private let tcp       = TcpClient()
    private let receiver  = UdpReceiver(port: 0)      // 0 = 系统分配端口
    private let sender    = UdpSender()
    private let assembler = FrameAssembler()
    private var decoder:  H265Decoder?

    private let macAudioPlayer = AudioPlayer()
    private let audioCapture   = AudioCapture()

    // 视频渲染视图（由 VideoSurface SwiftUI wrapper 注入）
    private weak var videoView: VideoSurfaceView?

    private var device: RemoteDevice?
    private var eventFrameId: UInt32 = 0

    // 心跳
    private var heartbeatTask: Task<Void, Never>?

    // 文件传输（原子标志位）
    private var fileReadySignal: Bool = false
    private let fileReadyLock = NSLock()

    // 后台任务
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // 解码器锁
    private let decoderLock = NSLock()

    // MARK: - Init

    init() {
        assembler.onFrameReady = { [weak self] data, isKeyframe in
            self?.decoder?.feed(data: data, isKeyframe: isKeyframe)
        }
        receiver.onPacket = { [weak self] parsed, payload, _ in
            switch parsed.type {
            case Packet.typeVideo:
                self?.assembler.onPacket(parsed, payload)
            case Packet.typeSystemAudio:
                self?.macAudioPlayer.write(payload)
            default:
                break
            }
        }
        tcp.onLine = { [weak self] line in
            self?.handleTcpLine(line)
        }
        tcp.onDisconnected = { [weak self] in
            Task { await self?.teardown() }
        }
        audioCapture.onAudioChunk = { [weak self] pcm in
            guard let self = self else { return }
            self.sender.sendAudio(pcm, frameId: self.nextFrameId())
        }
    }

    // MARK: - Video Surface

    func setVideoView(_ view: VideoSurfaceView?) {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        videoView = view
        guard let v = view else { return }
        // 更新已运行解码器的渲染目标
        if let dec = decoder {
            dec.displayLayer = v.displayLayer
            return
        }
        // 解码器尚未启动：若已连接则立即启动（补偿 RESOLUTION/OK 到达时 view 还未注入的竞态）
        if state == .connected {
            startDecoderLocked(view: v)
        }
    }

    // MARK: - Connect

    func connect(device: RemoteDevice, fps: Int = 60) {
        guard state == .idle || state == .disconnected else { return }
        state      = .connecting
        self.device = device
        self.fps    = fps

        Task {
            await performConnect(device: device, fps: fps)
        }
    }

    private func performConnect(device: RemoteDevice, fps: Int) async {
        beginBackgroundTask()

        receiver.start()
        sender.attach(fd: receiver.rawFd, host: device.host, port: device.udpPort)

        // 先发 HELLO，让 Mac 记录客户端 UDP 端点（clientEndpoint）
        // 必须等 HELLO 实际送出后再建立 TCP 连接并发 FPS 命令
        // 否则 Mac 收到 FPS 时 clientEndpoint=nil，startStreaming 产生的帧全部丢弃
        sender.sendEvent("HELLO", frameId: nextFrameId())
        // 等待底层 sendto 完成：sender 内部用 async queue，给 50ms 让 HELLO 包离开发送队列
        try? await Task.sleep(nanoseconds: 50_000_000)

        let ok = await tcp.connect(host: device.host, port: device.tcpPort)
        guard ok else {
            await teardown(); return
        }

        tcp.send("FPS:\(fps)")
        macAudioPlayer.start()

        await MainActor.run {
            state = .connected
        }
        startHeartbeat()
    }

    // MARK: - Controls

    func changeFps(_ newFps: Int) {
        fps = newFps
        guard state == .connected else { return }
        // flush 在后台执行避免主线程阻塞
        decoderLock.lock()
        let dec = decoder
        decoderLock.unlock()
        if let dec = dec {
            DispatchQueue.global(qos: .userInitiated).async {
                dec.flush()
            }
        }
        assembler.reset()
        tcp.send("FPS:\(newFps)")
    }

    func switchScreen(_ index: Int) {
        guard state == .connected else { return }
        currentScreen = index

        // 取出旧解码器并置空（在锁内操作引用，锁外执行 stop 避免死锁）
        decoderLock.lock()
        let oldDecoder = decoder
        decoder = nil
        decoderLock.unlock()

        // stop() 内部会 Invalidate VT session，可能阻塞等待回调完成
        // 在后台线程执行防止主线程卡死
        if let old = oldDecoder {
            DispatchQueue.global(qos: .userInitiated).async {
                old.stop()
            }
        }

        assembler.reset()
        tcp.send("SCREEN:\(index)")
    }

    func sendEvent(_ event: ControlEvent) {
        guard state == .connected else { return }
        let str = event.serialize()
        let fid = nextFrameId()
        sender.sendEvent(str, frameId: fid)
    }

    // MARK: - Audio

    func setAudioEnabled(_ enabled: Bool) {
        guard enabled != audioEnabled else { return }
        audioEnabled = enabled
        if enabled, state == .connected {
            tcp.send("AUDIO_ON")
            audioCapture.start()
        } else {
            audioCapture.stop()
            if state == .connected { tcp.send("AUDIO_OFF") }
        }
    }

    // MARK: - File Transfer

    /// 发送文件列表到 Mac ~/Downloads
    func sendFiles(urls: [URL]) {
        guard state == .connected, !urls.isEmpty else { return }
        Task(priority: .userInitiated) {
            for url in urls {
                await sendSingleFile(url: url)
            }
            await MainActor.run { fileTransferProgress = nil }
        }
    }

    private func sendSingleFile(url: URL) async {
        let fileName = url.lastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int, fileSize > 0 else {
            NSLog("[FileTransfer] 无法获取文件大小: \(url.lastPathComponent)"); return
        }

        NSLog("[FileTransfer] 开始 \(fileName) \(fileSize) bytes")
        await MainActor.run { fileTransferProgress = 0 }

        tcp.send("FILE_START:\(fileName):\(fileSize)")

        // 等待 Mac 回复 FILE_READY（最多 5 秒）
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            fileReadyLock.lock()
            let ready = fileReadySignal
            if ready { fileReadySignal = false }
            fileReadyLock.unlock()
            if ready { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // 流式发送文件字节
        guard let stream = InputStream(url: url) else { return }
        stream.open()
        defer { stream.close() }

        let chunkSize = 32_768  // 32KB
        var buf = [UInt8](repeating: 0, count: chunkSize)
        var sent = 0

        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: chunkSize)
            guard read > 0 else { break }
            tcp.sendRaw(Data(buf[0..<read]))
            sent += read
            let progress = Double(sent) / Double(fileSize)
            await MainActor.run { fileTransferProgress = progress }
        }

        tcp.send("FILE_END")
        NSLog("[FileTransfer] 完成 \(fileName) \(sent) bytes")
    }

    // MARK: - Disconnect

    func disconnect() {
        guard state != .idle else { return }
        if tcp.isConnected { tcp.send("DISCONNECT") }
        Task { await teardown() }
    }

    // MARK: - TCP 命令处理

    private func handleTcpLine(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if t.hasPrefix("RESOLUTION:") {
            let parts = t.dropFirst("RESOLUTION:".count).split(separator: ",")
            if let w = Int(parts.first ?? ""), let h = Int(parts.last ?? "") {
                remoteResolution = CGSize(width: w, height: h)
                videoView?.remoteSize = CGSize(width: w, height: h)
                // RESOLUTION 到达时无论之前是否收到 OK，都（重新）启动解码器
                // 这样能处理两种时序：
                //   · 初始连接：RESOLUTION → SCREENS → iOS发FPS → OK（解码器已在此启动）
                //   · 切屏：OK → startStreaming → RESOLUTION（先 OK 后 RESOLUTION，
                //     此时解码器为 nil，RESOLUTION 到达后才真正启动）
                startDecoderIfReady()
            }
        } else if t.hasPrefix("SCREENS:") {
            let list = t.dropFirst("SCREENS:".count).split(separator: ",").compactMap { entry -> ScreenInfo? in
                let parts = entry.split(separator: ":")
                guard parts.count >= 3,
                      let idx = Int(parts[0]) else { return nil }
                let name = String(parts[1])
                let dims = parts[2].split(separator: "x")
                let w = Int(dims.first ?? "0") ?? 0
                let h = Int(dims.last  ?? "0") ?? 0
                return ScreenInfo(id: idx, name: name, width: w, height: h)
            }
            if !list.isEmpty { screens = list }
        } else if t == "OK" {
            // Mac 在两个场景发 OK：
            //   1. FPS 命令回应（初始连接）：之后会收到 RESOLUTION，届时启动解码器
            //   2. SCREEN 切换回应：紧接着 startStreaming，再发 RESOLUTION
            // 两种情况都在 RESOLUTION 处理里统一启动解码器，这里不提前启动，
            // 避免使用旧分辨率创建解码器后被 RESOLUTION 覆盖。
            NSLog("[Session] 收到 OK，等待 RESOLUTION 后启动解码器")
        } else if t == "PONG" {
            // 心跳回应，忽略
        } else if t == "FILE_READY" {
            fileReadyLock.lock()
            fileReadySignal = true
            fileReadyLock.unlock()
        } else if t.hasPrefix("FILE_OK:") {
            let name = String(t.dropFirst("FILE_OK:".count))
            NSLog("[FileTransfer] Mac 已接收: \(name)")
        } else if t.hasPrefix("FILE_ERR:") {
            NSLog("[FileTransfer] Mac 报错: \(t.dropFirst("FILE_ERR:".count))")
        }
    }

    // MARK: - Decoder

    private func startDecoderIfReady() {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        // 若 videoView 尚未注入（onViewReady 还未回调），延迟到主线程下一 runloop 再试一次
        guard let v = videoView else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.decoderLock.lock()
                defer { self.decoderLock.unlock() }
                guard let v = self.videoView else { return }
                self.startDecoderLocked(view: v)
            }
            return
        }
        startDecoderLocked(view: v)
    }

    private func startDecoderLocked(view: VideoSurfaceView) {
        guard decoder == nil else { return }
        let size = remoteResolution ?? CGSize(width: 1920, height: 1080)
        let dec  = H265Decoder(fps: fps)
        dec.displayLayer = view.displayLayer   // 直接绑定到 AVSampleBufferDisplayLayer
        dec.start()
        decoder = dec
        NSLog("[Session] 解码器启动 \(Int(size.width))x\(Int(size.height)) @ \(fps)fps")
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled, state == .connected {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
                guard state == .connected else { break }
                tcp.send("PING")
            }
        }
    }

    // MARK: - Teardown

    @MainActor
    private func teardown() {
        heartbeatTask?.cancel(); heartbeatTask = nil

        if audioEnabled { tcp.send("AUDIO_OFF") }
        audioCapture.stop()
        audioEnabled = false
        macAudioPlayer.stop()

        tcp.disconnect()
        receiver.stop()

        decoderLock.lock()
        let oldDecoder = decoder
        decoder = nil
        decoderLock.unlock()
        // stop 在后台避免主线程死锁
        if let old = oldDecoder {
            DispatchQueue.global(qos: .userInitiated).async { old.stop() }
        }

        videoView?.flush()
        assembler.reset()
        fileReadyLock.lock()
        fileReadySignal = false
        fileReadyLock.unlock()
        fileTransferProgress = nil

        remoteResolution = nil
        screens          = []
        currentScreen    = 0
        device           = nil

        state = .disconnected

        endBackgroundTask()
    }

    // MARK: - Frame ID

    private func nextFrameId() -> UInt32 {
        eventFrameId = (eventFrameId &+ 1) & 0x7FFFFFFF
        return eventFrameId
    }

    // MARK: - Background Task

    private func beginBackgroundTask() {
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "LowRemote-Session") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}
