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
 * 布局规则：
 *   • 宽度由父容器给定（撑满右侧剩余宽度）
 *   • 高度 = 宽度 ÷ 1.6，由 onMeasure 自动算出
 *   → 不需要在 Compose 侧指定固定高度，Modifier.fillMaxWidth() 即可
 *
 * 手势识别：
 *   • 1 指滑动   → 鼠标移动（delta 模式，sensitivity 系数）
 *   • 1 指轻点   → 左键单击（< 200ms，位移 < 5dp）
 *   • 1 指长按滑 → 拖拽（按下 500ms 后开始，松手结束）
 *   • 2 指轻点   → 右键单击
 *   • 2 指垂直滑 → 滚轮（每 16dp 一格，自然方向）
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
        /** 宽高比分子：16，分母：10 */
        private const val ASPECT_W = 16
        private const val ASPECT_H = 10
    }

    /** 外部设置事件回调；由 RemoteSession.sendEvent 在 IO 线程派发，此处直接调用即可 */
    var onEvent: ((ControlEvent) -> Unit)? = null

    /** 触控灵敏度倍率 */
    var sensitivity: Float = 1.8f

    private val dp = context.resources.displayMetrics.density
    private val tapMaxMovePx = TAP_MAX_MOVE_DP * dp
    private val scrollThresholdPx = SCROLL_THRESHOLD_DP * dp

    // ── 绘制 ──────────────────────────────────────────────────────────────
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

    // ── 测量 ──────────────────────────────────────────────────────────────
    /**
     * 宽度取父容器给的 exactly/at-most 值；
     * 高度 = 宽度 × (10/16)，严格 16:10。
     */
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val specW = MeasureSpec.getSize(widthMeasureSpec)
        val w = if (specW > 0) specW else suggestedMinimumWidth.coerceAtLeast(1)
        val h = w * ASPECT_H / ASPECT_W
        setMeasuredDimension(w, h)
    }

    override fun onDraw(canvas: Canvas) {
        val inset = 4f * dp
        canvas.drawRoundRect(
            inset, inset, width - inset, height - inset,
            8f * dp, 8f * dp,
            borderPaint,
        )
        canvas.drawText(
            "触控板  ✦  双指右键  ✦  双指滚动",
            width / 2f,
            height / 2f + hintPaint.textSize / 3f,
            hintPaint,
        )
    }

    // ── 手势状态 ──────────────────────────────────────────────────────────
    private var gestureStartTime = 0L
    private var pointer0StartX = 0f
    private var pointer0StartY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var dragActive = false
    private var longPressFireTime = 0L
    private var scrollAccum = 0f

    private enum class Mode { None, Single, Two }
    private var mode = Mode.None

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
                dragActive = false
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

        // 长按超时后开始拖拽
        if (!dragActive &&
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
        // 自然滚动：手指上划 → 内容向上 → wheel +1（Mac 正值=上滚）
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
