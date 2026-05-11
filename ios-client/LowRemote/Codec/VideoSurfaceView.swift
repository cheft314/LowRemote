import UIKit
import AVFoundation
import VideoToolbox
import SwiftUI

/// 视频渲染视图：接收 CVPixelBuffer，通过 Metal AVSampleBufferDisplayLayer 渲染
/// 保持 16:10 比例（与 Mac 主显示器比例匹配）居中显示，四周留黑边
final class VideoSurfaceView: UIView {

    // MARK: - Layer

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    // MARK: - State

    /// 远端屏幕分辨率（宽, 高），由 RemoteSession 更新
    var remoteSize: CGSize = CGSize(width: 1920, height: 1080) {
        didSet { setNeedsLayout() }
    }

    private var ptsCounter: Int64 = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect          // 保持比例，自动加黑边
        displayLayer.backgroundColor = UIColor.black.cgColor
        // 请求控制时间的时钟 → 立即渲染，延迟最低
        displayLayer.controlTimebase = makeControlTimebase()
    }

    // MARK: - Feed

    /// 由 H265Decoder 回调（任意线程），渲染 CVPixelBuffer
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        ptsCounter += 1
        let pts = CMTime(value: ptsCounter, timescale: 600)

        var timing = CMSampleTimingInfo(
            duration:               .invalid,
            presentationTimeStamp:  pts,
            decodeTimeStamp:        .invalid
        )

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let fd = formatDesc else { return }

        var sampleBuf: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuf
        )
        guard let sb = sampleBuf else { return }

        // 标记为已准备好显示（必须用 kCFBooleanTrue，Swift Bool 会被静默忽略）
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
        if let arr = attachments as? [NSMutableDictionary], let first = arr.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.displayLayer.status == .failed {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sb)
        }
    }

    func flush() {
        DispatchQueue.main.async { self.displayLayer.flush() }
    }

    // MARK: - Layout (保持宽高比，黑边适配)

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = videoFrame(in: bounds, videoSize: remoteSize)
    }

    private func videoFrame(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let aspectW = bounds.width  / videoSize.width
        let aspectH = bounds.height / videoSize.height
        let scale   = min(aspectW, aspectH)
        let w = videoSize.width  * scale
        let h = videoSize.height * scale
        return CGRect(
            x: (bounds.width  - w) / 2,
            y: (bounds.height - h) / 2,
            width:  w,
            height: h
        )
    }

    // MARK: - Timebase

    private func makeControlTimebase() -> CMTimebase? {
        let hostClock = CMClockGetHostTimeClock()
        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: hostClock,
            timebaseOut: &timebase
        ) == noErr else { return nil }
        guard let tb = timebase else { return nil }
        CMTimebaseSetRate(tb, rate: 1.0)
        CMTimebaseSetTime(tb, time: .zero)
        return tb
    }
}

// MARK: - SwiftUI Wrapper

struct VideoSurface: UIViewRepresentable {

    @Binding var remoteSize: CGSize
    var onViewReady: ((VideoSurfaceView) -> Void)?

    func makeUIView(context: Context) -> VideoSurfaceView {
        let v = VideoSurfaceView()
        v.remoteSize = remoteSize
        onViewReady?(v)
        return v
    }

    func updateUIView(_ uiView: VideoSurfaceView, context: Context) {
        uiView.remoteSize = remoteSize
    }
}
