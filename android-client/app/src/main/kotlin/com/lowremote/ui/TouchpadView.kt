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
import kotlin.math.hypot

/**
 * Touchpad surface with a small built-in gesture state machine:
 *
 *   • 1 finger move        → mouse move (delta)
 *   • 1 finger tap         → left click
 *   • 1 finger long-press  → left button down; subsequent move = drag; up on release
 *   • 2 fingers short tap  → right click
 *   • 2 fingers vertical   → scroll wheel
 *
 * Coordinates sent use *delta* mode — the Mac accumulates onto the current
 * cursor position, which feels much more trackpad-like than absolute mapping.
 */
class TouchpadView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    companion object {
        private const val TAP_MAX_MS = 200L
        private const val TAP_MAX_MOVE_DP = 5f
        private const val LONG_PRESS_MS = 500L
        private const val SCROLL_ACCUMULATION_THRESHOLD_DP = 16f
    }

    var onEvent: ((ControlEvent) -> Unit)? = null

    /** Linear multiplier on raw touch deltas. Trackpads feel best at ~1.5–2.2. */
    var sensitivity: Float = 1.8f

    private val densityPx: Float = context.resources.displayMetrics.density
    private val tapMaxMovePx = TAP_MAX_MOVE_DP * densityPx
    private val scrollThresholdPx = SCROLL_ACCUMULATION_THRESHOLD_DP * densityPx

    // ---- Drawing ----
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.DKGRAY
        style = Paint.Style.STROKE
        strokeWidth = 2f * densityPx
    }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.GRAY
        textSize = 14f * densityPx
        textAlign = Paint.Align.CENTER
    }

    override fun onDraw(canvas: Canvas) {
        val inset = 4f * densityPx
        canvas.drawRoundRect(
            inset, inset, width - inset, height - inset,
            8f * densityPx, 8f * densityPx,
            borderPaint,
        )
        canvas.drawText("Touchpad", width / 2f, height / 2f, hintPaint)
    }

    // ---- Gesture state ----
    private var gestureStartTime = 0L
    private var pointer0StartX = 0f
    private var pointer0StartY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var cumulativeMove = 0f

    private var mode = Mode.None
    private var dragActive = false
    private var longPressFireTime = 0L

    /** Accumulates 2-finger Y delta so we emit scroll ticks, not wheel noise. */
    private var scrollAccum = 0f

    private enum class Mode { None, Single, Two }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = Mode.Single
                gestureStartTime = SystemClock.uptimeMillis()
                longPressFireTime = gestureStartTime + LONG_PRESS_MS
                pointer0StartX = event.x
                pointer0StartY = event.y
                lastX = event.x
                lastY = event.y
                cumulativeMove = 0f
                dragActive = false
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount == 2) {
                    mode = Mode.Two
                    scrollAccum = 0f
                    // Use pointer index 1 as the primary for delta tracking.
                    lastX = event.getX(1)
                    lastY = event.getY(1)
                }
            }

            MotionEvent.ACTION_MOVE -> {
                when (mode) {
                    Mode.Single -> handleSingleMove(event)
                    Mode.Two -> handleTwoFingerMove(event)
                    Mode.None -> {}
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (event.pointerCount == 2) {
                    // Second finger lifted. If we were in two-finger mode and
                    // barely moved, treat as right-click.
                    if (mode == Mode.Two) {
                        val elapsed = SystemClock.uptimeMillis() - gestureStartTime
                        if (elapsed < TAP_MAX_MS && abs(scrollAccum) < scrollThresholdPx) {
                            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
                            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                        }
                    }
                    // Fall back to single-finger tracking, if the remaining
                    // finger is still down.
                    val remainingIdx = if (event.actionIndex == 0) 1 else 0
                    lastX = event.getX(remainingIdx)
                    lastY = event.getY(remainingIdx)
                    mode = Mode.Single
                }
            }

            MotionEvent.ACTION_UP -> {
                val elapsed = SystemClock.uptimeMillis() - gestureStartTime
                if (mode == Mode.Single && !dragActive) {
                    val moved = hypot(event.x - pointer0StartX, event.y - pointer0StartY)
                    if (elapsed < TAP_MAX_MS && moved < tapMaxMovePx) {
                        onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
                        performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    }
                } else if (dragActive) {
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                    dragActive = false
                }
                mode = Mode.None
            }

            MotionEvent.ACTION_CANCEL -> {
                if (dragActive) {
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                    dragActive = false
                }
                mode = Mode.None
            }
        }
        return true
    }

    private fun handleSingleMove(event: MotionEvent) {
        val x = event.x
        val y = event.y
        val dx = x - lastX
        val dy = y - lastY
        lastX = x
        lastY = y

        // Kick off a drag when a long-press crosses the movement threshold.
        if (!dragActive &&
            SystemClock.uptimeMillis() >= longPressFireTime &&
            hypot(x - pointer0StartX, y - pointer0StartY) < tapMaxMovePx * 2f
        ) {
            dragActive = true
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            onEvent?.invoke(ControlEvent.MouseDown(ControlEvent.Button.LEFT))
        }

        if (dx == 0f && dy == 0f) return
        onEvent?.invoke(ControlEvent.MouseMove(dx * sensitivity, dy * sensitivity))
    }

    private fun handleTwoFingerMove(event: MotionEvent) {
        if (event.pointerCount < 2) return
        val x = event.getX(1)
        val y = event.getY(1)
        val dy = y - lastY
        lastX = x
        lastY = y
        scrollAccum += dy
        // One "wheel tick" per accumulated threshold; direction follows natural
        // scrolling (finger up = content up = wheel up / positive value on Mac).
        while (scrollAccum <= -scrollThresholdPx) {
            onEvent?.invoke(ControlEvent.MouseWheel(1))
            scrollAccum += scrollThresholdPx
        }
        while (scrollAccum >= scrollThresholdPx) {
            onEvent?.invoke(ControlEvent.MouseWheel(-1))
            scrollAccum -= scrollThresholdPx
        }
    }
}
