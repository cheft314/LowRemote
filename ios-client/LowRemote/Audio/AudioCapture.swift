import Foundation
import AVFoundation

/// 麦克风录制并通过 UDP 发送到 Mac (type 0x03)
///
/// 格式：PCM 16kHz, mono, Int16 小端 ── 与 Android AudioCapture 完全一致
/// Mac AudioReceiver.swift 以相同格式接收并播放
final class AudioCapture {

    private let engine    = AVAudioEngine()
    private var isRunning = false
    private let lock      = NSLock()

    // 20ms 块大小：16000 samples/s × 0.02s = 320 samples × 2 bytes = 640 bytes
    private let chunkFrames: AVAudioFrameCount = 320

    /// 每块 PCM 数据准备好时回调（已编码为 Int16 LE 字节）
    var onAudioChunk: ((Data) -> Void)?

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        guard checkPermission() else {
            NSLog("[AudioCapture] 麦克风权限未授权")
            return
        }

        configureAudioSession()

        let inputNode = engine.inputNode
        // 系统原生格式（通常为 44100/48000 Hz float32）
        let nativeFmt = inputNode.outputFormat(forBus: 0)

        // 目标格式：16kHz mono Int16
        guard let targetFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { return }

        // 安装 tap，使用系统原生格式接收，然后转换
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFmt) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.processBuffer(buffer, srcFormat: nativeFmt, dstFormat: targetFmt)
        }

        do {
            try engine.start()
            isRunning = true
            NSLog("[AudioCapture] 启动 16kHz mono Int16")
        } catch {
            NSLog("[AudioCapture] engine.start 失败: \(error)")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        NSLog("[AudioCapture] 停止")
    }

    // MARK: - Private

    private func processBuffer(_ buffer: AVAudioPCMBuffer,
                                srcFormat: AVAudioFormat,
                                dstFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return }

        // 目标帧数（resample 后）
        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        let dstFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard dstFrames > 0 else { return }

        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat,
                                             frameCapacity: dstFrames) else { return }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: dstBuf, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, dstBuf.frameLength > 0 else { return }

        // Int16 数据 → Data，分成 20ms 块发送
        guard let int16Ptr = dstBuf.int16ChannelData?[0] else { return }
        let totalBytes = Int(dstBuf.frameLength) * 2  // Int16 = 2 bytes
        let data = Data(bytes: int16Ptr, count: totalBytes)

        // 按 chunkFrames 分块回调
        let chunkBytes = Int(chunkFrames) * 2
        var offset = 0
        while offset + chunkBytes <= data.count {
            let chunk = data.subdata(in: offset..<(offset + chunkBytes))
            onAudioChunk?(chunk)
            offset += chunkBytes
        }
        // 剩余不足一块：直接发送
        if offset < data.count {
            onAudioChunk?(data.subdata(in: offset..<data.count))
        }
    }

    private func checkPermission() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            NSLog("[AudioCapture] AVAudioSession 配置失败: \(error)")
        }
    }
}
