package com.lowremote.ui

import android.net.Uri
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.lowremote.model.ControlEvent
import com.lowremote.model.MacKeyCodes
import com.lowremote.ui.theme.*

// ═══════════════════════════════════════════════════════════════════════════
// SHORTCUT KEYBOARD
// ═══════════════════════════════════════════════════════════════════════════
/**
 * 快捷键区域 — 竖向滚动分组布局。
 *
 * 结构（由上至下）：
 *  1. 工具栏（固定）  — 拖拽锁 · 音频 · 输入 · 文件  4个图标开关
 *  2. 输入栏（可见隐）— 内联文字输入
 *  3. 文件选择栏（可见隐）
 *  4. 快捷键分组 LazyColumn（竖向滚动，每组含标题 + N×3 网格）
 */
@Composable
fun ShortcutKeyboard(
    modifier:    Modifier = Modifier,
    onEvent:     (ControlEvent) -> Unit,
    audioOn:     Boolean = false,
    onAudio:     (Boolean) -> Unit = {},
    onSendText:  (String) -> Unit  = {},
    onSendFiles: (List<Uri>) -> Unit = {},
) {
    val rootView  = LocalView.current
    val ctx       = LocalContext.current
    val listState = rememberLazyListState()

    var showInput    by remember { mutableStateOf(false) }
    var showFilePick by remember { mutableStateOf(false) }

    val fileLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.GetMultipleContents()
    ) { uris ->
        if (uris.isNotEmpty()) {
            onSendFiles(uris)
            showFilePick = false
        }
    }

    val groups = remember { buildShortcutGroups() }

    Column(
        modifier = modifier
            .background(Background)
            .padding(horizontal = 6.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // ── Toolbar row ───────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(SurfaceL1)
                .border(1.dp, BorderSubtle, RoundedCornerShape(10.dp))
                .padding(horizontal = 6.dp, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            ToolbarToggle(
                icon     = Icons.Outlined.Mic,
                label    = if (audioOn) "传音中" else "传音",
                active   = audioOn,
                modifier = Modifier.weight(1f),
                view     = rootView,
                onClick  = { onAudio(!audioOn) },
            )
            ToolbarToggle(
                icon     = Icons.Outlined.Keyboard,
                label    = "打字",
                active   = showInput,
                modifier = Modifier.weight(1f),
                view     = rootView,
                onClick  = {
                    showInput    = !showInput
                    if (showInput) showFilePick = false
                },
            )
            ToolbarToggle(
                icon     = Icons.Outlined.AttachFile,
                label    = "文件",
                active   = showFilePick,
                modifier = Modifier.weight(1f),
                view     = rootView,
                onClick  = {
                    showFilePick = !showFilePick
                    if (showFilePick) showInput = false
                },
            )
        }

        // ── Inline input ──────────────────────────────────────────────────
        if (showInput) {
            InlineInputBar(onSend = { text ->
                if (text.isNotEmpty()) {
                    onSendText(text)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                        rootView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    else
                        rootView.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                }
            })
        }

        // ── File picker bar ───────────────────────────────────────────────
        if (showFilePick) {
            FilePickerBar(
                onPickFiles  = { fileLauncher.launch("*/*") },
                onPickImages = { fileLauncher.launch("image/*") },
                onPickVideos = { fileLauncher.launch("video/*") },
            )
        }

        // ── Grouped shortcut grid — LazyColumn ────────────────────────────
        LazyColumn(
            state   = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            contentPadding = PaddingValues(bottom = 4.dp),
        ) {
            groups.forEach { group ->
                // Group header
                item(key = "header_${group.title}") {
                    Text(
                        text     = group.title,
                        style    = MaterialTheme.typography.labelSmall,
                        color    = TextTertiary,
                        modifier = Modifier
                            .padding(start = 4.dp, top = 8.dp, bottom = 4.dp),
                    )
                }
                // Keys in rows of 3
                val rows = group.shortcuts.chunked(3)
                rows.forEachIndexed { rowIdx, row ->
                    item(key = "row_${group.title}_$rowIdx") {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            row.forEach { sc ->
                                KeyButton(
                                    label    = sc.label,
                                    modifier = Modifier.weight(1f),
                                    view     = rootView,
                                    onClick  = { onEvent(sc.event) },
                                )
                            }
                            // Fill remaining columns with empty space
                            repeat(3 - row.size) {
                                Box(modifier = Modifier.weight(1f))
                            }
                        }
                        Spacer(Modifier.height(4.dp))
                    }
                }
            }
        }
    }
}

