package com.lowremote.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Plays raw PCM audio received from the Mac server.
 *
 * Format: 16 000 Hz · mono · Int16 little-endian.
 * Matches the simplified AudioCaptureManager format on the Mac side.
 *
 * Architecture: a dedicated AudioTrack thread drains a bounded queue,
 * while [write] enqueues chunks from the UDP receive thread.
 * This decouples UDP jitter from the audio output clock and avoids the
 * "滋滋滋" noise caused by intermittent silence gaps when using
 * WRITE_NON_BLOCKING (which drops frames when the AudioTrack buffer is full
 * or when the caller arrives late).
 *
 * Usage:
 *   val player = AudioPlayer()
 *   player.start()
 *   player.write(pcmBytes)   // called for each UDP 0x04 payload
 *   player.stop()
 */
class AudioPlayer {

    companion object {
        private const val TAG         = "AudioPlayer"
        private const val SAMPLE_RATE = 16_000          // matches Mac capture
        private const val CHANNELS    = AudioFormat.CHANNEL_OUT_MONO
        private const val ENCODING    = AudioFormat.ENCODING_PCM_16BIT

        // Queue capacity in chunks.  Each 20-ms chunk = 640 bytes.
        // 50 chunks = 1 second; acts as a jitter buffer without adding
        // noticeable latency under normal Wi-Fi conditions.
        private const val QUEUE_CAPACITY = 50
    }

    private var track:       AudioTrack? = null
    private var playThread:  Thread?     = null
    private val running      = AtomicBoolean(false)
    private val queue        = LinkedBlockingQueue<ByteArray>(QUEUE_CAPACITY)

    fun start() {
        stop()

        val minBuf  = AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNELS, ENCODING)
        // Use ~300 ms internal buffer so the OS never underruns even under load.
        val bufSize = maxOf(minBuf * 6, SAMPLE_RATE * 2 / 10) // 200 ms

        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(CHANNELS)
                    .setEncoding(ENCODING)
                    .build()
            )
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        t.play()
        track = t
        running.set(true)
        queue.clear()

        // Dedicated write thread — never blocks the UDP receive coroutine.
        playThread = Thread({
            Log.d(TAG, "play thread started")
            while (running.get()) {
                try {
                    val chunk = queue.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
                        ?: continue
                    // Convert Int16 LE bytes → ShortArray and write with BLOCKING mode
                    // so every sample reaches the DAC in order.
                    val shorts = ShortArray(chunk.size / 2)
                    ByteBuffer.wrap(chunk).order(ByteOrder.LITTLE_ENDIAN)
                        .asShortBuffer().get(shorts)
                    t.write(shorts, 0, shorts.size)   // WRITE_BLOCKING (default)
                } catch (_: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.w(TAG, "play thread error: ${e.message}")
                }
            }
            Log.d(TAG, "play thread stopped")
        }, "AudioPlayer").also { it.isDaemon = true; it.start() }

        Log.d(TAG, "AudioTrack started: ${SAMPLE_RATE} Hz mono Int16, bufSize=$bufSize")
    }

    /**
     * Enqueue one UDP 0x04 payload.  Bytes are Int16 LE mono samples.
     * Called from the UDP receive coroutine — must not block.
     * If the queue is full (> 1 second of audio) the oldest chunk is
     * discarded to prevent latency runaway.
     */
    fun write(bytes: ByteArray, length: Int = bytes.size) {
        if (!running.get()) return
        val chunk = if (length == bytes.size) bytes else bytes.copyOf(length)
        if (!queue.offer(chunk)) {
            queue.poll()          // drop oldest to make room
            queue.offer(chunk)
        }
    }

    fun stop() {
        running.set(false)
        playThread?.interrupt()
        playThread?.join(500)
        playThread = null
        queue.clear()
        try { track?.stop(); track?.release() } catch (e: Exception) {
            Log.w(TAG, "stop: ${e.message}")
        }
        track = null
    }
}
