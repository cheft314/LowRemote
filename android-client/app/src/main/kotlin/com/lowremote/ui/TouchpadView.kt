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
import kotlin.math.sqrt

/**
 * Touchpad View — реplicates the feel of a real Mac trackpad.
 *
 * ┌──────────────────────────────────────────────────────┐
 * │  Gesture        Fingers  Action                      │
 * │  ──────────────────────────────────────────────────  │
 * │  Move cursor    1        delta move                   │
 * │  Left click     1 tap    < 200ms, < 8dp              │
 * │  Right click    2 tap    < 200ms                      │
 * │  Drag           1 hold   > 450ms then move            │
 * │  Scroll         2 drag   natural direction            │
 * │  Pinch zoom     2 pinch  GZ:scale                    │
 * │  Rotate         2 twist  GR:angle                    │
 * │  Mission Ctrl   3 up     ↑ fast swipe                 │
 * │  App Exposé     3 down   ↓ fast swipe                 │
 * │  Switch Space   3 L/R    ← → fast swipe               │
 * │  Switch Space   4 L/R    same as 3-finger             │
 * │  Mission Ctrl   4 up     same                         │
 * │  Show Desktop   4 down   same                         │
 * │  Launchpad      5 pinch  5 fingers close together     │
 * │  Show Desktop   5 spread 5 fingers spread out         │
 * └──────────────────────────────────────────────────────┘
 *
 * onMeasure: height = width × 10/16 (strict 16:10 ratio).
 */
