package com.lowremote.session

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Log
import android.view.Surface
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
            if (parsed.type == Packet.TYPE_VIDEO) assembler.onPacket(parsed, payload)
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
     * Toggle microphone capture.
     *
     * 当前实现说明：
     * ─────────────────────────────────────────────────────────────────
     * Android 端：开启后从麦克风捕获 16kHz / 16-bit / 单声道 PCM，
     *   通过 UDP (type=0x03) 持续发送给 Mac。
     *
     * Mac 端（当前版本）：尚未接收/播放 PCM 音频数据。Mac 端如果要
     *   实现语音输入，需要将接收到的 PCM 导入系统音频（例如通过
     *   BlackHole 虚拟声卡或 AVAudioEngine），才能让 Mac 的语音识别
     *   和其他应用使用手机麦克风。
     *
     * 因此：当前版本开启此功能后，手机麦克风音频发送到 Mac 但
     *   Mac 端不处理，对微信语音、语音识别等没有效果。
     *   这是一个功能存根，后续版本完善 Mac 端播放逻辑后才能完整使用。
     *
     * Note: RECORD_AUDIO permission must be granted before calling this.
     */
    fun setAudioEnabled(enabled: Boolean) {
        if (enabled == _audioEnabled.value) return
        _audioEnabled.value = enabled
        if (enabled && _state.value == State.Connected) startAudioCapture()
        else stopAudioCapture()
    }

    private fun startAudioCapture() {
        stopAudioCapture()
        val sampleRate  = 16_000
        val bufSize     = AudioRecord.getMinBufferSize(sampleRate,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT) * 2
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufSize)
        } catch (e: Exception) { Log.w(TAG, "AudioRecord failed: ${e.message}"); return }

        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return }
        rec.startRecording()
        audioRecord = rec

        audioJob = scope.launch(Dispatchers.IO) {
            val buf = ByteArray(bufSize)
            while (isActive && _audioEnabled.value) {
                val read = rec.read(buf, 0, buf.size)
                if (read > 0) {
                    // Send PCM as a UDP packet with type byte 0x03
                    // Frame format: same 10-byte header, type=0x03
                    val packet = com.lowremote.model.Packet.encodeAudio(
                        nextEventFrameId(), buf.copyOf(read))
                    sender.send(packet)
                }
            }
        }
        Log.d(TAG, "audio capture started @ ${sampleRate}Hz")
    }

    private fun stopAudioCapture() {
        audioJob?.cancel(); audioJob = null
        audioRecord?.apply { stop(); release() }; audioRecord = null
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
        stopAudioCapture()
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
