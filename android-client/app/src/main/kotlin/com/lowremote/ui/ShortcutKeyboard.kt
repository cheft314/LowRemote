package com.lowremote.ui

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lowremote.model.ControlEvent
import com.lowremote.model.MacKeyCodes

/**
 * 快捷键区域 —— 仅快捷键按钮网格，无标题、无输入框。
 * 点击按钮时触发震动反馈（VIRTUAL_KEY）。
 *
 * 布局：3 列均分，竖向可滚动（LazyColumn），充满父容器剩余高度。
 */
@Composable
fun ShortcutKeyboard(
    modifier: Modifier = Modifier,
    onEvent: (ControlEvent) -> Unit,
) {
    val shortcuts = remember { buildShortcuts() }
    val rows = remember(shortcuts) { shortcuts.chunked(3) }
    val listState = rememberLazyListState()
    val rootView = LocalView.current

    Box(
        modifier = modifier
            .background(Color(0xFF141414))
            .padding(horizontal = 4.dp, vertical = 4.dp),
    ) {
        LazyColumn(
            state = listState,
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
                            label = sc.label,
                            modifier = Modifier.weight(1f),
                            rootView = rootView,
                            onClick = { onEvent(sc.event) },
                        )
                    }
                    // 末行不足 3 个时用空 Box 占位，保持等宽
                    repeat(3 - row.size) {
                        Box(Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun KeyButton(
    label: String,
    modifier: Modifier = Modifier,
    rootView: View,
    onClick: () -> Unit,
) {
    Button(
        onClick = {
            // 触发震动反馈
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                rootView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            } else {
                rootView.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            }
            onClick()
        },
        modifier = modifier.height(36.dp),
        shape = RoundedCornerShape(5.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Color(0xFF2B2B2B),
            contentColor = Color(0xFFE0E0E0),
        ),
        contentPadding = PaddingValues(horizontal = 2.dp, vertical = 0.dp),
        elevation = null,
    ) {
        Text(
            text = label,
            fontSize = 12.sp,
            maxLines = 1,
            softWrap = false,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 快捷键定义
// ─────────────────────────────────────────────────────────────────────────────

private data class Shortcut(val label: String, val event: ControlEvent)

private fun buildShortcuts(): List<Shortcut> = listOf(
    // 常用编辑
    Shortcut("⌘C",    ControlEvent.KeyCombo("cmd", MacKeyCodes.C)),
    Shortcut("⌘V",    ControlEvent.KeyCombo("cmd", MacKeyCodes.V)),
    Shortcut("⌘X",    ControlEvent.KeyCombo("cmd", MacKeyCodes.X)),
    Shortcut("⌘Z",    ControlEvent.KeyCombo("cmd", MacKeyCodes.Z)),
    Shortcut("⌘⇧Z",  ControlEvent.KeyCombo("cmd+shift", MacKeyCodes.Z)),
    Shortcut("⌘A",    ControlEvent.KeyCombo("cmd", MacKeyCodes.A)),
    // 文件 / 应用
    Shortcut("⌘S",    ControlEvent.KeyCombo("cmd", MacKeyCodes.S)),
    Shortcut("⌘W",    ControlEvent.KeyCombo("cmd", MacKeyCodes.W)),
    Shortcut("⌘Q",    ControlEvent.KeyCombo("cmd", MacKeyCodes.Q)),
    Shortcut("⌘N",    ControlEvent.KeyCombo("cmd", MacKeyCodes.N)),
    Shortcut("⌘T",    ControlEvent.KeyCombo("cmd", MacKeyCodes.T)),
    Shortcut("⌘F",    ControlEvent.KeyCombo("cmd", MacKeyCodes.F)),
    // 系统
    Shortcut("⌘Tab",  ControlEvent.KeyCombo("cmd", MacKeyCodes.TAB)),
    Shortcut("⌘␣",   ControlEvent.KeyCombo("cmd", MacKeyCodes.SPACE)),
    Shortcut("⌘⇧3",  ControlEvent.KeyCombo("cmd+shift", 20)),   // 截图全屏
    Shortcut("⌘⇧4",  ControlEvent.KeyCombo("cmd+shift", 21)),   // 截图选区
    // 导航键
    Shortcut("Esc",    ControlEvent.KeyPress(MacKeyCodes.ESCAPE)),
    Shortcut("⏎",     ControlEvent.KeyPress(MacKeyCodes.RETURN)),
    Shortcut("⌫",     ControlEvent.KeyPress(MacKeyCodes.DELETE)),
    Shortcut("Tab",    ControlEvent.KeyPress(MacKeyCodes.TAB)),
    Shortcut("↑",      ControlEvent.KeyPress(MacKeyCodes.ARROW_UP)),
    Shortcut("←",      ControlEvent.KeyPress(MacKeyCodes.ARROW_LEFT)),
    Shortcut("↓",      ControlEvent.KeyPress(MacKeyCodes.ARROW_DOWN)),
    Shortcut("→",      ControlEvent.KeyPress(MacKeyCodes.ARROW_RIGHT)),
    // 页面导航
    Shortcut("⌘←",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_LEFT)),
    Shortcut("⌘→",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_RIGHT)),
    Shortcut("⌘↑",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_UP)),
    Shortcut("⌘↓",   ControlEvent.KeyCombo("cmd", MacKeyCodes.ARROW_DOWN)),
    // 亮度 / 音量（功能键模拟）
    Shortcut("⌘+",    ControlEvent.KeyCombo("cmd", 24)),
    Shortcut("⌘-",    ControlEvent.KeyCombo("cmd", 27)),
)
