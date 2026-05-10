package com.lowremote.model

/**
 * Control events the Android client sends to the Mac.
 *
 * Wire format (sent as ASCII string in UDP payload):
 *
 *  Mouse (delta mode, for touchpad):
 *   M:dx,dy          -> MouseMove delta
 *   MA:nx,ny         -> MouseAbsolute (normalized 0.0-1.0, for touchscreen mode)
 *   MC:L / MC:R      -> MouseClick
 *   MD:L / MD:R      -> MouseDown
 *   MU:L / MU:R      -> MouseUp
 *   MW:dy            -> MouseWheel (positive=up / natural scroll)
 *   MWH:dx           -> MouseWheelHorizontal
 *
 *  Gestures (sent as Mac-native CGEvent gestures):
 *   GZ:scale         -> Magnify (pinch zoom, scale delta e.g. 0.1 or -0.05)
 *   GR:angle         -> Rotate (radians delta)
 *   GS:fingers,dx,dy -> Swipe gesture (3/4 fingers)
 *   GME:             -> Mission Control (3-finger up)
 *   GAD:             -> App Expose / Launchpad (3-finger down)
 *   GSD:direction    -> 3-finger swipe desktop (L/R)
 *   GLP:             -> Launchpad (pinch 5 fingers in)
 *   GDT:             -> Show Desktop (spread 5 fingers out)
 *
 *  Keyboard:
 *   K:keyCode        -> KeyPress
 *   KC:mod,keyCode   -> KeyCombo
 *   T:text           -> TypeText
 */
sealed class ControlEvent {
    abstract fun serialize(): String

    // ── Mouse delta (touchpad mode) ──────────────────────────────────────────
    data class MouseMove(val dx: Float, val dy: Float) : ControlEvent() {
        override fun serialize() = "M:${f(dx)},${f(dy)}"
    }

    /** Touchscreen mode: move cursor to absolute normalized position then click. */
    data class MouseAbsolute(val normX: Float, val normY: Float) : ControlEvent() {
        override fun serialize() = "MA:${f(normX)},${f(normY)}"
    }

    enum class Button(val code: String) { LEFT("L"), RIGHT("R") }

    data class MouseClick(val button: Button) : ControlEvent() {
        override fun serialize() = "MC:${button.code}"
    }
    data class MouseDoubleClick(val button: Button) : ControlEvent() {
        override fun serialize() = "MDC:${button.code}"
    }
    data class MouseTripleClick(val button: Button) : ControlEvent() {
        override fun serialize() = "MTC:${button.code}"
    }
    data class MouseDown(val button: Button) : ControlEvent() {
        override fun serialize() = "MD:${button.code}"
    }
    data class MouseUp(val button: Button) : ControlEvent() {
        override fun serialize() = "MU:${button.code}"
    }
    data class MouseWheel(val dy: Int) : ControlEvent() {
        override fun serialize() = "MW:$dy"
    }
    data class MouseWheelH(val dx: Int) : ControlEvent() {
        override fun serialize() = "MWH:$dx"
    }

    /**
     * Velocity-proportional scroll in pixels.
     * Mac InputSimulator passes these directly to CGEvent(.pixel).
     * wheelY > 0 = scroll UP content; wheelX > 0 = scroll LEFT content.
     */
    data class ScrollPixels(val wheelX: Int, val wheelY: Int) : ControlEvent() {
        override fun serialize() = "SP:$wheelX,$wheelY"
    }

    // ── Gestures ─────────────────────────────────────────────────────────────

    /** Pinch-to-zoom: scaleDelta > 0 = zoom in, < 0 = zoom out. Range roughly ±0.05 per event. */
    data class Magnify(val scaleDelta: Float) : ControlEvent() {
        override fun serialize() = "GZ:${f(scaleDelta)}"
    }

    /** Two-finger rotation in radians (counter-clockwise positive). */
    data class Rotate(val angleDelta: Float) : ControlEvent() {
        override fun serialize() = "GR:${f(angleDelta)}"
    }

    /** Mission Control – three-finger swipe up. */
    object MissionControl : ControlEvent() {
        override fun serialize() = "GME:"
    }

    /** App Exposé – three-finger swipe down. */
    object AppExpose : ControlEvent() {
        override fun serialize() = "GAD:"
    }

    /** Three-finger swipe left/right to switch full-screen spaces. */
    data class SwitchDesktop(val direction: Direction) : ControlEvent() {
        enum class Direction(val code: String) { LEFT("L"), RIGHT("R") }
        override fun serialize() = "GSD:${direction.code}"
    }

    /** Four-finger swipe left/right = cycle through windows of same app. */
    data class FourFingerSwipeH(val direction: SwitchDesktop.Direction) : ControlEvent() {
        override fun serialize() = "G4H:${direction.code}"
    }

    /** Four-finger swipe up/down = Mission Control up, show desktop down. */
    data class FourFingerSwipeV(val direction: VDirection) : ControlEvent() {
        enum class VDirection(val code: String) { UP("U"), DOWN("D") }
        override fun serialize() = "G4V:${direction.code}"
    }

    /** Five-finger pinch in = Launchpad. */
    object Launchpad : ControlEvent() {
        override fun serialize() = "GLP:"
    }

    /** Five-finger spread out = Show Desktop. */
    object ShowDesktop : ControlEvent() {
        override fun serialize() = "GDT:"
    }

    // ── Keyboard ─────────────────────────────────────────────────────────────
    data class KeyPress(val keyCode: Int) : ControlEvent() {
        override fun serialize() = "K:$keyCode"
    }
    data class KeyCombo(val modifiers: String, val keyCode: Int) : ControlEvent() {
        override fun serialize() = "KC:$modifiers,$keyCode"
    }
    data class TypeText(val text: String) : ControlEvent() {
        override fun serialize() = "T:$text"
    }

    companion object {
        /** Fixed-format float: 2 decimal places, dot separator, no locale issues. */
        fun f(v: Float): String {
            // Use 2dp for gestures (need more precision than mouse deltas)
            val rounded = Math.round(v * 100f) / 100f
            val s = rounded.toString()
            return if (s.endsWith(".0")) s.dropLast(2) else s
        }
    }
}

/**
 * macOS CGKeyCode constants (Apple HIToolbox/Events.h)
 */
object MacKeyCodes {
    const val A = 0;  const val B = 11; const val C = 8;  const val D = 2
    const val E = 14; const val F = 3;  const val G = 5;  const val H = 4
    const val I = 34; const val J = 38; const val K = 40; const val L = 37
    const val M = 46; const val N = 45; const val O = 31; const val P = 35
    const val Q = 12; const val R = 15; const val S = 1;  const val T = 17
    const val U = 32; const val V = 9;  const val W = 13; const val X = 7
    const val Y = 16; const val Z = 6

    const val RETURN = 36;      const val TAB = 48;         const val SPACE = 49
    const val DELETE = 51;      const val ESCAPE = 53;      const val FORWARD_DELETE = 117
    const val ARROW_LEFT = 123; const val ARROW_RIGHT = 124
    const val ARROW_DOWN = 125; const val ARROW_UP = 126
    const val HOME = 115;       const val END = 119
    const val PAGE_UP = 116;    const val PAGE_DOWN = 121
    const val F1 = 122; const val F2 = 120; const val F3 = 99; const val F4 = 118
    const val F5 = 96;  const val F6 = 97;  const val F7 = 98; const val F8 = 100
    const val F9 = 101; const val F10 = 109; const val F11 = 103; const val F12 = 111
}
