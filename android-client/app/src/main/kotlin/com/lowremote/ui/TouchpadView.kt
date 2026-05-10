package com.lowremote.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.SystemClock
import android.util.AttributeSet
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import com.lowremote.model.ControlEvent
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * Trackpad View — full Mac gesture set.
 *
 * GESTURE TABLE
 * ─────────────────────────────────────────────────────────────────
 * 1 finger move        → cursor delta move (sensitivity × dp)
 * 1 finger tap         → left click  (<220ms, <8dp travel)
 * 1 finger double-tap  → double click (two taps <400ms apart)
 * 1 finger long-press  → drag lock (if dragLockEnabled=true: hold
 *                         >450ms then move = drag; otherwise just move)
 * 2 finger tap         → right click
 * 2 finger drag        → scroll (natural: finger up → content up)
 *                         or pinch-zoom / rotate (auto-detect by span)
 * 3 finger swipe ↑     → Mission Control (Ctrl+↑)
 * 3 finger swipe ↓     → App Exposé (Ctrl+↓)
 * 3 finger swipe ←/→   → Switch Space (Ctrl+←/→)
 * 4 finger swipe ↑/↓/←/→ → same as 3-finger
 * 5 finger pinch       → Launchpad
 * 5 finger spread      → Show Desktop
 *
 * SCROLL DIRECTION FIX (was inverted):
 *   Android touch: finger moves DOWN → dMidY > 0
 *   "Natural scroll" on Mac: finger down → content moves down → wheel tick DOWN
 *   CGEvent wheel1 positive = scroll UP
 *   So: finger down (dMidY > 0) → wheel1 = -1  ← fixed
 *       finger up   (dMidY < 0) → wheel1 = +1
 *
 * onMeasure: height = width × 10/16 (strict 16:10).
 */
