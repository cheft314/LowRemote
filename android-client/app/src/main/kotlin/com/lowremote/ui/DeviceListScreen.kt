package com.lowremote.ui

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.zIndex
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.lowremote.model.RemoteDevice
import com.lowremote.network.MdnsDiscovery
import com.lowremote.session.SavedHost
import com.lowremote.session.SavedHostsStore
import com.lowremote.session.toRemoteDevice
import com.lowremote.ui.theme.*
import kotlinx.coroutines.launch
import java.util.UUID


// ═══════════════════════════════════════════════════════════════════════════
// DEVICE LIST SCREEN
// ═══════════════════════════════════════════════════════════════════════════
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceListScreen(
    discovery: MdnsDiscovery,
    onConnect: (RemoteDevice, Int) -> Unit,
) {
    val context       = LocalContext.current
    val store         = remember { SavedHostsStore(context) }
    val scope         = rememberCoroutineScope()

    val mdnsDevices   by discovery.devices.collectAsState()
    val savedHosts    by store.hosts.collectAsState(initial = emptyList())
    val settings      by store.settings.collectAsState(initial = com.lowremote.session.SavedHostsStore.AppSettings())

    var selectedFps   by remember { mutableIntStateOf(60) }
    var showAddDialog by remember { mutableStateOf(false) }
    var editingHost   by remember { mutableStateOf<SavedHost?>(null) }

    // Sync default FPS from settings
    LaunchedEffect(settings.defaultFps) { selectedFps = settings.defaultFps }

    AppTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Background)
                .windowInsetsPadding(WindowInsets.systemBars),
        ) {
            // ── Fixed header ──────────────────────────────────────────────
            ScreenHeader(modifier = Modifier.align(Alignment.TopCenter).zIndex(1f))

            // ── Scrollable content below header ───────────────────────────
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 112.dp, bottom = 32.dp),
            ) {
                item {
                    FpsSelector(
                        selected  = selectedFps,
                        onSelect  = {
                            selectedFps = it
                            scope.launch { store.updateSettings { s -> s.copy(defaultFps = it) } }
                        },
                        modifier  = Modifier.padding(horizontal = 20.dp),
                    )
                    Spacer(Modifier.height(24.dp))
                }

                // ── mDNS section ──────────────────────────────────────────
                item {
                    SectionLabel(
                        icon  = Icons.Outlined.Wifi,
                        title = "局域网自动发现",
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                    Spacer(Modifier.height(10.dp))
                }

                if (mdnsDevices.isEmpty()) {
                    item { SearchingIndicator(modifier = Modifier.padding(horizontal = 20.dp)) }
                } else {
                    items(mdnsDevices, key = { it.key }) { device ->
                        MdnsDeviceCard(
                            device    = device,
                            onClick   = { onConnect(device, selectedFps) },
                            modifier  = Modifier.padding(horizontal = 20.dp),
                        )
                        Spacer(Modifier.height(8.dp))
                    }
                }

                // ── Saved hosts section ───────────────────────────────────
                item {
                    Spacer(Modifier.height(20.dp))
                    SectionLabel(
                        icon  = Icons.Outlined.BookmarkBorder,
                        title = "已保存的主机",
                        action = {
                            AddHostButton(onClick = { showAddDialog = true })
                        },
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                    Spacer(Modifier.height(10.dp))
                }

                if (savedHosts.isEmpty()) {
                    item {
                        SavedHostsEmptyHint(
                            onAdd    = { showAddDialog = true },
                            modifier = Modifier.padding(horizontal = 20.dp),
                        )
                    }
                } else {
                    items(savedHosts, key = { it.id }) { host ->
                        SavedHostCard(
                            host     = host,
                            onClick  = { onConnect(host.toRemoteDevice(), selectedFps) },
                            onEdit   = { editingHost = it },
                            onDelete = { scope.launch { store.removeHost(host.id) } },
                            modifier = Modifier.padding(horizontal = 20.dp),
                        )
                        Spacer(Modifier.height(8.dp))
                    }
                }

                // ── Bottom add button ──────────────────────────────────────
                item {
                    Spacer(Modifier.height(16.dp))
                    AddHostFullButton(
                        onClick  = { showAddDialog = true },
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                }
            }

            // ── Dialogs ───────────────────────────────────────────────────
            if (showAddDialog) {
                AddHostDialog(
                    initial  = null,
                    onDismiss = { showAddDialog = false },
                    onSave   = { host ->
                        scope.launch { store.addHost(host) }
                        showAddDialog = false
                    },
                )
            }
            editingHost?.let { host ->
                AddHostDialog(
                    initial  = host,
                    onDismiss = { editingHost = null },
                    onSave   = { updated ->
                        scope.launch { store.addHost(updated) }
                        editingHost = null
                    },
                )
            }
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// HEADER
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun ScreenHeader(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Background)
            .drawBehind {
                // Subtle radial glow at top-centre
                drawCircle(
                    brush  = Brush.radialGradient(
                        colors = listOf(AccentGlow, Color.Transparent),
                        center = Offset(size.width / 2f, 0f),
                        radius = size.width * 0.7f,
                    ),
                    radius = size.width * 0.7f,
                    center = Offset(size.width / 2f, 0f),
                )
            }
            .padding(horizontal = 20.dp, vertical = 28.dp),
    ) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // App icon badge
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(
                            Brush.linearGradient(listOf(Accent, Purple))
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.DesktopWindows,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(22.dp),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        text  = "LowRemote",
                        style = MaterialTheme.typography.headlineMedium,
                        color = TextPrimary,
                    )
                    Text(
                        text  = "Mac 远程控制",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextTertiary,
                    )
                }
            }
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// FPS SELECTOR
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun FpsSelector(
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        Text(
            text  = "帧率",
            style = MaterialTheme.typography.labelMedium,
            color = TextTertiary,
        )
        Spacer(Modifier.height(8.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(SurfaceL1)
                .border(1.dp, BorderSubtle, RoundedCornerShape(12.dp))
                .padding(4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            listOf(30, 60, 120).forEach { fps ->
                val isSelected = fps == selected
                val bgColor by animateColorAsState(
                    targetValue = if (isSelected) Accent else Color.Transparent,
                    animationSpec = tween(200),
                    label = "fps_bg",
                )
                val textColor by animateColorAsState(
                    targetValue = if (isSelected) Color.White else TextSecondary,
                    animationSpec = tween(200),
                    label = "fps_text",
                )
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(9.dp))
                        .background(bgColor)
                        .clickable { onSelect(fps) }
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text  = "${fps} fps",
                        style = MaterialTheme.typography.labelLarge,
                        color = textColor,
                    )
                }
            }
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// SECTION LABEL
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun SectionLabel(
    icon: ImageVector,
    title: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = TextTertiary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text  = title,
                style = MaterialTheme.typography.labelMedium,
                color = TextTertiary,
            )
        }
        action?.invoke()
    }
}

