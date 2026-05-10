package com.lowremote.model

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * UDP packet format, mirroring the Mac side.
 *
 * Header (10 bytes, little-endian):
 *   frame_id : uint32
 *   pkt_idx  : uint16
 *   pkt_total: uint16
 *   type     : uint8   (0x01 = video, 0x02 = control)
 *   flags    : uint8   (bit 0 = keyframe-start)
 */
object Packet {
    const val HEADER_SIZE = 10
    const val MTU_SAFE_TOTAL = 1400
    const val MAX_PAYLOAD_SIZE = MTU_SAFE_TOTAL - HEADER_SIZE

    const val TYPE_VIDEO: Byte = 0x01
    const val TYPE_CONTROL: Byte = 0x02

    const val FLAG_KEYFRAME: Byte = 0x01

    /**
     * Build a control-event packet ready for `DatagramSocket.send`.
     */
    const val TYPE_AUDIO: Byte = 0x03

    fun encodeAudio(frameId: Int, pcm: ByteArray): ByteArray {
        val buf = ByteBuffer.allocate(HEADER_SIZE + pcm.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(frameId)
        buf.putShort(0)
        buf.putShort(1)
        buf.put(TYPE_AUDIO)
        buf.put(0)
        buf.put(pcm)
        return buf.array()
    }

    fun encodeControl(frameId: Int, eventString: String): ByteArray {
        val payload = eventString.toByteArray(Charsets.UTF_8)
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(frameId)
        buf.putShort(0)
        buf.putShort(1)
        buf.put(TYPE_CONTROL)
        buf.put(0)
        buf.put(payload)
        return buf.array()
    }

    /**
     * Parse the header of a received packet.
     * Returns null if the buffer is too small or malformed.
     *
     * `buffer` is expected to be positioned at 0 and have `limit` set to the
     * received datagram size.
     */
    data class Parsed(
        val frameId: Int,
        val pktIdx: Int,
        val pktTotal: Int,
        val type: Byte,
        val flags: Byte,
        /** Absolute offset within the datagram where the payload starts. */
        val payloadOffset: Int,
        /** Length of the payload in bytes. */
        val payloadLength: Int,
    ) {
        val isKeyframe: Boolean get() = (flags.toInt() and FLAG_KEYFRAME.toInt()) != 0
    }

    fun parse(data: ByteArray, length: Int): Parsed? {
        if (length < HEADER_SIZE) return null
        val bb = ByteBuffer.wrap(data, 0, length).order(ByteOrder.LITTLE_ENDIAN)
        val frameId = bb.int
        val pktIdx = bb.short.toInt() and 0xFFFF
        val pktTotal = bb.short.toInt() and 0xFFFF
        val type = bb.get()
        val flags = bb.get()
        return Parsed(
            frameId = frameId,
            pktIdx = pktIdx,
            pktTotal = pktTotal,
            type = type,
            flags = flags,
            payloadOffset = HEADER_SIZE,
            payloadLength = length - HEADER_SIZE,
        )
    }
}
