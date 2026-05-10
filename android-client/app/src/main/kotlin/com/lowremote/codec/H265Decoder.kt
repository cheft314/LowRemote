package com.lowremote.codec

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * H.265 (HEVC) hardware decoder driven in asynchronous mode.
 *
 * Input queue: [feed] can be called from any thread. The bytes are buffered
 * in a small in-memory queue and drained on the codec callback thread —
 * this avoids blocking the UDP thread when the codec momentarily has no
 * free input buffers (e.g. at startup before the first csd frame).
 *
 * Output: always renders directly to the [surface] with no CPU copy.
 *
 * Decoder initialisation: the first frame we feed is expected to be a
 * keyframe with VPS/SPS/PPS prepended (Annex-B), which MediaCodec parses
 * via CSD-0. Until such a frame arrives we drop all non-keyframes.
 */
class H265Decoder(
    private val surface: Surface,
    private val expectedFps: Int,
) {
    companion object {
        private const val TAG = "H265Decoder"
        private const val MIME = "video/hevc"
        private const val INPUT_QUEUE_CAP = 8
    }

    private var codec: MediaCodec? = null
    private var codecThread: HandlerThread? = null
    private var codecHandler: Handler? = null

    private val started = AtomicBoolean(false)
    private val csdReceived = AtomicBoolean(false)
    private val pendingInputs = ConcurrentLinkedQueue<ByteArray>()
    private val availableInputIndexes = ConcurrentLinkedQueue<Int>()

    private var ptsCounter: Long = 0

    fun start(width: Int = 1920, height: Int = 1080) {
        if (started.get()) return

        val thread = HandlerThread("h265-decoder").apply { start() }
        val handler = Handler(thread.looper)
        codecThread = thread
        codecHandler = handler

        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            // KEY_LOW_LATENCY was introduced in API 30 and dramatically reduces
            // decoder output queue depth when the codec supports it.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                setFloat(MediaFormat.KEY_OPERATING_RATE, expectedFps.toFloat())
                setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            }
        }

        val c = MediaCodec.createDecoderByType(MIME)
        c.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                availableInputIndexes.offer(index)
                drainPending()
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo,
            ) {
                // render=true pushes the frame to the attached Surface immediately.
                try {
                    codec.releaseOutputBuffer(index, true)
                } catch (e: IllegalStateException) {
                    // codec was stopped between the callback firing and us handling it
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.w(TAG, "codec error: ${e.diagnosticInfo}", e)
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.d(TAG, "output format: $format")
            }
        }, handler)

        c.configure(format, surface, null, 0)
        c.start()
        codec = c
        started.set(true)
        Log.d(TAG, "started ($width x $height @ ${expectedFps}fps)")
    }

    fun stop() {
        if (!started.getAndSet(false)) return
        try {
            codec?.stop()
        } catch (_: Exception) {}
        try {
            codec?.release()
        } catch (_: Exception) {}
        codec = null
        pendingInputs.clear()
        availableInputIndexes.clear()
        csdReceived.set(false)

        codecThread?.quitSafely()
        codecThread = null
        codecHandler = null
    }

    /**
     * Feed a complete Annex-B frame. For the first frame this MUST be a
     * keyframe (with VPS/SPS/PPS) — earlier frames are silently discarded.
     */
    fun feed(bytes: ByteArray, isKeyframe: Boolean) {
        if (!started.get()) return
        if (!csdReceived.get()) {
            if (!isKeyframe && !looksLikeParameterSet(bytes)) {
                // Waiting for the first IDR; anything else is unusable.
                return
            }
            csdReceived.set(true)
        }
        pendingInputs.offer(bytes)
        drainPending()
    }

    private fun drainPending() {
        val c = codec ?: return
        while (true) {
            val data = pendingInputs.peek() ?: return
            val idx = availableInputIndexes.poll() ?: return
            pendingInputs.poll()
            try {
                val buf = c.getInputBuffer(idx) ?: return
                buf.clear()
                if (buf.capacity() < data.size) {
                    Log.w(TAG, "input buffer too small (${buf.capacity()} < ${data.size}); dropping frame")
                    c.queueInputBuffer(idx, 0, 0, 0, 0)
                    continue
                }
                buf.put(data)
                ptsCounter += 1_000_000L / expectedFps
                c.queueInputBuffer(idx, 0, data.size, ptsCounter, 0)
            } catch (e: IllegalStateException) {
                // codec stopped concurrently
                return
            }
        }
    }

    /**
     * Heuristic: if the Annex-B blob begins with a VPS NAL (H.265 NAL type 32)
     * we can treat it like a CSD chunk even if the upstream flag didn't mark it.
     */
    private fun looksLikeParameterSet(bytes: ByteArray): Boolean {
        // Start code: 00 00 00 01 or 00 00 01
        var i = 0
        if (bytes.size > 4 && bytes[0] == 0.toByte() && bytes[1] == 0.toByte()
            && bytes[2] == 0.toByte() && bytes[3] == 1.toByte()) {
            i = 4
        } else if (bytes.size > 3 && bytes[0] == 0.toByte() && bytes[1] == 0.toByte()
            && bytes[2] == 1.toByte()) {
            i = 3
        } else return false
        if (i >= bytes.size) return false
        val nalType = (bytes[i].toInt() ushr 1) and 0x3F
        // 32 = VPS, 33 = SPS, 34 = PPS
        return nalType in 32..34
    }

    fun flush() {
        if (!started.get()) return
        try {
            codec?.flush()
        } catch (_: Exception) {}
        pendingInputs.clear()
        availableInputIndexes.clear()
    }
}