class TouchpadView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    companion object {
        private const val TAP_MS          = 220L
        private const val TAP_MOVE_DP     = 8f
        private const val LONG_PRESS_MS   = 450L
        private const val SWIPE_VEL_DP    = 500f  // dp/s threshold to trigger 3-finger swipe
        private const val SCROLL_TICK_DP  = 12f
        private const val PINCH_MIN_DELTA = 0.005f // ignore micro-pinch noise
        private const val TWO_MODE_SWITCH_DP = 6f  // px movement before deciding scroll vs pinch
    }

    /** Deliver events to RemoteSession. Must be called from UI thread. */
    var onEvent: ((ControlEvent) -> Unit)? = null

    /** Mouse movement multiplier for single-finger delta. */
    var sensitivity: Float = 2.0f

    // ── Resources ────────────────────────────────────────────────────────────
    private val dp            = context.resources.displayMetrics.density
    private val tapMovePx     = TAP_MOVE_DP * dp
    private val scrollTickPx  = SCROLL_TICK_DP * dp
    private val twoModePx     = TWO_MODE_SWITCH_DP * dp

    // ── Drawing ───────────────────────────────────────────────────────────────
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(50, 255, 255, 255)
        style = Paint.Style.STROKE
        strokeWidth = 1f * dp
    }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(35, 255, 255, 255)
        textSize = 10f * dp
        textAlign = Paint.Align.CENTER
    }

    // ── Measure ───────────────────────────────────────────────────────────────
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec).coerceAtLeast(1)
        setMeasuredDimension(w, w * 10 / 16)
    }

    override fun onDraw(canvas: Canvas) {
        val ins = 3f * dp
        canvas.drawRoundRect(ins, ins, width - ins, height - ins, 6f * dp, 6f * dp, borderPaint)
        canvas.drawText("触控板  ·  双指滚动/捏合  ·  三指手势", width / 2f,
            height / 2f + hintPaint.textSize / 3f, hintPaint)
    }

    // ── Gesture state machine ─────────────────────────────────────────────────

    private enum class TwoFingerMode { UNDECIDED, SCROLL, PINCH_ROTATE }

    /** All touch state is stored here and reset on each full gesture cycle. */
    private var fingerCount    = 0
    private var gestureStart   = 0L
    private var longPressTime  = 0L
    private var dragActive     = false

    // Single-finger
    private var sf0StartX = 0f;  private var sf0StartY = 0f
    private var sfLastX   = 0f;  private var sfLastY   = 0f
    private var sfLastT   = 0L

    // Two-finger
    private var tfMode     = TwoFingerMode.UNDECIDED
    private var tfScrollX  = 0f;  private var tfScrollY  = 0f  // accumulators
    private var tfLastMidX = 0f;  private var tfLastMidY = 0f
    private var tfLastSpan = 0f
    private var tfLastAngle = 0f
    private var tfTotalMove = 0f   // total mid-point movement (for mode decision)

    // Multi-finger (3/4/5) swipe detection
    private var mfStartMidX = 0f; private var mfStartMidY = 0f
    private var mfLastMidX  = 0f; private var mfLastMidY  = 0f
    private var mfStartSpan = 0f  // for 5-finger pinch/spread
    private var mfGestureFired = false  // only fire once per gesture

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val count = event.pointerCount

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                fingerCount  = 1
                gestureStart = SystemClock.uptimeMillis()
                longPressTime = gestureStart + LONG_PRESS_MS
                sf0StartX = event.x; sf0StartY = event.y
                sfLastX   = event.x; sfLastY   = event.y
                sfLastT   = gestureStart
                dragActive = false
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                fingerCount = count
                when (count) {
                    2 -> {
                        tfMode = TwoFingerMode.UNDECIDED
                        tfScrollX = 0f; tfScrollY = 0f; tfTotalMove = 0f
                        val mid = midpoint(event)
                        tfLastMidX = mid.first; tfLastMidY = mid.second
                        tfLastSpan  = span(event)
                        tfLastAngle = angle(event)
                    }
                    3, 4 -> {
                        val mid = midpointAll(event)
                        mfStartMidX = mid.first; mfStartMidY = mid.second
                        mfLastMidX  = mid.first; mfLastMidY  = mid.second
                        mfGestureFired = false
                    }
                    5 -> {
                        mfStartSpan = spanAll(event)
                        mfGestureFired = false
                    }
                }
                // Cancel any pending single-finger long-press drag
                if (count >= 2 && dragActive) {
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                    dragActive = false
                }
            }

            MotionEvent.ACTION_MOVE -> when (fingerCount) {
                1 -> handleOneFingerMove(event)
                2 -> handleTwoFingerMove(event)
                3, 4 -> handleMultiFingerMove(event, fingerCount)
                5 -> handleFiveFingerMove(event)
            }

            MotionEvent.ACTION_POINTER_UP -> {
                val remaining = count - 1
                if (remaining < fingerCount) {
                    // Leaving the gesture — evaluate taps
                    evaluatePointerUp(event, fingerCount)
                    fingerCount = remaining
                    // Reset two-finger tracking to remaining finger
                    if (remaining == 1) {
                        val idx = if (event.actionIndex == 0) 1 else 0
                        sfLastX = event.getX(idx); sfLastY = event.getY(idx)
                        sfLastT = SystemClock.uptimeMillis()
                    }
                }
            }

            MotionEvent.ACTION_UP -> {
                val elapsed = SystemClock.uptimeMillis() - gestureStart
                if (fingerCount == 1 && !dragActive) {
                    val moved = hypot(event.x - sf0StartX, event.y - sf0StartY)
                    if (elapsed < TAP_MS && moved < tapMovePx) {
                        onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
                        haptic(HapticFeedbackConstants.VIRTUAL_KEY)
                    }
                } else if (dragActive) {
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                    dragActive = false
                }
                fingerCount = 0
            }

            MotionEvent.ACTION_CANCEL -> {
                if (dragActive) {
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                    dragActive = false
                }
                fingerCount = 0
            }
        }
        return true
    }

    // ── One-finger ────────────────────────────────────────────────────────────

    private fun handleOneFingerMove(event: MotionEvent) {
        val now = SystemClock.uptimeMillis()
        val dx  = event.x - sfLastX
        val dy  = event.y - sfLastY

        // Long-press → start drag
        if (!dragActive && now >= longPressTime &&
            hypot(event.x - sf0StartX, event.y - sf0StartY) < tapMovePx * 4f
        ) {
            dragActive = true
            haptic(HapticFeedbackConstants.LONG_PRESS)
            onEvent?.invoke(ControlEvent.MouseDown(ControlEvent.Button.LEFT))
        }

        sfLastX = event.x; sfLastY = event.y; sfLastT = now
        if (dx == 0f && dy == 0f) return
        onEvent?.invoke(ControlEvent.MouseMove(dx * sensitivity, dy * sensitivity))
    }

    // ── Two-finger ────────────────────────────────────────────────────────────

    private fun handleTwoFingerMove(event: MotionEvent) {
        val mid   = midpoint(event)
        val midX  = mid.first; val midY = mid.second
        val curSpan  = span(event)
        val curAngle = angle(event)

        val dMidX  = midX  - tfLastMidX
        val dMidY  = midY  - tfLastMidY
        val dSpan  = curSpan  - tfLastSpan
        val dAngle = curAngle - tfLastAngle

        // Decide mode when undecided
        if (tfMode == TwoFingerMode.UNDECIDED) {
            tfTotalMove += hypot(dMidX, dMidY)
            val pinchMag = abs(dSpan)
            if (tfTotalMove > twoModePx) {
                tfMode = TwoFingerMode.SCROLL
            } else if (pinchMag > twoModePx * 0.5f) {
                tfMode = TwoFingerMode.PINCH_ROTATE
            }
        }

        when (tfMode) {
            TwoFingerMode.SCROLL -> {
                // Natural scroll: finger direction = content direction
                // → positive dY (finger down) → content moves down → wheel -1 (standard)
                // Mac "natural scroll" is already inverted at OS level, so we match it:
                // finger up → wheel +1 (scroll up in content)
                tfScrollX += dMidX
                tfScrollY += dMidY
                while (tfScrollY <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(1));  tfScrollY += scrollTickPx }
                while (tfScrollY >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(-1)); tfScrollY -= scrollTickPx }
                while (tfScrollX <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(1));  tfScrollX += scrollTickPx }
                while (tfScrollX >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(-1)); tfScrollX -= scrollTickPx }
            }
            TwoFingerMode.PINCH_ROTATE -> {
                // Pinch
                if (curSpan > 0 && abs(dSpan) > PINCH_MIN_DELTA * dp) {
                    val scaleDelta = dSpan / curSpan   // fractional change
                    if (abs(scaleDelta) > PINCH_MIN_DELTA) {
                        onEvent?.invoke(ControlEvent.Magnify(scaleDelta))
                    }
                }
                // Rotation (small angle in radians)
                val dRad = dAngle * (Math.PI / 180.0).toFloat()
                if (abs(dRad) > 0.01f) {
                    onEvent?.invoke(ControlEvent.Rotate(dRad))
                }
            }
            TwoFingerMode.UNDECIDED -> { /* still deciding */ }
        }

        tfLastMidX = midX; tfLastMidY = midY
        tfLastSpan  = curSpan
        tfLastAngle = curAngle
    }

    // ── Multi-finger (3 / 4) ─────────────────────────────────────────────────

    private fun handleMultiFingerMove(event: MotionEvent, fingers: Int) {
        if (mfGestureFired) return
        val mid  = midpointAll(event)
        val midX = mid.first; val midY = mid.second
        val dX   = midX - mfStartMidX
        val dY   = midY - mfStartMidY
        val dist = hypot(dX, dY)
        val threshold = 40f * dp   // must move 40dp before triggering

        if (dist < threshold) {
            mfLastMidX = midX; mfLastMidY = midY
            return
        }

        // Determine dominant direction
        val horizontal = abs(dX) > abs(dY)
        mfGestureFired = true

        if (fingers == 3) {
            if (horizontal) {
                val dir = if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT
                          else        ControlEvent.SwitchDesktop.Direction.RIGHT
                onEvent?.invoke(ControlEvent.SwitchDesktop(dir))
            } else {
                if (dY < 0) onEvent?.invoke(ControlEvent.MissionControl)   // up
                else        onEvent?.invoke(ControlEvent.AppExpose)         // down
            }
        } else { // 4 fingers
            if (horizontal) {
                val dir = if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT
                          else        ControlEvent.SwitchDesktop.Direction.RIGHT
                onEvent?.invoke(ControlEvent.FourFingerSwipeH(dir))
            } else {
                val vdir = if (dY < 0) ControlEvent.FourFingerSwipeV.VDirection.UP
                           else        ControlEvent.FourFingerSwipeV.VDirection.DOWN
                onEvent?.invoke(ControlEvent.FourFingerSwipeV(vdir))
            }
        }
        haptic(HapticFeedbackConstants.LONG_PRESS)
    }

    // ── Five-finger ───────────────────────────────────────────────────────────

    private fun handleFiveFingerMove(event: MotionEvent) {
        if (mfGestureFired) return
        val curSpan = spanAll(event)
        val ratio   = if (mfStartSpan > 0) curSpan / mfStartSpan else 1f

        if (ratio < 0.65f) {          // pinch in → Launchpad
            mfGestureFired = true
            onEvent?.invoke(ControlEvent.Launchpad)
            haptic(HapticFeedbackConstants.LONG_PRESS)
        } else if (ratio > 1.45f) {   // spread out → Show Desktop
            mfGestureFired = true
            onEvent?.invoke(ControlEvent.ShowDesktop)
            haptic(HapticFeedbackConstants.LONG_PRESS)
        }
    }

    // ── Tap evaluation on POINTER_UP ─────────────────────────────────────────

    private fun evaluatePointerUp(event: MotionEvent, wasFingers: Int) {
        val elapsed = SystemClock.uptimeMillis() - gestureStart
        if (elapsed > TAP_MS) return   // too slow → not a tap

        when (wasFingers) {
            2 -> {
                // Two-finger tap = right-click (only if we didn't scroll/pinch much)
                if (tfMode == TwoFingerMode.UNDECIDED || tfTotalMove < tapMovePx) {
                    onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
                    haptic(HapticFeedbackConstants.CONTEXT_CLICK)
                }
            }
            3 -> {
                // Three-finger tap = middle-click (open link in new tab, etc.)
                // Mac doesn't have a native middle-click shortcut, use ⌘ click instead
                onEvent?.invoke(ControlEvent.MouseDown(ControlEvent.Button.LEFT))
                onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
            }
            // 4/5 finger taps intentionally ignored
        }
    }

    // ── Geometry helpers ─────────────────────────────────────────────────────

    /** Midpoint between pointer 0 and pointer 1. */
    private fun midpoint(ev: MotionEvent): Pair<Float, Float> {
        val x = (ev.getX(0) + ev.getX(1)) / 2f
        val y = (ev.getY(0) + ev.getY(1)) / 2f
        return Pair(x, y)
    }

    /** Distance between pointer 0 and pointer 1. */
    private fun span(ev: MotionEvent): Float =
        hypot(ev.getX(1) - ev.getX(0), ev.getY(1) - ev.getY(0))

    /** Angle in degrees between pointer 0 and pointer 1. */
    private fun angle(ev: MotionEvent): Float =
        Math.toDegrees(atan2(
            (ev.getY(1) - ev.getY(0)).toDouble(),
            (ev.getX(1) - ev.getX(0)).toDouble()
        )).toFloat()

    /** Centroid of all active pointers. */
    private fun midpointAll(ev: MotionEvent): Pair<Float, Float> {
        var sumX = 0f; var sumY = 0f
        for (i in 0 until ev.pointerCount) {
            sumX += ev.getX(i); sumY += ev.getY(i)
        }
        return Pair(sumX / ev.pointerCount, sumY / ev.pointerCount)
    }

    /** Average distance from centroid (rough "span" for multi-finger). */
    private fun spanAll(ev: MotionEvent): Float {
        val mid = midpointAll(ev)
        var sum = 0f
        for (i in 0 until ev.pointerCount) {
            sum += hypot(ev.getX(i) - mid.first, ev.getY(i) - mid.second)
        }
        return sum / ev.pointerCount
    }

    private fun haptic(type: Int) = performHapticFeedback(type)
}
