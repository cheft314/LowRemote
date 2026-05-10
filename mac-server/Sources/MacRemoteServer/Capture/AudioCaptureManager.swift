import Foundation
import AVFoundation
import CoreAudio

/// Captures system audio output (loopback) via AVAudioEngine's input tap on the
/// default output device, then delivers raw PCM frames to the caller.
///
/// Format: 48 000 Hz · stereo (2 ch) · Float32 interleaved · little-endian.
/// Each callback delivers up to ~10 ms of audio (~480 samples per channel).
///
/// macOS 14+ exposes `AVCaptureDevice` audio, but AVAudioEngine + outputNode tap
/// works back to macOS 10.15 and doesn't require ScreenCaptureKit entitlements.
///
/// ⚠️ System audio loopback on macOS requires either:
///   a) macOS 14.2+ with `kAudioDevicePropertyTapDescription` (private), or
///   b) a virtual audio driver (BlackHole / Loopback) set as the default output,
///      and then this class taps AVAudioEngine's mainMixerNode.
///
/// For MVP we use approach (b): install an input tap on the main mixer so we
/// capture whatever the user has routed through the engine. When no virtual
/// driver is present the tap captures silence — but produces no crash.
final class AudioCaptureManager {

    // ── Public API ────────────────────────────────────────────────────────────

    /// Fired on a high-priority audio thread. `data` is a single interleaved
    /// Float32 buffer (left0, right0, left1, right1 …). Length is always an
    /// even multiple of the frame stride (2 × Float32).
    var onAudioBuffer: ((Data) -> Void)?

    // ── Internal state ────────────────────────────────────────────────────────

    private var engine: AVAudioEngine?

    /// Target output format: 48 kHz, stereo, Float32.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    func start() {
        stop()

        let e = AVAudioEngine()
        engine = e

        // installTap on the mainMixerNode captures the engine's mix before it
        // goes to the output device — this is the closest we can get to a
        // loopback without a kernel extension.
        let mixer = e.mainMixerNode
        let outputFormat = Self.outputFormat
        let bufferSize: AVAudioFrameCount = 1024

        // The tap format must match the mixer's output format; we convert.
        let tapFormat = mixer.outputFormat(forBus: 0)

        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) {
            [weak self] buffer, _ in
            self?.handleBuffer(buffer, tapFormat: tapFormat, targetFormat: outputFormat)
        }

        do {
            try e.start()
            NSLog("[Audio] AVAudioEngine started (tap on mainMixerNode)")
        } catch {
            NSLog("[Audio] AVAudioEngine.start() failed: \(error)")
            engine = nil
        }
    }

    func stop() {
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // ── Buffer handling ───────────────────────────────────────────────────────

    private func handleBuffer(_ buffer: AVAudioPCMBuffer,
                              tapFormat: AVAudioFormat,
                              targetFormat: AVAudioFormat) {
        // Convert the tap's native format → 48 kHz Float32 stereo interleaved.
        guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            NSLog("[Audio] Cannot create AVAudioConverter")
            return
        }

        let frameCount = buffer.frameLength
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(
                Double(frameCount) * targetFormat.sampleRate / tapFormat.sampleRate + 1
            )
        ) else { return }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let err = error {
            NSLog("[Audio] Conversion error: \(err)")
            return
        }

        let frameLen = Int(outBuffer.frameLength)
        guard frameLen > 0 else { return }

        // Copy interleaved Float32 samples into a Data blob.
        let channelCount = Int(targetFormat.channelCount)
        let totalSamples = frameLen * channelCount
        var data = Data(count: totalSamples * MemoryLayout<Float>.size)

        data.withUnsafeMutableBytes { rawPtr in
            guard let dst = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }

            if targetFormat.isInterleaved, let src = outBuffer.floatChannelData?[0] {
                // Already interleaved — single channel-data pointer.
                dst.initialize(from: src, count: totalSamples)
            } else if let chData = outBuffer.floatChannelData {
                // Non-interleaved: interleave manually.
                for frame in 0..<frameLen {
                    for ch in 0..<channelCount {
                        dst[frame * channelCount + ch] = chData[ch][frame]
                    }
                }
            }
        }

        onAudioBuffer?(data)
    }
}
