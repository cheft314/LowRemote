import Foundation
import CoreGraphics
import CoreVideo
import IOSurface

/// Captures a display at a configurable frame rate using CGDisplayStream.
final class ScreenCaptureManager {

    private var stream: CGDisplayStream?
    private let callbackQueue = DispatchQueue(label: "LowRemote.Capture", qos: .userInteractive)

    var onFrame: ((CVPixelBuffer) -> Void)?

    // MARK: - Display enumeration

    struct DisplayInfo {
        let id: CGDirectDisplayID
        let name: String
        let size: CGSize
    }

    static func allDisplays() -> [DisplayInfo] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)
        return (0..<Int(count)).compactMap { i in
            let d = displayIDs[i]
            let w = CGDisplayPixelsWide(d)
            let h = CGDisplayPixelsHigh(d)
            guard w > 0, h > 0 else { return nil }
            let name = d == CGMainDisplayID() ? "主屏幕" : "屏幕\(i+1)"
            return DisplayInfo(id: d, name: name, size: CGSize(width: w, height: h))
        }
    }

    static func mainDisplayPixelSize() -> CGSize? {
        let d = CGMainDisplayID()
        let w = CGDisplayPixelsWide(d)
        let h = CGDisplayPixelsHigh(d)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: - Capture

    func start(fps: Int, displayID: CGDirectDisplayID = CGMainDisplayID()) {
        stop()

        let width  = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)
        let minFrameTime = 1.0 / Double(fps)
        let pixelFormat: Int32 = Int32(kCVPixelFormatType_32BGRA)

        let properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime:  minFrameTime,
            CGDisplayStream.showCursor:        true,
            CGDisplayStream.queueDepth:        5,
            CGDisplayStream.preserveAspectRatio: true,
        ]

        guard let s = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth:  width,
            outputHeight: height,
            pixelFormat:  pixelFormat,
            properties:   properties as CFDictionary,
            queue:        callbackQueue,
            handler: { [weak self] status, _, ioSurface, _ in
                guard status == .frameComplete,
                      let surface = ioSurface,
                      let pb = Self.makePixelBuffer(from: surface, width: width, height: height)
                else { return }
                self?.onFrame?(pb)
            }
        ) else {
            NSLog("[Capture] Failed to create CGDisplayStream for display \(displayID)")
            return
        }

        guard s.start() == .success else {
            NSLog("[Capture] CGDisplayStream.start() failed")
            return
        }
        stream = s
        NSLog("[Capture] Started \(width)×\(height) @ \(fps)fps (display \(displayID))")
    }

    func stop() {
        stream?.stop()
        stream = nil
    }

    private static func makePixelBuffer(from surface: IOSurfaceRef,
                                        width: Int, height: Int) -> CVPixelBuffer? {
        var out: Unmanaged<CVPixelBuffer>?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                                     attrs as CFDictionary, &out)
        guard status == kCVReturnSuccess else { return nil }
        return out?.takeRetainedValue()
    }
}
