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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.lowremote.model.ControlEvent
import com.lowremote.model.MacKeyCodes

/**
 * 快捷键区域。
 *
 * 四区结构：
 *  1. 功能开关行（固定，不滚动）  — 拖拽锁 · 麦克风 · 键盘输入
 *  2. 内联键盘输入区（可显隐）    — 弹出 Android IME，输入后发送到 Mac
 *  3. 文件发送区（可显隐）        — 选择文件/图片/视频，发送到 Mac Downloads 目录
 *  4. 快捷键滚动网格（剩余空间）  — 3 列，可滚动
 */
@Composable
fun ShortcutKeyboard(
    modifier:      Modifier = Modifier,
    onEvent:       (ControlEvent) -> Unit,
    dragLockOn:    Boolean  = false,
    onDragLock:    (Boolean) -> Unit = {},
    audioOn:       Boolean  = false,
    onAudio:       (Boolean) -> Unit = {},
    onSendText:    (String) -> Unit  = {},
    onSendFiles:   (List<Uri>) -> Unit = {},
) {
    val shortcuts = remember { buildShortcuts() }
    val rows      = remember(shortcuts) { shortcuts.chunked(3) }
    val listState = rememberLazyListState()
    val rootView  = LocalView.current
    val ctx       = LocalContext.current

    var showInput    by remember { mutableStateOf(false) }
    var showFilePick by remember { mutableStateOf(false) }

    // File/image/video picker — supports multiple files of any type
    val fileLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.GetMultipleContents()
    ) { uris ->
        if (uris.isNotEmpty()) {
            onSendFiles(uris)
            showFilePick = false
        }
    }

    Column(
        modifier = modifier
            .background(Color(0xFF141414))
            .padding(horizontal = 4.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // ── Row 1: functional toggles ─────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            ToggleIconBtn(
                label    = if (dragLockOn) "🔒拖拽" else "拖拽",
                active   = dragLockOn,
                modifier = Modifier.weight(1f),
                view     = rootView,
                onClick  = { onDragLock(!dragLockOn) },
            )
            ToggleIconBtn(
                label    = if (audioOn) "🎙️传音中" else "🎙️传音",
                active   = audioOn,
                modifier = Modifier.weight(1f),
                view     = rootView,
                onClick  = { onAudio(!audioOn) },
            )
            ToggleIconBtn(
                label    = if (showInput) "⌨️收键盘" else "⌨️打字",
                active   = showInput,
                modifier = Modifier.weight(1f),
                view     = rootView,
                onClick  = {
                    showInput = !showInput
                    if (showInput) showFilePick = false
                },
            )
            ToggleIconBtn(
                label    = if (showFilePick) "📎收起" else "📎文件",
                active   = showFilePick,
                modifier = Modifier.weight(1f),
                view     = rootView,
                onClick  = {
                    showFilePick = !showFilePick
                    if (showFilePick) showInput = false
                },
            )
        }

        // ── Row 2: inline IME input bar ───────────────────────────────────────
        if (showInput) {
            InlineInputBar(
                onSend = { text ->
                    if (text.isNotEmpty()) {
                        onSendText(text)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                            rootView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        else
                            rootView.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    }
                },
            )
        }

        // ── Row 3: file picker bar ────────────────────────────────────────────
        if (showFilePick) {
            FilePickerBar(
                onPickFiles  = { fileLauncher.launch("*/*") },
                onPickImages = { fileLauncher.launch("image/*") },
                onPickVideos = { fileLauncher.launch("video/*") },
            )
        }

        // ── Row 4: shortcut grid ──────────────────────────────────────────────
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                state    = listState,
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                items(rows) { row ->
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
                        repeat(3 - row.size) { Box(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

// ── Inline IME input ──────────────────────────────────────────────────────────
@Composable
private fun InlineInputBar(onSend: (String) -> Unit) {
    val editRef = remember { mutableStateOf<EditText?>(null) }
    val onSendUpdated by rememberUpdatedState(onSend)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF1E1E1E), RoundedCornerShape(6.dp))
            .padding(horizontal = 6.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        AndroidView(
            factory = { ctx2 ->
                EditText(ctx2).apply {
                    hint       = "输入文字 → 发往 Mac（回车发送）"
                    inputType  = android.text.InputType.TYPE_CLASS_TEXT or
                                 android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                    imeOptions = EditorInfo.IME_ACTION_SEND
                    setTextColor(0xFFFFFFFF.toInt())
                    setHintTextColor(0xFF666666.toInt())
                    background    = null
                    maxLines      = 1
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
                        val imm = ctx2.getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
                                as InputMethodManager
                        imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
                    }
                }
            },
            modifier = Modifier.weight(1f),
        )

        Button(
            onClick = {
                val et = editRef.value ?: return@Button
                val t  = et.text.toString()
                if (t.isNotEmpty()) { onSendUpdated(t); et.setText("") }
            },
            colors   = ButtonDefaults.buttonColors(
                containerColor = Color(0xFF4A90E2), contentColor = Color.White),
            shape    = RoundedCornerShape(5.dp),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
            modifier = Modifier.height(30.dp),
        ) { Text("发", fontSize = 11.sp) }
    }
}

