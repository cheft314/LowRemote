import UIKit
import AVFoundation
import SwiftUI

/// 视频渲染视图：AVSampleBufferDisplayLayer 直接接受压缩的 HEVC CMSampleBuffer
/// H265Decoder 把 Annex-B 转换成 HVCC CMSampleBuffer 后直接 enqueue 到这个 layer，
/// layer 内部自动完成解码（模拟器走软件解码，真机走硬件解码）+ 渲染。
final class VideoSurfaceView: UIView {

    // MARK: - Layer

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    /// 暴露给 H265Decoder 直接 enqueue compressed CMSampleBuffer
    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    // MARK: - State

    var remoteSize: CGSize = CGSize(width: 1920, height: 1080) {
        didSet { setNeedsLayout() }
    }

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
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        // 不设置 controlTimebase，由 DisplayImmediately attachment 负责立即渲染
        // 不使用 controlTimebase：直接依赖 kCMSampleAttachmentKey_DisplayImmediately
        // 使用 controlTimebase + time=0 时，HostTimeClock 已运行数万秒，
        // PTS 从 1/600 开始的帧全部被认为是"过期帧"而丢弃。
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

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = fitRect(in: bounds, videoSize: remoteSize)
    }

    private func fitRect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width  * scale
        let h = videoSize.height * scale
        return CGRect(x: (bounds.width-w)/2, y: (bounds.height-h)/2, width: w, height: h)
    }

    // MARK: - Timebase（已移除，改用 DisplayImmediately 直接渲染）
    // controlTimebase + CMTimebaseSetTime(time: .zero) 与 HostTimeClock 不兼容：
    // 系统时钟已运行数万秒，PTS 从 1/600 起的帧全被判为过期。
    // 使用 kCMSampleAttachmentKey_DisplayImmediately = kCFBooleanTrue 即可立即渲染。
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
