package com.lowremote.ui

import android.content.Context
import android.os.SystemClock
import android.util.AttributeSet
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import com.lowremote.model.ControlEvent
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Video surface + touch input combined view.
 *
 * MODE A — touchscreen (touchscreenMode=true, default)
 *   1 finger tap       → move cursor to that position then left-click
 *   1 finger double-tap → double-click at that position
 *   1 finger long-press → right-click at that position (no drag)
 *   1 finger drag       → cursor follows finger (absolute)
 *   2 finger scroll     → natural-direction scroll wheel
 *   3/4/5 finger        → system gestures (same as TouchpadView)
 *
 * MODE B — trackpad (touchscreenMode=false)
 *   Entire video area acts as a large trackpad; same gesture set as
 *   TouchpadView including drag-lock support.
 *
 * SCROLL DIRECTION (fixed):
 *   Natural scroll: finger DOWN → dY > 0 → content moves DOWN → wheel tick = -1
 *   Finger UP       → dY < 0 → content moves UP   → wheel tick = +1
 */
class VideoTouchView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : SurfaceView(context, attrs), SurfaceHolder.Callback {

    // ── Surface ───────────────────────────────────────────────────────────────
    var onSurfaceReady:    ((android.view.Surface) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null
    var targetAspectWidth:  Int = 16
    var targetAspectHeight: Int = 10
    init { holder.addCallback(this) }
    override fun surfaceCreated(h: SurfaceHolder)                      { onSurfaceReady?.invoke(h.surface) }
    override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, h2: Int) {}
    override fun surfaceDestroyed(h: SurfaceHolder)                     { onSurfaceDestroyed?.invoke() }

    // ── Config ────────────────────────────────────────────────────────────────
    var onEvent: ((ControlEvent) -> Unit)? = null
    var touchscreenMode: Boolean = true
    var sensitivity:     Float   = 2.0f
    /** Only effective in trackpad mode. */
    var dragLockEnabled: Boolean = false
    /** Called on ACTION_DOWN — lets the parent close any open drawer immediately. */
    var onFirstTouch: (() -> Unit)? = null

    // ── Constants ─────────────────────────────────────────────────────────────
    private val dp           = context.resources.displayMetrics.density
    private val tapMovePx    = 10f * dp
    private val scrollTickPx = 12f * dp
    private val mfSwipePx    = 18f * dp
    private val TAP_MS       = 240L
    private val DBLCLICK_MS  = 380L
    private val LONG_MS      = 480L

    // ── Single-finger ─────────────────────────────────────────────────────────
    private var sfStartX = 0f; private var sfStartY = 0f
    private var sfLastX  = 0f; private var sfLastY  = 0f
    private var sfStartT = 0L; private var sfLongT  = 0L
    private var sfAbsDragging   = false
    private var sfDeltaDragging = false
    private var sfLongFired     = false   // long-press right-click already fired

    // Double-tap tracking (supports triple-click too)
    private var lastTapT  = 0L; private var lastTapX  = 0f; private var lastTapY  = 0f
    private var prevTapT  = 0L; private var prevTapX  = 0f; private var prevTapY  = 0f

    // ── Two-finger ────────────────────────────────────────────────────────────
    private var tfMidX = 0f; private var tfMidY = 0f
    private var tfScrollX = 0f; private var tfScrollY = 0f

    // ── Multi-finger ──────────────────────────────────────────────────────────
    private var fingerCount = 0
    private var mfStartMidX = 0f; private var mfStartMidY = 0f
    private var mfStartSpan = 0f; private var mfFired = false

