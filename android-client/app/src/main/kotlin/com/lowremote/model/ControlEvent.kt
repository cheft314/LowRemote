package com.lowremote.model

/**
 * Control events the Android client sends to the Mac (serialised to the
 * string formats documented in the spec §5.2).
 *
 * Wire examples:
 *   M:5.2,-3.1     -> MouseMove(dx=5.2, dy=-3.1)    // delta mode
 *   MC:L           -> MouseClick(LEFT)
 *   MC:R           -> MouseClick(RIGHT)
 *   MD:L           -> MouseDown(LEFT)
 *   MU:L           -> MouseUp(LEFT)
 *   MW:3           -> MouseWheel(3)
 *   K:36           -> KeyPress(36)
 *   KC:cmd,9       -> KeyCombo("cmd", 9)
 *   T:hello        -> TypeText("hello")
 */
sealed class ControlEvent {
    abstract fun serialize(): String

    data class MouseMove(val dx: Float, val dy: Float) : ControlEvent() {
        // Keep to 1 decimal place — that's sub-pixel enough and keeps packets small.
        override fun serialize(): String = "M:${format(dx)},${format(dy)}"
    }

    enum class Button(val code: String) { LEFT("L"), RIGHT("R") }

    data class MouseClick(val button: Button) : ControlEvent() {
        override fun serialize(): String = "MC:${button.code}"
    }

    data class MouseDoubleClick(val button: Button) : ControlEvent() {
        override fun serialize(): String = "MDC:${button.code}"
    }

    data class MouseDown(val button: Button) : ControlEvent() {
        override fun serialize(): String = "MD:${button.code}"
    }

    data class MouseUp(val button: Button) : ControlEvent() {
        override fun serialize(): String = "MU:${button.code}"
    }

    data class MouseWheel(val dy: Int) : ControlEvent() {
        override fun serialize(): String = "MW:$dy"
    }

    data class KeyPress(val keyCode: Int) : ControlEvent() {
        override fun serialize(): String = "K:$keyCode"
    }

    /**
     * Modifier keys concatenated with '+', e.g. "cmd", "cmd+shift".
     * Recognised names on the Mac side: cmd, ctrl, alt (alias opt), shift.
     */
    data class KeyCombo(val modifiers: String, val keyCode: Int) : ControlEvent() {
        override fun serialize(): String = "KC:$modifiers,$keyCode"
    }

    data class TypeText(val text: String) : ControlEvent() {
        override fun serialize(): String = "T:$text"
    }

    companion object {
        private fun format(f: Float): String {
            // Avoid the Locale-dependent "%.1f" (comma vs dot in some locales).
            val rounded = kotlin.math.round(f * 10f) / 10f
            // Strip trailing ".0" for compactness.
            val s = rounded.toString()
            return if (s.endsWith(".0")) s.dropLast(2) else s
        }
    }
}

/**
 * macOS CGKeyCode constants for the standard shortcuts we expose in the UI.
 * Values are defined by Apple's HIToolbox/Events.h.
 */
object MacKeyCodes {
    const val A = 0
    const val B = 11
    const val C = 8
    const val D = 2
    const val E = 14
    const val F = 3
    const val G = 5
    const val H = 4
    const val I = 34
    const val J = 38
    const val K = 40
    const val L = 37
    const val M = 46
    const val N = 45
    const val O = 31
    const val P = 35
    const val Q = 12
    const val R = 15
    const val S = 1
    const val T = 17
    const val U = 32
    const val V = 9
    const val W = 13
    const val X = 7
    const val Y = 16
    const val Z = 6

    const val RETURN = 36
    const val TAB = 48
    const val SPACE = 49
    const val DELETE = 51     // Backspace
    const val ESCAPE = 53
    const val ARROW_LEFT = 123
    const val ARROW_RIGHT = 124
    const val ARROW_DOWN = 125
    const val ARROW_UP = 126
}
