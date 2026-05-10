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
 * 视频渲染 + 触控一体 View。
 *
 * 支持两种模式：
 *
 * ① 触屏模式（touchscreenMode = true）— 默认
 *   • 单指轻点   → 将鼠标移到对应位置，然后左键单击（绝对坐标映射）
 *   • 单指长按   → 右键单击
 *   • 单指拖动   → 鼠标跟随（绝对坐标持续映射）
 *   • 双指滚动   → 滚轮（自然方向）
 *   优点：所见即点击，不需要先找鼠标位置，手机上最直观
 *
 * ② 触控板模式（touchscreenMode = false）
 *   • 与 TouchpadView 完全相同的 delta 手势集，整个视频区作为超大触控板
 *   • 额外支持 2/3/4/5 指手势
 *
 * 坐标映射：
 *   手机触点 (px, py) 相对于 View 尺寸归一化 → 发送 MA:nx,ny 给 Mac
 *   Mac 侧将 (nx, ny) 映射到屏幕像素坐标
 *
 * 注意：SurfaceView 本身负责视频渲染（Surface 交给 MediaCodec）。
 */
class VideoTouchView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : SurfaceView(context, attrs), SurfaceHolder.Callback {

    // ── Surface 回调 ──────────────────────────────────────────────────────────
    var onSurfaceReady: ((android.view.Surface) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null

    var targetAspectWidth: Int  = 16
    var targetAspectHeight: Int = 10

    /** Event callback — called from UI thread. */
    var onEvent: ((ControlEvent) -> Unit)? = null

    /** true = touchscreen (absolute), false = trackpad (delta). */
    var touchscreenMode: Boolean = true

    /** Sensitivity multiplier for delta / trackpad mode. */
    var sensitivity: Float = 2.0f

    init { holder.addCallback(this) }

    override fun surfaceCreated(holder: SurfaceHolder) { onSurfaceReady?.invoke(holder.surface) }
    override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) { onSurfaceDestroyed?.invoke() }

    // ── Touch ─────────────────────────────────────────────────────────────────

    private companion object {
        const val TAP_MS       = 220L
        const val TAP_MOVE_DP  = 10f
        const val LONG_PRESS_MS = 500L
        const val SCROLL_TICK_DP = 14f
    }

    private val dp          = context.resources.displayMetrics.density
    private val tapMovePx   = TAP_MOVE_DP   * dp
    private val scrollTickPx = SCROLL_TICK_DP * dp

    // Single-finger state
    private var sfStartX = 0f; private var sfStartY = 0f
    private var sfLastX  = 0f; private var sfLastY  = 0f
    private var sfStartT = 0L
    private var sfLongT  = 0L
    private var sfDragging = false   // absolute drag (touchscreen mode)
    private var sfDeltaDragging = false  // delta drag (trackpad mode)

    // Two-finger scroll
    private var tfLastMidX = 0f; private var tfLastMidY = 0f
    private var tfScrollX  = 0f; private var tfScrollY  = 0f