// ── Toolbar toggle button ─────────────────────────────────────────────────
@Composable
private fun ToolbarToggle(
    icon:     ImageVector,
    label:    String,
    active:   Boolean,
    modifier: Modifier = Modifier,
    view:     View,
    onClick:  () -> Unit,
) {
    val bg by animateColorAsState(
        targetValue = if (active) KeySurfaceActive else Color.Transparent,
        animationSpec = tween(160),
        label = "tool_bg",
    )
    val iconTint by animateColorAsState(
        targetValue = if (active) Accent else TextTertiary,
        animationSpec = tween(160),
        label = "tool_icon",
    )

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(bg)
            .clickable {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                else
                    view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                onClick()
            }
            .padding(horizontal = 4.dp, vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = iconTint,
            modifier = Modifier.size(15.dp),
        )
        Text(
            text  = label,
            style = MaterialTheme.typography.labelSmall,
            color = if (active) Accent else TextTertiary,
            maxLines = 1,
            softWrap = false,
        )
    }
}

// ── Key button ────────────────────────────────────────────────────────────
@Composable
private fun KeyButton(
    label:    String,
    modifier: Modifier = Modifier,
    view:     View,
    onClick:  () -> Unit,
) {
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.92f else 1f,
        animationSpec = spring(stiffness = 600f),
        label = "key_scale",
        finishedListener = { pressed = false },
    )

    Box(
        modifier = modifier
            .scale(scale)
            .height(36.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(KeySurface)
            .border(1.dp, KeyBorder, RoundedCornerShape(8.dp))
            .clickable {
                pressed = true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                else
                    view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                onClick()
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text  = label,
            style = MaterialTheme.typography.labelMedium,
            color = TextPrimary,
            maxLines = 1,
            softWrap = false,
        )
    }
}

