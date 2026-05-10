package com.lowremote.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Plays raw PCM audio received from the Mac server.
 *
 * Expected format: 48 000 Hz · stereo (2 channels) · Float32 interleaved · little-endian.
 * This matches [AudioCaptureManager] on the Mac side.
 *
 * Usage:
 *   val player = AudioPlayer()
 *   player.start()
 *   // on each UDP audio packet payload:
 *   player.write(pcmBytes)
 *   // when session ends:
 *   player.stop()
 */
class AudioPlayer {

    companion object {
        private const val TAG = "AudioPlayer"
        private const val SAMPLE_RATE = 48_000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_STEREO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_FLOAT
    }

    private var track: AudioTrack? = null

    fun start() {
        stop()

        val minBuf = AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        // Use at least 4× the minimum to absorb jitter from UDP delivery.
        val bufSize = maxOf(minBuf * 4, 65536)

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
                    .setChannelMask(CHANNEL_CONFIG)
                    .setEncoding(AUDIO_FORMAT)
                    .build()
            )
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        t.play()
        track = t
        Log.d(TAG, "AudioTrack started (bufSize=$bufSize)")
    }

    /**
     * Feed a raw PCM chunk from the UDP payload. The bytes are
     * Float32 little-endian interleaved samples (L, R, L, R …).
     *
     * Called from the UDP receive thread — AudioTrack.write() is thread-safe
     * in streaming mode and will block briefly if the internal buffer is full,
     * which provides natural back-pressure.
     */
    fun write(bytes: ByteArray, length: Int = bytes.size) {
        val t = track ?: return
        if (t.playState != AudioTrack.PLAYSTATE_PLAYING) return

        // Convert byte array → FloatArray (little-endian Float32).
        val floatCount = length / 4
        if (floatCount == 0) return
        val floats = FloatArray(floatCount)
        val bb = ByteBuffer.wrap(bytes, 0, floatCount * 4).order(ByteOrder.LITTLE_ENDIAN)
        bb.asFloatBuffer().get(floats)

        // Non-blocking write: write what fits; drop the rest to avoid latency build-up.
        t.write(floats, 0, floatCount, AudioTrack.WRITE_NON_BLOCKING)
    }

    fun stop() {
        try {
            track?.stop()
            track?.release()
        } catch (e: Exception) {
            Log.w(TAG, "stop error: ${e.message}")
        }
        track = null
    }
}
