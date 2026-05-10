package com.lowremote.model

/**
 * A Mac discovered on the LAN via mDNS.
 */
data class RemoteDevice(
    val name: String,
    val host: String,
    val tcpPort: Int,
    val udpPort: Int,
) {
    val key: String get() = "$host:$tcpPort"
}
