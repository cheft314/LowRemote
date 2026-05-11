import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import AVFoundation

/// H.265 (HEVC) 解码器 —— 直接喂 compressed CMSampleBuffer 给 AVSampleBufferDisplayLayer
///
/// 架构（对比旧版 VTDecompressionSession 方案）：
///
///   旧版：Annex-B → splitNAL → HVCC → CMBlockBuffer → VTDecompressionSession
///         → CVPixelBuffer → VideoSurfaceView.enqueue → AVSampleBufferDisplayLayer
///
///   新版：Annex-B → splitNAL → HVCC → CMBlockBuffer → CMSampleBuffer (compressed)
///         → AVSampleBufferDisplayLayer.enqueue  ← layer 自己负责解码+渲染
///
/// 优点：
///   · AVSampleBufferDisplayLayer 在模拟器走软件解码，真机走硬件，无需区分环境
///   · 模拟器上不再走 #if targetEnvironment(simulator) return 分支
///   · 减少 VTDecompressionSession 的竞态/死锁/回调线程问题
///   · 与 Android MediaCodec + Surface 设计思路完全对应
/// 设计对齐 Android H265Decoder.kt：
/// - 等待首个含 VPS/SPS/PPS 的 IDR 帧初始化 session
/// - Annex-B 输入（00 00 00 01 起始码）→ 内部转换为 HVCC length-prefixed 格式
/// - 输出 CVPixelBuffer 供 VideoSurfaceView 渲染
///
/// ⚠️ VideoToolbox 不接受 Annex-B start codes！必须转为 4-byte big-endian length prefix。
final class H265Decoder {

    // MARK: - Public interface

    /// 设置渲染目标 layer（H265Decoder 直接 enqueue compressed CMSampleBuffer）
    weak var displayLayer: AVSampleBufferDisplayLayer?

    // MARK: - State

    private var formatDesc: CMVideoFormatDescription?
    private var started = false
    private var csdReceived = false
    private var ptsCounter: Int64 = 0
    private let fps: Int

    private let lock = NSLock()

    init(fps: Int = 60) {
        self.fps = fps
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        started = true
        csdReceived = false
        ptsCounter = 0
        lock.unlock()
        NSLog("[H265Decoder] started (fps=\(fps))")
    }