// ── File picker bar ───────────────────────────────────────────────────────────
/**
 * 三个按钮：
 *  · 📄文件  — 任意类型（*∕*）
 *  · 🖼️图片  — image∕*
 *  · 🎬视频  — video∕*
 * 选完后文件经 TCP 传至 Mac，保存在 ~/Downloads 目录。
 */
@Composable
private fun FilePickerBar(
    onPickFiles:  () -> Unit,
    onPickImages: () -> Unit,
    onPickVideos: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF1A1E26), RoundedCornerShape(6.dp))
            .padding(horizontal = 6.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment     = Alignment.CenterVertically,
    ) {
        Text("发送到 Mac↓:", color = Color(0xFF888888), fontSize = 10.sp,
             modifier = Modifier.padding(end = 2.dp))
        FileTypeBtn("📄文件",  Color(0xFF2D5A8E), onPickFiles)
        FileTypeBtn("🖼️图片", Color(0xFF3A6B3A), onPickImages)
        FileTypeBtn("🎬视频", Color(0xFF6B3A3A), onPickVideos)
    }
}

@Composable
private fun FileTypeBtn(label: String, bgColor: Color, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        colors  = ButtonDefaults.buttonColors(
            containerColor = bgColor, contentColor = Color.White),
        shape   = RoundedCornerShape(5.dp),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        modifier = Modifier.height(30.dp),
    ) { Text(label, fontSize = 11.sp, maxLines = 1, softWrap = false) }
}

// ── Small button widgets ──────────────────────────────────────────────────────
@Composable
private fun ToggleIconBtn(
    label:    String,
    active:   Boolean,
    modifier: Modifier = Modifier,
    view:     View,
    onClick:  () -> Unit,
) {
    Button(
        onClick = {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            else
                view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            onClick()
        },
        modifier = modifier.height(30.dp),
        shape    = RoundedCornerShape(5.dp),
        colors   = ButtonDefaults.buttonColors(
            containerColor = if (active) Color(0xFF1D4E89) else Color(0xFF252525),
            contentColor   = if (active) Color(0xFFADD8FF) else Color(0xFF999999),
        ),
        contentPadding = PaddingValues(horizontal = 2.dp, vertical = 0.dp),
        elevation = null,
    ) {
        Text(label, fontSize = 10.sp, maxLines = 1, softWrap = false)
    }
}

