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
 * Format: 48 000 Hz · stereo · Float32 interleaved · little-endian.
 * Matches [AudioCaptureManager] on the Mac side.
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
        private const val SAMPLE_RATE = 48_000
        private const val CHANNELS    = AudioFormat.CHANNEL_OUT_STEREO
        private const val ENCODING    = AudioFormat.ENCODING_PCM_FLOAT
    }

    private var track: AudioTrack? = null

    fun start() {
        stop()
        val minBuf  = AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNELS, ENCODING)
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
                    .setChannelMask(CHANNELS)
                    .setEncoding(ENCODING)
                    .build()
            )
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        t.play()
        track = t
        Log.d(TAG, "AudioTrack started: 48kHz stereo Float32, bufSize=$bufSize")
    }

    /**
     * Feed one UDP 0x04 payload.  Bytes are Float32 LE interleaved [L,R,L,R…].
     * Uses WRITE_NON_BLOCKING to absorb jitter without building up latency.
     */
    fun write(bytes: ByteArray, length: Int = bytes.size) {
        val t = track ?: return
        if (t.playState != AudioTrack.PLAYSTATE_PLAYING) return
        val floatCount = length / 4
        if (floatCount == 0) return
        val floats = FloatArray(floatCount)
        ByteBuffer.wrap(bytes, 0, floatCount * 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .asFloatBuffer()
            .get(floats)
        t.write(floats, 0, floatCount, AudioTrack.WRITE_NON_BLOCKING)
    }

    fun stop() {
        try { track?.stop(); track?.release() } catch (e: Exception) {
            Log.w(TAG, "stop: ${e.message}")
        }
        track = null
    }
}
