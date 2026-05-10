package com.lowremote.session

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Log
import android.view.Surface
import com.lowremote.audio.AudioPlayer
import com.lowremote.codec.FrameAssembler
import com.lowremote.codec.H265Decoder
import com.lowremote.model.ControlEvent
import com.lowremote.model.Packet
import com.lowremote.model.RemoteDevice
import com.lowremote.network.TcpClient
import com.lowremote.network.UdpReceiver
import com.lowremote.network.UdpSender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class RemoteSession {

    companion object {
        private const val TAG = "RemoteSession"
        private const val CLIENT_UDP_PORT = 0
        private const val HEARTBEAT_INTERVAL_MS = 30_000L
    }

    enum class State { Idle, Connecting, Connected, Disconnected }

    data class ScreenInfo(val index: Int, val name: String, val width: Int, val height: Int)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val tcp      = TcpClient(scope)
    private val receiver = UdpReceiver(port = CLIENT_UDP_PORT)
    private val sender   = UdpSender()
    private val assembler = FrameAssembler()

    // ── Mac-system-audio player (type 0x04) ────────────────────────────────────
    private val macAudioPlayer = AudioPlayer()

    private var decoder: H265Decoder? = null
    @Volatile private var surface: Surface? = null
    private var heartbeatJob: Job? = null
    private val decoderLock = Any()
    private var device: RemoteDevice? = null
    private var eventFrameId: Int = 0

    // ── Audio ──────────────────────────────────────────────────────────────────
    private var audioRecord: AudioRecord? = null
    private var audioJob: Job? = null

    // ── State flows ────────────────────────────────────────────────────────────
    private val _state             = MutableStateFlow(State.Idle)
    val state: StateFlow<State>    = _state

    private val _remoteResolution  = MutableStateFlow<Pair<Int, Int>?>(null)
    val remoteResolution: StateFlow<Pair<Int, Int>?> = _remoteResolution

    private val _fps               = MutableStateFlow(60)
    val fps: StateFlow<Int>        = _fps

    private val _screens           = MutableStateFlow<List<ScreenInfo>>(emptyList())
    val screens: StateFlow<List<ScreenInfo>> = _screens

    private val _currentScreen     = MutableStateFlow(0)
    val currentScreen: StateFlow<Int> = _currentScreen

    private val _audioEnabled      = MutableStateFlow(false)
    val audioEnabled: StateFlow<Boolean> = _audioEnabled

    // ── Init ───────────────────────────────────────────────────────────────────
    init {
        assembler.onFrameReady = { bytes, isKeyframe -> decoder?.feed(bytes, isKeyframe) }
        receiver.onPacket = { parsed, payload, _ ->
            when (parsed.type) {
                Packet.TYPE_VIDEO        -> assembler.onPacket(parsed, payload)
                Packet.TYPE_SYSTEM_AUDIO -> macAudioPlayer.write(payload)
            }
        }
        tcp.onLine       = { line -> handleTcpLine(line) }
        tcp.onDisconnected = { scope.launch { teardown() } }
    }

    // ── Surface ────────────────────────────────────────────────────────────────
    fun setSurface(s: Surface?) {
        synchronized(decoderLock) {
            surface = s
            if (s == null) { decoder?.stop(); decoder = null; return }
            if (_state.value == State.Connected && decoder == null) startDecoderIfReadyLocked()
        }
    }

    // ── Connect ────────────────────────────────────────────────────────────────
    fun connect(device: RemoteDevice, fps: Int) {
        if (_state.value != State.Idle && _state.value != State.Disconnected) return
        _state.value = State.Connecting
        this.device  = device
        _fps.value   = fps

        scope.launch {
            receiver.start()
            val sock = receiver.sharedSocket() ?: run { teardown(); return@launch }
            sender.attach(sock, device.host, device.udpPort)
            sender.sendEvent("HELLO", nextEventFrameId())

            if (!tcp.connect(device.host, device.tcpPort)) { teardown(); return@launch }

            tcp.send("FPS:$fps")
            _state.value = State.Connected
            macAudioPlayer.start()
            startHeartbeat()
        }
    }

    fun changeFps(fps: Int) {
        _fps.value = fps
        if (_state.value == State.Connected) {
            synchronized(decoderLock) { decoder?.flush() }
            assembler.reset()
            tcp.send("FPS:$fps")
        }
    }

    fun switchScreen(index: Int) {
        if (_state.value != State.Connected) return
        _currentScreen.value = index
        // Tear down old decoder — resolution may change
        synchronized(decoderLock) { decoder?.stop(); decoder = null }
        assembler.reset()
        tcp.send("SCREEN:$index")
    }

    fun sendEvent(event: ControlEvent) {
        if (_state.value != State.Connected) return
        val serialized = event.serialize()
        val frameId    = nextEventFrameId()
        scope.launch(Dispatchers.IO) {
            try { sender.sendEvent(serialized, frameId) }
            catch (e: Exception) { Log.w(TAG, "sendEvent failed: ${e.message}") }
        }
    }

    // ── Audio ──────────────────────────────────────────────────────────────────
    /**
     * Toggle microphone capture and streaming to Mac.
     *
     * Protocol:
     *   1. Android sends TCP "AUDIO_ON"  → Mac starts AVAudioEngine playback
     *   2. Android streams raw PCM chunks over UDP (type=0x03)
     *      Format: 16 000 Hz, mono, 16-bit signed little-endian, ~20 ms chunks
     *   3. Mac plays PCM through its default output device.
     *      All apps that read from the default *input* will NOT hear this directly;
     *      the audio comes out of the speakers/headphones.
     *      To route it as a microphone input you need a loopback virtual device
     *      (e.g. BlackHole 2ch) set as both output + input in Audio MIDI Setup.
     *      For **dictation / Siri / speech recognition** on macOS, set the Mac's
     *      System Settings → Sound → Input to the same virtual device.
     *
     * Note: RECORD_AUDIO permission must be granted before calling this.
     */
    fun setAudioEnabled(enabled: Boolean) {
        if (enabled == _audioEnabled.value) return
        _audioEnabled.value = enabled
        if (enabled && _state.value == State.Connected) {
            tcp.send("AUDIO_ON")   // tell Mac to start AVAudioEngine
            startAudioCapture()
        } else {
            stopAudioCapture()
            if (_state.value == State.Connected) tcp.send("AUDIO_OFF")
        }
    }

    private fun startAudioCapture() {
        stopAudioCapture()
        // Must match Mac AudioReceiver exactly:
        //   sampleRate = 16 000 Hz
        //   channels   = mono (1)
        //   encoding   = PCM 16-bit signed little-endian
        val sampleRate = 16_000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT

        // Use ~20 ms chunks: 16000 samples/s * 0.02 s * 2 bytes = 640 bytes.
        // getMinBufferSize is a lower bound; we use 4× to avoid underruns.
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
        if (minBuf == AudioRecord.ERROR_BAD_VALUE || minBuf <= 0) {
            Log.w(TAG, "AudioRecord.getMinBufferSize failed"); return
        }
        val bufSize = maxOf(minBuf * 4, 1280) // at least 2 × 20ms frames

        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate, channelConfig, encoding, bufSize
            )
        } catch (e: Exception) { Log.w(TAG, "AudioRecord ctor: ${e.message}"); return }

        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.w(TAG, "AudioRecord not initialized"); rec.release(); return
        }

        rec.startRecording()
        audioRecord = rec
        Log.d(TAG, "audio capture started: ${sampleRate} Hz mono 16-bit, buf=$bufSize")

        audioJob = scope.launch(Dispatchers.IO) {
            // Each read delivers one chunk; we send it immediately.
            // 20-ms read size keeps latency low while amortising UDP overhead.
            val chunkBytes = (sampleRate / 50) * 2   // 20 ms × 2 bytes/sample = 640
            val buf = ByteArray(chunkBytes)
            while (isActive && _audioEnabled.value) {
                val read = rec.read(buf, 0, chunkBytes)
                if (read > 0) {
                    val packet = Packet.encodeAudio(nextEventFrameId(), buf.copyOf(read))
                    sender.send(packet)
                }
            }
        }
    }

    private fun stopAudioCapture() {
        audioJob?.cancel(); audioJob = null
        try { audioRecord?.stop() } catch (_: Exception) {}
        audioRecord?.release(); audioRecord = null
    }

    // ── Disconnect / Release ───────────────────────────────────────────────────
    fun disconnect() {
        if (_state.value == State.Idle) return
        if (tcp.isConnected) tcp.send("DISCONNECT")
        scope.launch { teardown() }
    }

    fun release() {
        scope.launch { teardown() }
        scope.cancel()
    }

    // ── TCP line handler ───────────────────────────────────────────────────────
    private fun handleTcpLine(line: String) {
        val trimmed = line.trim()
        when {
            trimmed.startsWith("RESOLUTION:") -> {
                val p = trimmed.removePrefix("RESOLUTION:").split(",")
                val w = p.getOrNull(0)?.toIntOrNull()
                val h = p.getOrNull(1)?.toIntOrNull()
                if (w != null && h != null) {
                    _remoteResolution.value = w to h
                    startDecoderIfReady()
                }
            }
            trimmed.startsWith("SCREENS:") -> {
                // Format: SCREENS:0:主屏幕:2560x1600,1:屏幕2:1920x1080
                val list = trimmed.removePrefix("SCREENS:").split(",").mapNotNull { entry ->
                    val parts = entry.split(":")
                    if (parts.size < 3) return@mapNotNull null
                    val idx  = parts[0].toIntOrNull() ?: return@mapNotNull null
                    val name = parts[1]
                    val dim  = parts[2].split("x")
                    val w2   = dim.getOrNull(0)?.toIntOrNull() ?: 0
                    val h2   = dim.getOrNull(1)?.toIntOrNull() ?: 0
                    ScreenInfo(idx, name, w2, h2)
                }
                if (list.isNotEmpty()) _screens.value = list
            }
            trimmed == "OK" -> startDecoderIfReady()
            trimmed == "PONG" -> { /* heartbeat */ }
        }
    }

    // ── Decoder ────────────────────────────────────────────────────────────────
    private fun startDecoderIfReady() {
        synchronized(decoderLock) { startDecoderIfReadyLocked() }
    }
    private fun startDecoderIfReadyLocked() {
        val s        = surface ?: return
        if (decoder != null) return
        val (w, h)   = _remoteResolution.value ?: (1920 to 1080)
        val dec      = H265Decoder(s, _fps.value)
        dec.start(w, h)
        decoder      = dec
        Log.d(TAG, "decoder: ${w}x${h} @ ${_fps.value}fps")
    }

    // ── Heartbeat ──────────────────────────────────────────────────────────────
    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(HEARTBEAT_INTERVAL_MS)
                if (tcp.isConnected) tcp.send("PING") else break
            }
        }
    }

    // ── Teardown ───────────────────────────────────────────────────────────────
    private suspend fun teardown() {
        heartbeatJob?.cancel(); heartbeatJob = null
        if (_audioEnabled.value) tcp.send("AUDIO_OFF")
        stopAudioCapture()
        _audioEnabled.value = false
        macAudioPlayer.stop()
        tcp.disconnect()
        receiver.stop()
        synchronized(decoderLock) { decoder?.stop(); decoder = null }
        assembler.reset()
        _state.value = State.Disconnected
        device = null
    }

    private fun nextEventFrameId(): Int {
        eventFrameId = (eventFrameId + 1) and 0x7FFFFFFF
        return eventFrameId
    }
}
