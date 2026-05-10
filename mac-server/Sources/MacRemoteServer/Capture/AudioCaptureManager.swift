import Foundation
import AVFoundation
import CoreAudio

/// Captures Mac system audio output via AVAudioEngine's mainMixerNode tap
/// and delivers raw PCM chunks to the caller.
///
/// Format: 48 000 Hz · stereo (2 ch) · Float32 interleaved · little-endian.
/// Each callback delivers ≤ 1024 frames (~21 ms of audio).
///
/// ⚠️  The tap is placed on the engine's mainMixerNode which only captures
/// audio that flows through this AVAudioEngine instance.  On macOS 14.2+
/// you can use SCStreamConfiguration.capturesAudio = true for true system
/// loopback; for older macOS a virtual audio driver (e.g. BlackHole) routed
/// through this engine is required to capture third-party app audio.
/// Without such routing the tap will produce silence — but no crash.
final class AudioCaptureManager {

    // MARK: - Public

    /// Called on a high-priority audio thread.
    /// `data` is Float32 interleaved little-endian: [L0, R0, L1, R1 …].
    var onAudioBuffer: ((Data) -> Void)?

    // MARK: - Private

    private var engine: AVAudioEngine?

    /// 48 kHz · stereo · Float32 interleaved — matches Android AudioPlayer.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!

    // MARK: - Lifecycle

    func start() {
        stop()
        let e = AVAudioEngine()
        engine = e
        let mixer = e.mainMixerNode
        let tapFormat = mixer.outputFormat(forBus: 0)
        let targetFmt = Self.outputFormat

        mixer.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) {
            [weak self] buffer, _ in
            self?.handleBuffer(buffer, tapFormat: tapFormat, targetFmt: targetFmt)
        }

        do {
            try e.start()
            NSLog("[AudioCapture] AVAudioEngine started (mainMixerNode tap, 48kHz stereo Float32)")
        } catch {
            NSLog("[AudioCapture] AVAudioEngine.start() failed: \(error)")
            engine = nil
        }
    }

    func stop() {
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - Buffer handling

    private func handleBuffer(_ buffer: AVAudioPCMBuffer,
                               tapFormat: AVAudioFormat,
                               targetFmt: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: tapFormat, to: targetFmt) else {
            NSLog("[AudioCapture] cannot create AVAudioConverter")
            return
        }

        let ratio  = targetFmt.sampleRate / tapFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outCap)
        else { return }

        var inputConsumed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            if inputConsumed { status.pointee = .noDataNow; return nil }
            inputConsumed = true
            status.pointee = .haveData
            return buffer
        }
        if let err = convErr { NSLog("[AudioCapture] conversion error: \(err)"); return }

        let frameLen   = Int(outBuf.frameLength)
        guard frameLen > 0 else { return }
        let chCount    = Int(targetFmt.channelCount)
        let totalSamps = frameLen * chCount
        var data = Data(count: totalSamps * MemoryLayout<Float>.size)

        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            if targetFmt.isInterleaved, let src = outBuf.floatChannelData?[0] {
                dst.initialize(from: src, count: totalSamps)
            } else if let ch = outBuf.floatChannelData {
                for f in 0..<frameLen {
                    for c in 0..<chCount { dst[f * chCount + c] = ch[c][f] }
                }
            }
        }

        onAudioBuffer?(data)
    }
}