@Composable
private fun KeyButton(
    label:    String,
    modifier: Modifier = Modifier,
    view:     View,
    onClick:  () -> Unit,
) {
    Button(
        onClick = {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            else
                view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            onClick()
        },
        modifier = modifier.height(36.dp),
        shape    = RoundedCornerShape(5.dp),
        colors   = ButtonDefaults.buttonColors(
            containerColor = Color(0xFF2B2B2B), contentColor = Color(0xFFE0E0E0)),
        contentPadding = PaddingValues(horizontal = 2.dp, vertical = 0.dp),
        elevation = null,
    ) {
        Text(label, fontSize = 12.sp, maxLines = 1, softWrap = false)
    }
}

// ── Shortcut definitions ──────────────────────────────────────────────────────
private data class Shortcut(val label: String, val event: ControlEvent)

private fun buildShortcuts(): List<Shortcut> = listOf(
    // ── Row 1: 最高频编辑键 ─────────────────────────────────────────────────
    Shortcut("⌫",    ControlEvent.KeyPress(MacKeyCodes.DELETE)),
    Shortcut("⏎",    ControlEvent.KeyPress(MacKeyCodes.RETURN)),
    Shortcut("⌘C",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.C)),
    Shortcut("⌘V",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.V)),
    // ── Row 2: 常用功能键（前移） ────────────────────────────────────────────
    Shortcut("Esc",  ControlEvent.KeyPress(MacKeyCodes.ESCAPE)),
    Shortcut("⌘Tab", ControlEvent.KeyCombo("cmd",       MacKeyCodes.TAB)),
    Shortcut("⌘␣",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.SPACE)),
    // ── Row 3: 编辑操作 ──────────────────────────────────────────────────────
    Shortcut("⌘X",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.X)),
    Shortcut("⌘Z",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.Z)),
    Shortcut("⌘⇧Z",  ControlEvent.KeyCombo("cmd+shift", MacKeyCodes.Z)),
    Shortcut("⌘A",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.A)),
    Shortcut("Tab",  ControlEvent.KeyPress(MacKeyCodes.TAB)),
    // ── Row 4: 文件 / 应用操作 ───────────────────────────────────────────────
    Shortcut("⌘S",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.S)),
    Shortcut("⌘W",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.W)),
    Shortcut("⌘Q",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.Q)),
    Shortcut("⌘N",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.N)),
    Shortcut("⌘T",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.T)),
    Shortcut("⌘F",   ControlEvent.KeyCombo("cmd",       MacKeyCodes.F)),
    // ── Row 5: 方向键 ────────────────────────────────────────────────────────
    Shortcut("↑",    ControlEvent.KeyPress(MacKeyCodes.ARROW_UP)),
    Shortcut("←",    ControlEvent.KeyPress(MacKeyCodes.ARROW_LEFT)),
    Shortcut("↓",    ControlEvent.KeyPress(MacKeyCodes.ARROW_DOWN)),
    Shortcut("→",    ControlEvent.KeyPress(MacKeyCodes.ARROW_RIGHT)),
    // ── Row 6: ⌘方向（行首/行尾/文首/文尾） ─────────────────────────────────
    Shortcut("⌘←",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_LEFT)),
    Shortcut("⌘→",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_RIGHT)),
    Shortcut("⌘↑",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_UP)),
    Shortcut("⌘↓",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_DOWN)),
    // ── Row 7: 缩放 / 截图 ───────────────────────────────────────────────────
    Shortcut("⌘+",   ControlEvent.KeyCombo("cmd", 24)),
    Shortcut("⌘-",   ControlEvent.KeyCombo("cmd", 27)),
    Shortcut("⌘⇧3",  ControlEvent.KeyCombo("cmd+shift", 20)),
    Shortcut("⌘⇧4",  ControlEvent.KeyCombo("cmd+shift", 21)),
    // ── Row 8: F 键 ──────────────────────────────────────────────────────────
    Shortcut("F3",   ControlEvent.KeyPress(MacKeyCodes.F3)),
    Shortcut("F4",   ControlEvent.KeyPress(MacKeyCodes.F4)),
    Shortcut("F11",  ControlEvent.KeyPress(MacKeyCodes.F11)),
)