@Composable
private fun AddHostButton(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .background(AccentGlow)
            .padding(horizontal = 10.dp, vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.Filled.Add, null, tint = Accent, modifier = Modifier.size(14.dp))
            Text("添加", style = MaterialTheme.typography.labelMedium, color = Accent)
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// MDNS DEVICE CARD
// ═══════════════════════════════════════════════════════════════════════════
@Composable
private fun MdnsDeviceCard(
    device: RemoteDevice,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessMedium),
        label = "card_scale",
    )

    Box(
        modifier = modifier
            .fillMaxWidth()
            .scale(scale)
            .clip(RoundedCornerShape(14.dp))
            .background(SurfaceL1)
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(listOf(BorderDefault, BorderSubtle)),
                shape = RoundedCornerShape(14.dp),
            )
            .clickable {
                pressed = true
                onClick()
            }
            .padding(16.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Icon badge
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(SurfaceL2),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.LaptopMac,
                    contentDescription = null,
                    tint = Accent,
                    modifier = Modifier.size(22.dp),
                )
            }
            // Device info
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text  = device.name,
                    style = MaterialTheme.typography.titleMedium,
                    color = TextPrimary,
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    text  = "${device.host}  ·  TCP ${device.tcpPort}",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextTertiary,
                )
            }
            // Online indicator + arrow
            Column(horizontalAlignment = Alignment.End) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(7.dp)
                            .clip(CircleShape)
                            .background(OnlineGreen),
                    )
                    Text(
                        text  = "在线",
                        style = MaterialTheme.typography.labelSmall,
                        color = OnlineGreen,
                    )
                }
                Spacer(Modifier.height(6.dp))
                Icon(
                    imageVector = Icons.Filled.ChevronRight,
                    contentDescription = null,
                    tint = TextTertiary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

// ── Searching indicator ────────────────────────────────────────────────────
@Composable
private fun SearchingIndicator(modifier: Modifier = Modifier) {
    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val alpha by infiniteTransition.animateFloat(
        initialValue   = 0.3f,
        targetValue    = 0.7f,
        animationSpec  = infiniteRepeatable(
            animation   = tween(900, easing = FastOutSlowInEasing),
            repeatMode  = RepeatMode.Reverse,
        ),
        label = "search_alpha",
    )

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SurfaceL1)
            .border(1.dp, BorderSubtle, RoundedCornerShape(12.dp))
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CircularProgressIndicator(
            modifier  = Modifier.size(16.dp),
            color     = Accent,
            strokeWidth = 2.dp,
        )
        Column {
            Text(
                text  = "正在搜索局域网设备…",
                style = MaterialTheme.typography.bodyMedium,
                color = TextSecondary.copy(alpha = alpha),
            )
            Text(
                text  = "请确认 Mac 已启动 LowRemote，且与手机同一 Wi-Fi",
                style = MaterialTheme.typography.bodySmall,
                color = TextTertiary,
            )
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// SAVED HOST CARD
// ═══════════════════════════════════════════════════════════════════════════
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SavedHostCard(
    host: SavedHost,
    onClick: () -> Unit,
    onEdit: (SavedHost) -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) { onDelete(); true }
            else false
        },
        positionalThreshold = { it * 0.4f },
    )

    SwipeToDismissBox(
        state    = dismissState,
        modifier = modifier,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            // Red delete background revealed on swipe
            val color by animateColorAsState(
                if (dismissState.dismissDirection == SwipeToDismissBoxValue.EndToStart)
                    ErrorRed else SurfaceL1,
                label = "swipe_bg",
            )
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(14.dp))
                    .background(color)
                    .padding(end = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = "删除",
                    tint = Color.White,
                    modifier = Modifier.size(22.dp),
                )
            }
        },
        content = {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(SurfaceL1)
                    .border(1.dp, BorderSubtle, RoundedCornerShape(14.dp))
                    .clickable(onClick = onClick)
                    .padding(16.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    // Globe icon
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(SurfaceL2),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Language,
                            contentDescription = null,
                            tint = Purple,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    // Host info
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text  = host.label,
                            style = MaterialTheme.typography.titleMedium,
                            color = TextPrimary,
                        )
                        Spacer(Modifier.height(3.dp))
                        Text(
                            text  = "${host.host}  :  ${host.tcpPort}",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextTertiary,
                        )
                    }
                    // Edit + arrow
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        IconButton(
                            onClick = { onEdit(host) },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                Icons.Outlined.Edit,
                                contentDescription = "编辑",
                                tint = TextTertiary,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        Icon(
                            imageVector = Icons.Filled.ChevronRight,
                            contentDescription = null,
                            tint = TextTertiary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        },
    )
}