    // ── Touch dispatch ────────────────────────────────────────────────────────
    override fun onTouchEvent(ev: MotionEvent): Boolean {
        val count = ev.pointerCount
        when (ev.actionMasked) {

            MotionEvent.ACTION_DOWN -> {
                fingerCount     = 1
                sfStartX = ev.x; sfStartY = ev.y
                sfLastX  = ev.x; sfLastY  = ev.y
                sfStartT = SystemClock.uptimeMillis()
                sfLongT  = sfStartT + LONG_MS
                sfAbsDragging = false; sfDeltaDragging = false; sfLongFired = false
                // Notify parent immediately so it can close any open drawer
                onFirstTouch?.invoke()
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                fingerCount = count
                when (count) {
                    2 -> {
                        tfMidX = (ev.getX(0) + ev.getX(1)) / 2f
                        tfMidY = (ev.getY(0) + ev.getY(1)) / 2f
                        tfScrollX = 0f; tfScrollY = 0f
                        cancelActiveDrag()
                    }
                    3, 4 -> {
                        midAll(ev).let { (mx, my) -> mfStartMidX = mx; mfStartMidY = my }
                        mfFired = false; cancelActiveDrag()
                    }
                    5 -> { mfStartSpan = spanAll(ev); mfFired = false; cancelActiveDrag() }
                }
            }

            MotionEvent.ACTION_MOVE -> when (fingerCount) {
                1    -> handleOneMove(ev)
                2    -> handleTwoMove(ev)
                3, 4 -> handleMfMove(ev, fingerCount)
                5    -> handleFiveMove(ev)
            }

            MotionEvent.ACTION_POINTER_UP -> {
                val remaining = count - 1
                if (remaining < fingerCount) {
                    if (fingerCount == 2) evalTwoFingerTap(ev)
                    fingerCount = remaining
                    if (remaining == 1) {
                        val i = if (ev.actionIndex == 0) 1 else 0
                        sfLastX = ev.getX(i); sfLastY = ev.getY(i)
                    }
                }
            }

            MotionEvent.ACTION_UP -> {
                val elapsed = SystemClock.uptimeMillis() - sfStartT
                val moved   = hypot(ev.x - sfStartX, ev.y - sfStartY)
                when {
                    sfAbsDragging || sfDeltaDragging -> cancelActiveDrag()
                    sfLongFired -> { /* right-click already sent */ }
                    fingerCount == 1 && elapsed < TAP_MS && moved < tapMovePx -> {
                        fireTap(ev.x, ev.y)
                    }
                }
                fingerCount = 0
            }

            MotionEvent.ACTION_CANCEL -> { cancelActiveDrag(); fingerCount = 0 }
        }
        return true
    }

    // ── One-finger ────────────────────────────────────────────────────────────
    private fun handleOneMove(ev: MotionEvent) {
        val now  = SystemClock.uptimeMillis()
        val dx   = ev.x - sfLastX
        val dy   = ev.y - sfLastY

        if (touchscreenMode) {
            // Long-press without too much movement → right-click (once)
            if (!sfLongFired && !sfAbsDragging && now >= sfLongT &&
                hypot(ev.x - sfStartX, ev.y - sfStartY) < tapMovePx * 2.5f
            ) {
                sfLongFired = true
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                val (nx, ny) = normalize(ev.x, ev.y)
                onEvent?.invoke(ControlEvent.MouseAbsolute(nx, ny))
                onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
                return
            }
            if (!sfLongFired) {
                // Continuous absolute tracking
                val (nx, ny) = normalize(ev.x, ev.y)
                onEvent?.invoke(ControlEvent.MouseAbsolute(nx, ny))
            }
        } else {
            // Trackpad mode
            if (dragLockEnabled && !sfDeltaDragging && now >= sfLongT &&
                hypot(ev.x - sfStartX, ev.y - sfStartY) < tapMovePx * 4f
            ) {
                sfDeltaDragging = true
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                onEvent?.invoke(ControlEvent.MouseDown(ControlEvent.Button.LEFT))
            }
            if (dx != 0f || dy != 0f)
                onEvent?.invoke(ControlEvent.MouseMove(dx * sensitivity, dy * sensitivity))
        }

        sfLastX = ev.x; sfLastY = ev.y
    }

