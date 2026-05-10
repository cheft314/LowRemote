import Foundation
import AVFoundation
import CoreAudio

// ─────────────────────────────────────────────────────────────────────────────
//  AudioCaptureManager
//
//  Captures Mac system-audio output via AVAudioEngine and delivers it to
//  the caller **and** to the Mac's default audio input device so apps
//  that listen to the microphone (Dictation, Siri, speech-recognition)
//  also hear the stream.
//
//  Architecture
//  ┌───────────────────────────────────────────────────────────┐
//  │  AVAudioEngine                                            │
//  │                                                           │
//  │  inputNode ──tap──► convertToPCM ──► onAudioBuffer (UDP) │
//  │     │                                                     │
//  │     └──► mainMixerNode ──► outputNode (speakers)         │
//  │                                                           │
//  └───────────────────────────────────────────────────────────┘
//
//  The tap is installed on the engine's **input node** (which reads from
//  the default audio input device — system loopback on macOS 14+, or a
//  virtual driver like BlackHole on older versions).
//
//  To route system audio into the Mac's microphone input (for Dictation /
//  speech recognition) the system audio output device must be set to a
//  loopback virtual device (e.g. BlackHole, Loopback, or macOS 14.2+'s
//  built-in loopback), which then appears as a selectable input.  This
//  class handles capture only; routing is a system-level setting.
//
//  Format sent to Android: 48 000 Hz · stereo · Float32 LE interleaved.
//  Format matches AudioPlayer.kt on the Android side.
// ─────────────────────────────────────────────────────────────────────────────
final class AudioCaptureManager {

    // MARK: - Public

    /// Called on a high-priority audio thread.
    /// `data` is Float32 interleaved little-endian: [L0, R0, L1, R1 …].
    var onAudioBuffer: ((Data) -> Void)?

    // MARK: - Private

    private var engine: AVAudioEngine?
    /// Pre-built converter; created once when formats are known to avoid
    /// repeated creation inside the hot-path tap callback.
    private var converter: AVAudioConverter?
    private var convOutputFormat: AVAudioFormat?

    /// Target format for Android AudioPlayer (48 kHz, stereo, Float32 interleaved).
    static let targetFormat = AVAudioFormat(
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

        // The input node connects to the default system audio input.
        // On macOS 14+ this is the system audio loopback device when the
        // output is set to a virtual driver; on older macOS it is whatever
        // the user has selected in System Settings → Sound → Input.
        let inputNode = e.inputNode

        // We MUST call prepare() before asking for the input format;
        // otherwise sampleRate can be 0 and the converter will fail.
        e.prepare()

        // inputFormat is determined by the hardware; do NOT request a
        // specific format here — that is what caused the Code=-1 error.
        let hwFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[AudioCapture] hw input format: \(hwFormat)")

        guard hwFormat.sampleRate > 0 else {
            NSLog("[AudioCapture] hardware sample rate is 0; no audio input device available.")
            engine = nil
            return
        }

        let target = Self.targetFormat

        // Build converter once.  If formats are identical we skip conversion.
        if hwFormat != target, let conv = AVAudioConverter(from: hwFormat, to: target) {
            converter = conv
            convOutputFormat = target
            NSLog("[AudioCapture] converter: \(hwFormat.sampleRate) Hz → \(target.sampleRate) Hz")
        } else if hwFormat == target {
            converter = nil
            convOutputFormat = nil
            NSLog("[AudioCapture] formats match; no conversion needed")
        } else {
            NSLog("[AudioCapture] could not create AVAudioConverter; will send raw")
            converter = nil
            convOutputFormat = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) {
            [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        do {
            try e.start()
            NSLog("[AudioCapture] AVAudioEngine started (input tap, \(hwFormat.sampleRate) Hz)")
        } catch {
            NSLog("[AudioCapture] AVAudioEngine.start() failed: \(error)")
            engine = nil
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        convOutputFormat = nil
    }

    // MARK: - Buffer handling

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        if let conv = converter, let targetFmt = convOutputFormat {
            convertAndSend(buffer, converter: conv, targetFmt: targetFmt)
        } else {
            // Same format — copy floats directly.
            sendBuffer(buffer, format: buffer.format)
        }
    }

    private func convertAndSend(_ buffer: AVAudioPCMBuffer,
                                  converter: AVAudioConverter,
                                  targetFmt: AVAudioFormat) {
        let ratio  = targetFmt.sampleRate / buffer.format.sampleRate
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
        if let err = convErr {
            NSLog("[AudioCapture] conversion error (suppressed after first): \(err.code)")
            return
        }
        guard outBuf.frameLength > 0 else { return }
        sendBuffer(outBuf, format: targetFmt)
    }

    private func sendBuffer(_ buf: AVAudioPCMBuffer, format: AVAudioFormat) {
        let frameLen  = Int(buf.frameLength)
        let chCount   = Int(format.channelCount)
        let totalSamp = frameLen * chCount
        guard totalSamp > 0 else { return }

        var data = Data(count: totalSamp * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            if format.isInterleaved, let src = buf.floatChannelData?[0] {
                dst.initialize(from: src, count: totalSamp)
            } else if let ch = buf.floatChannelData {
                for f in 0..<frameLen {
                    for c in 0..<chCount { dst[f * chCount + c] = ch[c][f] }
                }
            }
        }
        onAudioBuffer?(data)
    }
}
