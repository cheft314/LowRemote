package com.lowremote.session

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

/**
 * Holds everything needed for an active remote-control session with one Mac:
 *   - TCP control channel
 *   - UDP receiver (video) + sender (events)
 *   - Frame assembler + H.265 decoder feeding a Surface
 *   - Heartbeat
 *
 * State machine is intentionally thin: Idle → Connecting → Connected → Idle.
 * Disconnects collapse back to Idle and tear everything down.
 */
class RemoteSession {

    companion object {
        private const val TAG = "RemoteSession"
        /** Client-side UDP bind port. 0 = ephemeral, picked by the OS. */
        private const val CLIENT_UDP_PORT = 0
        private const val HEARTBEAT_INTERVAL_MS = 30_000L
    }

    enum class State { Idle, Connecting, Connected, Disconnected }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val tcp = TcpClient(scope)
    private val receiver = UdpReceiver(port = CLIENT_UDP_PORT)
    private val sender = UdpSender()
    private val assembler = FrameAssembler()

    private var decoder: H265Decoder? = null
    @Volatile private var surface: Surface? = null
    private var heartbeatJob: Job? = null
    private val decoderLock = Any()

    private var device: RemoteDevice? = null
    private var eventFrameId: Int = 0

    private val _state = MutableStateFlow(State.Idle)
    val state: StateFlow<State> = _state

    private val _remoteResolution = MutableStateFlow<Pair<Int, Int>?>(null)
    val remoteResolution: StateFlow<Pair<Int, Int>?> = _remoteResolution

    private val _fps = MutableStateFlow(60)
    val fps: StateFlow<Int> = _fps

    init {
        assembler.onFrameReady = { bytes, isKeyframe ->
            decoder?.feed(bytes, isKeyframe)
        }

        receiver.onPacket = { parsed, payload, _ ->
            when (parsed.type) {
                Packet.TYPE_VIDEO -> assembler.onPacket(parsed, payload)
                else -> { /* ignore */ }
            }
        }

        tcp.onLine = { line -> handleTcpLine(line) }
        tcp.onDisconnected = {
            scope.launch { teardown() }
        }
    }

    fun setSurface(s: Surface?) {
        synchronized(decoderLock) {
            surface = s
            // Surface gone → tear down decoder so MediaCodec doesn't keep
            // writing into an invalidated EGL target.
            if (s == null) {
                decoder?.stop()
                decoder = null
                return
            }
            // Surface just appeared while we were already connected: start
            // decoding immediately.
            if (_state.value == State.Connected && decoder == null) {
                startDecoderIfReadyLocked()
            }
        }
    }

    fun connect(device: RemoteDevice, fps: Int) {
        if (_state.value != State.Idle && _state.value != State.Disconnected) return
        _state.value = State.Connecting
        this.device = device
        _fps.value = fps

        scope.launch {
            // 1. Start UDP first so the sender's source port is bound and we
            //    don't miss the very first video frame the Mac emits.
            receiver.start()
            val sock = receiver.sharedSocket()
            if (sock == null) {
                Log.w(TAG, "receiver socket unavailable")
                teardown()
                return@launch
            }
            sender.attach(sock, device.host, device.udpPort)

            // 2. Poke the Mac's UDP listener with a no-op so it learns our
            //    endpoint and can start streaming frames to us.
            sender.sendEvent("HELLO", nextEventFrameId())

            // 3. Open TCP control channel.
            val ok = tcp.connect(device.host, device.tcpPort)
            if (!ok) {
                Log.w(TAG, "tcp connect failed")
                teardown()
                return@launch
            }

            // 4. Request the desired fps. The Mac responds with OK and begins
            //    streaming; the RESOLUTION line is pushed eagerly on connect.
            tcp.send("FPS:$fps")

            _state.value = State.Connected
            startHeartbeat()
        }
    }

    fun changeFps(fps: Int) {
        _fps.value = fps
        if (_state.value == State.Connected) {
            // Quick decoder reset — params may change on keyframe boundary.
            synchronized(decoderLock) {
                decoder?.flush()
            }
            assembler.reset()
            tcp.send("FPS:$fps")
        }
    }

    fun sendEvent(event: ControlEvent) {
        if (_state.value != State.Connected) return
        // Must NOT run on the main/UI thread — DatagramSocket.send() is a
        // network call and Android will throw NetworkOnMainThreadException if
        // invoked from the touch-event callback chain.
        val serialized = event.serialize()
        val frameId = nextEventFrameId()
        scope.launch(Dispatchers.IO) {
            try {
                sender.sendEvent(serialized, frameId)
            } catch (e: Exception) {
                Log.w(TAG, "sendEvent failed: ${e.message}")
            }
        }
    }

    fun disconnect() {
        if (_state.value == State.Idle) return
        if (tcp.isConnected) tcp.send("DISCONNECT")
        scope.launch { teardown() }
    }

    fun release() {
        scope.launch { teardown() }
        scope.cancel()
    }

    // MARK: - Internals

    private fun handleTcpLine(line: String) {
        val trimmed = line.trim()
        when {
            trimmed.startsWith("RESOLUTION:") -> {
                val parts = trimmed.removePrefix("RESOLUTION:").split(",")
                if (parts.size == 2) {
                    val w = parts[0].toIntOrNull()
                    val h = parts[1].toIntOrNull()
                    if (w != null && h != null) {
                        _remoteResolution.value = w to h
                        startDecoderIfReady()
                    }
                }
            }
            trimmed == "OK" -> {
                // Server accepted our FPS; decoder can run now.
                startDecoderIfReady()
            }
            trimmed == "PONG" -> { /* heartbeat reply */ }
        }
    }

    private fun startDecoderIfReady() {
        synchronized(decoderLock) {
            startDecoderIfReadyLocked()
        }
    }

    private fun startDecoderIfReadyLocked() {
        val s = surface ?: return
        if (decoder != null) return
        val (w, h) = _remoteResolution.value ?: (1920 to 1080)
        val dec = H265Decoder(s, _fps.value)
        dec.start(w, h)
        decoder = dec
        Log.d(TAG, "decoder started: $w x $h @ ${_fps.value}fps")
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(HEARTBEAT_INTERVAL_MS)
                if (tcp.isConnected) tcp.send("PING") else break
            }
        }
    }

    private suspend fun teardown() {
        heartbeatJob?.cancel()
        heartbeatJob = null
        tcp.disconnect()
        receiver.stop()
        synchronized(decoderLock) {
            decoder?.stop()
            decoder = null
        }
        assembler.reset()
        _state.value = State.Disconnected
        device = null
    }

    private fun nextEventFrameId(): Int {
        eventFrameId = (eventFrameId + 1) and 0x7FFFFFFF
        return eventFrameId
    }
}
