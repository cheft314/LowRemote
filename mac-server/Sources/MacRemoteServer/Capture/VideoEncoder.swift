import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Low-latency H.265 (HEVC) hardware encoder using VideoToolbox.
///
/// Output is an Annex-B (start-code prefixed) byte stream — the format Android's
/// MediaCodec expects. For keyframes we emit VPS/SPS/PPS before the IDR NAL so
/// the decoder can initialise without needing an out-of-band csd exchange.
final class VideoEncoder {

    private let width: Int
    private let height: Int
    private let fps: Int
    private let bitrate: Int

    private var session: VTCompressionSession?
    private var lastParameterSets: Data? // cached VPS+SPS+PPS in Annex-B form
    private var frameTimestamp: Int64 = 0

    /// Called on VideoToolbox's callback thread. Don't block here for long.
    var onEncodedFrame: ((Data, Bool) -> Void)?

    init(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.encoderCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionOut
        )
        guard status == noErr, let session = sessionOut else {
            NSLog("[Encoder] VTCompressionSessionCreate failed: \(status)")
            return false
        }
        self.session = session

        configureSession(session)

        VTCompressionSessionPrepareToEncodeFrames(session)
        return true
    }

    func stop() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, until: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: - Configuration

    private func configureSession(_ session: VTCompressionSession) {
        func setProp(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }

        setProp(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        setProp(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        setProp(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        setProp(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        setProp(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)

        // Keyframe every 2 seconds — refreshes reference frames for late joiners
        // and recovers from UDP packet loss.
        let keyframeInterval = fps * 2
        setProp(kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeInterval as CFNumber)
        setProp(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)

        // Cap data rate: [byteLimit, windowSeconds]. This is a hard ceiling on top of
        // the AverageBitRate target — useful on congested Wi-Fi.
        let byteLimitPerSecond = bitrate / 8
        setProp(kVTCompressionPropertyKey_DataRateLimits,
                [byteLimitPerSecond * 2, 1] as CFArray)
    }

    // MARK: - Encode

    func encode(pixelBuffer: CVPixelBuffer) {
        guard let session = session else { return }
        frameTimestamp &+= 1
        let pts = CMTime(value: frameTimestamp, timescale: CMTimeScale(fps))
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    // MARK: - VT callback

    private static let encoderCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon = refcon else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr, let sampleBuffer = sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        encoder.handleEncoded(sampleBuffer)
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var output = Data()

        // On keyframes, prepend VPS+SPS+PPS so the decoder can init mid-stream.
        if isKeyframe, let parameterSets = extractHEVCParameterSetsAnnexB(sampleBuffer) {
            lastParameterSets = parameterSets
            output.append(parameterSets)
        }

        // Append the frame itself, converted from AVCC (4-byte length prefixes)
        // to Annex-B (start codes).
        if let annexB = convertAVCCtoAnnexB(sampleBuffer) {
            output.append(annexB)
        }

        guard !output.isEmpty else { return }
        onEncodedFrame?(output, isKeyframe)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return false
        }
        // If NotSync is absent or false → this is a sync sample (keyframe).
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    /// Extract VPS/SPS/PPS from the sample buffer's format description and emit
    /// them as a single Annex-B framed blob.
    private func extractHEVCParameterSetsAnnexB(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        var setCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &setCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard countStatus == noErr, setCount > 0 else { return nil }

        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        for i in 0..<setCount {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: i,
                parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if s == noErr, let ptr = ptr {
                out.append(contentsOf: startCode)
                out.append(UnsafeBufferPointer(start: ptr, count: size))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Convert AVCC (length-prefixed) NALs in the sample buffer's data to
    /// Annex-B (start-code prefixed).
    private func convertAVCCtoAnnexB(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let src = dataPointer else { return nil }

        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        out.reserveCapacity(totalLength + 16)

        var offset = 0
        while offset + 4 <= totalLength {
            // AVCC length is big-endian 4-byte
            var len: UInt32 = 0
            memcpy(&len, src.advanced(by: offset), 4)
            len = UInt32(bigEndian: len)
            let nalLen = Int(len)
            guard nalLen > 0, offset + 4 + nalLen <= totalLength else { break }

            out.append(contentsOf: startCode)
            src.advanced(by: offset + 4).withMemoryRebound(to: UInt8.self, capacity: nalLen) { p in
                out.append(UnsafeBufferPointer(start: p, count: nalLen))
            }
            offset += 4 + nalLen
        }
        return out
    }
}