// ── Inline IME input bar ──────────────────────────────────────────────────
@Composable
private fun InlineInputBar(onSend: (String) -> Unit) {
    val editRef = remember { mutableStateOf<EditText?>(null) }
    val onSendUpdated by rememberUpdatedState(onSend)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(SurfaceL1)
            .border(1.dp, BorderDefault, RoundedCornerShape(10.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        AndroidView(
            factory = { ctx ->
                EditText(ctx).apply {
                    hint       = "输入文字发往 Mac…"
                    inputType  = android.text.InputType.TYPE_CLASS_TEXT or
                                 android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
                                 android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
                    imeOptions = EditorInfo.IME_FLAG_NO_ENTER_ACTION
                    setTextColor(0xFFF0F0F8.toInt())
                    setHintTextColor(0xFF505065.toInt())
                    textSize      = 10f          // 字体缩小为原来一半（原约 14sp）
                    background    = null
                    minLines      = 3
                    maxLines      = 3
                    editRef.value = this

                    setOnEditorActionListener { _, actionId, _ ->
                        if (actionId == EditorInfo.IME_ACTION_SEND ||
                            actionId == EditorInfo.IME_ACTION_DONE) {
                            val t = text.toString()
                            if (t.isNotEmpty()) { onSendUpdated(t); setText("") }
                            true
                        } else false
                    }

                    post {
                        requestFocus()
                        val imm = ctx.getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
                                as InputMethodManager
                        imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
                    }
                }
            },
            modifier = Modifier.weight(1f),
        )

        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(Accent)
                .clickable {
                    val et = editRef.value ?: return@clickable
                    val t  = et.text.toString()
                    if (t.isNotEmpty()) { onSendUpdated(t); et.setText("") }
                }
                .padding(horizontal = 12.dp, vertical = 6.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("发", style = MaterialTheme.typography.labelLarge, color = Color.White)
        }
    }
}

// ── File picker bar ───────────────────────────────────────────────────────
@Composable
private fun FilePickerBar(
    onPickFiles:  () -> Unit,
    onPickImages: () -> Unit,
    onPickVideos: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(SurfaceL1)
            .border(1.dp, BorderSubtle, RoundedCornerShape(10.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FileTypeBtn("📄 文件",  Color(0xFF1E3A5F), onPickFiles)
        FileTypeBtn("🖼️ 图片", Color(0xFF1A3D1A), onPickImages)
        FileTypeBtn("🎬 视频", Color(0xFF3D1A1A), onPickVideos)
    }
}

@Composable
private fun FileTypeBtn(label: String, bg: Color, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(7.dp))
            .background(bg)
            .border(1.dp, BorderSubtle, RoundedCornerShape(7.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = TextPrimary, maxLines = 1, softWrap = false)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHORTCUT GROUPS
// ═══════════════════════════════════════════════════════════════════════════
private data class Shortcut(val label: String, val event: ControlEvent)
private data class ShortcutGroup(val title: String, val shortcuts: List<Shortcut>)

private fun buildShortcutGroups(): List<ShortcutGroup> = listOf(
    ShortcutGroup("系统", listOf(
        Shortcut("Launchpad",  ControlEvent.Launchpad),
        Shortcut("程序坞",      ControlEvent.MissionControl),
        Shortcut("显示桌面",    ControlEvent.ShowDesktop),
        Shortcut("⌘Tab",       ControlEvent.KeyCombo("cmd", MacKeyCodes.TAB)),
        Shortcut("⌘␣",         ControlEvent.KeyCombo("cmd", MacKeyCodes.SPACE)),
        Shortcut("Esc",        ControlEvent.KeyPress(MacKeyCodes.ESCAPE)),
    )),
    ShortcutGroup("编辑", listOf(
        Shortcut("⌫",   ControlEvent.KeyPress(MacKeyCodes.DELETE)),
        Shortcut("⏎",   ControlEvent.KeyPress(MacKeyCodes.RETURN)),
        Shortcut("Tab", ControlEvent.KeyPress(MacKeyCodes.TAB)),
        Shortcut("⌘C",  ControlEvent.KeyCombo("cmd", MacKeyCodes.C)),
        Shortcut("⌘V",  ControlEvent.KeyCombo("cmd", MacKeyCodes.V)),
        Shortcut("⌘X",  ControlEvent.KeyCombo("cmd", MacKeyCodes.X)),
        Shortcut("⌘Z",  ControlEvent.KeyCombo("cmd", MacKeyCodes.Z)),
        Shortcut("⌘⇧Z", ControlEvent.KeyCombo("cmd+shift", MacKeyCodes.Z)),
        Shortcut("⌘A",  ControlEvent.KeyCombo("cmd", MacKeyCodes.A)),
    )),
    ShortcutGroup("文件 / 应用", listOf(
        Shortcut("⌘S",  ControlEvent.KeyCombo("cmd", MacKeyCodes.S)),
        Shortcut("⌘W",  ControlEvent.KeyCombo("cmd", MacKeyCodes.W)),
        Shortcut("⌘Q",  ControlEvent.KeyCombo("cmd", MacKeyCodes.Q)),
        Shortcut("⌘N",  ControlEvent.KeyCombo("cmd", MacKeyCodes.N)),
        Shortcut("⌘T",  ControlEvent.KeyCombo("cmd", MacKeyCodes.T)),
        Shortcut("⌘F",  ControlEvent.KeyCombo("cmd", MacKeyCodes.F)),
    )),
    ShortcutGroup("光标 / 导航", listOf(
        Shortcut("↑",   ControlEvent.KeyPress(MacKeyCodes.ARROW_UP)),
        Shortcut("←",   ControlEvent.KeyPress(MacKeyCodes.ARROW_LEFT)),
        Shortcut("↓",   ControlEvent.KeyPress(MacKeyCodes.ARROW_DOWN)),
        Shortcut("→",   ControlEvent.KeyPress(MacKeyCodes.ARROW_RIGHT)),
        Shortcut("⌘←",  ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_LEFT)),
        Shortcut("⌘→",  ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_RIGHT)),
        Shortcut("⌘↑",  ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_UP)),
        Shortcut("⌘↓",  ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_DOWN)),
    )),
    ShortcutGroup("视图 / 截图", listOf(
        Shortcut("⌘+",   ControlEvent.KeyCombo("cmd", 24)),
        Shortcut("⌘-",   ControlEvent.KeyCombo("cmd", 27)),
        Shortcut("⌘⇧3",  ControlEvent.KeyCombo("cmd+shift", 20)),
        Shortcut("⌘⇧4",  ControlEvent.KeyCombo("cmd+shift", 21)),
    )),
    ShortcutGroup("功能键", listOf(
        Shortcut("F3",  ControlEvent.KeyPress(MacKeyCodes.F3)),
        Shortcut("F4",  ControlEvent.KeyPress(MacKeyCodes.F4)),
        Shortcut("F5",  ControlEvent.KeyPress(MacKeyCodes.F5)),
        Shortcut("F11", ControlEvent.KeyPress(MacKeyCodes.F11)),
        Shortcut("F12", ControlEvent.KeyPress(MacKeyCodes.F12)),
    )),
)
