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
        // 优先尝试 IPv6 dual-stack socket（可同时收 IPv4 和 IPv6）
        var s = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        var useIPv6 = true
        if s < 0 {
            // 降级到 IPv4-only
            s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            useIPv6 = false
        }
        guard s >= 0 else { return }

        var reuse: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var rcvBuf: Int32 = 4 * 1024 * 1024
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        let bound: Int32
        if useIPv6 {
            // IPV6_V6ONLY = 0 → 同时接收 IPv4-mapped IPv6 地址的包（dual-stack）
            var v6only: Int32 = 0
            setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))

            var addr6 = sockaddr_in6()
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port   = port.bigEndian
            addr6.sin6_addr   = in6addr_any
            bound = withUnsafeBytes(of: &addr6) { ptr in
                bind(s, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        } else {
            var addr4 = sockaddr_in()
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port   = port.bigEndian
            addr4.sin_addr.s_addr = INADDR_ANY
            bound = withUnsafeBytes(of: &addr4) { ptr in
                bind(s, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(s); return }

        fd = s

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.readPacket() }
        src.setCancelHandler  { close(s) }
        src.resume()
        source = src as? DispatchSource

        NSLog("[UDPRecv] listening on port \(boundPort()) (IPv\(useIPv6 ? "6 dual-stack" : "4"))")
    }

    func stop() {
        (source as? DispatchSourceRead)?.cancel()
        source = nil
        fd = -1
    }

    /// 返回实际绑定端口（用于同 socket 发送时告知 Mac）
    func boundPort() -> UInt16 {
        guard fd >= 0 else { return 0 }
        // 先尝试 IPv6 getsockname
        var addr6 = sockaddr_in6()
        var len6  = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let ret = withUnsafeMutableBytes(of: &addr6) { ptr in
            getsockname(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &len6)
        }
        if ret == 0 && addr6.sin6_family == sa_family_t(AF_INET6) {
            return UInt16(bigEndian: addr6.sin6_port)
        }
        // 降级 IPv4
        var addr4 = sockaddr_in()
        var len4  = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutableBytes(of: &addr4) { ptr in
            getsockname(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &len4)
        }
        return UInt16(bigEndian: addr4.sin_port)
    }

    /// 暴露 fd 供 UdpSender 共享同一 socket
    var rawFd: Int32 { fd }

    // MARK: - Private

    // 首包诊断计数器
    private var packetCount = 0

    private func readPacket() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        // 使用足够大的 sockaddr 缓冲区，可以容纳 IPv4 和 IPv6
        var storageBytes = [UInt8](repeating: 0, count: MemoryLayout<sockaddr_storage>.size)
        var senderLen = socklen_t(storageBytes.count)

        let n = storageBytes.withUnsafeMutableBytes { addrPtr in
            recvfrom(fd, &buf, buf.count, 0,
                     addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     &senderLen)
        }
        guard n > 0 else { return }

        packetCount += 1
        if packetCount <= 5 || packetCount % 300 == 0 {
            NSLog("[UDPRecv] 收到第 \(packetCount) 个包，大小=\(n) bytes")
        }

        // 解析发送方地址（调试用）
        let senderIP: String = storageBytes.withUnsafeBytes { ptr in
            let family = ptr.loadUnaligned(fromByteOffset: 1, as: UInt8.self)
            var ipBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if family == UInt8(AF_INET) {
                var addr4 = ptr.loadUnaligned(fromByteOffset: 0, as: sockaddr_in.self)
                inet_ntop(AF_INET, &addr4.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            } else if family == UInt8(AF_INET6) {
                var addr6 = ptr.loadUnaligned(fromByteOffset: 0, as: sockaddr_in6.self)
                inet_ntop(AF_INET6, &addr6.sin6_addr, &ipBuf, socklen_t(INET6_ADDRSTRLEN))
            }
            return String(cString: ipBuf)
        }

        let data = Data(bytes: buf, count: n)
        guard let parsed = Packet.parse(data) else {
            if packetCount <= 3 {
                NSLog("[UDPRecv] Packet.parse 失败 from \(senderIP)，数据前10字节: \(Array(buf.prefix(10)))")
            }
            return
        }
        if packetCount <= 3 {
            NSLog("[UDPRecv] type=\(parsed.type) frameId=\(parsed.frameId) pktIdx=\(parsed.pktIdx)/\(parsed.pktTotal) payload=\(parsed.payload.count)B from \(senderIP)")
        }
        onPacket?(parsed, parsed.payload, senderIP)
    }
}
