package com.lowremote.ui

import android.content.Context
import android.util.AttributeSet
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * SurfaceView that keeps a 16:10 aspect ratio inside whatever bounds Compose
 * gives us, letter/pillar-boxing the rest as black.
 *
 * Exposes a simple listener so [RemoteSession] can swap in the current
 * Android `Surface` as the decoder's render target.
 */
class VideoSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : SurfaceView(context, attrs), SurfaceHolder.Callback {

    /** Aspect ratio target. Kept configurable so we can adapt to the Mac's real screen ratio later. */
    var targetAspectWidth: Int = 16
    var targetAspectHeight: Int = 10

    var onSurfaceReady: ((android.view.Surface) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null

    init {
        holder.addCallback(this)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val availW = MeasureSpec.getSize(widthMeasureSpec)
        val availH = MeasureSpec.getSize(heightMeasureSpec)
        if (availW <= 0 || availH <= 0) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            return
        }

        val targetW: Int
        val targetH: Int
        if (availW * targetAspectHeight > availH * targetAspectWidth) {
            // Space is wider than target ratio → pillar-box.
            targetH = availH
            targetW = availH * targetAspectWidth / targetAspectHeight
        } else {
            // Space is taller than target ratio → letter-box.
            targetW = availW
            targetH = availW * targetAspectHeight / targetAspectWidth
        }
        setMeasuredDimension(targetW, targetH)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        onSurfaceReady?.invoke(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // Nothing — decoder will scale to fit.
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        onSurfaceDestroyed?.invoke()
    }
}
