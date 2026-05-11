package com.lowremote.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.lowremote.model.ControlEvent
import com.lowremote.session.RemoteSession
import com.lowremote.session.SavedHostsStore
import com.lowremote.ui.theme.*
import kotlinx.coroutines.launch

// ═══════════════════════════════════════════════════════════════════════════
// REMOTE SCREEN  —  竖屏三段式 / 横屏左右式  双布局
// ═══════════════════════════════════════════════════════════════════════════
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

    // ── Persisted settings ────────────────────────────────────────────────
    val context  = LocalContext.current
    val store    = remember { SavedHostsStore(context) }
    val settings by store.settings.collectAsState(initial = SavedHostsStore.AppSettings())
    val scope    = rememberCoroutineScope()

    var drawerOpen       by remember { mutableStateOf(false) }
    var videoTouchscreen by remember { mutableStateOf(true) }
    var dragLockEnabled  by remember { mutableStateOf(false) }
    var scrollModeEnabled by remember { mutableStateOf(false) }
    val videoViewRef     = remember { mutableStateOf<VideoTouchView?>(null) }

    // ── Lock-orientation effect ───────────────────────────────────────────
    val activity = context as? ComponentActivity
    DisposableEffect(settings.lockPortrait) {
        activity?.requestedOrientation = if (settings.lockPortrait)
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
        onDispose {
            activity?.requestedOrientation =
                android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
        }
    }

    // ── Back handler ──────────────────────────────────────────────────────
    BackHandler(enabled = true) {
        drawerOpen = !drawerOpen
    }

    // ── Mic permission ────────────────────────────────────────────────────
    val audioPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> if (granted) session.setAudioEnabled(true) }

    fun toggleAudio(on: Boolean) {
        if (on) {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED) session.setAudioEnabled(true)
            else audioPermLauncher.launch(Manifest.permission.RECORD_AUDIO)
        } else session.setAudioEnabled(false)
    }

    // ── Detect orientation ────────────────────────────────────────────────
    val configuration = LocalConfiguration.current
    val isLandscape = configuration.screenWidthDp > configuration.screenHeightDp

    AppTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Background),
        ) {
            if (isLandscape) {
                LandscapeLayout(
                    session           = session,
                    resolution        = resolution,
                    videoTouchscreen  = videoTouchscreen,
                    dragLockEnabled   = dragLockEnabled,
                    scrollModeEnabled = scrollModeEnabled,
                    audioOn           = audioOn,
                    videoViewRef      = videoViewRef,
                    onEvent           = { session.sendEvent(it) },
                    onDragLock        = { dragLockEnabled = it },
                    onScrollMode      = { scrollModeEnabled = it },
                    onAudio           = ::toggleAudio,
                    onSendText        = { session.sendEvent(ControlEvent.TypeText(it)) },
                    onSendFiles       = { uris -> session.sendFiles(uris, context) },
                )
            } else {
                PortraitLayout(
                    session           = session,
                    resolution        = resolution,
                    videoTouchscreen  = videoTouchscreen,
                    dragLockEnabled   = dragLockEnabled,
                    scrollModeEnabled = scrollModeEnabled,
                    audioOn           = audioOn,
                    videoViewRef      = videoViewRef,
                    onEvent           = { session.sendEvent(it) },
                    onDragLock        = { dragLockEnabled = it },
                    onScrollMode      = { scrollModeEnabled = it },
                    onAudio           = ::toggleAudio,
                    onSendText        = { session.sendEvent(ControlEvent.TypeText(it)) },
                    onSendFiles       = { uris -> session.sendFiles(uris, context) },
                )
            }

            // ── Settings drawer (slides from right, 50% width) ────────────
            AnimatedVisibility(
                visible  = drawerOpen,
                enter    = slideInHorizontally(tween(260)) { it },
                exit     = slideOutHorizontally(tween(220)) { it },
                modifier = Modifier.align(Alignment.CenterEnd),
            ) {
                // The drawer itself is 50% wide and handles its own touches.
                // We do NOT add a full-screen scrim here; instead, the
                // BackHandler / edge-swipe closes it, and the scrim below
                // only covers the NON-drawer half so clicks on the drawer
                // items work normally.
                SessionDrawer(
                    fps              = fps,
                    state            = state,
                    resolution       = resolution,
                    screens          = screens,
                    curScreen        = curScreen,
                    audioOn          = audioOn,
                    videoTouchscreen = videoTouchscreen,
                    dragLockEnabled  = dragLockEnabled,
                    lockPortrait     = settings.lockPortrait,
                    onChangeFps      = { session.changeFps(it) },
                    onSwitchScreen   = { session.switchScreen(it) },
                    onToggleVideoMode = { videoTouchscreen = it },
                    onToggleDragLock = { dragLockEnabled = it },
                    onToggleAudio    = ::toggleAudio,
                    onToggleLockPortrait = { lock ->
                        scope.launch { store.updateSettings { s -> s.copy(lockPortrait = lock) } }
                    },
                    onDisconnect     = { drawerOpen = false; onDisconnect() },
                    onClose          = { drawerOpen = false },
                )
            }

            // Tap on the LEFT half (non-drawer area) to close drawer
            if (drawerOpen) {
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(0.5f)   // only the half NOT covered by drawer
                        .align(Alignment.CenterStart)
                        .clickable(
                            indication = null,
                            interactionSource = remember { MutableInteractionSource() },
                        ) { drawerOpen = false }
                )
            }
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// PORTRAIT LAYOUT  —  上(视频) 中(快捷键) 下(触控板)
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun PortraitLayout(
    session: RemoteSession,
    resolution: Pair<Int, Int>?,
    videoTouchscreen: Boolean,
    dragLockEnabled: Boolean,
    scrollModeEnabled: Boolean,
    audioOn: Boolean,
    videoViewRef: MutableState<VideoTouchView?>,
    onEvent: (ControlEvent) -> Unit,
    onDragLock: (Boolean) -> Unit,
    onScrollMode: (Boolean) -> Unit,
    onAudio: (Boolean) -> Unit,
    onSendText: (String) -> Unit,
    onSendFiles: (List<android.net.Uri>) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {

        // ── TOP: Video area — width=full, height=width * aspect ────────────
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .background(Color.Black),
        ) {
            val viewW = constraints.maxWidth
            val (remW, remH) = resolution ?: Pair(16, 10)
            val aspectH = (viewW * remH / remW.toFloat()).toInt()

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(with(LocalDensity.current) { aspectH.toDp() }),
            ) {
                AndroidView(
                    factory = { c ->
                        VideoTouchView(c).also { v ->
                            videoViewRef.value = v
                            v.touchscreenMode   = videoTouchscreen
                            v.dragLockEnabled   = dragLockEnabled
                            resolution?.let { (w, h) ->
                                v.targetAspectWidth  = w
                                v.targetAspectHeight = h
                            }
                            v.onSurfaceReady     = { s -> session.setSurface(s) }
                            v.onSurfaceDestroyed = { session.setSurface(null) }
                            v.onEvent            = { ev -> onEvent(ev) }
                        }
                    },
                    update = { v ->
                        v.touchscreenMode = videoTouchscreen
                        v.dragLockEnabled = dragLockEnabled
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
                // No floating settings button — use back-swipe to open drawer
            }
        }

        // ── MIDDLE: Shortcut keyboard ────────────────────────────────────
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            ShortcutKeyboard(
                modifier    = Modifier.fillMaxSize(),
                onEvent     = onEvent,
                audioOn     = audioOn,
                onAudio     = onAudio,
                onSendText  = onSendText,
                onSendFiles = onSendFiles,
            )
        }

        // ── BOTTOM: Touchpad with drag/scroll overlay buttons ─────────────
        Box(modifier = Modifier.fillMaxWidth()) {
            AndroidView(
                factory = { c ->
                    TouchpadView(c).also { v ->
                        v.dragLockEnabled   = dragLockEnabled
                        v.scrollModeEnabled = scrollModeEnabled
                        v.onEvent = { ev -> onEvent(ev) }
                    }
                },
                update = { v ->
                    v.dragLockEnabled   = dragLockEnabled
                    v.scrollModeEnabled = scrollModeEnabled
                },
                modifier = Modifier.fillMaxWidth(),
            )

            // Drag-lock toggle — top-left of touchpad
            TouchpadOverlayBtn(
                label   = if (dragLockEnabled) "拖拽 ●" else "拖拽",
                active  = dragLockEnabled,
                modifier = Modifier.align(Alignment.TopStart).padding(6.dp),
                onClick = { onDragLock(!dragLockEnabled) },
            )

            // Scroll-mode toggle — top-right of touchpad
            TouchpadOverlayBtn(
                label   = if (scrollModeEnabled) "滚动 ●" else "滚动",
                active  = scrollModeEnabled,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp),
                onClick = { onScrollMode(!scrollModeEnabled) },
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// LANDSCAPE LAYOUT  —  left video + right panel
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun LandscapeLayout(
    session: RemoteSession,
    resolution: Pair<Int, Int>?,
    videoTouchscreen: Boolean,
    dragLockEnabled: Boolean,
    scrollModeEnabled: Boolean,
    audioOn: Boolean,
    videoViewRef: MutableState<VideoTouchView?>,
    onEvent: (ControlEvent) -> Unit,
    onDragLock: (Boolean) -> Unit,
    onScrollMode: (Boolean) -> Unit,
    onAudio: (Boolean) -> Unit,
    onSendText: (String) -> Unit,
    onSendFiles: (List<android.net.Uri>) -> Unit,
) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val density    = LocalDensity.current
        val screenH    = with(density) { constraints.maxHeight.toDp() }
        val screenW    = with(density) { constraints.maxWidth.toDp() }
        val (remW, remH) = resolution ?: Pair(16, 10)
        val ratio      = remW.toFloat() / remH.toFloat()
        val minRightDp = 100.dp
        val videoWDp   = (screenH * ratio).coerceAtMost(screenW - minRightDp)
        val rightWDp   = screenW - videoWDp

        Row(modifier = Modifier.fillMaxSize()) {
            // Video panel — no floating button
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .width(videoWDp)
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                AndroidView(
                    factory = { c ->
                        VideoTouchView(c).also { v ->
                            videoViewRef.value = v
                            v.touchscreenMode   = videoTouchscreen
                            v.dragLockEnabled   = dragLockEnabled
                            resolution?.let { (w, h) ->
                                v.targetAspectWidth  = w
                                v.targetAspectHeight = h
                            }
                            v.onSurfaceReady     = { s -> session.setSurface(s) }
                            v.onSurfaceDestroyed = { session.setSurface(null) }
                            v.onEvent            = { ev -> onEvent(ev) }
                        }
                    },
                    update = { v ->
                        v.touchscreenMode = videoTouchscreen
                        v.dragLockEnabled = dragLockEnabled
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

            // Right control panel
            Column(
                modifier = Modifier
                    .fillMaxHeight()
                    .width(rightWDp)
                    .background(Background),
            ) {
                Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                    ShortcutKeyboard(
                        modifier    = Modifier.fillMaxSize(),
                        onEvent     = onEvent,
                        audioOn     = audioOn,
                        onAudio     = onAudio,
                        onSendText  = onSendText,
                        onSendFiles = onSendFiles,
                    )
                }
                // Landscape touchpad with overlay buttons
                Box(modifier = Modifier.fillMaxWidth()) {
                    AndroidView(
                        factory = { c ->
                            TouchpadView(c, isLandscape = true).also { v ->
                                v.dragLockEnabled   = dragLockEnabled
                                v.scrollModeEnabled = scrollModeEnabled
                                v.onEvent = { ev -> onEvent(ev) }
                            }
                        },
                        update = { v ->
                            v.dragLockEnabled   = dragLockEnabled
                            v.scrollModeEnabled = scrollModeEnabled
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    TouchpadOverlayBtn(
                        label   = if (dragLockEnabled) "拖拽 ●" else "拖拽",
                        active  = dragLockEnabled,
                        modifier = Modifier.align(Alignment.TopStart).padding(4.dp),
                        onClick = { onDragLock(!dragLockEnabled) },
                    )
                    TouchpadOverlayBtn(
                        label   = if (scrollModeEnabled) "滚动 ●" else "滚动",
                        active  = scrollModeEnabled,
                        modifier = Modifier.align(Alignment.TopEnd).padding(4.dp),
                        onClick = { onScrollMode(!scrollModeEnabled) },
                    )
                }
            }
        }
    }
}

// ── Touchpad overlay button ───────────────────────────────────────────────
@Composable
private fun TouchpadOverlayBtn(
    label: String,
    active: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val bgColor by animateColorAsState(
        targetValue = if (active) Accent.copy(alpha = 0.85f) else Color.Black.copy(alpha = 0.4f),
        animationSpec = tween(160),
        label = "tob_bg",
    )
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(bgColor)
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text  = label,
            color = Color.White,
            style = MaterialTheme.typography.labelSmall,
        )
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// SESSION DRAWER  (50% screen width, no click-through to the drawer content)
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun SessionDrawer(
    fps: Int,
    state: RemoteSession.State,
    resolution: Pair<Int, Int>?,
    screens: List<RemoteSession.ScreenInfo>,
    curScreen: Int,
    audioOn: Boolean,
    videoTouchscreen: Boolean,
    dragLockEnabled: Boolean,
    lockPortrait: Boolean,
    onChangeFps: (Int) -> Unit,
    onSwitchScreen: (Int) -> Unit,
    onToggleVideoMode: (Boolean) -> Unit,
    onToggleDragLock: (Boolean) -> Unit,
    onToggleAudio: (Boolean) -> Unit,
    onToggleLockPortrait: (Boolean) -> Unit,
    onDisconnect: () -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxHeight()
            .fillMaxWidth(0.5f)   // exactly half the screen
            .background(SurfaceL1)
            .border(
                width = 1.dp,
                color = BorderDefault,
                shape = RoundedCornerShape(topStart = 0.dp, bottomStart = 0.dp),
            )
            // consume all touches so they don't fall through to the scrim
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                onClick = { /* absorb */ },
            ),
    ) {
        // ── Top bar ───────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(SurfaceL2)
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    val isConnected = state == RemoteSession.State.Connected
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(if (isConnected) OnlineGreen else TextTertiary),
                    )
                    Text(
                        text  = if (isConnected) "已连接" else "连接中…",
                        style = MaterialTheme.typography.labelLarge,
                        color = if (isConnected) OnlineGreen else TextTertiary,
                    )
                }
                resolution?.let { (w, h) ->
                    Text(
                        text  = "${w} × ${h}",
                        style = MaterialTheme.typography.labelSmall,
                        color = TextTertiary,
                    )
                }
            }
            Button(
                onClick = onDisconnect,
                colors  = ButtonDefaults.buttonColors(
                    containerColor = ErrorRed,
                    contentColor   = Color.White,
                ),
                shape   = RoundedCornerShape(10.dp),
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
                modifier = Modifier.height(36.dp),
            ) {
                Text("断开", style = MaterialTheme.typography.labelLarge)
            }
        }

        HorizontalDivider(color = BorderSubtle)

        // ── Scrollable settings ───────────────────────────────────────────
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Screen selector
            if (screens.isNotEmpty()) {
                DrawerSection("屏幕") {
                    screens.forEach { screen ->
                        val isActive = screen.index == curScreen
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(if (isActive) KeySurfaceActive else KeySurface)
                                .border(1.dp, if (isActive) Accent.copy(0.4f) else BorderSubtle, RoundedCornerShape(10.dp))
                                .clickable { onSwitchScreen(screen.index) }
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment     = Alignment.CenterVertically,
                        ) {
                            Text(screen.name, style = MaterialTheme.typography.bodyMedium, color = TextPrimary)
                            Text("${screen.width}×${screen.height}", style = MaterialTheme.typography.bodySmall, color = TextTertiary)
                        }
                        Spacer(Modifier.height(4.dp))
                    }
                }
            }

            // FPS
            DrawerSection("帧率") {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(30, 60, 120).forEach { f ->
                        DrawerToggleBtn("${f}fps", f == fps) { onChangeFps(f) }
                    }
                }
            }

            // Video mode
            DrawerSection("视频区模式") {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    DrawerToggleBtn("触屏",   videoTouchscreen)  { onToggleVideoMode(true) }
                    DrawerToggleBtn("触控板", !videoTouchscreen) { onToggleVideoMode(false) }
                }
                Spacer(Modifier.height(2.dp))
                Text(
                    if (videoTouchscreen) "点哪跳哪 · 长按右键 · 双指滚动"
                    else "相对移动 · 双指滚动",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextTertiary,
                )
            }

            // Drag lock
            DrawerSection("拖拽模式") {
                DrawerSwitch(
                    label    = "拖拽锁（长按后才可拖拽）",
                    checked  = dragLockEnabled,
                    onChange = onToggleDragLock,
                )
            }

            // Audio
            DrawerSection("麦克风传输") {
                DrawerSwitch(
                    label    = "开启麦克风实时传至 Mac",
                    checked  = audioOn,
                    onChange = onToggleAudio,
                )
            }

            // Orientation
            DrawerSection("布局设置") {
                DrawerSwitch(
                    label    = "锁定竖屏方向",
                    sublabel = "关闭时随系统自动旋转",
                    checked  = lockPortrait,
                    onChange = onToggleLockPortrait,
                )
            }

            Spacer(Modifier.height(4.dp))
            Text(
                "← 点击左侧或按返回键关闭",
                style = MaterialTheme.typography.bodySmall,
                color = TextTertiary.copy(alpha = 0.5f),
            )
        }
    }
}

