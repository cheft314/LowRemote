package com.lowremote

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.lowremote.network.MdnsDiscovery
import com.lowremote.session.RemoteSession
import com.lowremote.ui.DeviceListScreen
import com.lowremote.ui.RemoteScreen
import com.lowremote.ui.theme.AppTheme

/**
 * Single activity.
 *
 * enableEdgeToEdge() makes the app draw under the status bar, navigation bar,
 * and – critically – the camera cut-out area.  The content then uses
 * WindowInsets to offset anything that must NOT be obscured (e.g. the
 * device-list screen), while the remote screen deliberately fills every pixel.
 */
class MainActivity : ComponentActivity() {

    private lateinit var session: RemoteSession
    private lateinit var discovery: MdnsDiscovery
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Draw under the notch / punch-hole / display-cutout on all API levels.
        enableEdgeToEdge()

        // On API 28+ explicitly allow drawing into the display cutout area.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.also { attrs ->
                attrs.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val wifi = getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("LowRemote-mdns").apply {
            setReferenceCounted(false)
            acquire()
        }

        session   = RemoteSession()
        discovery = MdnsDiscovery(this)
        discovery.start()

        setContent { Root(session = session, discovery = discovery) }
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

    DisposableEffect(state) {
        if (state == RemoteSession.State.Idle || state == RemoteSession.State.Disconnected) {
            discovery.start()
        }
        onDispose { }
    }

    AppTheme {
        when (state) {
            RemoteSession.State.Idle,
            RemoteSession.State.Disconnected ->
                DeviceListScreen(discovery = discovery, onConnect = { d, fps -> session.connect(d, fps) })

            RemoteSession.State.Connecting,
            RemoteSession.State.Connected ->
                RemoteScreen(session = session, onDisconnect = { session.disconnect() })
        }
    }
}
