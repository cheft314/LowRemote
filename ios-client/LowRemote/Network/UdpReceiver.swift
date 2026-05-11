import Foundation

/// UDP 接收器 —— POSIX socket，与 Android UdpReceiver.kt 完全对齐
/// 使用 POSIX 而非 NWListener，避免 Network.framework UDP 首包竞态。
final class UdpReceiver {

    private var fd: Int32 = -1
    private var source: DispatchSource?
    private let queue = DispatchQueue(
        label: "LowRemote.UDPRecv",
        qos: .userInteractive
    )
    private let port: UInt16

    /// (parsed packet, raw payload, sender IP) → void
    var onPacket: ((Packet.Parsed, Data, String) -> Void)?

    init(port: UInt16 = 0) {
        self.port = port
    }

    // MARK: - Lifecycle

    /// 启动并绑定端口；0 = 系统分配
    func start() {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return }

        var reuse: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var rcvBuf: Int32 = 4 * 1024 * 1024
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafeBytes(of: &addr) { ptr in
            bind(s, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                 socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard bound == 0 else { close(s); return }

        fd = s

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.readPacket() }
        src.setCancelHandler  { close(s) }
        src.resume()
        source = src as? DispatchSource

        NSLog("[UDPRecv] listening on port \(boundPort())")
    }

    func stop() {
        (source as? DispatchSourceRead)?.cancel()
        source = nil
        fd = -1
    }

    /// 返回实际绑定端口（用于同 socket 发送时告知 Mac）
    func boundPort() -> UInt16 {
        guard fd >= 0 else { return 0 }
        var addr = sockaddr_in()
        var len  = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutableBytes(of: &addr) { ptr in
            getsockname(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &len)
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// 暴露 fd 供 UdpSender 共享同一 socket
    var rawFd: Int32 { fd }

    // MARK: - Private

    private func readPacket() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        var senderAddr = sockaddr_in()
        var senderLen  = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = withUnsafeMutableBytes(of: &senderAddr) { addrPtr in
            recvfrom(fd, &buf, buf.count, 0,
                     addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     &senderLen)
        }
        guard n > 0 else { return }

        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var inAddr = senderAddr.sin_addr
        inet_ntop(AF_INET, &inAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        let senderIP = String(cString: ipBuf)

        let data = Data(bytes: buf, count: n)
        guard let parsed = Packet.parse(data) else { return }
        onPacket?(parsed, parsed.payload, senderIP)
    }
}
