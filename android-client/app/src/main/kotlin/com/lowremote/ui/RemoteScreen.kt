package com.lowremote.ui

import android.Manifest
import android.content.pm.PackageManager
import android.text.InputType
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.lowremote.model.ControlEvent
import com.lowremote.session.RemoteSession

// ═══════════════════════════════════════════════════════════════════════════
// REMOTE SCREEN
// ═══════════════════════════════════════════════════════════════════════════
/**
 * 主控制界面 — 全屏零 Header。
 *
 * 布局：左侧视频区（height × 1.6），右侧控制区（剩余宽度）。
 * 按返回键：向右滑入抽屉（占屏幕约 50% 宽），再按返回收回抽屉。
 *
 * 抽屉布局：
 *   • 顶部置顶：当前分辨率 + 断开按钮
 *   • 可滚动设置区：屏幕切换 / 帧率 / 视频模式 / 布局 / 音频 / 文字输入 / 拖拽锁
 */
@Composable
fun RemoteScreen(
    session: RemoteSession,
    onDisconnect: () -> Unit,
) {
    val fps         by session.fps.collectAsState()
    val resolution  by session.remoteResolution.collectAsState()
    val state       by session.state.collectAsState()
    val screens     by session.screens.collectAsState()
    val curScreen   by session.currentScreen.collectAsState()
    val audioOn     by session.audioEnabled.collectAsState()

    // ── Persistent prefs ──────────────────────────────────────────────────────
    var drawerOpen       by remember { mutableStateOf(false) }
    var mirrorLayout     by remember { mutableStateOf(false) }   // swap L↔R
    var videoTouchscreen by remember { mutableStateOf(true) }
    var dragLockEnabled  by remember { mutableStateOf(false) }

    // Back key: open drawer if closed, close if open
    BackHandler(enabled = true) {
        if (drawerOpen) drawerOpen = false else drawerOpen = true
    }

    // ── Permission launcher for mic ────────────────────────────────────────────
    val ctx = LocalContext.current
    val audioPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> if (granted) session.setAudioEnabled(true) }

    // ── Layout ────────────────────────────────────────────────────────────────
    val density   = LocalDensity.current
    val layoutDir = if (mirrorLayout) LayoutDirection.Rtl else LayoutDirection.Ltr
    val videoViewRef = remember { mutableStateOf<VideoTouchView?>(null) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            val screenHDp = with(density) { constraints.maxHeight.toDp() }
            val screenWDp = with(density) { constraints.maxWidth.toDp() }

            // Compute video width from the actual remote screen's aspect ratio.
            // Falls back to 16:10 until the first RESOLUTION message arrives.
            val (remW, remH) = resolution ?: Pair(16, 10)
            val ratio        = remW.toFloat() / remH.toFloat()
            // Video fills full screen height; width = height × ratio, clamped so
            // the right panel is at least 80 dp wide.
            val minRightDp   = 80.dp
            val maxVideoWDp  = screenWDp - minRightDp
            val videoWDp     = (screenHDp * ratio).coerceAtMost(maxVideoWDp)
            val rightWDp     = screenWDp - videoWDp

            CompositionLocalProvider(LocalLayoutDirection provides layoutDir) {
                Row(modifier = Modifier.fillMaxSize()) {
                    // ── Video ─────────────────────────────────────────────────
                    Box(
                        modifier = Modifier.fillMaxHeight().width(videoWDp).background(Color.Black),
                        contentAlignment = Alignment.Center,
                    ) {
                        AndroidView(
                            factory = { c ->
                                VideoTouchView(c).also { v ->
                                    videoViewRef.value = v
                                    v.touchscreenMode  = videoTouchscreen
                                    v.dragLockEnabled  = dragLockEnabled
                                    resolution?.let { (w, h) ->
                                        v.targetAspectWidth  = w
                                        v.targetAspectHeight = h
                                    }
                                    v.onSurfaceReady    = { s -> session.setSurface(s) }
                                    v.onSurfaceDestroyed = { session.setSurface(null) }
                                    v.onEvent = { ev -> session.sendEvent(ev) }
                                    v.onFirstTouch = { drawerOpen = false }
                                }
                            },
                            update = { v ->
                                v.touchscreenMode = videoTouchscreen
                                v.dragLockEnabled  = dragLockEnabled
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
                    }

                    // ── Right control panel ───────────────────────────────────
                    Column(
                        modifier = Modifier
                            .fillMaxHeight()
                            .width(rightWDp)
                            .background(Color(0xFF111111)),
                    ) {
                        ShortcutKeyboard(
                            modifier      = Modifier.fillMaxWidth().weight(1f),
                            onEvent       = { ev -> session.sendEvent(ev) },
                            dragLockOn    = dragLockEnabled,
                            onDragLock    = { dragLockEnabled = it },
                            audioOn       = audioOn,
                            onAudio       = { on ->
                                if (on) {
                                    if (ContextCompat.checkSelfPermission(ctx,
                                            Manifest.permission.RECORD_AUDIO) ==
                                        PackageManager.PERMISSION_GRANTED) {
                                        session.setAudioEnabled(true)
                                    } else {
                                        audioPermLauncher.launch(Manifest.permission.RECORD_AUDIO)
                                    }
                                } else {
                                    session.setAudioEnabled(false)
                                }
                            },
                            onSendText    = { text -> session.sendEvent(ControlEvent.TypeText(text)) },
                        )
                        AndroidView(
                            factory = { c ->
                                TouchpadView(c).apply {
                                    setBackgroundColor(0xFF1A1A1A.toInt())
                                    this.dragLockEnabled = dragLockEnabled
                                    onEvent = { ev: ControlEvent -> session.sendEvent(ev) }
                                }
                            },
                            update = { v -> v.dragLockEnabled = dragLockEnabled },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }

        // ── Right-side sliding drawer ─────────────────────────────────────────
        // No scrim — the drawer slides in without a background overlay so the
        // video/control area behind it stays fully visible and touchable.
        AnimatedVisibility(
            visible  = drawerOpen,
            enter    = slideInHorizontally(tween(260)) { it },
            exit     = slideOutHorizontally(tween(220)) { it },
            modifier = Modifier.align(Alignment.CenterEnd),
        ) {
            SessionDrawer(
                fps              = fps,
                state            = state,
                resolution       = resolution,
                screens          = screens,
                curScreen        = curScreen,
                mirrorLayout     = mirrorLayout,
                videoTouchscreen = videoTouchscreen,
                dragLockEnabled  = dragLockEnabled,
                audioOn          = audioOn,
                onChangeFps      = { session.changeFps(it) },
                onSwitchScreen   = { session.switchScreen(it) },
                onToggleMirror   = { mirrorLayout     = it },
                onToggleVideoMode = { videoTouchscreen = it },
                onToggleDragLock = { dragLockEnabled  = it },
                onToggleAudio    = { on ->
                    if (on) {
                        if (ContextCompat.checkSelfPermission(ctx,
                                Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                            session.setAudioEnabled(true)
                        else
                            audioPermLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    } else {
                        session.setAudioEnabled(false)
                    }
                },
                onDisconnect = { drawerOpen = false; onDisconnect() },
                onClose      = { drawerOpen = false },
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// SESSION DRAWER  (slides in from the right, takes ~50% screen width)
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun SessionDrawer(
    fps: Int,
    state: RemoteSession.State,
    resolution: Pair<Int, Int>?,
    screens: List<RemoteSession.ScreenInfo>,
    curScreen: Int,
    mirrorLayout: Boolean,
    videoTouchscreen: Boolean,
    dragLockEnabled: Boolean,
    audioOn: Boolean,
    onChangeFps: (Int) -> Unit,
    onSwitchScreen: (Int) -> Unit,
    onToggleMirror: (Boolean) -> Unit,
    onToggleVideoMode: (Boolean) -> Unit,
    onToggleDragLock: (Boolean) -> Unit,
    onToggleAudio: (Boolean) -> Unit,
    onDisconnect: () -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxHeight()
            .fillMaxWidth(0.5f)
            .background(Color(0xF0141414))
            // Always use LTR inside the drawer regardless of mirror setting
            .then(Modifier),
    ) {
        // ── PINNED TOP: status + disconnect ───────────────────────────────────
        DrawerTopBar(
            state      = state,
            resolution = resolution,
            onDisconnect = onDisconnect,
        )

        HorizontalDivider(color = Color(0xFF2A2A2A))

        // ── SCROLLABLE SETTINGS ───────────────────────────────────────────────
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Screens
            if (screens.isNotEmpty()) {
                DrawerSection("屏幕切换") {
                    screens.forEach { screen ->
                        DrawerRow(
                            label = screen.name,
                            sublabel = "${screen.width}×${screen.height}",
                            active = screen.index == curScreen,
                            onClick = { onSwitchScreen(screen.index) },
                        )
                    }
                }
            }

            // FPS
            DrawerSection("帧率") {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(30, 60, 120).forEach { f ->
                        TinyToggleBtn("${f}fps", f == fps) { onChangeFps(f) }
                    }
                }
            }

            // Video mode
            DrawerSection("视频区操作模式") {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    TinyToggleBtn("触屏",  videoTouchscreen)  { onToggleVideoMode(true) }
                    TinyToggleBtn("触控板", !videoTouchscreen) { onToggleVideoMode(false) }
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    if (videoTouchscreen) "点哪跳哪 · 长按右键 · 双指滚动"
                    else "超大触控板 · 双指滚动/捏合 · 三指手势",
                    color = Color(0xFF555555), fontSize = 10.sp,
                )
            }

            // Layout — only mirror toggle remains; flip removed (use system rotation)
            DrawerSection("布局") {
                DrawerSwitch("控制区在左（横向反转）", mirrorLayout, onToggleMirror)
            }

            // Drag lock
            DrawerSection("拖拽模式") {
                DrawerSwitch("拖拽锁（长按0.45s后才可拖拽，关闭则自由移动）",
                    dragLockEnabled, onToggleDragLock)
            }

            // Audio
            DrawerSection("语音传输") {
                DrawerSwitch("开启麦克风传输", audioOn, onToggleAudio)
                Spacer(Modifier.height(3.dp))
                Text(
                    "开启后手机麦克风音频实时传至 Mac 并播放。\n" +
                    "语音识别/Siri：在 Mac「系统设置→声音→输入」选择对应设备。\n" +
                    "如需让微信等 App 收到声音，需配合 BlackHole 虚拟声卡做回环。",
                    color = Color(0xFF666666), fontSize = 10.sp,
                )
            }

            Spacer(Modifier.height(8.dp))
            Text("点击空白区域或再次按返回关闭",
                color = Color(0xFF3A3A3A), fontSize = 10.sp,
                modifier = Modifier.fillMaxWidth())
        }
    }
}

// ── Drawer components ─────────────────────────────────────────────────────────

@Composable
private fun DrawerTopBar(
    state: RemoteSession.State,
    resolution: Pair<Int, Int>?,
    onDisconnect: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF1A1A1A))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column {
            Text(
                if (state == RemoteSession.State.Connected) "● 已连接" else "○ 断开",
                color  = if (state == RemoteSession.State.Connected) Color(0xFF4CAF50) else Color(0xFFB0B0B0),
                fontSize = 13.sp,
            )
            resolution?.let { (w, h) ->
                Text("${w}×${h}", color = Color(0xFF555555), fontSize = 10.sp)
            }
        }
        Button(
            onClick = onDisconnect,
            colors  = ButtonDefaults.buttonColors(
                containerColor = Color(0xFFB23A48), contentColor = Color.White),
            shape   = RoundedCornerShape(6.dp),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
            modifier = Modifier.height(32.dp),
        ) { Text("断开", fontSize = 12.sp) }
    }
}

@Composable
private fun DrawerSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, color = Color(0xFF666666), fontSize = 11.sp)
        content()
    }
}

