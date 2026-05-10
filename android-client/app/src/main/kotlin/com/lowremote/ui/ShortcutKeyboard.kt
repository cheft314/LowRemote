package com.lowremote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lowremote.model.ControlEvent
import com.lowremote.model.MacKeyCodes

/**
 * Right-top area: canned shortcut buttons plus a free-form text input.
 *
 * Shortcut keys send *exactly* one KeyPress or KeyCombo event; the Mac side
 * handles modifier flag masks. The text input fires a TypeText event on
 * send so we don't spam per-character events during typing.
 */
@Composable
fun ShortcutKeyboard(
    modifier: Modifier = Modifier,
    onEvent: (ControlEvent) -> Unit,
) {
    val shortcuts = remember { defaultShortcuts() }
    var text by remember { mutableStateOf("") }

    Column(
        modifier = modifier
            .background(Color(0xFF1B1B1B))
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "快捷键",
            color = Color(0xFFB0B0B0),
            fontWeight = FontWeight.SemiBold,
        )
        Box(modifier = Modifier.weight(1f, fill = true).fillMaxWidth()) {
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(shortcuts.chunked(3)) { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        row.forEach { sc ->
                            ShortcutButton(
                                label = sc.label,
                                modifier = Modifier.weight(1f),
                                onClick = { onEvent(sc.event) }
                            )
                        }
                        // Pad the final row if it has < 3 buttons, so widths match.
                        repeat(3 - row.size) {
                            Box(modifier = Modifier.weight(1f)) {}
                        }
                    }
                }
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.weight(1f),
                singleLine = true,
                placeholder = { Text("输入文字后发送") },
            )
            IconButton(onClick = {
                if (text.isNotEmpty()) {
                    onEvent(ControlEvent.TypeText(text))
                    text = ""
                }
            }) {
                Icon(Icons.Default.Send, contentDescription = "发送")
            }
        }
    }
}

@Composable
private fun ShortcutButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = modifier,
        colors = ButtonDefaults.buttonColors(
            containerColor = Color(0xFF2D2D2D),
            contentColor = Color.White,
        ),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp, vertical = 8.dp)
    ) {
        Text(label, fontSize = 12.sp)
    }
}

private data class Shortcut(val label: String, val event: ControlEvent)

private fun defaultShortcuts(): List<Shortcut> = listOf(
    Shortcut("⌘C",    ControlEvent.KeyCombo("cmd", MacKeyCodes.C)),
    Shortcut("⌘V",    ControlEvent.KeyCombo("cmd", MacKeyCodes.V)),
    Shortcut("⌘X",    ControlEvent.KeyCombo("cmd", MacKeyCodes.X)),
    Shortcut("⌘Z",    ControlEvent.KeyCombo("cmd", MacKeyCodes.Z)),
    Shortcut("⌘⇧Z",  ControlEvent.KeyCombo("cmd+shift", MacKeyCodes.Z)),
    Shortcut("⌘A",    ControlEvent.KeyCombo("cmd", MacKeyCodes.A)),
    Shortcut("⌘S",    ControlEvent.KeyCombo("cmd", MacKeyCodes.S)),
    Shortcut("⌘W",    ControlEvent.KeyCombo("cmd", MacKeyCodes.W)),
    Shortcut("⌘Q",    ControlEvent.KeyCombo("cmd", MacKeyCodes.Q)),
    Shortcut("⌘Tab",  ControlEvent.KeyCombo("cmd", MacKeyCodes.TAB)),
    Shortcut("⌘␣",   ControlEvent.KeyCombo("cmd", MacKeyCodes.SPACE)),
    Shortcut("Esc",    ControlEvent.KeyPress(MacKeyCodes.ESCAPE)),
    Shortcut("⏎",     ControlEvent.KeyPress(MacKeyCodes.RETURN)),
    Shortcut("⌫",     ControlEvent.KeyPress(MacKeyCodes.DELETE)),
    Shortcut("Tab",    ControlEvent.KeyPress(MacKeyCodes.TAB)),
    Shortcut("←",      ControlEvent.KeyPress(MacKeyCodes.ARROW_LEFT)),
    Shortcut("↓",      ControlEvent.KeyPress(MacKeyCodes.ARROW_DOWN)),
    Shortcut("→",      ControlEvent.KeyPress(MacKeyCodes.ARROW_RIGHT)),
)
