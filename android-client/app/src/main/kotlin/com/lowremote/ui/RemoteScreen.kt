package com.lowremote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.lowremote.model.ControlEvent
import com.lowremote.session.RemoteSession

/**
 * Main control surface. Fixed three-region layout:
 *
 *   ┌───────────────────────────┬───────────────────────┐
 *   │                           │   ShortcutKeyboard    │
 *   │                           │     (top 45%)         │
 *   │    SurfaceView (video)    ├───────────────────────┤
 *   │   16:10 with black bars   │    TouchpadView       │
 *   │                           │     (bottom 55%)      │
 *   └───────────────────────────┴───────────────────────┘
 *          ~60% width                   ~40% width
 */
@Composable
fun RemoteScreen(
    session: RemoteSession,
    onDisconnect: () -> Unit,
) {
    val state by session.state.collectAsState()
    val fps by session.fps.collectAsState()
    val resolution by session.remoteResolution.collectAsState()

    Column(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        TopBar(
            state = state,
            fps = fps,
            resolution = resolution,
            onChangeFps = { session.changeFps(it) },
            onDisconnect = onDisconnect,
        )
        Row(modifier = Modifier.fillMaxSize()) {
            // Left: video area (60%)
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .weight(0.6f)
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                AndroidView(
                    factory = { ctx ->
                        VideoSurfaceView(ctx).apply {
                            resolution?.let { (w, h) ->
                                targetAspectWidth = w
                                targetAspectHeight = h
                            }
                            onSurfaceReady = { surface -> session.setSurface(surface) }
                            onSurfaceDestroyed = { session.setSurface(null) }
                        }
                    },
                    update = { view ->
                        resolution?.let { (w, h) ->
                            if (view.targetAspectWidth != w || view.targetAspectHeight != h) {
                                view.targetAspectWidth = w
                                view.targetAspectHeight = h
                                view.requestLayout()
                            }
                        }
                    },
                )
            }

            // Right: control panel (40%)
            Column(
                modifier = Modifier
                    .fillMaxHeight()
                    .weight(0.4f)
                    .background(Color(0xFF101010)),
            ) {
                ShortcutKeyboard(
                    modifier = Modifier.weight(0.45f).fillMaxWidth(),
                    onEvent = { ev -> session.sendEvent(ev) },
                )
                AndroidView(
                    factory = { ctx ->
                        TouchpadView(ctx).apply {
                            setBackgroundColor(0xFF1B1B1B.toInt())
                            onEvent = { ev: ControlEvent -> session.sendEvent(ev) }
                        }
                    },
                    modifier = Modifier.weight(0.55f).fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun TopBar(
    state: RemoteSession.State,
    fps: Int,
    resolution: Pair<Int, Int>?,
    onChangeFps: (Int) -> Unit,
    onDisconnect: () -> Unit,
) {
    val statusLabel = when (state) {
        RemoteSession.State.Idle -> "空闲"
        RemoteSession.State.Connecting -> "连接中…"
        RemoteSession.State.Connected -> "已连接"
        RemoteSession.State.Disconnected -> "已断开"
    }
    val resLabel = resolution?.let { "${it.first}×${it.second}" } ?: "—"

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF181818))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(statusLabel, color = Color.White, fontSize = 13.sp)
        Spacer(Modifier.width(6.dp))
        Text(resLabel, color = Color(0xFFB0B0B0), fontSize = 12.sp)
        Spacer(Modifier.weight(1f))

        Text("FPS", color = Color(0xFFB0B0B0), fontSize = 12.sp)
        listOf(30, 60, 120).forEach { f ->
            Button(
                onClick = { onChangeFps(f) },
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (f == fps) Color(0xFF4A90E2) else Color(0xFF2D2D2D),
                    contentColor = Color.White,
                ),
                shape = RoundedCornerShape(4.dp),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                modifier = Modifier.height(28.dp),
            ) {
                Text(f.toString(), fontSize = 11.sp)
            }
        }

        Spacer(Modifier.width(4.dp))
        Button(
            onClick = onDisconnect,
            colors = ButtonDefaults.buttonColors(
                containerColor = Color(0xFFB23A48),
                contentColor = Color.White,
            ),
            shape = RoundedCornerShape(4.dp),
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
            modifier = Modifier.height(28.dp),
        ) {
            Text("断开", fontSize = 11.sp)
        }
    }
}
