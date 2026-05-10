package com.lowremote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.lowremote.model.ControlEvent
import com.lowremote.session.RemoteSession

/**
 * 主控制界面 — 零 Header 全屏，充分利用挖孔屏每一像素。
 *
 * 布局（横屏）：
 *
 *   ┌──────────────────────────────┬────────────────────┐
 *   │  VideoTouchView              │  ShortcutKeyboard  │
 *   │  高 = 全屏高（含挖孔区）      │  (剩余高度)         │
 *   │  宽 = 高 × 1.6               ├────────────────────┤
 *   │                              │  TouchpadView      │
 *   │  [触屏/触控板 可切换]         │  宽满, 高=宽÷1.6   │
 *   └──────────────────────────────┴────────────────────┘
 *
 * 横向反转：将 Row 的 LayoutDirection 翻转，视频在右、控制面板在左。
 * 挖孔屏：fillMaxSize() + LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES（在 MainActivity 设置），
 *   视频区故意绘制到挖孔区域（挖孔在视频里几乎不可察），控制区不会被遮挡（挖孔在屏幕另一侧）。
 *
 * 返回键 → 弹出半透明菜单，包含：
 *   • 连接状态 / 分辨率
 *   • FPS 切换
 *   • 视频区模式切换（触屏 / 触控板）
 *   • 横向反转开关
 *   • 断开按钮
 */
