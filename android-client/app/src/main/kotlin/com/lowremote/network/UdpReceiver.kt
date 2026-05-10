package com.lowremote.network

import android.util.Log
import com.lowremote.model.Packet
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

/**
 * Receives UDP packets from the Mac. We intentionally use a blocking
 * `DatagramSocket` on a dedicated high-priority thread rather than
 * `DatagramChannel` + Selector — for a single-peer stream it's simpler and
 * has no measurable latency difference on modern Android.
 *
 * The callback delivers the datagram body as a fresh `ByteArray` of exactly
 * the received length, along with the parsed header. The caller is expected
 * to hand video fragments to a [com.lowremote.codec.FrameAssembler].
 */
class UdpReceiver(
    private val port: Int,
    private val recvBufferBytes: Int = 4 * 1024 * 1024,
) {
    companion object {
        private const val TAG = "UdpReceiver"
        private const val BUF_SIZE = 65536
    }

    @Volatile private var running = false
    private var socket: DatagramSocket? = null
    private var thread: Thread? = null

    /**
     * Called on the receive thread (NOT the main thread) with every packet.
     * Keep work here minimal; hand data off to queues / MediaCodec.
     */
    var onPacket: ((Packet.Parsed, ByteArray, Int) -> Unit)? = null

    /** host+port we'll pin to via connect() so the kernel filters unexpected senders. */
    var peerHost: InetAddress? = null
    var peerPort: Int = 0

    fun start() {
        if (running) return
        running = true

        val sock = DatagramSocket(null)
        sock.reuseAddress = true
        try {
            sock.receiveBufferSize = recvBufferBytes
        } catch (_: Exception) { /* best-effort */ }
        sock.bind(java.net.InetSocketAddress(port))
        socket = sock

        thread = thread(name = "udp-receiver", priority = Thread.MAX_PRIORITY) {
            receiveLoop(sock)
        }
        Log.d(TAG, "started on :$port")
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        thread?.join(200)
        thread = null
    }

    /**
     * Returns the local port the socket is bound to. Same as `port` unless 0 was passed.
     */
    fun localPort(): Int = socket?.localPort ?: port

    /**
     * Share the underlying socket so [UdpSender] can send from the same port —
     * this lets Mac's UDP server treat our client-endpoint pair as stable and
     * route return traffic symmetrically through NAT/firewalls.
     */
    fun sharedSocket(): DatagramSocket? = socket

    private fun receiveLoop(sock: DatagramSocket) {
        val buf = ByteArray(BUF_SIZE)
        val dp = DatagramPacket(buf, buf.size)
        while (running) {
            try {
                sock.receive(dp)
                val len = dp.length
                if (len < Packet.HEADER_SIZE) continue
                val parsed = Packet.parse(buf, len) ?: continue

                // Copy the payload into a right-sized array — the shared buffer
                // will be reused on the next receive().
                val copy = ByteArray(parsed.payloadLength)
                System.arraycopy(buf, parsed.payloadOffset, copy, 0, parsed.payloadLength)

                onPacket?.invoke(parsed, copy, parsed.payloadLength)
            } catch (e: IOException) {
                if (running) {
                    Log.w(TAG, "receive error: ${e.message}")
                }
            }
        }
    }
}

/**
 * Helper to write UDP datagrams out, preferably reusing the same socket as the
 * receiver (so the Mac sees us as a single host:port pair).
 */
class UdpSender {

    companion object { private const val TAG = "UdpSender" }

    private var socket: DatagramSocket? = null
    private var peerAddress: InetAddress? = null
    private var peerPort: Int = 0

    /**
     * Use the receiver's socket so both directions share a source port.
     * Must be called before [send].
     */
    fun attach(socket: DatagramSocket, host: String, port: Int) {
        this.socket = socket
        this.peerAddress = InetAddress.getByName(host)
        this.peerPort = port
    }

    fun send(bytes: ByteArray) {
        val sock = socket ?: return
        val addr = peerAddress ?: return
        try {
            sock.send(DatagramPacket(bytes, bytes.size, addr, peerPort))
        } catch (e: IOException) {
            Log.w(TAG, "send failed: ${e.message}")
        }
    }

    fun sendEvent(eventString: String, frameId: Int) {
        send(Packet.encodeControl(frameId, eventString))
    }
}
