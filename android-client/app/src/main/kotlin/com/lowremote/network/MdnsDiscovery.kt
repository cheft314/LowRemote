package com.lowremote.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import com.lowremote.model.RemoteDevice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.ConcurrentHashMap

/**
 * Discovers Mac servers on the LAN via Bonjour/mDNS.
 *
 * Uses Android's built-in NsdManager. On API 34+ we use the Executor-based
 * resolveService variant; on older versions we fall back to the deprecated
 * listener variant (which is the only one available).
 */
class MdnsDiscovery(private val context: Context) {

    companion object {
        private const val TAG = "MdnsDiscovery"
        private const val SERVICE_TYPE = "_maclocalremote._tcp."
    }

    private val nsdManager by lazy {
        context.getSystemService(Context.NSD_SERVICE) as NsdManager
    }

    private val _devices = MutableStateFlow<List<RemoteDevice>>(emptyList())
    val devices: StateFlow<List<RemoteDevice>> = _devices

    /** Keyed by service name (not device-stable, but unique during a scan). */
    private val byName = ConcurrentHashMap<String, RemoteDevice>()

    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null) return

        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "discovery started for $serviceType")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "start failed: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "stop failed: $errorCode")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                Log.d(TAG, "found ${info.serviceName}")
                resolve(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                Log.d(TAG, "lost ${info.serviceName}")
                byName.remove(info.serviceName)
                _devices.value = byName.values.toList().sortedBy { it.name }
            }
        }
        listener = l
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
            } catch (_: Exception) { /* already stopped */ }
        }
        listener = null
        byName.clear()
        _devices.value = emptyList()
    }

    private fun resolve(info: NsdServiceInfo) {
        val resolveCallback = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "resolve failed for ${serviceInfo.serviceName}: $errorCode")
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val host = serviceInfo.host?.hostAddress ?: return
                val tcpPort = serviceInfo.port
                val udpPort = tcpPort + 1  // fallback if TXT not provided

                val txt = serviceInfo.attributes
                val parsedUdp = txt["udp_port"]?.let { runCatching { String(it).toInt() }.getOrNull() }
                val deviceName = txt["device"]?.let { String(it) } ?: serviceInfo.serviceName

                val device = RemoteDevice(
                    name = deviceName,
                    host = host,
                    tcpPort = tcpPort,
                    udpPort = parsedUdp ?: udpPort,
                )
                byName[serviceInfo.serviceName] = device
                _devices.value = byName.values.toList().sortedBy { it.name }
                Log.d(TAG, "resolved: $device")
            }
        }

        @Suppress("DEPRECATION")
        nsdManager.resolveService(info, resolveCallback)
    }
}