    // ── Two-finger ────────────────────────────────────────────────────────────
    private fun handleTwoMove(ev: MotionEvent) {
        val mx = (ev.getX(0) + ev.getX(1)) / 2f
        val my = (ev.getY(0) + ev.getY(1)) / 2f
        val dX = mx - tfMidX; val dY = my - tfMidY
        tfMidX = mx; tfMidY = my
        tfScrollX += dX; tfScrollY += dY
        // Natural scroll (fixed): finger down → dY > 0 → content down → wheel -1
        while (tfScrollY >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(-1)); tfScrollY -= scrollTickPx }
        while (tfScrollY <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(+1)); tfScrollY += scrollTickPx }
        while (tfScrollX >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(-1)); tfScrollX -= scrollTickPx }
        while (tfScrollX <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(+1)); tfScrollX += scrollTickPx }
    }

    // ── Multi-finger (3/4) ────────────────────────────────────────────────────
    private fun handleMfMove(ev: MotionEvent, fingers: Int) {
        if (mfFired) return
        val (mx, my) = midAll(ev)
        val dX = mx - mfStartMidX; val dY = my - mfStartMidY
        if (hypot(dX, dY) < mfSwipePx) return
        mfFired = true
        val horiz = abs(dX) > abs(dY)
        if (fingers == 3) {
            if (horiz) onEvent?.invoke(ControlEvent.SwitchDesktop(
                if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT else ControlEvent.SwitchDesktop.Direction.RIGHT))
            else if (dY < 0) onEvent?.invoke(ControlEvent.MissionControl)
            else             onEvent?.invoke(ControlEvent.AppExpose)
        } else {
            if (horiz) onEvent?.invoke(ControlEvent.FourFingerSwipeH(
                if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT else ControlEvent.SwitchDesktop.Direction.RIGHT))
            else onEvent?.invoke(ControlEvent.FourFingerSwipeV(
                if (dY < 0) ControlEvent.FourFingerSwipeV.VDirection.UP else ControlEvent.FourFingerSwipeV.VDirection.DOWN))
        }
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }

    private fun handleFiveMove(ev: MotionEvent) {
        if (mfFired) return
        val r = if (mfStartSpan > 0) spanAll(ev) / mfStartSpan else 1f
        when {
            r < 0.62f  -> { mfFired = true; onEvent?.invoke(ControlEvent.Launchpad);   performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
            r > 1.48f  -> { mfFired = true; onEvent?.invoke(ControlEvent.ShowDesktop); performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
        }
    }

    // ── Tap (with double/triple-click) ────────────────────────────────────────
    private fun fireTap(x: Float, y: Float) {
        val now  = SystemClock.uptimeMillis()
        val gap1 = now - lastTapT
        val gap2 = now - prevTapT
        val near1 = hypot(x - lastTapX, y - lastTapY) < tapMovePx * 3f
        val near2 = hypot(x - prevTapX,  y - prevTapY)  < tapMovePx * 3f

        performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)

        if (touchscreenMode) {
            val (nx, ny) = normalize(x, y)
            onEvent?.invoke(ControlEvent.MouseAbsolute(nx, ny))
        }

        when {
            // Triple-click
            gap1 < DBLCLICK_MS && near1 && gap2 < DBLCLICK_MS * 2 && near2 && lastTapT > 0L && prevTapT > 0L -> {
                onEvent?.invoke(ControlEvent.MouseTripleClick(ControlEvent.Button.LEFT))
                prevTapT = 0L; lastTapT = 0L
            }
            // Double-click
            gap1 < DBLCLICK_MS && near1 && lastTapT > 0L -> {
                onEvent?.invoke(ControlEvent.MouseDoubleClick(ControlEvent.Button.LEFT))
                prevTapT = lastTapT; prevTapX = lastTapX; prevTapY = lastTapY
                lastTapT = now; lastTapX = x; lastTapY = y
            }
            // Single-click
            else -> {
                onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
                prevTapT = lastTapT; prevTapX = lastTapX; prevTapY = lastTapY
                lastTapT = now; lastTapX = x; lastTapY = y
            }
        }
    }

    private fun evalTwoFingerTap(ev: MotionEvent) {
        val elapsed = SystemClock.uptimeMillis() - sfStartT
        val totalScroll = hypot(tfScrollX, tfScrollY)
        if (elapsed < TAP_MS + 60 && totalScroll < tapMovePx) {
            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        }
    }

    private fun cancelActiveDrag() {
        if (sfAbsDragging || sfDeltaDragging)
            onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
        sfAbsDragging = false; sfDeltaDragging = false
    }

    // ── Geometry ──────────────────────────────────────────────────────────────
    private fun normalize(px: Float, py: Float) = Pair(
        (px / width.coerceAtLeast(1)).coerceIn(0f, 1f),
        (py / height.coerceAtLeast(1)).coerceIn(0f, 1f))
    private fun midAll(ev: MotionEvent): Pair<Float, Float> {
        var sx = 0f; var sy = 0f
        repeat(ev.pointerCount) { sx += ev.getX(it); sy += ev.getY(it) }
        return Pair(sx / ev.pointerCount, sy / ev.pointerCount)
    }
    private fun spanAll(ev: MotionEvent): Float {
        val (mx, my) = midAll(ev); var s = 0f
        repeat(ev.pointerCount) { s += hypot(ev.getX(it) - mx, ev.getY(it) - my) }
        return s / ev.pointerCount
    }
}
