import Foundation
import CoreGraphics
import CoreVideo
import IOSurface

/// Captures a specific display at a configurable frame rate using CGDisplayStream.
///
/// The callback delivers a CVPixelBuffer backed by the captured IOSurface so the
/// encoder can feed it straight into VideoToolbox without a copy.
final class ScreenCaptureManager {

    private var stream: CGDisplayStream?
    private let callbackQueue = DispatchQueue(label: "LowRemote.Capture", qos: .userInteractive)

    var onFrame: ((CVPixelBuffer) -> Void)?

    /// The display currently being captured (updated by start()).
    private(set) var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    static func mainDisplayPixelSize() -> CGSize? {
        let displayID = CGMainDisplayID()
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Returns the pixel size of the given display, or nil on failure.
    static func pixelSize(of displayID: CGDirectDisplayID) -> CGSize? {
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// All currently-online display IDs.
    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    func start(fps: Int, displayID: CGDirectDisplayID = CGMainDisplayID()) {
        stop()

        activeDisplayID = displayID
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)

        let minFrameTime: Double = 1.0 / Double(fps)
        let pixelFormat: Int32 = Int32(kCVPixelFormatType_32BGRA)

        let properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: minFrameTime,
            CGDisplayStream.showCursor: true,
            CGDisplayStream.queueDepth: 5,
            CGDisplayStream.preserveAspectRatio: true
        ]

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: pixelFormat,
            properties: properties as CFDictionary,
            queue: callbackQueue,
            handler: { [weak self] status, _, ioSurface, _ in
                guard status == .frameComplete,
                      let surface = ioSurface,
                      let pixelBuffer = Self.makePixelBuffer(from: surface,
                                                             width: width,
                                                             height: height)
                else { return }
                self?.onFrame?(pixelBuffer)
            }
        ) else {
            NSLog("[Capture] Failed to create CGDisplayStream for display \(displayID)")
            return
        }

        let result = stream.start()
        if result != .success {
            NSLog("[Capture] CGDisplayStream.start() returned \(result.rawValue)")
            return
        }

        self.stream = stream
        NSLog("[Capture] Started display \(displayID) at \(width)x\(height) @ \(fps)fps")
    }

    func stop() {
        if let s = stream {
            _ = s.stop()
            stream = nil
        }
    }

    /// Wrap an IOSurface in a CVPixelBuffer (no pixel copy).
    private static func makePixelBuffer(from surface: IOSurfaceRef,
                                        width: Int,
                                        height: Int) -> CVPixelBuffer? {
        var pixelBufferOut: Unmanaged<CVPixelBuffer>?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard status == kCVReturnSuccess else {
            NSLog("[Capture] CVPixelBufferCreateWithIOSurface failed: \(status)")
            return nil
        }
        return pixelBufferOut?.takeRetainedValue()
    }
}