class TouchpadView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    companion object {
        private const val TAP_MS            = 220L   // max tap duration
        private const val DOUBLE_TAP_MS     = 380L   // max gap between two taps
        private const val TAP_MOVE_DP       = 8f
        private const val LONG_PRESS_MS     = 450L
        private const val SCROLL_TICK_DP    = 10f    // px per scroll tick (smaller = faster)
        private const val PINCH_MIN_DELTA   = 0.004f
        // Multi-finger gesture: trigger after only 18dp displacement (was 40dp — too high)
        private const val MF_SWIPE_DP       = 18f
    }

    var onEvent: ((ControlEvent) -> Unit)? = null
    var sensitivity: Float = 2.0f
    /** When true, long-press + drag = drag.  When false, all single-finger moves are plain moves. */
    var dragLockEnabled: Boolean = false

    private val dp             = context.resources.displayMetrics.density
    private val tapMovePx      = TAP_MOVE_DP  * dp
    private val scrollTickPx   = SCROLL_TICK_DP * dp
    private val mfSwipePx      = MF_SWIPE_DP * dp

    // ── Drawing ───────────────────────────────────────────────────────────────
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(50, 255, 255, 255); style = Paint.Style.STROKE
        strokeWidth = 1f * dp
    }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(30, 255, 255, 255); textSize = 9.5f * dp
        textAlign = Paint.Align.CENTER
    }
    private val dragPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(80, 74, 144, 226); style = Paint.Style.FILL
    }

    override fun onMeasure(w: Int, h: Int) {
        val pw = MeasureSpec.getSize(w).coerceAtLeast(1)
        setMeasuredDimension(pw, pw * 10 / 16)
    }

    override fun onDraw(canvas: Canvas) {
        val ins = 3f * dp
        canvas.drawRoundRect(ins, ins, width - ins, height - ins, 6f * dp, 6f * dp, borderPaint)
        if (dragActive) {
            canvas.drawRoundRect(ins, ins, width - ins, height - ins, 6f * dp, 6f * dp, dragPaint)
        }
        val hint = buildString {
            append("触控板")
            if (dragActive) append("  🔒拖拽中")
            else append("  · 双指滚动 · 三指手势")
        }
        canvas.drawText(hint, width / 2f, height / 2f + hintPaint.textSize / 3f, hintPaint)
    }

    // ── Touch state ───────────────────────────────────────────────────────────
    private enum class TwoMode { UNDECIDED, SCROLL, PINCH_ROTATE }

    private var fingerCount    = 0
    private var gestureStart   = 0L
    private var longPressTime  = 0L
    private var dragActive     = false

    // Single-finger
    private var sfStartX = 0f; private var sfStartY = 0f
    private var sfLastX  = 0f; private var sfLastY  = 0f

    // Double-tap tracking
    private var lastTapTime = 0L
    private var lastTapX    = 0f; private var lastTapY = 0f

    // Two-finger
    private var tfMode     = TwoMode.UNDECIDED
    private var tfScrollX  = 0f; private var tfScrollY = 0f
    private var tfLastMidX = 0f; private var tfLastMidY = 0f
    private var tfLastSpan = 0f; private var tfLastAngle = 0f
    private var tfTotalMove = 0f

    // Multi-finger (3/4/5)
    private var mfStartMidX = 0f; private var mfStartMidY = 0f
    private var mfStartSpan = 0f
    private var mfFired = false

    // ── Touch dispatch ────────────────────────────────────────────────────────
    override fun onTouchEvent(ev: MotionEvent): Boolean {
        val count = ev.pointerCount
        when (ev.actionMasked) {

            MotionEvent.ACTION_DOWN -> {
                fingerCount   = 1
                gestureStart  = SystemClock.uptimeMillis()
                longPressTime = gestureStart + LONG_PRESS_MS
                sfStartX = ev.x; sfStartY = ev.y
                sfLastX  = ev.x; sfLastY  = ev.y
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                fingerCount = count
                when (count) {
                    2 -> {
                        tfMode = TwoMode.UNDECIDED
                        tfScrollX = 0f; tfScrollY = 0f; tfTotalMove = 0f
                        midpoint(ev).let { (mx, my) -> tfLastMidX = mx; tfLastMidY = my }
                        tfLastSpan  = span2(ev)
                        tfLastAngle = angle2(ev)
                        // Cancel drag if started
                        if (dragActive) { fireDragUp(); dragActive = false }
                    }
                    3, 4 -> {
                        midpointAll(ev).let { (mx, my) -> mfStartMidX = mx; mfStartMidY = my }
                        mfFired = false
                    }
                    5 -> { mfStartSpan = spanAll(ev); mfFired = false }
                }
            }

            MotionEvent.ACTION_MOVE -> when (fingerCount) {
                1    -> handleOneMove(ev)
                2    -> handleTwoMove(ev)
                3, 4 -> handleMultiMove(ev, fingerCount)
                5    -> handleFiveMove(ev)
            }

            MotionEvent.ACTION_POINTER_UP -> {
                val remaining = count - 1
                if (remaining < fingerCount) {
                    evaluatePointerUp(ev, fingerCount)
                    fingerCount = remaining
                    if (remaining == 1) {
                        val idx = if (ev.actionIndex == 0) 1 else 0
                        sfLastX = ev.getX(idx); sfLastY = ev.getY(idx)
                    }
                }
            }

            MotionEvent.ACTION_UP -> {
                val elapsed = SystemClock.uptimeMillis() - gestureStart
                val moved   = hypot(ev.x - sfStartX, ev.y - sfStartY)
                if (fingerCount == 1) {
                    if (!dragActive && elapsed < TAP_MS && moved < tapMovePx) {
                        fireTap()
                    } else if (dragActive) {
                        fireDragUp()
                        dragActive = false
                        invalidate()
                    }
                }
                fingerCount = 0
            }

            MotionEvent.ACTION_CANCEL -> {
                if (dragActive) { fireDragUp(); dragActive = false; invalidate() }
                fingerCount = 0
            }
        }
        return true
    }

    // ── Single finger ─────────────────────────────────────────────────────────
    private fun handleOneMove(ev: MotionEvent) {
        val now = SystemClock.uptimeMillis()
        val dx  = ev.x - sfLastX
        val dy  = ev.y - sfLastY

        if (dragLockEnabled && !dragActive && now >= longPressTime &&
            hypot(ev.x - sfStartX, ev.y - sfStartY) < tapMovePx * 4f
        ) {
            dragActive = true
            haptic(HapticFeedbackConstants.LONG_PRESS)
            onEvent?.invoke(ControlEvent.MouseDown(ControlEvent.Button.LEFT))
            invalidate()
        }

        sfLastX = ev.x; sfLastY = ev.y
        if (dx == 0f && dy == 0f) return
        onEvent?.invoke(ControlEvent.MouseMove(dx * sensitivity, dy * sensitivity))
    }

    // ── Two finger ────────────────────────────────────────────────────────────
    private fun handleTwoMove(ev: MotionEvent) {
        val (midX, midY) = midpoint(ev)
        val curSpan  = span2(ev)
        val curAngle = angle2(ev)
        val dMidX    = midX - tfLastMidX
        val dMidY    = midY - tfLastMidY
        val dSpan    = curSpan - tfLastSpan
        val dAngle   = curAngle - tfLastAngle

        if (tfMode == TwoMode.UNDECIDED) {
            tfTotalMove += hypot(dMidX, dMidY)
            if (tfTotalMove > scrollTickPx * 0.8f)  tfMode = TwoMode.SCROLL
            else if (abs(dSpan) > scrollTickPx * 0.4f) tfMode = TwoMode.PINCH_ROTATE
        }

        when (tfMode) {
            TwoMode.SCROLL -> {
                // Natural scroll: finger down → content down → wheel -1
                tfScrollX += dMidX; tfScrollY += dMidY
                while (tfScrollY >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(-1)); tfScrollY -= scrollTickPx }
                while (tfScrollY <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(+1)); tfScrollY += scrollTickPx }
                while (tfScrollX >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(-1)); tfScrollX -= scrollTickPx }
                while (tfScrollX <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(+1)); tfScrollX += scrollTickPx }
            }
            TwoMode.PINCH_ROTATE -> {
                if (curSpan > 0 && abs(dSpan) > PINCH_MIN_DELTA * dp) {
                    val s = dSpan / curSpan
                    if (abs(s) > PINCH_MIN_DELTA) onEvent?.invoke(ControlEvent.Magnify(s))
                }
                val dRad = dAngle * (Math.PI / 180.0).toFloat()
                if (abs(dRad) > 0.015f) onEvent?.invoke(ControlEvent.Rotate(dRad))
            }
            TwoMode.UNDECIDED -> {}
        }

        tfLastMidX = midX; tfLastMidY = midY
        tfLastSpan  = curSpan; tfLastAngle = curAngle
    }

    // ── Multi-finger (3/4) ────────────────────────────────────────────────────
    private fun handleMultiMove(ev: MotionEvent, fingers: Int) {
        if (mfFired) return
        val (midX, midY) = midpointAll(ev)
        val dX   = midX - mfStartMidX
        val dY   = midY - mfStartMidY
        val dist = hypot(dX, dY)
        if (dist < mfSwipePx) return

        mfFired = true
        val horiz = abs(dX) > abs(dY)

        if (fingers == 3) {
            if (horiz) onEvent?.invoke(ControlEvent.SwitchDesktop(
                if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT else ControlEvent.SwitchDesktop.Direction.RIGHT))
            else if (dY < 0) onEvent?.invoke(ControlEvent.MissionControl)
            else             onEvent?.invoke(ControlEvent.AppExpose)
        } else { // 4
            if (horiz) onEvent?.invoke(ControlEvent.FourFingerSwipeH(
                if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT else ControlEvent.SwitchDesktop.Direction.RIGHT))
            else onEvent?.invoke(ControlEvent.FourFingerSwipeV(
                if (dY < 0) ControlEvent.FourFingerSwipeV.VDirection.UP else ControlEvent.FourFingerSwipeV.VDirection.DOWN))
        }
        haptic(HapticFeedbackConstants.LONG_PRESS)
    }

    // ── Five-finger ───────────────────────────────────────────────────────────
    private fun handleFiveMove(ev: MotionEvent) {
        if (mfFired) return
        val r = if (mfStartSpan > 0) spanAll(ev) / mfStartSpan else 1f
        when {
            r < 0.62f  -> { mfFired = true; onEvent?.invoke(ControlEvent.Launchpad);   haptic(HapticFeedbackConstants.LONG_PRESS) }
            r > 1.48f  -> { mfFired = true; onEvent?.invoke(ControlEvent.ShowDesktop); haptic(HapticFeedbackConstants.LONG_PRESS) }
        }
    }

    // ── Tap logic ─────────────────────────────────────────────────────────────
    private fun fireTap() {
        val now = SystemClock.uptimeMillis()
        val gapToLast = now - lastTapTime
        val nearLast  = hypot(sfStartX - lastTapX, sfStartY - lastTapY) < tapMovePx * 3f

        if (gapToLast < DOUBLE_TAP_MS && nearLast) {
            // Double-tap: send two clicks in rapid succession
            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
            haptic(HapticFeedbackConstants.VIRTUAL_KEY)
            lastTapTime = 0L // reset so next tap doesn't triple-click
        } else {
            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
            haptic(HapticFeedbackConstants.VIRTUAL_KEY)
            lastTapTime = now; lastTapX = sfStartX; lastTapY = sfStartY
        }
    }

    private fun fireDragUp() {
        onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
    }

    // ── Pointer-up tap evaluation (2/3 finger) ────────────────────────────────
    private fun evaluatePointerUp(ev: MotionEvent, wasFingers: Int) {
        val elapsed = SystemClock.uptimeMillis() - gestureStart
        if (elapsed > TAP_MS + 60) return // small extra grace period for multi-touch
        when (wasFingers) {
            2 -> if (tfMode == TwoMode.UNDECIDED || tfTotalMove < tapMovePx) {
                onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
                haptic(HapticFeedbackConstants.CONTEXT_CLICK)
            }
            // 3-finger tap: ignored (too easy to trigger accidentally)
        }
    }

    // ── Geometry ──────────────────────────────────────────────────────────────
    private fun midpoint(ev: MotionEvent) = Pair(
        (ev.getX(0) + ev.getX(1)) / 2f, (ev.getY(0) + ev.getY(1)) / 2f)
    private fun span2(ev: MotionEvent) =
        hypot(ev.getX(1) - ev.getX(0), ev.getY(1) - ev.getY(0))
    private fun angle2(ev: MotionEvent) =
        Math.toDegrees(atan2((ev.getY(1) - ev.getY(0)).toDouble(),
            (ev.getX(1) - ev.getX(0)).toDouble())).toFloat()
    private fun midpointAll(ev: MotionEvent): Pair<Float, Float> {
        var sx = 0f; var sy = 0f
        repeat(ev.pointerCount) { sx += ev.getX(it); sy += ev.getY(it) }
        return Pair(sx / ev.pointerCount, sy / ev.pointerCount)
    }
    private fun spanAll(ev: MotionEvent): Float {
        val (mx, my) = midpointAll(ev); var s = 0f
        repeat(ev.pointerCount) { s += hypot(ev.getX(it) - mx, ev.getY(it) - my) }
        return s / ev.pointerCount
    }

    private fun haptic(t: Int) = performHapticFeedback(t)
}
