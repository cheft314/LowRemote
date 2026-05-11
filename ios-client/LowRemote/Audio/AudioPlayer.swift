import Foundation
import AVFoundation

/// 播放 Mac 系统音频 (type 0x04)
///
/// Mac 发来的格式：Float32, 48 kHz, 双声道, 小端，交错排列
/// 对齐 Android AudioPlayer.kt (AudioTrack Float32 48kHz stereo)
final class AudioPlayer {

    private let engine       = AVAudioEngine()
    private let playerNode   = AVAudioPlayerNode()
    private var inputFormat: AVAudioFormat?
    private var isRunning    = false

    // 防止并发写入
    private let lock = NSLock()

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        configureAudioSession()

        // Mac 发送：Float32 48kHz 双声道交错
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true          // Mac AudioCaptureManager 输出交错
        ) else {
            NSLog("[AudioPlayer] 无法创建 AVAudioFormat"); return
        }
        inputFormat = fmt

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: fmt)

        do {
            try engine.start()
            playerNode.play()
            isRunning = true
            NSLog("[AudioPlayer] 启动 Float32 48kHz 立体声")
        } catch {
            NSLog("[AudioPlayer] engine.start 失败: \(error)")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        playerNode.stop()
        engine.stop()
        isRunning = false
        NSLog("[AudioPlayer] 停止")
    }

    /// 写入原始 PCM 字节（Float32 交错，48kHz stereo）
    func write(_ data: Data) {
        guard isRunning, let fmt = inputFormat else { return }

        let bytesPerFrame = 8  // Float32(4) × 2 channels
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return }

        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)

        // Float32 交错数据直接写入 interleaved buffer
        data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress else { return }
            if let dst = buf.floatChannelData?[0] {
                memcpy(dst, src, frameCount * bytesPerFrame)
            }
        }

        playerNode.scheduleBuffer(buf, completionHandler: nil)
    }

    // MARK: - AVAudioSession

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // playAndRecord 允许同时录麦和播放
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            NSLog("[AudioPlayer] AVAudioSession 配置失败: \(error)")
        }
    }
}