// ── Drawer sub-components ─────────────────────────────────────────────────

@Composable
private fun DrawerSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text  = title,
            style = MaterialTheme.typography.labelMedium,
            color = TextTertiary,
        )
        content()
    }
}

@Composable
private fun DrawerToggleBtn(label: String, active: Boolean, onClick: () -> Unit) {
    val bg by animateColorAsState(
        targetValue = if (active) Accent else KeySurface,
        animationSpec = tween(180),
        label = "dtb_bg",
    )
    val tc by animateColorAsState(
        targetValue = if (active) Color.White else TextSecondary,
        animationSpec = tween(180),
        label = "dtb_tc",
    )
    Button(
        onClick  = onClick,
        colors   = ButtonDefaults.buttonColors(containerColor = bg, contentColor = tc),
        shape    = RoundedCornerShape(8.dp),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
        modifier = Modifier.height(32.dp),
        elevation = null,
    ) { Text(label, style = MaterialTheme.typography.labelMedium) }
}

@Composable
private fun DrawerSwitch(
    label: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    sublabel: String? = null,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment     = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
            Text(label, style = MaterialTheme.typography.bodyMedium, color = TextPrimary)
            if (sublabel != null) {
                Text(sublabel, style = MaterialTheme.typography.bodySmall, color = TextTertiary)
            }
        }
        Switch(
            checked         = checked,
            onCheckedChange = onChange,
            colors          = SwitchDefaults.colors(
                checkedTrackColor    = Accent,
                uncheckedTrackColor  = SurfaceL3,
                uncheckedBorderColor = BorderDefault,
            ),
        )
    }
}
