import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// H.265 (HEVC) 硬件解码器，使用 VideoToolbox VTDecompressionSession
///
/// 设计对齐 Android H265Decoder.kt：
/// - 等待首个含 VPS/SPS/PPS 的 IDR 帧初始化 session
/// - Annex-B 输入（00 00 00 01 起始码）→ 内部转换为 HVCC length-prefixed 格式
/// - 输出 CVPixelBuffer 供 VideoSurfaceView 渲染
///
/// ⚠️ VideoToolbox 不接受 Annex-B start codes！必须转为 4-byte big-endian length prefix。
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
        let s = session
        session = nil
        formatDesc = nil
        started = false
        csdReceived = false
        sessionLock.unlock()

        // Invalidate outside the lock to avoid deadlock with VT callback thread
        if let s = s {
            VTDecompressionSessionInvalidate(s)
        }
    }

    func flush() {
        sessionLock.lock()
        let s = session
        sessionLock.unlock()

        // WaitForAsynchronousFrames outside the lock to prevent deadlock
        if let s = s {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
        }
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

        // 解析并分离 NAL units（不含 start codes）
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

        sessionLock.lock()
        guard let s = session, let fd = formatDesc else {
            sessionLock.unlock()
            return
        }
        sessionLock.unlock()

        // 过滤掉参数集 NAL（VPS/SPS/PPS），只保留 VCL slice NAL units 送入解码器
        let vcls = nals.filter { nal in
            guard !nal.isEmpty else { return false }
            let nalType = (nal[0] >> 1) & 0x3F
            return nalType < 32  // 0-31 = VCL NAL units
        }
        guard !vcls.isEmpty else { return }

        // 将 NAL units 转换为 HVCC 格式（4-byte big-endian length prefix）并组合为 CMBlockBuffer
        guard let blockBuf = nalsToHVCCBlockBuffer(vcls) else { return }

        ptsCounter += 1
        var timing = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp:  CMTime(value: ptsCounter, timescale: CMTimeScale(fps)),
            decodeTimeStamp:        .invalid
        )

        let totalSize = vcls.reduce(0) { $0 + 4 + $1.count }
        var sampleSize = totalSize

        var sampleBuf: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuf
        )
        guard status == noErr, let sb = sampleBuf else {
            NSLog("[H265Decoder] CMSampleBufferCreateReady failed: \(status)")
            return
        }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            s, sampleBuffer: sb, flags: flags, infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _, _ in
            guard let self = self else { return }
            guard status == noErr, let imageBuffer = imageBuffer else {
                if status != noErr {
                    NSLog("[H265Decoder] decode callback error: \(status)")
                }
                return
            }
            self.onDecodedFrame?(imageBuffer)
        }

        if decodeStatus != noErr {
            NSLog("[H265Decoder] VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
        }
    }

    // MARK: - Session management

    private func rebuildSession(formatDesc newDesc: CMVideoFormatDescription) {
        // 停旧的（在锁内但不做 WaitForAsync，直接 Invalidate 避免死锁）
        if let old = session {
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
            // 低延迟：实时解码
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            session = s
            ptsCounter = 0
            NSLog("[H265Decoder] session created %dx%d",
                  CMVideoFormatDescriptionGetDimensions(newDesc).width,
                  CMVideoFormatDescriptionGetDimensions(newDesc).height)
        } else {
            NSLog("[H265Decoder] VTDecompressionSessionCreate failed: \(st)")
        }
        #endif
    }

    // MARK: - HVCC conversion

    /// 将多个 NAL units（不含 start code）转换为 HVCC 格式的 CMBlockBuffer
    /// 每个 NAL 前面加 4 字节大端长度前缀
    private func nalsToHVCCBlockBuffer(_ nals: [Data]) -> CMBlockBuffer? {
        // 计算总大小
        let totalSize = nals.reduce(0) { $0 + 4 + $1.count }

        // 构建连续内存：[4-byte length][NAL body][4-byte length][NAL body]...
        var hvccData = Data(capacity: totalSize)
        for nal in nals {
            // 4-byte big-endian length
            var length = UInt32(nal.count).bigEndian
            hvccData.append(Data(bytes: &length, count: 4))
            hvccData.append(nal)
        }

        // 创建 CMBlockBuffer（必须拷贝数据，因为 hvccData 是栈变量）
        var blockBuf: CMBlockBuffer?
        let status = hvccData.withUnsafeBytes { rawBuf in
            var bb: CMBlockBuffer?
            let st = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,           // let CM allocate
                blockLength: totalSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: totalSize,
                flags: 0,
                blockBufferOut: &bb
            )
            guard st == noErr, let buf = bb else { return st }

            // Copy data into the block buffer
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: buf,
                offsetIntoDestination: 0,
                dataLength: totalSize
            )
            if copyStatus == noErr {
                blockBuf = buf
            }
            return copyStatus
        }
        return status == noErr ? blockBuf : nil
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
