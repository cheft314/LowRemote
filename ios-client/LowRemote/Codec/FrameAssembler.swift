import Foundation

/// UDP 分片重组器，完整对齐 Android FrameAssembler.kt
///
/// 以 frameId 为 key 收集同一帧的所有分片，全部到齐后回调 onFrameReady。
/// 超时帧（默认 50ms，比 Android 8ms 宽松以适配 iOS 调度）自动清除。
final class FrameAssembler {

    // MARK: - Config
    private let timeoutMs: Int64 = 50
    private let maxPendingFrames = 32

    // MARK: - State
    private var frames: [UInt32: FrameBuffer] = [:]
    private let lock  = NSLock()
    private var lastEvictTime: Int64 = 0

    /// (完整帧字节, 是否关键帧) → 解码器
    var onFrameReady: ((Data, Bool) -> Void)?

    // MARK: - Public

    func onPacket(_ parsed: Packet.Parsed, _ payload: Data) {
        let now = currentMs()

        lock.lock()
        // 定期清过期帧（每 100ms 一次）
        if now - lastEvictTime > 100 {
            evictExpired(now: now)
            lastEvictTime = now
        }

        let fid = parsed.frameId
        if frames[fid] == nil {
            // 防止无限增长
            if frames.count >= maxPendingFrames { evictOldest() }
            frames[fid] = FrameBuffer(total: Int(parsed.pktTotal),
                                      isKeyframe: parsed.isKeyframe,
                                      createdAt: now)
        }

        let buf = frames[fid]!
        buf.put(index: Int(parsed.pktIdx), data: payload)

        if buf.isComplete {
            frames.removeValue(forKey: fid)
            lock.unlock()
            if let assembled = buf.assemble() {
                onFrameReady?(assembled, buf.isKeyframe)
            }
            return
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func evictExpired(now: Int64) {
        frames = frames.filter { now - $0.value.createdAt <= timeoutMs }
    }

    private func evictOldest() {
        guard let oldest = frames.min(by: { $0.value.createdAt < $1.value.createdAt }) else { return }
        frames.removeValue(forKey: oldest.key)
    }

    private func currentMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - FrameBuffer

private final class FrameBuffer {
    let total:      Int
    let isKeyframe: Bool
    let createdAt:  Int64

    private var slots:    [Data?]
    private var received: Int = 0

    init(total: Int, isKeyframe: Bool, createdAt: Int64) {
        self.total      = max(total, 1)
        self.isKeyframe = isKeyframe
        self.createdAt  = createdAt
        self.slots      = Array(repeating: nil, count: self.total)
    }

    var isComplete: Bool { received == total }

    func put(index: Int, data: Data) {
        guard index >= 0 && index < total else { return }
        if slots[index] == nil {
            slots[index] = data
            received += 1
        }
    }

    func assemble() -> Data? {
        var out = Data()
        for slot in slots {
            guard let s = slot else { return nil }
            out.append(s)
        }
        return out
    }
}