    // Multi-finger (3/4/5) — delegated to a small embedded copy of the logic
    private var fingerCount = 0
    private var mfStartMidX = 0f; private var mfStartMidY = 0f
    private var mfStartSpan = 0f
    private var mfFired = false

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val count = event.pointerCount
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                fingerCount = 1
                sfStartX = event.x; sfStartY = event.y
                sfLastX  = event.x; sfLastY  = event.y
                sfStartT = SystemClock.uptimeMillis()
                sfLongT  = sfStartT + LONG_PRESS_MS
                sfDragging = false; sfDeltaDragging = false
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                fingerCount = count
                when (count) {
                    2 -> {
                        val mx = (event.getX(0) + event.getX(1)) / 2f
                        val my = (event.getY(0) + event.getY(1)) / 2f
                        tfLastMidX = mx; tfLastMidY = my
                        tfScrollX = 0f; tfScrollY = 0f
                        if (sfDragging) {
                            onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                            sfDragging = false
                        }
                        if (sfDeltaDragging) {
                            onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                            sfDeltaDragging = false
                        }
                    }
                    3, 4 -> {
                        val m = midpointAll(event)
                        mfStartMidX = m.first; mfStartMidY = m.second; mfFired = false
                    }
                    5 -> {
                        mfStartSpan = spanAll(event); mfFired = false
                    }
                }
            }
            MotionEvent.ACTION_MOVE -> when (fingerCount) {
                1 -> handleOneMove(event)
                2 -> handleTwoMove(event)
                3, 4 -> handleMultiMove(event, fingerCount)
                5 -> handleFiveMove(event)
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (count - 1 < fingerCount) {
                    if (fingerCount == 2) {
                        val elapsed = SystemClock.uptimeMillis() - sfStartT
                        val totalScroll = hypot(tfScrollX, tfScrollY)
                        if (elapsed < TAP_MS && totalScroll < tapMovePx) {
                            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
                            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                        }
                    }
                    fingerCount = count - 1
                    if (fingerCount == 1) {
                        val idx = if (event.actionIndex == 0) 1 else 0
                        sfLastX = event.getX(idx); sfLastY = event.getY(idx)
                    }
                }
            }
            MotionEvent.ACTION_UP -> {
                val elapsed = SystemClock.uptimeMillis() - sfStartT
                val moved   = hypot(event.x - sfStartX, event.y - sfStartY)
                when {
                    sfDragging -> {
                        onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                        sfDragging = false
                    }
                    sfDeltaDragging -> {
                        onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                        sfDeltaDragging = false
                    }
                    fingerCount == 1 && elapsed < TAP_MS && moved < tapMovePx -> {
                        if (touchscreenMode) {
                            // Absolute: move then click
                            val (nx, ny) = normalize(event.x, event.y)
                            onEvent?.invoke(ControlEvent.MouseAbsolute(nx, ny))
                            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
                        } else {
                            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
                        }
                        performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    }
                }
                fingerCount = 0
            }
            MotionEvent.ACTION_CANCEL -> {
                if (sfDragging || sfDeltaDragging)
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                sfDragging = false; sfDeltaDragging = false; fingerCount = 0
            }
        }
        return true
    }

    private fun handleOneMove(event: MotionEvent) {
        val now = SystemClock.uptimeMillis()

        if (touchscreenMode) {
            // Long-press → right-click
            if (!sfDragging && now >= sfLongT &&
                hypot(event.x - sfStartX, event.y - sfStartY) < tapMovePx * 2f) {
                sfDragging = true  // re-using flag as "long press fired"
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
                return
            }
            // Continuous drag: keep sending absolute position
            val (nx, ny) = normalize(event.x, event.y)
            onEvent?.invoke(ControlEvent.MouseAbsolute(nx, ny))
        } else {
            // Trackpad mode: delta
            if (!sfDeltaDragging && now >= sfLongT &&
                hypot(event.x - sfStartX, event.y - sfStartY) < tapMovePx * 4f) {
                sfDeltaDragging = true
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                onEvent?.invoke(ControlEvent.MouseDown(ControlEvent.Button.LEFT))
            }
            val dx = event.x - sfLastX
            val dy = event.y - sfLastY
            if (dx != 0f || dy != 0f)
                onEvent?.invoke(ControlEvent.MouseMove(dx * sensitivity, dy * sensitivity))
        }
        sfLastX = event.x; sfLastY = event.y
    }

    private fun handleTwoMove(event: MotionEvent) {
        val mx  = (event.getX(0) + event.getX(1)) / 2f
        val my  = (event.getY(0) + event.getY(1)) / 2f
        val dX  = mx - tfLastMidX
        val dY  = my - tfLastMidY
        tfLastMidX = mx; tfLastMidY = my
        tfScrollX += dX; tfScrollY += dY
        while (tfScrollY <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(1));  tfScrollY += scrollTickPx }
        while (tfScrollY >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheel(-1)); tfScrollY -= scrollTickPx }
        while (tfScrollX <= -scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(1));  tfScrollX += scrollTickPx }
        while (tfScrollX >=  scrollTickPx) { onEvent?.invoke(ControlEvent.MouseWheelH(-1)); tfScrollX -= scrollTickPx }
    }

    private fun handleMultiMove(event: MotionEvent, fingers: Int) {
        if (mfFired) return
        val m  = midpointAll(event)
        val dX = m.first  - mfStartMidX
        val dY = m.second - mfStartMidY
        val dist = hypot(dX, dY)
        if (dist < 38f * dp) return
        mfFired = true
        val horizontal = abs(dX) > abs(dY)
        if (fingers == 3) {
            if (horizontal) {
                val dir = if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT
                          else        ControlEvent.SwitchDesktop.Direction.RIGHT
                onEvent?.invoke(ControlEvent.SwitchDesktop(dir))
            } else {
                if (dY < 0) onEvent?.invoke(ControlEvent.MissionControl)
                else        onEvent?.invoke(ControlEvent.AppExpose)
            }
        } else {
            if (horizontal) {
                val dir = if (dX < 0) ControlEvent.SwitchDesktop.Direction.LEFT
                          else        ControlEvent.SwitchDesktop.Direction.RIGHT
                onEvent?.invoke(ControlEvent.FourFingerSwipeH(dir))
            } else {
                val vd = if (dY < 0) ControlEvent.FourFingerSwipeV.VDirection.UP
                         else        ControlEvent.FourFingerSwipeV.VDirection.DOWN
                onEvent?.invoke(ControlEvent.FourFingerSwipeV(vd))
            }
        }
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }

    private fun handleFiveMove(event: MotionEvent) {
        if (mfFired) return
        val cur = spanAll(event)
        val r   = if (mfStartSpan > 0) cur / mfStartSpan else 1f
        if (r < 0.65f)      { mfFired = true; onEvent?.invoke(ControlEvent.Launchpad);    performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
        else if (r > 1.45f) { mfFired = true; onEvent?.invoke(ControlEvent.ShowDesktop);  performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Normalize touch coordinate to [0,1] within this view's bounds. */
    private fun normalize(px: Float, py: Float): Pair<Float, Float> {
        val w = width.coerceAtLeast(1)
        val h = height.coerceAtLeast(1)
        return Pair(
            (px / w).coerceIn(0f, 1f),
            (py / h).coerceIn(0f, 1f),
        )
    }

    private fun midpointAll(ev: MotionEvent): Pair<Float, Float> {
        var sx = 0f; var sy = 0f
        for (i in 0 until ev.pointerCount) { sx += ev.getX(i); sy += ev.getY(i) }
        return Pair(sx / ev.pointerCount, sy / ev.pointerCount)
    }

    private fun spanAll(ev: MotionEvent): Float {
        val m = midpointAll(ev); var sum = 0f
        for (i in 0 until ev.pointerCount) sum += hypot(ev.getX(i) - m.first, ev.getY(i) - m.second)
        return sum / ev.pointerCount
    }
}
