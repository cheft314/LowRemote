import Foundation
import AVFoundation

// ─────────────────────────────────────────────────────────────────────────────
//  AudioCaptureManager
//
//  Captures the Mac's default audio INPUT (mic or loopback device) and
//  streams it to Android as 16 kHz · mono · Int16 LE.
//
//  Why 16 kHz / mono / Int16?
//  • The "滋滋滋" distortion was caused by the original Float32 48 kHz path:
//    AVAudioConverter failed (Code=-1) when the engine had no real audio
//    graph, and WRITE_NON_BLOCKING on Android dropped frames causing gaps.
//  • 16 kHz mono Int16 is:
//    - speech-quality (plenty for voice / loopback monitoring)
//    - 32 kB/s wire bandwidth vs 384 kB/s for Float32 48 kHz stereo
//    - natively supported by every Android AudioTrack without a converter
//    - matches the existing Android mic-to-Mac format (type 0x03) for
//      consistency; type 0x04 now carries this simpler format
//
//  System audio loopback on macOS:
//  • macOS 14.2+: set the output device to "BlackHole 2ch" or any virtual
//    loopback device → it appears as input → this tap captures it.
//  • Older macOS: same principle, or use the built-in Loopback capture API.
//  Without a loopback device the tap captures the built-in microphone.
// ─────────────────────────────────────────────────────────────────────────────
final class AudioCaptureManager {

    var onAudioBuffer: ((Data) -> Void)?

    private var engine:    AVAudioEngine?
    private var converter: AVAudioConverter?

    // ── Target format: 16 kHz · mono · Int16 ─────────────────────────────────
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate:   16_000,
        channels:     1,
        interleaved:  true
    )!

    // MARK: - Lifecycle

    func start() {
        stop()
        let e = AVAudioEngine()
        engine = e

        // IMPORTANT: Do NOT call e.prepare() here.
        // On macOS 14+ (and macOS 26) AVAudioEngine.prepare() asserts
        // "inputNode != nullptr || outputNode != nullptr".  This assertion
        // fires when the engine graph has no nodes yet — which is always true
        // on a freshly-created engine before installTap is called.
        //
        // Correct sequence (confirmed with Apple DTS):
        //   1. Access inputNode  ← registers it in the internal graph
        //   2. installTap        ← wires it into the graph
        //   3. engine.start()   ← prepare() is called internally here
        //
        // Reading inputNode.outputFormat(forBus:0) before installTap is safe
        // because accessing the property is enough to register the node.

        let inputNode = e.inputNode
        let hwFmt     = inputNode.outputFormat(forBus: 0)
        NSLog("[AudioCapture] hw input format: \(hwFmt)")

        guard hwFmt.sampleRate > 0 else {
            NSLog("[AudioCapture] sampleRate=0 — no audio input device available")
            engine = nil; return
        }

        let target = Self.targetFormat

        if hwFmt != target {
            if let conv = AVAudioConverter(from: hwFmt, to: target) {
                converter = conv
                NSLog("[AudioCapture] converter: \(Int(hwFmt.sampleRate)) Hz \(hwFmt.channelCount)ch → 16kHz mono Int16")
            } else {
                NSLog("[AudioCapture] cannot build converter — sending raw")
            }
        }

        // installTap wires the inputNode into the engine graph.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFmt) {
            [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        // engine.start() calls prepare() internally after the graph is ready.
        do {
            try e.start()
            NSLog("[AudioCapture] engine started (\(Int(hwFmt.sampleRate)) Hz)")
        } catch {
            NSLog("[AudioCapture] engine.start() error: \(error)")
            e.inputNode.removeTap(onBus: 0)
            engine = nil
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine    = nil
        converter = nil
    }

    // MARK: - Buffer handling

    private func handleBuffer(_ src: AVAudioPCMBuffer) {
        guard src.frameLength > 0 else { return }

        if let conv = converter {
            convertAndSend(src, conv: conv)
        } else {
            // hw format matches target or no converter available
            sendAsInt16(src, format: src.format)
        }
    }

    private func convertAndSend(_ src: AVAudioPCMBuffer, conv: AVAudioConverter) {
        let target    = Self.targetFormat
        let ratio     = target.sampleRate / src.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(src.frameLength) * ratio + 1)

        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames)
        else { return }

        var consumed  = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return src
        }
        if let e = err { NSLog("[AudioCapture] convert error: \(e.code)"); return }
        guard out.frameLength > 0 else { return }
        sendAsInt16(out, format: target)
    }

    /// Copy Int16 samples into a Data blob and fire the callback.
    private func sendAsInt16(_ buf: AVAudioPCMBuffer, format: AVAudioFormat) {
        let frames = Int(buf.frameLength)
        let ch     = Int(format.channelCount)
        guard frames > 0 else { return }

        // If the buffer holds Int16 data we can memcpy directly.
        if format.commonFormat == .pcmFormatInt16,
           let ptr = buf.int16ChannelData {
            let byteCount = frames * ch * MemoryLayout<Int16>.size
            let data = Data(bytes: ptr[0], count: byteCount)
            onAudioBuffer?(data)
            return
        }

        // Fallback: convert Float32 → Int16 manually.
        if format.commonFormat == .pcmFormatFloat32,
           let chData = buf.floatChannelData {
            var out = Data(count: frames * ch * 2)
            out.withUnsafeMutableBytes { rawPtr in
                guard let dst = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self)
                else { return }
                for f in 0..<frames {
                    for c in 0..<ch {
                        let s = chData[c][f]
                        let clamped = max(-1.0, min(1.0, s))
                        dst[f * ch + c] = Int16(clamped * 32767.0)
                    }
                }
            }
            onAudioBuffer?(out)
        }
    }
}
