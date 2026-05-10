package com.lowremote.network

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Line-based TCP control channel to the Mac.
 *
 * Sends/receives `\n`-terminated UTF-8 strings. Runs its read loop on a
 * background coroutine and hands decoded lines to [onLine].
 */
class TcpClient(
    private val scope: CoroutineScope,
) {
    companion object {
        private const val TAG = "TcpClient"
        private const val CONNECT_TIMEOUT_MS = 3000
    }

    private var socket: Socket? = null
    private var output: OutputStream? = null
    private var readerJob: Job? = null

    var onLine: ((String) -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null
    var onConnected: (() -> Unit)? = null

    suspend fun connect(host: String, port: Int): Boolean = withContext(Dispatchers.IO) {
        disconnect()
        try {
            val s = Socket()
            s.tcpNoDelay = true
            s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            socket = s
            output = s.getOutputStream()
            startReader(s)
            onConnected?.invoke()
            Log.d(TAG, "connected to $host:$port")
            true
        } catch (e: IOException) {
            Log.w(TAG, "connect failed: ${e.message}")
            false
        }
    }

    private fun startReader(s: Socket) {
        readerJob?.cancel()
        readerJob = scope.launch(Dispatchers.IO) {
            val reader = BufferedReader(InputStreamReader(s.getInputStream(), Charsets.UTF_8))
            try {
                while (isActive) {
                    val line = reader.readLine() ?: break
                    onLine?.invoke(line)
                }
            } catch (e: IOException) {
                Log.d(TAG, "reader ended: ${e.message}")
            } finally {
                onDisconnected?.invoke()
                try { s.close() } catch (_: IOException) {}
            }
        }
    }

    fun send(line: String) {
        val payload = if (line.endsWith("\n")) line else "$line\n"
        scope.launch(Dispatchers.IO) {
            try {
                output?.write(payload.toByteArray(Charsets.UTF_8))
                output?.flush()
            } catch (e: IOException) {
                Log.w(TAG, "send failed: ${e.message}")
            }
        }
    }

    fun disconnect() {
        readerJob?.cancel()
        readerJob = null
        try { socket?.close() } catch (_: IOException) {}
        socket = null
        output = null
    }

    val isConnected: Boolean
        get() = socket?.isConnected == true && socket?.isClosed == false
}
