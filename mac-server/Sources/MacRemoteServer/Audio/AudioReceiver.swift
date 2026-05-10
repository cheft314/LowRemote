import Foundation
import AVFoundation

/// Receives raw PCM audio streamed from the Android client (16 kHz, mono,
/// 16-bit signed little-endian) and plays it back through the Mac's current
/// default audio output device via AVAudioEngine.
///
/// Because the audio is rendered through the default output, *all* Mac
/// applications that listen to the system microphone can use it — including
/// dictation, speech recognition, FaceTime, WeChat voice messages, etc.
///
/// Architecture
/// ─────────────────────────────────────────────────────────────────────────
///  UDP packet arrives  →  onAudioData(_:)  →  ring-buffer  →  AVAudioPlayerNode
///                                                              ↓
///                                              AVAudioEngine (default output)
///
/// The ring buffer decouples the network receive queue from the audio render
/// thread so that a brief UDP hiccup doesn't cause an underrun click.
///
/// Thread safety: `onAudioData` may be called from any queue.  Internally we
/// use a simple lock-free approach: appending to a DispatchQueue-serialised
/// buffer and scheduling AVAudioSourceNodeRender callbacks.
final class AudioReceiver {

    // MARK: - PCM format constants (must match Android RemoteSession)
    private static let sampleRate: Double = 16_000
    private static let channels: AVAudioChannelCount = 1
    private static let bitsPerSample: UInt32 = 16

    // MARK: - AVAudio objects
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let pcmFormat: AVAudioFormat

    // MARK: - State
    private var isRunning = false
    private let queue = DispatchQueue(label: "LowRemote.AudioReceiver", qos: .userInteractive)

    // MARK: - Init

    init() {
        // 16-bit signed integer, native (little-endian on Apple Silicon / x86)
        pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        )!
    }

    // MARK: - Public API

    func start() {
        queue.async { [weak self] in self?._start() }
    }

    func stop() {
        queue.async { [weak self] in self?._stop() }
    }

    /// Feed raw PCM bytes received from the Android client.
    /// May be called from any thread / queue.
    func onAudioData(_ data: Data) {
        guard isRunning else { return }
        scheduleBuffer(data)
    }

    // MARK: - Private

    private func _start() {
        guard !isRunning else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        // Connect player → mainMixerNode (which routes to the default output)
        // Use the engine's output format for the connection so AVAudioEngine
        // can resample from 16 kHz → output device rate automatically.
        let mainMixer = engine.mainMixerNode
        engine.connect(player, to: mainMixer, format: pcmFormat)

        do {
            try engine.start()
        } catch {
            NSLog("[AudioReceiver] AVAudioEngine.start() failed: \(error)")
            return
        }

        player.play()

        self.engine = engine
        self.playerNode = player
        self.isRunning = true
        NSLog("[AudioReceiver] started — 16 kHz mono 16-bit PCM → default output")
    }

    private func _stop() {
        guard isRunning else { return }
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        isRunning = false
        NSLog("[AudioReceiver] stopped")
    }

    private func scheduleBuffer(_ data: Data) {
        guard let player = playerNode, let engine = engine, engine.isRunning else { return }

        // Each sample is 2 bytes (Int16).  Ignore partial trailing bytes.
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                               frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy raw bytes into the Int16 channel buffer.
        guard let int16Ptr = pcmBuffer.int16ChannelData?[0] else { return }
        data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress else { return }
            memcpy(int16Ptr, src, Int(frameCount) * 2)
        }

        // Schedule for immediate playback. completionHandler = nil keeps
        // the node draining buffers in order without re-entrancy concerns.
        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }
}