@Composable
private fun DrawerRow(label: String, sublabel: String, active: Boolean, onClick: () -> Unit) {
    val bg by animateColorAsState(
        if (active) Color(0xFF1D3557) else Color(0xFF1E1E1E), label = "dr_bg")
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(bg, RoundedCornerShape(6.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label,    color = Color.White, fontSize = 12.sp)
        Text(sublabel, color = Color(0xFF555555), fontSize = 10.sp)
    }
}

@Composable
private fun DrawerSwitch(label: String, checked: Boolean, onChanged: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = Color(0xFFCCCCCC), fontSize = 12.sp, modifier = Modifier.weight(1f))
        Switch(
            checked  = checked,
            onCheckedChange = onChanged,
            colors   = SwitchDefaults.colors(
                checkedTrackColor   = Color(0xFF4A90E2),
                uncheckedTrackColor = Color(0xFF333333),
            ),
        )
    }
}

@Composable
private fun TinyToggleBtn(label: String, active: Boolean, onClick: () -> Unit) {
    val bg by animateColorAsState(
        if (active) Color(0xFF4A90E2) else Color(0xFF2A2A2A), label = "ttb_bg")
    Button(
        onClick = onClick,
        colors  = ButtonDefaults.buttonColors(containerColor = bg, contentColor = Color.White),
        shape   = RoundedCornerShape(5.dp),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
        modifier = Modifier.height(30.dp),
    ) { Text(label, fontSize = 11.sp) }
}
