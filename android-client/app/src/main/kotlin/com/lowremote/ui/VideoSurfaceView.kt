package com.lowremote.ui

import android.content.Context
import android.util.AttributeSet
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * 视频渲染 SurfaceView。
 *
 * 不做任何比例裁剪 —— 父容器（BoxWithConstraints）已经把宽度算成了
 * screenHeight × 1.6，直接撑满即可。MediaCodec 会把帧缩放到 Surface 尺寸。
 *
 * [targetAspectWidth] / [targetAspectHeight] 保留供将来扩展，目前不影响测量。
 */
class VideoSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : SurfaceView(context, attrs), SurfaceHolder.Callback {

    var targetAspectWidth: Int = 16
    var targetAspectHeight: Int = 10

    var onSurfaceReady: ((android.view.Surface) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null

    init {
        holder.addCallback(this)
    }

    // 不覆盖 onMeasure —— 让 Compose Modifier.fillMaxSize() 完全控制尺寸，
    // 这样 SurfaceView 就是父容器的精确大小，不做额外裁剪。

    override fun surfaceCreated(holder: SurfaceHolder) {
        onSurfaceReady?.invoke(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // MediaCodec 的输出会自动缩放到新的 Surface 尺寸，无需额外处理。
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        onSurfaceDestroyed?.invoke()
    }
}