@Composable
fun RemoteScreen(
    session: RemoteSession,
    onDisconnect: () -> Unit,
) {
    val fps        by session.fps.collectAsState()
    val resolution by session.remoteResolution.collectAsState()
    val state      by session.state.collectAsState()

    // ── Persistent UI preferences (survive recomposition) ────────────────────
    var showMenu        by remember { mutableStateOf(false) }
    var mirrorLayout    by remember { mutableStateOf(false) }   // horizontal flip
    var videoTouchscreen by remember { mutableStateOf(true) }   // touchscreen vs trackpad

    BackHandler { showMenu = true }

    // Keep a stable reference to VideoTouchView so we can update its mode.
    val videoViewRef = remember { mutableStateOf<VideoTouchView?>(null) }
    LaunchedEffect(videoTouchscreen) {
        videoViewRef.value?.touchscreenMode = videoTouchscreen
    }

    // Mirror the entire Row by reversing LayoutDirection
    val layoutDir = if (mirrorLayout) LayoutDirection.Rtl else LayoutDirection.Ltr

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            // Consume ALL insets: draw under status-bar, nav-bar, and cutout
            .windowInsetsPadding(WindowInsets(0, 0, 0, 0)),
    ) {
        val density   = LocalDensity.current
        val screenHDp = with(density) { constraints.maxHeight.toDp() }
        val screenWDp = with(density) { constraints.maxWidth.toDp() }

        // Left column: video — height fills screen, width = height × 1.6
        val videoWDp  = (screenHDp * 1.6f).coerceAtMost(screenWDp)
        val rightWDp  = screenWDp - videoWDp

        CompositionLocalProvider(LocalLayoutDirection provides layoutDir) {
            Row(modifier = Modifier.fillMaxSize()) {

                // ── Video area ────────────────────────────────────────────────
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .width(videoWDp)
                        .background(Color.Black),
                    contentAlignment = Alignment.Center,
                ) {
                    AndroidView(
                        factory = { ctx ->
                            VideoTouchView(ctx).also { v ->
                                videoViewRef.value = v
                                v.touchscreenMode = videoTouchscreen
                                resolution?.let { (w, h) ->
                                    v.targetAspectWidth  = w
                                    v.targetAspectHeight = h
                                }
                                v.onSurfaceReady    = { s -> session.setSurface(s) }
                                v.onSurfaceDestroyed = { session.setSurface(null) }
                                v.onEvent = { ev -> session.sendEvent(ev) }
                            }
                        },
                        update = { v ->
                            v.touchscreenMode = videoTouchscreen
                            resolution?.let { (w, h) ->
                                if (v.targetAspectWidth != w || v.targetAspectHeight != h) {
                                    v.targetAspectWidth  = w
                                    v.targetAspectHeight = h
                                    v.requestLayout()
                                }
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    )

                    // Touch-mode indicator badge (top corner)
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(6.dp)
                            .background(
                                color = if (videoTouchscreen) Color(0x884A90E2) else Color(0x88333333),
                                shape = RoundedCornerShape(4.dp),
                            )
                            .clickable { videoTouchscreen = !videoTouchscreen }
                            .padding(horizontal = 6.dp, vertical = 3.dp),
                    ) {
                        Text(
                            text = if (videoTouchscreen) "触屏" else "触控板",
                            color = Color.White,
                            fontSize = 10.sp,
                        )
                    }
                }

                // ── Right control panel ───────────────────────────────────────
                Column(
                    modifier = Modifier
                        .fillMaxHeight()
                        .width(rightWDp)
                        .background(Color(0xFF111111)),
                ) {
                    ShortcutKeyboard(
                        modifier = Modifier.fillMaxWidth().weight(1f),
                        onEvent  = { ev -> session.sendEvent(ev) },
                    )
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
        }

        // ── Back-key menu overlay ─────────────────────────────────────────────
        if (showMenu) {
            SessionMenuDialog(
                fps              = fps,
                state            = state,
                resolution       = resolution,
                mirrorLayout     = mirrorLayout,
                videoTouchscreen = videoTouchscreen,
                onChangeFps      = { session.changeFps(it) },
                onToggleMirror   = { mirrorLayout = it },
                onToggleVideoMode = { videoTouchscreen = it },
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
// 菜单弹窗（返回键触发）
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun SessionMenuDialog(
    fps: Int,
    state: RemoteSession.State,
    resolution: Pair<Int, Int>?,
    mirrorLayout: Boolean,
    videoTouchscreen: Boolean,
    onChangeFps: (Int) -> Unit,
    onToggleMirror: (Boolean) -> Unit,
    onToggleVideoMode: (Boolean) -> Unit,
    onDisconnect: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xAA000000))
                .clickable(onClick = onDismiss),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier = Modifier
                    .width(280.dp)
                    .background(Color(0xFF1E1E1E), RoundedCornerShape(14.dp))
                    .clickable { /* consume */ }
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // ── Status ────────────────────────────────────────────────────
                Text(
                    text = if (state == RemoteSession.State.Connected) "● 已连接" else "○ 未连接",
                    color = if (state == RemoteSession.State.Connected) Color(0xFF4CAF50) else Color(0xFFB0B0B0),
                    fontSize = 14.sp,
                )
                resolution?.let { (w, h) ->
                    Spacer(Modifier.height(3.dp))
                    Text("${w}×${h}", color = Color(0xFF666666), fontSize = 11.sp)
                }

                Spacer(Modifier.height(16.dp))
                Divider(color = Color(0xFF2D2D2D))
                Spacer(Modifier.height(14.dp))

                // ── FPS ───────────────────────────────────────────────────────
                MenuSectionLabel("帧率")
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(30, 60, 120).forEach { f ->
                        ToggleButton(
                            label = "${f}fps",
                            active = f == fps,
                            onClick = { onChangeFps(f); onDismiss() },
                        )
                    }
                }

                Spacer(Modifier.height(14.dp))
                Divider(color = Color(0xFF2D2D2D))
                Spacer(Modifier.height(14.dp))

                // ── Video touch mode ──────────────────────────────────────────
                MenuSectionLabel("视频区操作模式")
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ToggleButton(
                        label  = "触屏模式",
                        active = videoTouchscreen,
                        onClick = { onToggleVideoMode(true) },
                    )
                    ToggleButton(
                        label  = "触控板模式",
                        active = !videoTouchscreen,
                        onClick = { onToggleVideoMode(false) },
                    )
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    text = if (videoTouchscreen)
                        "点哪跳哪·单指轻点单击·长按右键·双指滚动"
                    else
                        "超大触控板·delta移动·双指滚动/捏合·三指手势",
                    color  = Color(0xFF666666),
                    fontSize = 10.sp,
                )

                Spacer(Modifier.height(14.dp))
                Divider(color = Color(0xFF2D2D2D))
                Spacer(Modifier.height(14.dp))

                // ── Mirror / flip ────────────────────────────────────────────
                MenuSectionLabel("布局")
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("横向反转（控制区在左）", color = Color(0xFFB0B0B0), fontSize = 13.sp)
                    Switch(
                        checked = mirrorLayout,
                        onCheckedChange = onToggleMirror,
                        colors = SwitchDefaults.colors(
                            checkedThumbColor    = Color.White,
                            checkedTrackColor    = Color(0xFF4A90E2),
                            uncheckedTrackColor  = Color(0xFF333333),
                        ),
                    )
                }

                Spacer(Modifier.height(14.dp))
                Divider(color = Color(0xFF2D2D2D))
                Spacer(Modifier.height(14.dp))

                // ── Disconnect ────────────────────────────────────────────────
                Button(
                    onClick = onDisconnect,
                    colors  = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFFB23A48),
                        contentColor   = Color.White,
                    ),
                    shape    = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("断开连接", fontSize = 14.sp)
                }

                Spacer(Modifier.height(10.dp))
                Text("点击空白处关闭", color = Color(0xFF444444), fontSize = 10.sp)
            }
        }
    }
}

// ── Small reusable composables ────────────────────────────────────────────────

@Composable
private fun MenuSectionLabel(text: String) {
    Text(text, color = Color(0xFF888888), fontSize = 11.sp,
        modifier = Modifier.fillMaxWidth())
}

@Composable
private fun ToggleButton(label: String, active: Boolean, onClick: () -> Unit) {
    val bg by animateColorAsState(
        targetValue = if (active) Color(0xFF4A90E2) else Color(0xFF2D2D2D),
        label = "toggle_bg",
    )
    Button(
        onClick  = onClick,
        colors   = ButtonDefaults.buttonColors(containerColor = bg, contentColor = Color.White),
        shape    = RoundedCornerShape(6.dp),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(label, fontSize = 12.sp)
    }
}
