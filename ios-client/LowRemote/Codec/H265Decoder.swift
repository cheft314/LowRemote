import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// H.265 (HEVC) 硬件解码器，使用 VideoToolbox VTDecompressionSession
///
/// 设计对齐 Android H265Decoder.kt：
/// - 等待首个含 VPS/SPS/PPS 的 IDR 帧初始化 session
/// - Annex-B 输入（00 00 00 01 起始码）
/// - 输出 CVPixelBuffer 供 VideoSurfaceView 渲染
final class H265Decoder {

    // MARK: - Public interface

    /// 解码完成回调（在 VideoToolbox 线程调用，需自行切主线程）
    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    // MARK: - State

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var started = false
    private var csdReceived = false
    private var ptsCounter: Int64 = 0
    private let fps: Int

    private let sessionLock = NSLock()

    init(fps: Int = 60) {
        self.fps = fps
    }

    // MARK: - Lifecycle

    func start() {
        started = true
        csdReceived = false
    }

    func stop() {
        sessionLock.lock()
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session     = nil
        formatDesc  = nil
        started     = false
        csdReceived = false
        sessionLock.unlock()
    }

    func flush() {
        sessionLock.lock()
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s) }
        sessionLock.unlock()
        csdReceived = false
    }

    // MARK: - Feed

    /// 送入完整 Annex-B 帧（含 start codes）
    func feed(data: Data, isKeyframe: Bool) {
        guard started else { return }

        // 等待首个含参数集的帧
        if !csdReceived {
            guard isKeyframe || looksLikeParameterSet(data) else { return }
            csdReceived = true
        }

        // 解析并分离 NAL units
        let nals = splitAnnexB(data)
        if nals.isEmpty { return }

        // 若是关键帧则尝试（重）建 session
        if isKeyframe {
            if let newDesc = buildFormatDescription(from: nals) {
                sessionLock.lock()
                let needRebuild = formatDesc == nil ||
                    !CMFormatDescriptionEqual(formatDesc!, otherFormatDescription: newDesc)
                if needRebuild {
                    rebuildSession(formatDesc: newDesc)
                }
                sessionLock.unlock()
            }
        }

        guard let s = session, let fd = formatDesc else { return }

        // 将 Annex-B 数据转换为 AVCC CMBlockBuffer，送入解码器
        guard let blockBuf = annexBToBlockBuffer(data) else { return }

        ptsCounter += 1
        var timing = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp:  CMTime(value: ptsCounter, timescale: CMTimeScale(fps)),
            decodeTimeStamp:        .invalid
        )

        var sampleBuf: CMSampleBuffer?
        var size = data.count
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuf
        )
        guard status == noErr, let sb = sampleBuf else { return }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
        _ = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: flags, infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else { return }
            self.onDecodedFrame?(imageBuffer)
        }
    }

    // MARK: - Session management

    private func rebuildSession(formatDesc newDesc: CMVideoFormatDescription) {
        // 停旧的
        if let old = session {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
            session = nil
        }
        formatDesc = newDesc

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:   kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var s: VTDecompressionSession?

        // 模拟器没有 HEVC 硬件解码器，强制请求硬件会阻塞/卡死，加以提示后直接返回
        #if targetEnvironment(simulator)
        NSLog("[H265Decoder] ⚠️ 运行在模拟器，H.265 硬件解码不可用，请在真机上测试视频流功能")
        return
        #else
        // Session must use nil outputCallback when using closure-based VTDecompressionSessionDecodeFrame.
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newDesc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &s
        )
        if st == noErr, let s = s {
            // 低延迟
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            session = s
            NSLog("[H265Decoder] session created %dx%d",
                  CMVideoFormatDescriptionGetDimensions(newDesc).width,
                  CMVideoFormatDescriptionGetDimensions(newDesc).height)
        } else {
            NSLog("[H265Decoder] VTDecompressionSessionCreate failed: \(st)")
        }
        #endif
    }

    // MARK: - Annex-B helpers

    /// 提取 Annex-B 流中的 parameter sets (VPS/SPS/PPS) 并构建 CMVideoFormatDescription
    private func buildFormatDescription(from nals: [Data]) -> CMVideoFormatDescription? {
        var vps: Data? = nil
        var sps: Data? = nil
        var pps: Data? = nil

        for nal in nals {
            guard !nal.isEmpty else { continue }
            let nalType = (nal[0] >> 1) & 0x3F
            switch nalType {
            case 32: vps = nal
            case 33: sps = nal
            case 34: pps = nal
            default: break
            }
        }
        guard let v = vps, let s = sps, let p = pps else { return nil }

        return v.withUnsafeBytes { vPtr in
            s.withUnsafeBytes { sPtr in
                p.withUnsafeBytes { pPtr in
                    let ptrs: [UnsafePointer<UInt8>] = [
                        vPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        sPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        pPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    var sizes: [Int] = [v.count, s.count, p.count]
                    var desc: CMVideoFormatDescription?
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: ptrs,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )
                    return desc
                }
            }
        }
    }

    /// Annex-B → CMBlockBuffer（保留 start codes，VT 需要）
    private func annexBToBlockBuffer(_ data: Data) -> CMBlockBuffer? {
        var blockBuf: CMBlockBuffer?
        let status = data.withUnsafeBytes { rawBuf in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: rawBuf.baseAddress!),
                blockLength: data.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuf
            )
        }
        return status == noErr ? blockBuf : nil
    }

    /// 按 00 00 00 01 或 00 00 01 分割 Annex-B，返回不含 start code 的 NAL 列表
    private func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        let bytes = [UInt8](data)
        var i = 0

        func findNextStartCode(from offset: Int) -> Int? {
            var j = offset
            while j + 2 < bytes.count {
                if bytes[j] == 0 && bytes[j+1] == 0 {
                    if bytes[j+2] == 1 { return j }
                    if j + 3 < bytes.count && bytes[j+2] == 0 && bytes[j+3] == 1 { return j }
                }
                j += 1
            }
            return nil
        }

        while i < bytes.count {
            // skip start code
            if i + 3 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                i += 4
            } else if i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                i += 3
            } else {
                i += 1
                continue
            }
            let start = i
            let end = findNextStartCode(from: i) ?? bytes.count
            if end > start {
                nals.append(Data(bytes[start..<end]))
            }
            i = end
        }
        return nals
    }

    /// 启发式：blob 以 VPS/SPS/PPS NAL 开头 → 可当 CSD 使用
    private func looksLikeParameterSet(_ data: Data) -> Bool {
        var i = 0
        let bytes = [UInt8](data)
        if bytes.count > 4 && bytes[0]==0 && bytes[1]==0 && bytes[2]==0 && bytes[3]==1 { i = 4 }
        else if bytes.count > 3 && bytes[0]==0 && bytes[1]==0 && bytes[2]==1 { i = 3 }
        else { return false }
        guard i < bytes.count else { return false }
        let nalType = (bytes[i] >> 1) & 0x3F
        return nalType >= 32 && nalType <= 34   // VPS=32, SPS=33, PPS=34
    }
}
