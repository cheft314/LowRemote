package com.lowremote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
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
import androidx.compose.material3.Divider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.lowremote.model.ControlEvent
import com.lowremote.session.RemoteSession

/**
 * 主控制界面 — 无顶部 Header，全屏充分利用每一像素。
 *
 * 布局规则：
 *   ┌──────────────────────────┬──────────────────┐
 *   │  SurfaceView             │  ShortcutKeyboard│
 *   │  高度 = 全屏高度          │  (剩余高度 - 触控)│
 *   │  宽度 = 高度 × 1.6       ├──────────────────┤
 *   │  (Mac 16:10 比例)        │  TouchpadView    │
 *   │                          │  宽 = 右侧满宽   │
 *   │                          │  高 = 宽 ÷ 1.6   │
 *   └──────────────────────────┴──────────────────┘
 *
 * 按返回键弹出半透明菜单（FPS 切换、断开、状态信息）。
 */
@Composable
fun RemoteScreen(
    session: RemoteSession,
    onDisconnect: () -> Unit,
) {
    val fps by session.fps.collectAsState()
    val resolution by session.remoteResolution.collectAsState()
    val state by session.state.collectAsState()

    // 控制菜单显示
    var showMenu by remember { mutableStateOf(false) }

    // 返回键 → 弹出菜单而非直接退出
    BackHandler { showMenu = true }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        // constraints 里是像素值，用 LocalDensity 转成 Dp
        val density = LocalDensity.current
        val screenHDp = with(density) { constraints.maxHeight.toDp() }
        val screenWDp = with(density) { constraints.maxWidth.toDp() }

        // 视频区宽度 = 全屏高度 × 1.6，超出屏幕宽度时夹住
        val videoWDp = (screenHDp * 1.6f).coerceAtMost(screenWDp)
        val rightWDp = screenWDp - videoWDp

        Row(modifier = Modifier.fillMaxSize()) {
            // ── 左侧：视频区 ──────────────────────────────────────
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .width(videoWDp)
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                AndroidView(
                    factory = { ctx ->
                        VideoSurfaceView(ctx).also { v ->
                            resolution?.let { (w, h) ->
                                v.targetAspectWidth = w
                                v.targetAspectHeight = h
                            }
                            v.onSurfaceReady = { surface -> session.setSurface(surface) }
                            v.onSurfaceDestroyed = { session.setSurface(null) }
                        }
                    },
                    update = { v ->
                        resolution?.let { (w, h) ->
                            if (v.targetAspectWidth != w || v.targetAspectHeight != h) {
                                v.targetAspectWidth = w
                                v.targetAspectHeight = h
                                v.requestLayout()
                            }
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }

            // ── 右侧：控制区（剩余宽度） ──────────────────────────
            Column(
                modifier = Modifier
                    .fillMaxHeight()
                    .width(rightWDp)
                    .background(Color(0xFF111111)),
            ) {
                // 快捷键区：撑满剩余高度（Column weight=1）
                ShortcutKeyboard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    onEvent = { ev -> session.sendEvent(ev) },
                )

                // 触控板：宽度由 fillMaxWidth 给定，
                // 高度由 TouchpadView.onMeasure 按 16:10 自动计算
                AndroidView(
                    factory = { ctx ->
                        TouchpadView(ctx).apply {
                            setBackgroundColor(0xFF1A1A1A.toInt())
                            onEvent = { ev: ControlEvent -> session.sendEvent(ev) }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        // ── 菜单弹层（返回键触发）────────────────────────────────
        if (showMenu) {
            SessionMenuDialog(
                fps = fps,
                state = state,
                resolution = resolution,
                onChangeFps = { session.changeFps(it) },
                onDisconnect = {
                    showMenu = false
                    onDisconnect()
                },
                onDismiss = { showMenu = false },
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 返回键菜单弹窗
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun SessionMenuDialog(
    fps: Int,
    state: RemoteSession.State,
    resolution: Pair<Int, Int>?,
    onChangeFps: (Int) -> Unit,
    onDisconnect: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        // 无遮罩：直接居中显示菜单卡片，点击卡片外区域关闭
        Box(
            modifier = Modifier
                .fillMaxSize()
                .clickable(onClick = onDismiss),
            contentAlignment = Alignment.Center,
        ) {
            // 菜单卡片，阻止点击穿透
            Column(
                modifier = Modifier
                    .width(260.dp)
                    .background(Color(0xFF1E1E1E), RoundedCornerShape(12.dp))
                    .clickable { /* consume */ }
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // 状态信息
                val statusText = when (state) {
                    RemoteSession.State.Connected -> "● 已连接"
                    RemoteSession.State.Connecting -> "○ 连接中…"
                    else -> "○ 未连接"
                }
                Text(
                    statusText,
                    color = if (state == RemoteSession.State.Connected) Color(0xFF4CAF50)
                    else Color(0xFFB0B0B0),
                    fontSize = 14.sp,
                )

                resolution?.let { (w, h) ->
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "${w}×${h}",
                        color = Color(0xFF888888),
                        fontSize = 12.sp,
                    )
                }

                Spacer(Modifier.height(16.dp))
                Divider(color = Color(0xFF333333))
                Spacer(Modifier.height(16.dp))

                // FPS 选择
                Text("帧率", color = Color(0xFFB0B0B0), fontSize = 13.sp)
                Spacer(Modifier.height(8.dp))
                Row {
                    listOf(30, 60, 120).forEach { f ->
                        Button(
                            onClick = {
                                onChangeFps(f)
                                onDismiss()
                            },
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (f == fps) Color(0xFF4A90E2) else Color(0xFF2D2D2D),
                                contentColor = Color.White,
                            ),
                            shape = RoundedCornerShape(6.dp),
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                            modifier = Modifier.padding(horizontal = 4.dp),
                        ) {
                            Text("${f}fps", fontSize = 12.sp)
                        }
                    }
                }

                Spacer(Modifier.height(20.dp))
                Divider(color = Color(0xFF333333))
                Spacer(Modifier.height(16.dp))

                // 断开按钮
                Button(
                    onClick = onDisconnect,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFFB23A48),
                        contentColor = Color.White,
                    ),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("断开连接", fontSize = 14.sp)
                }

                Spacer(Modifier.height(8.dp))

                Text(
                    "点击空白处关闭",
                    color = Color(0xFF555555),
                    fontSize = 11.sp,
                )
            }
        }
    }
}
