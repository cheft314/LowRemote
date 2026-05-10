package com.lowremote.codec

import android.util.Log
import com.lowremote.model.Packet
import java.util.concurrent.ConcurrentHashMap

/**
 * Re-assembles UDP fragments (one Annex-B H.265 frame per frame_id) into
 * complete byte arrays ready for MediaCodec.
 *
 * At 120fps the inter-frame window is ~8ms; any fragment whose other pieces
 * don't arrive within [timeoutMs] is evicted — a late frame is worse than a
 * dropped one because it would cascade latency onto everything behind it.
 *
 * This class is safe to call from the UDP receive thread.
 */
class FrameAssembler(
    private val timeoutMs: Long = 50,
) {
    companion object { private const val TAG = "FrameAssembler" }

    private class FrameBuffer(val total: Int, val createdAt: Long) {
        val chunks = arrayOfNulls<ByteArray>(total)
        var received = 0
        var keyframe = false
        fun put(idx: Int, data: ByteArray) {
            if (idx < 0 || idx >= total) return
            if (chunks[idx] == null) {
                chunks[idx] = data
                received++
            }
        }
        val isComplete: Boolean get() = received == total
        fun assemble(): ByteArray {
            val totalLen = chunks.sumOf { it?.size ?: 0 }
            val out = ByteArray(totalLen)
            var pos = 0
            for (c in chunks) {
                if (c != null) {
                    System.arraycopy(c, 0, out, pos, c.size)
                    pos += c.size
                }
            }
            return out
        }
    }

    /** frame_id -> in-flight buffer */
    private val frames = ConcurrentHashMap<Int, FrameBuffer>()

    /** Highest frame_id we've already emitted, to drop late arrivals. */
    @Volatile private var lastEmittedId: Int = -1

    /** Callback invoked with a fully assembled frame (Annex-B). */
    var onFrameReady: ((bytes: ByteArray, isKeyframe: Boolean) -> Unit)? = null

    fun onPacket(parsed: Packet.Parsed, payload: ByteArray) {
        if (parsed.type != Packet.TYPE_VIDEO) return
        val frameId = parsed.frameId
        if (frameId <= lastEmittedId && !parsed.isKeyframe) {
            // Already emitted a later frame; this one's stale.
            return
        }

        if (parsed.pktTotal <= 0) return
        val buffer = frames.getOrPut(frameId) {
            FrameBuffer(parsed.pktTotal, System.currentTimeMillis())
        }
        buffer.put(parsed.pktIdx, payload)
        if (parsed.isKeyframe) buffer.keyframe = true

        if (buffer.isComplete) {
            frames.remove(frameId)
            val bytes = buffer.assemble()
            lastEmittedId = frameId
            onFrameReady?.invoke(bytes, buffer.keyframe)
            evictOlder(frameId)
        }
        evictExpired()
    }

    private fun evictOlder(currentId: Int) {
        // Drop any in-flight frame older than the one we just emitted.
        val iter = frames.entries.iterator()
        while (iter.hasNext()) {
            val e = iter.next()
            if (e.key < currentId) iter.remove()
        }
    }

    private fun evictExpired() {
        val now = System.currentTimeMillis()
        val iter = frames.entries.iterator()
        while (iter.hasNext()) {
            val e = iter.next()
            if (now - e.value.createdAt > timeoutMs) {
                iter.remove()
                Log.d(TAG, "dropped incomplete frame ${e.key} (${e.value.received}/${e.value.total})")
            }
        }
    }

    fun reset() {
        frames.clear()
        lastEmittedId = -1
    }
}
