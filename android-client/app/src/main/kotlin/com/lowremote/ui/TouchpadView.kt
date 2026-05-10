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
 * 触控板 View —— 严格保持 16:10（1.6:1）宽高比。
 *
 * 手势识别：
 *   • 1 指滑动        → 鼠标移动（delta 模式，sensitivity 系数）
 *   • 1 指轻点        → 左键单击（< 200ms，位移 < 5dp）
 *   • 1 指快速双点     → 左键双击（两次点击间隔 < 300ms）
 *   • 1 指长按滑      → 拖拽（按下 500ms 后开始，松手结束）
 *   • 拖拽锁定开关    → 点击右下角"拖拽"按钮切换锁定模式
 *   • 2 指轻点        → 右键单击
 *   • 2 指垂直滑      → 滚轮（每 16dp 一格，自然方向）
 */
class TouchpadView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    companion object {
        private const val TAP_MAX_MS = 200L
        private const val TAP_MAX_MOVE_DP = 5f
        private const val LONG_PRESS_MS = 500L
        private const val SCROLL_THRESHOLD_DP = 16f
        private const val DOUBLE_TAP_MAX_MS = 300L
        private const val ASPECT_W = 16
        private const val ASPECT_H = 10
    }

    var onEvent: ((ControlEvent) -> Unit)? = null
    var sensitivity: Float = 1.8f

    private val dp = context.resources.displayMetrics.density
    private val tapMaxMovePx = TAP_MAX_MOVE_DP * dp
    private val scrollThresholdPx = SCROLL_THRESHOLD_DP * dp

    // ── Drag-lock state ───────────────────────────────────────────────────────
    /** When true the left button stays held down until the user taps the button again. */
    var dragLocked: Boolean = false
        private set(value) {
            field = value
            invalidate()
        }

    // ── Drawing ────────────────────────────────────────────────────────────────
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(60, 255, 255, 255)
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * dp
    }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(40, 255, 255, 255)
        textSize = 11f * dp
        textAlign = Paint.Align.CENTER
    }
    private val btnPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 10f * dp
        textAlign = Paint.Align.CENTER
    }
    private val btnBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    // ── Measurement ────────────────────────────────────────────────────────────
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val specW = MeasureSpec.getSize(widthMeasureSpec)
        val w = if (specW > 0) specW else suggestedMinimumWidth.coerceAtLeast(1)
        val h = w * ASPECT_H / ASPECT_W
        setMeasuredDimension(w, h)
    }

    // ── Drag-toggle button geometry ────────────────────────────────────────────
    private val btnW get() = 48f * dp
    private val btnH get() = 22f * dp
    private val btnMargin get() = 6f * dp
    private fun btnLeft() = width - btnW - btnMargin
    private fun btnTop() = height - btnH - btnMargin
    private fun btnRight() = width - btnMargin
    private fun btnBottom() = height - btnMargin

    private fun hitsDragButton(x: Float, y: Float) =
        x >= btnLeft() && x <= btnRight() && y >= btnTop() && y <= btnBottom()

    override fun onDraw(canvas: Canvas) {
        val inset = 4f * dp
        canvas.drawRoundRect(
            inset, inset, width - inset, height - inset,
            8f * dp, 8f * dp, borderPaint,
        )
        canvas.drawText(
            "触控板  ✦  双指右键  ✦  双指滚动",
            width / 2f,
            height / 2f + hintPaint.textSize / 3f,
            hintPaint,
        )

        // Drag-lock toggle button (bottom-right corner)
        val bL = btnLeft(); val bT = btnTop(); val bR = btnRight(); val bB = btnBottom()
        btnBgPaint.color = if (dragLocked) Color.argb(200, 74, 144, 226)
                           else Color.argb(120, 50, 50, 50)
        canvas.drawRoundRect(bL, bT, bR, bB, 5f * dp, 5f * dp, btnBgPaint)
        btnPaint.color = Color.WHITE
        canvas.drawText(
            if (dragLocked) "拖拽●" else "拖拽",
            (bL + bR) / 2f,
            bT + (bB - bT) / 2f + btnPaint.textSize / 3f,
            btnPaint,
        )
    }

    // ── Gesture state ──────────────────────────────────────────────────────────
    private var gestureStartTime = 0L
    private var pointer0StartX = 0f
    private var pointer0StartY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var dragActive = false
    private var longPressFireTime = 0L
    private var scrollAccum = 0f

    // Double-tap tracking
    private var lastTapTime = 0L
    private var lastTapX = 0f
    private var lastTapY = 0f

    private enum class Mode { None, Single, Two }
    private var mode = Mode.None

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Drag-lock button takes priority
                if (hitsDragButton(event.x, event.y)) {
                    return true // handled on UP
                }
                mode = Mode.Single
                gestureStartTime = SystemClock.uptimeMillis()
                longPressFireTime = gestureStartTime + LONG_PRESS_MS
                pointer0StartX = event.x
                pointer0StartY = event.y
                lastX = event.x
                lastY = event.y
                if (!dragLocked) dragActive = false
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount == 2) {
                    mode = Mode.Two
                    scrollAccum = 0f
                    lastX = event.getX(1)
                    lastY = event.getY(1)
                }
            }

            MotionEvent.ACTION_MOVE -> when (mode) {
                Mode.Single -> handleSingleMove(event)
                Mode.Two -> handleTwoFingerMove(event)
                Mode.None -> Unit
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (event.pointerCount == 2) {
                    if (mode == Mode.Two) {
                        val elapsed = SystemClock.uptimeMillis() - gestureStartTime
                        if (elapsed < TAP_MAX_MS && abs(scrollAccum) < scrollThresholdPx) {
                            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.RIGHT))
                            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                        }
                    }
                    val remainIdx = if (event.actionIndex == 0) 1 else 0
                    lastX = event.getX(remainIdx)
                    lastY = event.getY(remainIdx)
                    mode = Mode.Single
                }
            }

            MotionEvent.ACTION_UP -> {
                // Drag-lock button tap
                if (hitsDragButton(event.x, event.y)) {
                    toggleDragLock()
                    return true
                }

                val elapsed = SystemClock.uptimeMillis() - gestureStartTime
                if (mode == Mode.Single && !dragActive) {
                    val moved = hypot(event.x - pointer0StartX, event.y - pointer0StartY)
                    if (elapsed < TAP_MAX_MS && moved < tapMaxMovePx) {
                        handleTap(event.x, event.y)
                    }
                } else if (dragActive && !dragLocked) {
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                    dragActive = false
                }
                mode = Mode.None
            }

            MotionEvent.ACTION_CANCEL -> {
                if (dragActive && !dragLocked) {
                    onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
                    dragActive = false
                }
                mode = Mode.None
            }
        }
        return true
    }

    private fun handleTap(x: Float, y: Float) {
        val now = SystemClock.uptimeMillis()
        val timeSinceLast = now - lastTapTime
        val distFromLast = hypot(x - lastTapX, y - lastTapY)

        if (timeSinceLast < DOUBLE_TAP_MAX_MS && distFromLast < tapMaxMovePx * 3f) {
            // Double-tap detected
            onEvent?.invoke(ControlEvent.MouseDoubleClick(ControlEvent.Button.LEFT))
            performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            // Reset so a third tap doesn't re-trigger
            lastTapTime = 0L
        } else {
            onEvent?.invoke(ControlEvent.MouseClick(ControlEvent.Button.LEFT))
            performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            lastTapTime = now
            lastTapX = x
            lastTapY = y
        }
    }

    private fun toggleDragLock() {
        if (dragLocked) {
            // Release the held button
            onEvent?.invoke(ControlEvent.MouseUp(ControlEvent.Button.LEFT))
            dragActive = false
            dragLocked = false
            performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        } else {
            // Engage drag lock: press and hold left button
            onEvent?.invoke(ControlEvent.MouseDown(ControlEvent.Button.LEFT))
            dragActive = true
            dragLocked = true
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
    }

    private fun handleSingleMove(event: MotionEvent) {
        val x = event.x
        val y = event.y
        val dx = x - lastX
        val dy = y - lastY
        lastX = x
        lastY = y

        // Long-press drag (only when drag-lock is not already active)
        if (!dragActive && !dragLocked &&
            SystemClock.uptimeMillis() >= longPressFireTime &&
            hypot(x - pointer0StartX, y - pointer0StartY) < tapMaxMovePx * 3f
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
        val y = event.getY(1)
        val dy = y - lastY
        lastX = event.getX(1)
        lastY = y
        scrollAccum += dy
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