@Composable
private fun SavedHostsEmptyHint(onAdd: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SurfaceL1)
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(listOf(BorderSubtle, Color.Transparent)),
                shape = RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onAdd)
            .padding(20.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Outlined.AddCircleOutline,
                contentDescription = null,
                tint = TextTertiary,
                modifier = Modifier.size(28.dp),
            )
            Text(
                text  = "添加自定义主机",
                style = MaterialTheme.typography.bodyMedium,
                color = TextTertiary,
            )
            Text(
                text  = "支持外网 IP，适合远程连接办公室 Mac",
                style = MaterialTheme.typography.bodySmall,
                color = TextTertiary,
            )
        }
    }
}


// ── Bottom full-width add button ──────────────────────────────────────────
@Composable
private fun AddHostFullButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .height(52.dp),
        shape  = RoundedCornerShape(14.dp),
        border = BorderStroke(1.dp, BorderDefault),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = TextSecondary,
        ),
    ) {
        Icon(Icons.Filled.Add, null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            "添加自定义主机 IP",
            style = MaterialTheme.typography.labelLarge,
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// ADD / EDIT HOST DIALOG
// ═══════════════════════════════════════════════════════════════════════════
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddHostDialog(
    initial: SavedHost?,
    onDismiss: () -> Unit,
    onSave: (SavedHost) -> Unit,
) {
    var label   by remember { mutableStateOf(initial?.label   ?: "") }
    var host    by remember { mutableStateOf(initial?.host    ?: "") }
    var tcpPort by remember { mutableStateOf(initial?.tcpPort?.toString() ?: "8890") }
    var udpPort by remember { mutableStateOf(initial?.udpPort?.toString() ?: "8891") }

    val focusManager    = LocalFocusManager.current
    val hostFocus       = remember { FocusRequester() }
    val tcpFocus        = remember { FocusRequester() }
    val udpFocus        = remember { FocusRequester() }

    val isValid = host.isNotBlank()
        && tcpPort.toIntOrNull() in 1..65535
        && udpPort.toIntOrNull() in 1..65535

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(0.92f)
                .clip(RoundedCornerShape(20.dp))
                .background(SurfaceL1)
                .border(1.dp, BorderDefault, RoundedCornerShape(20.dp))
                .padding(24.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                // Dialog title
                Text(
                    text  = if (initial == null) "添加主机" else "编辑主机",
                    style = MaterialTheme.typography.headlineSmall,
                    color = TextPrimary,
                )

                // Label
                DialogField(
                    value       = label,
                    onValue     = { label = it },
                    label       = "备注名称（可选）",
                    placeholder = "例：办公室 Mac",
                    keyboardType = KeyboardType.Text,
                    imeAction   = ImeAction.Next,
                    onNext      = { hostFocus.requestFocus() },
                )

                // Host / IP
                DialogField(
                    value       = host,
                    onValue     = { host = it },
                    label       = "IP 地址或主机名 *",
                    placeholder = "例：192.168.1.5 或 my.mac.com",
                    keyboardType = KeyboardType.Uri,
                    imeAction   = ImeAction.Next,
                    onNext      = { tcpFocus.requestFocus() },
                    modifier    = Modifier.focusRequester(hostFocus),
                )

                // Ports row
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    DialogField(
                        value       = tcpPort,
                        onValue     = { if (it.length <= 5) tcpPort = it.filter(Char::isDigit) },
                        label       = "TCP 端口",
                        placeholder = "8890",
                        keyboardType = KeyboardType.Number,
                        imeAction   = ImeAction.Next,
                        onNext      = { udpFocus.requestFocus() },
                        modifier    = Modifier
                            .weight(1f)
                            .focusRequester(tcpFocus),
                    )
                    DialogField(
                        value       = udpPort,
                        onValue     = { if (it.length <= 5) udpPort = it.filter(Char::isDigit) },
                        label       = "UDP 端口",
                        placeholder = "8891",
                        keyboardType = KeyboardType.Number,
                        imeAction   = ImeAction.Done,
                        onNext      = { focusManager.clearFocus() },
                        modifier    = Modifier
                            .weight(1f)
                            .focusRequester(udpFocus),
                    )
                }

                // Buttons row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    OutlinedButton(
                        onClick  = onDismiss,
                        modifier = Modifier.weight(1f).height(46.dp),
                        shape    = RoundedCornerShape(12.dp),
                        border   = BorderStroke(1.dp, BorderDefault),
                        colors   = ButtonDefaults.outlinedButtonColors(contentColor = TextSecondary),
                    ) { Text("取消", style = MaterialTheme.typography.labelLarge) }

                    Button(
                        onClick = {
                            val tcp = tcpPort.toIntOrNull() ?: return@Button
                            val udp = udpPort.toIntOrNull() ?: return@Button
                            onSave(
                                SavedHost(
                                    id      = initial?.id ?: UUID.randomUUID().toString(),
                                    label   = label.ifBlank { host },
                                    host    = host.trim(),
                                    tcpPort = tcp,
                                    udpPort = udp,
                                )
                            )
                        },
                        enabled  = isValid,
                        modifier = Modifier.weight(1f).height(46.dp),
                        shape    = RoundedCornerShape(12.dp),
                        colors   = ButtonDefaults.buttonColors(
                            containerColor = Accent,
                            contentColor   = Color.White,
                            disabledContainerColor = AccentDim.copy(alpha = 0.4f),
                            disabledContentColor   = TextDisabled,
                        ),
                    ) { Text("保存", style = MaterialTheme.typography.labelLarge) }
                }
            }
        }
    }
}

@Composable
private fun DialogField(
    value: String,
    onValue: (String) -> Unit,
    label: String,
    placeholder: String,
    keyboardType: KeyboardType,
    imeAction: ImeAction,
    onNext: () -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value         = value,
        onValueChange = onValue,
        label         = { Text(label, style = MaterialTheme.typography.labelMedium) },
        placeholder   = { Text(placeholder, style = MaterialTheme.typography.bodySmall) },
        singleLine    = true,
        modifier      = modifier.fillMaxWidth(),
        shape         = RoundedCornerShape(10.dp),
        colors        = OutlinedTextFieldDefaults.colors(
            focusedBorderColor     = Accent,
            unfocusedBorderColor   = BorderDefault,
            cursorColor            = Accent,
            focusedLabelColor      = Accent,
            unfocusedLabelColor    = TextTertiary,
            focusedTextColor       = TextPrimary,
            unfocusedTextColor     = TextPrimary,
        ),
        keyboardOptions = KeyboardOptions(
            keyboardType = keyboardType,
            imeAction    = imeAction,
        ),
        keyboardActions = KeyboardActions(
            onNext = { onNext() },
            onDone = { onNext() },
        ),
    )
}
