import AppKit
import CoreGraphics
import ApplicationServices
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusTitleItem: NSMenuItem!
    private var fpsTitleItem: NSMenuItem!

    private var bonjour: BonjourAdvertiser!
    private var tcpServer: TCPServer!
    private var udpServer: UDPServer!
    private var screenCapture: ScreenCaptureManager!
    private var encoder: VideoEncoder!
    private var inputSimulator: InputSimulator!
    private var audioCapture: AudioCaptureManager!   // Mac → Android

    private var clientEndpoint: (host: String, port: UInt16)?
    /// Set when the client requests FPS/SCREEN streaming; capture actually starts in
    /// `tryStartStreamingIfReady()` once `clientEndpoint` is known from the first UDP datagram.
    /// Avoids dropping all video when TCP (`FPS:`) is handled before HELLO is read on the UDP queue
    /// — a race that worsened after signaling TCP accept only at `.ready` (see iOS `RemoteSession`).
    private var streamingDesired: Bool = false
    private var currentFPS: Int = 60
    private var frameIdCounter: UInt32 = 0
    /// Index of the display currently being streamed. 0 = main display.
    private var currentDisplayIndex: Int = 0
    private var audioReceiver: AudioReceiver?        // Android mic → Mac speaker

    // ── File transfer state ────────────────────────────────────────────────────
    private var pendingFileName: String?
    private var pendingFileSize: Int = 0
    private var pendingFileBytesReceived: Int = 0
    private var pendingFileHandle: FileHandle?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        checkPermissions()
        startServers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStreaming()
        audioCapture?.stop()
        audioReceiver?.stop()
        tcpServer?.stop()
        udpServer?.stop()
        bonjour?.stop()
    }

    // MARK: - Menu Bar UI

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🖥️"
            button.toolTip = "LowRemote"
        }
        statusMenu = NSMenu()

        statusTitleItem = NSMenuItem(title: "状态：等待连接", action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false
        statusMenu.addItem(statusTitleItem)

        statusMenu.addItem(NSMenuItem.separator())

        fpsTitleItem = NSMenuItem(title: "帧率：60 fps", action: nil, keyEquivalent: "")
        fpsTitleItem.isEnabled = false
        statusMenu.addItem(fpsTitleItem)

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 LowRemote", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = statusMenu
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusTitleItem.title = "状态：\(text)"
        }
    }

    private func updateFPS(_ fps: Int) {
        DispatchQueue.main.async {
            self.fpsTitleItem.title = "帧率：\(fps) fps"
        }
    }

    // MARK: - Permissions

    private func checkPermissions() {
        // Screen recording permission (required for CGDisplayStream)
        // Note: CGPreflightScreenCaptureAccess is non-intrusive, CGRequestScreenCaptureAccess may prompt.
        let hasScreen = CGPreflightScreenCaptureAccess()
        if !hasScreen {
            CGRequestScreenCaptureAccess()
            NSLog("[LowRemote] Screen recording permission not yet granted. Please enable in System Settings.")
        }

        // Accessibility permission (required for CGEventPost)
        let opts: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !trusted {
            NSLog("[LowRemote] Accessibility permission not yet granted. Please enable in System Settings.")
        }
    }

    // MARK: - Servers

    private func startServers() {
        inputSimulator = InputSimulator()

        // TCP control server
        tcpServer = TCPServer(port: 8890)
        tcpServer.onCommand = { [weak self] cmd, clientHost in
            self?.handleTCPCommand(cmd, clientHost: clientHost)
        }
        tcpServer.onClientConnected = { [weak self] host in
            self?.updateStatus("已连接 \(host)")
            // Handshake: send resolution + screen list
            self?.sendHandshake()
        }
        tcpServer.onClientDisconnected = { [weak self] in
            self?.updateStatus("等待连接")
            self?.streamingDesired = false
            self?.stopStreaming()
            self?.clientEndpoint = nil
            self?.udpServer.resetClientAssociation()
        }
        // ── File transfer callbacks ────────────────────────────────────────────
        tcpServer.onFileStart = { [weak self] filename, size, _ in
            self?.beginFileReceive(filename: filename, size: size)
        }
        tcpServer.onFileChunk = { [weak self] chunk, _ in
            self?.appendFileChunk(chunk)
        }
        tcpServer.onFileEnd = { [weak self] _ in
            self?.finalizeFileReceive()
        }
        tcpServer.start()

        // UDP data server (receives control events, audio PCM, sends video)
        audioReceiver = AudioReceiver()

        udpServer = UDPServer(port: 8891)
        udpServer.onControlEvent = { [weak self] event in
            self?.inputSimulator.handleEvent(event)
        }
        udpServer.onAudioData = { [weak self] pcmData in
            self?.audioReceiver?.onAudioData(pcmData)
        }
        udpServer.onFirstPacketFromClient = { [weak self] host, port in
            // Remember client's UDP endpoint so we know where to stream video to
            self?.clientEndpoint = (host: host, port: port)
            NSLog("[LowRemote] UDP client endpoint: \(host):\(port)")
            self?.tryStartStreamingIfReady()
        }
        udpServer.start()

        // Bonjour / mDNS
        bonjour = BonjourAdvertiser(
            serviceType: "_maclocalremote._tcp.",
            serviceName: Host.current().localizedName ?? "Mac",
            tcpPort: 8890,
            udpPort: 8891
        )
        bonjour.start()

        NSLog("[LowRemote] Servers started. TCP:8890 UDP:8891 mDNS:_maclocalremote._tcp.")
    }

    // MARK: - TCP Command Handling

    private func sendHandshake() {
        // Send current display's resolution
        let displays = ScreenCaptureManager.allDisplays()
        let idx = min(currentDisplayIndex, displays.count - 1)
        let size = idx >= 0 ? displays[idx].size : CGSize(width: 1920, height: 1080)
        tcpServer.broadcast("RESOLUTION:\(Int(size.width)),\(Int(size.height))\n")
        // Send screen list
        let names = displays.enumerated().map { i, d in
            "\(i):\(d.name):\(Int(d.size.width))x\(Int(d.size.height))"
        }.joined(separator: ",")
        tcpServer.broadcast("SCREENS:\(names)\n")
    }

    private func handleTCPCommand(_ cmd: String, clientHost: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[LowRemote] TCP cmd: \(trimmed) from \(clientHost)")

        if trimmed.hasPrefix("FPS:") {
            let val = trimmed.dropFirst(4)
            if let fps = Int(val), [30, 60, 120].contains(fps) {
                currentFPS = fps
                updateFPS(fps)
                tcpServer.broadcast("OK\n")
                streamingDesired = true
                tryStartStreamingIfReady()
            }
        } else if trimmed.hasPrefix("SCREEN:") {
            let val = trimmed.dropFirst(7)
            if let idx = Int(val) {
                let displays = ScreenCaptureManager.allDisplays()
                if idx >= 0 && idx < displays.count {
                    currentDisplayIndex = idx
                    tcpServer.broadcast("OK\n")
                    streamingDesired = true
                    tryStartStreamingIfReady()
                    // Re-send resolution for new screen
                    let sz = displays[idx].size
                    tcpServer.broadcast("RESOLUTION:\(Int(sz.width)),\(Int(sz.height))\n")
                }
            }
        } else if trimmed == "PING" {
            tcpServer.broadcast("PONG\n")
        } else if trimmed == "AUDIO_ON" {
            // ⚠️  Echo / howl prevention:
            //
            // AudioReceiver plays the Android mic through the Mac's speakers
            // (or default output device).  AudioCaptureManager taps the Mac's
            // audio INPUT.  If the input device is the same as (or can hear)
            // the output — e.g. via BlackHole loopback, or simply because the
            // built-in microphone picks up the speakers — the captured audio
            // will contain the already-played mic audio, which is then sent
            // BACK to Android, creating a feedback loop.
            //
            // Solution: pause system-audio capture while mic streaming is
            // active.  The two features are mutually exclusive.
            //
            // If the user genuinely needs both simultaneously they should use
            // a proper AEC (Acoustic Echo Cancellation) solution at the OS
            // level, such as:
            //   • System Settings → Sound → Input: choose a different device
            //     from the output (e.g. AirPods as output, built-in as input).
            //   • Use BlackHole + multi-output device but route them carefully
            //     so the mic input device does NOT include the BlackHole loopback.
            audioCapture?.stop()
            audioCapture = nil
            NSLog("[AudioEcho] System audio capture PAUSED while mic streaming is active")
            audioReceiver?.start()
            tcpServer.broadcast("OK\n")
        } else if trimmed == "AUDIO_OFF" {
            audioReceiver?.stop()
            // Resume system audio capture now that mic streaming stopped
            if screenCapture != nil {   // only if we're still streaming video
                audioCapture = AudioCaptureManager()
                audioCapture.onAudioBuffer = { [weak self] pcmData in
                    self?.sendSystemAudio(pcmData)
                }
                audioCapture.start()
                NSLog("[AudioEcho] System audio capture RESUMED after mic streaming stopped")
            }
            tcpServer.broadcast("OK\n")
        } else if trimmed == "DISCONNECT" {
            streamingDesired = false
            stopStreaming()
            tcpServer.disconnectAll()
        }
    }

    // MARK: - Streaming

    private func tryStartStreamingIfReady() {
        guard streamingDesired, clientEndpoint != nil else { return }
        startStreaming(fps: currentFPS)
    }

    private func startStreaming(fps: Int) {
        stopStreaming()

        let displays = ScreenCaptureManager.allDisplays()
        let idx = min(currentDisplayIndex, max(0, displays.count - 1))
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        if !displays.isEmpty {
            displayID = displays[idx].id
            width  = Int(displays[idx].size.width)
            height = Int(displays[idx].size.height)
        } else {
            displayID = CGMainDisplayID()
            width  = 1920
            height = 1080
        }

        // Keep InputSimulator in sync with which display is being streamed
        inputSimulator.activeDisplayID = displayID

        let bitrate: Int
        switch fps {
        case 30: bitrate = 8_000_000
        case 60: bitrate = 15_000_000
        case 120: bitrate = 25_000_000
        default: bitrate = 15_000_000
        }

        encoder = VideoEncoder(width: width, height: height, fps: fps, bitrate: bitrate)
        encoder.onEncodedFrame = { [weak self] nalData, isKeyframe in
            self?.sendEncodedFrame(nalData, isKeyframe: isKeyframe)
        }

        guard encoder.start() else {
            NSLog("[LowRemote] Failed to start encoder")
            return
        }

        screenCapture = ScreenCaptureManager()
        screenCapture.onFrame = { [weak self] pixelBuffer in
            self?.encoder.encode(pixelBuffer: pixelBuffer)
        }
        screenCapture.start(fps: fps, displayID: displayID)

        // Start Mac-system-audio → Android capture (type 0x04)
        audioCapture = AudioCaptureManager()
        audioCapture.onAudioBuffer = { [weak self] pcmData in
            self?.sendSystemAudio(pcmData)
        }
        audioCapture.start()

        NSLog("[LowRemote] Streaming started at \(fps) fps (\(width)x\(height)) display[\(idx)] id=\(displayID)")
    }

    private func stopStreaming() {
        screenCapture?.stop(); screenCapture = nil
        encoder?.stop();       encoder = nil
        audioCapture?.stop();  audioCapture = nil
    }

    private func sendEncodedFrame(_ nalData: Data, isKeyframe: Bool) {
        guard let endpoint = clientEndpoint else { return }

        let frameId = nextFrameId()
        let maxPayload = Packet.maxPayloadSize
        let totalChunks = (nalData.count + maxPayload - 1) / maxPayload
        guard totalChunks > 0, totalChunks <= 0xFFFF else { return }

        for idx in 0..<totalChunks {
            let start = idx * maxPayload
            let end = min(start + maxPayload, nalData.count)
            let chunk = nalData.subdata(in: start..<end)
            let packet = Packet.encodeVideo(
                frameId: frameId,
                pktIdx: UInt16(idx),
                pktTotal: UInt16(totalChunks),
                isKeyframe: isKeyframe && idx == 0,
                payload: chunk
            )
            udpServer.send(packet, to: endpoint.host, port: endpoint.port)
        }
    }

    private func sendSystemAudio(_ pcmData: Data) {
        guard let endpoint = clientEndpoint else { return }
        // Float32 48kHz stereo: 1024 frames = 8192 bytes — fits in one MTU-safe packet.
        // Chunk if somehow larger.
        let maxP = Packet.maxPayloadSize
        var offset = 0
        while offset < pcmData.count {
            let end    = min(offset + maxP, pcmData.count)
            let chunk  = pcmData.subdata(in: offset..<end)
            let packet = Packet.encodeSystemAudio(frameId: nextFrameId(), payload: chunk)
            udpServer.send(packet, to: endpoint.host, port: endpoint.port)
            offset = end
        }
    }

    private func nextFrameId() -> UInt32 {
        frameIdCounter &+= 1
        return frameIdCounter
    }

    // MARK: - File Receive

    /// Prepare a writable file in ~/Downloads for the incoming transfer.
    private func beginFileReceive(filename: String, size: Int) {
        // Sanitise the filename: strip path separators to prevent traversal attacks.
        let safe = filename
            .components(separatedBy: "/").last?
            .components(separatedBy: "\\").last ?? "file"
        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")

        // Create Downloads directory if it somehow doesn't exist.
        try? FileManager.default.createDirectory(at: downloadsURL,
                                                  withIntermediateDirectories: true)

        // Avoid overwriting an existing file by appending a counter.
        var destURL = downloadsURL.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: destURL.path) {
            let name = (safe as NSString).deletingPathExtension
            let ext  = (safe as NSString).pathExtension
            var n = 1
            repeat {
                let candidate = ext.isEmpty ? "\(name)_\(n)" : "\(name)_\(n).\(ext)"
                destURL = downloadsURL.appendingPathComponent(candidate)
                n += 1
            } while FileManager.default.fileExists(atPath: destURL.path) && n < 1000
        }

        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        pendingFileHandle        = try? FileHandle(forWritingTo: destURL)
        pendingFileName          = destURL.lastPathComponent
        pendingFileSize          = size
        pendingFileBytesReceived = 0

        NSLog("[FileReceive] started: \(destURL.path)  expected \(size) bytes")
    }

    /// Write a raw chunk to the open file handle.
    private func appendFileChunk(_ chunk: Data) {
        guard let fh = pendingFileHandle else { return }
        fh.write(chunk)
        pendingFileBytesReceived += chunk.count
    }

    /// Close the file and notify the Android client.
    private func finalizeFileReceive() {
        guard let fh = pendingFileHandle else { return }
        fh.closeFile()
        let name     = pendingFileName ?? "file"
        let received = pendingFileBytesReceived
        let expected = pendingFileSize

        pendingFileHandle        = nil
        pendingFileName          = nil
        pendingFileSize          = 0
        pendingFileBytesReceived = 0

        if received == expected {
            NSLog("[FileReceive] complete: \(name)  \(received) bytes")
            tcpServer.broadcast("FILE_OK:\(name)\n")
        } else {
            NSLog("[FileReceive] size mismatch: \(name)  got \(received), expected \(expected)")
            tcpServer.broadcast("FILE_ERR:size mismatch (\(received)/\(expected))\n")
        }
    }
}