    func stop() {
        lock.lock()
        started = false
        csdReceived = false
        formatDesc = nil
        ptsCounter = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer?.flush()
        }
        NSLog("[H265Decoder] stopped")
    }

    func flush() {
        lock.lock()
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
        ptsCounter = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer?.flush()
        }
    }

    // MARK: - Feed

    /// 送入完整 Annex-B 帧（含 start codes），转换后推给 AVSampleBufferDisplayLayer
    func feed(data: Data, isKeyframe: Bool) {
        lock.lock()
        guard started else { lock.unlock(); return }
        lock.unlock()

        // 等待首个含参数集的帧
        if !csdReceived {
            guard isKeyframe || looksLikeParameterSet(data) else { return }
            lock.lock()
            csdReceived = true
            lock.unlock()
        }

        // 解析并分离 NAL units（不含 start codes）
        let nals = splitAnnexB(data)
        if nals.isEmpty {
            NSLog("[H265Decoder] splitAnnexB empty, data.count=\(data.count)")
            return
        }

        // 若是关键帧则更新 formatDescription（从 VPS/SPS/PPS 参数集构建）
        if isKeyframe {
            if let newDesc = buildFormatDescription(from: nals) {
                lock.lock()
                let needRebuild = formatDesc == nil ||
                    !CMFormatDescriptionEqual(formatDesc!, otherFormatDescription: newDesc)
                if needRebuild {
                    formatDesc = newDesc
                    ptsCounter = 0
                    NSLog("[H265Decoder] formatDesc updated %dx%d",
                          CMVideoFormatDescriptionGetDimensions(newDesc).width,
                          CMVideoFormatDescriptionGetDimensions(newDesc).height)
                }
                lock.unlock()
            } else {
                NSLog("[H265Decoder] buildFormatDescription failed, NAL count=\(nals.count)")
            }
        }

        lock.lock()
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
        let pts = ptsCounter
        lock.unlock()

        // 过滤掉参数集 NAL（VPS/SPS/PPS），只保留 VCL slice NAL units
        let vcls = nals.filter { nal in
            guard !nal.isEmpty else { return false }
            let nalType = (nal[0] >> 1) & 0x3F
            return nalType < 32  // 0-31 = VCL NAL units
        }
        guard !vcls.isEmpty else { return }  // 纯参数集帧，无需解码

        // 将 VCL NAL units 转换为 HVCC 格式（4-byte big-endian length prefix）
        guard let blockBuf = nalsToHVCCBlockBuffer(vcls) else {
            NSLog("[H265Decoder] nalsToHVCCBlockBuffer failed")
            return
        }

        var timing = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp:  CMTime(value: pts, timescale: CMTimeScale(fps)),
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

        // 标记立即显示
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
        if let arr = attachments as? [NSMutableDictionary], let first = arr.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }

        // 推给 AVSampleBufferDisplayLayer（含压缩 HEVC 数据，layer 内部解码+渲染）
        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.displayLayer else {
                NSLog("[H265Decoder] displayLayer is nil, frame dropped")
                return
            }
            if layer.status == .failed {
                NSLog("[H265Decoder] displayLayer.status=failed, flushing")
                layer.flush()
            }
            if layer.isReadyForMoreMediaData {
                layer.enqueue(sb)
            } else {
                NSLog("[H265Decoder] displayLayer not ready for more data")
            }
        // 闭包回调：`VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)`
        //（对应 VTDecompressionSessionDecodeFrameWithOutputHandler；勿加 frameOptions——带 frameOptions 的重载仅在 iOS 18+）。
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            s,
            sampleBuffer: sb,
            flags: flags,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
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

    // MARK: - HVCC conversion

    /// 将多个 NAL units（不含 start code）转换为 HVCC 格式的 CMBlockBuffer
    private func nalsToHVCCBlockBuffer(_ nals: [Data]) -> CMBlockBuffer? {
        let totalSize = nals.reduce(0) { $0 + 4 + $1.count }
        var hvccData = Data(capacity: totalSize)
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            hvccData.append(Data(bytes: &length, count: 4))
            hvccData.append(nal)
    private func rebuildSession(formatDesc newDesc: CMVideoFormatDescription) {
        // 停旧的（在锁内但不做 WaitForAsync，直接 Invalidate 避免死锁）
        if let old = session {
            VTDecompressionSessionInvalidate(old)
            session = nil
        }

        var blockBuf: CMBlockBuffer?
        let status = hvccData.withUnsafeBytes { rawBuf in
            var bb: CMBlockBuffer?
            let st = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: totalSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: totalSize,
                flags: 0,
                blockBufferOut: &bb
            )
            guard st == noErr, let buf = bb else { return st }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: buf,
                offsetIntoDestination: 0,
                dataLength: totalSize
            )
            if copyStatus == noErr { blockBuf = buf }
            return copyStatus
        }
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

    private func buildFormatDescription(from nals: [Data]) -> CMVideoFormatDescription? {
        var vps: Data?; var sps: Data?; var pps: Data?
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
                    var sizes = [v.count, s.count, p.count]
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
                    if j+3 < bytes.count && bytes[j+2] == 0 && bytes[j+3] == 1 { return j }
                }
                j += 1
            }
            return nil
        }

        while i < bytes.count {
            if i+3 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==0 && bytes[i+3]==1 {
                i += 4
            } else if i+2 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==1 {
                i += 3
            } else { i += 1; continue }
            let start = i
            let end = findNextStartCode(from: i) ?? bytes.count
            if end > start { nals.append(Data(bytes[start..<end])) }
            i = end
        }
        return nals
    }

    private func looksLikeParameterSet(_ data: Data) -> Bool {
        var i = 0
        let bytes = [UInt8](data)
        if bytes.count > 4 && bytes[0]==0 && bytes[1]==0 && bytes[2]==0 && bytes[3]==1 { i = 4 }
        else if bytes.count > 3 && bytes[0]==0 && bytes[1]==0 && bytes[2]==1 { i = 3 }
        else { return false }
        guard i < bytes.count else { return false }
        let nalType = (bytes[i] >> 1) & 0x3F
        return nalType >= 32 && nalType <= 34
    }
}
