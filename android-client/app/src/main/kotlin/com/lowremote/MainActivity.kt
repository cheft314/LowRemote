package com.lowremote

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.lowremote.network.MdnsDiscovery
import com.lowremote.session.RemoteSession
import com.lowremote.ui.DeviceListScreen
import com.lowremote.ui.RemoteScreen

/**
 * Single activity that owns the [RemoteSession] and switches between the
 * device-list screen and the active-remote screen based on session state.
 *
 * We also grab a `MulticastLock` for the lifetime of the activity — on Wi-Fi,
 * some vendors filter inbound multicast (mDNS) packets until an app explicitly
 * requests them, and discovery silently returns nothing without it.
 */
class MainActivity : ComponentActivity() {

    private lateinit var session: RemoteSession
    private lateinit var discovery: MdnsDiscovery
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Keep mDNS traffic flowing even when the Wi-Fi stack would otherwise
        // filter it.
        val wifi = getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("LowRemote-mdns").apply {
            setReferenceCounted(false)
            acquire()
        }

        session = RemoteSession()
        discovery = MdnsDiscovery(this)
        discovery.start()

        setContent {
            Root(session = session, discovery = discovery)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        discovery.stop()
        session.release()
        multicastLock?.let { if (it.isHeld) it.release() }
    }
}

@Composable
private fun Root(session: RemoteSession, discovery: MdnsDiscovery) {
    val state by session.state.collectAsState()

    // Re-initiate discovery whenever we're back on the list screen, so newly
    // booted Macs appear without restarting the app.
    DisposableEffect(state) {
        if (state == RemoteSession.State.Idle || state == RemoteSession.State.Disconnected) {
            discovery.start()
        }
        onDispose { /* keep discovery alive while app is in foreground */ }
    }

    when (state) {
        RemoteSession.State.Idle,
        RemoteSession.State.Disconnected -> {
            DeviceListScreen(
                discovery = discovery,
                onConnect = { device, fps ->
                    session.connect(device, fps)
                },
            )
        }
        RemoteSession.State.Connecting,
        RemoteSession.State.Connected -> {
            RemoteScreen(
                session = session,
                onDisconnect = { session.disconnect() },
            )
        }
    }
}
