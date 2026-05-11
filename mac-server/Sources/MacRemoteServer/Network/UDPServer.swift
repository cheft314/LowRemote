import Foundation

/// UDP server that:
///   - Listens on a port for control events from the iOS/Android client
///   - Learns the client's UDP source endpoint from the first packet
///   - Exposes `send(_:to:port:)` to push encoded video fragments back
///
/// 收发复用同一 POSIX socket fd，消除 NWConnection 建立延迟和随机源端口问题。
final class UDPServer {

    private let listenPort: UInt16
    private let queue = DispatchQueue(label: "LowRemote.UDPServer", qos: .userInteractive)

    private var serverFd: Int32 = -1
    private var source: DispatchSourceRead?

    var onControlEvent: ((ControlEvent) -> Void)?
    var onFirstPacketFromClient: ((String, UInt16) -> Void)?
    /// Called on the UDPServer's GCD queue with raw PCM bytes (16 kHz, mono, 16-bit LE).
    var onAudioData: ((Data) -> Void)?

    private var knownClientKey: String?

    init(port: UInt16) {
        self.listenPort = port
    }

    func start() {
        // 使用 IPv6 dual-stack socket，可同时收发 IPv4 和 IPv6 包
        var fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        var useIPv6 = true
        if fd < 0 {
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            useIPv6 = false
        }
        guard fd >= 0 else {
            NSLog("[UDPServer] socket() failed: \(errno)")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Increase receive buffer to 4 MB
        var rcvBuf: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        let bindResult: Int32
        if useIPv6 {
            // IPV6_V6ONLY=0 → dual-stack，同时接收 IPv4-mapped 包
            var v6only: Int32 = 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
            var addr6 = sockaddr_in6()
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port   = listenPort.bigEndian
            addr6.sin6_addr   = in6addr_any
            bindResult = withUnsafeBytes(of: &addr6) { ptr in
                bind(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        } else {
            var addr4 = sockaddr_in()
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port   = listenPort.bigEndian
            addr4.sin_addr.s_addr = INADDR_ANY
            bindResult = withUnsafeBytes(of: &addr4) { ptr in
                bind(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("[UDPServer] bind() failed: \(errno)")
            close(fd)
            return
        }

        serverFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readPacket() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src

        NSLog("[UDPServer] listening on UDP :\(listenPort) (IPv\(useIPv6 ? "6 dual-stack" : "4"))")
    }

    func stop() {
        source?.cancel()
        source = nil
        serverFd = -1
    }

    // MARK: - Inbound (same fd, GCD)

    private func readPacket() {
        guard serverFd >= 0 else { return }

        var buf = [UInt8](repeating: 0, count: 65536)
        // 使用 sockaddr_storage 容纳 IPv4 和 IPv6
        var storageBytes = [UInt8](repeating: 0, count: MemoryLayout<sockaddr_storage>.size)
        var senderLen = socklen_t(storageBytes.count)

        let n = storageBytes.withUnsafeMutableBytes { addrPtr in
            recvfrom(serverFd, &buf, buf.count, 0,
                     addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     &senderLen)
        }
        guard n > 0 else { return }

        // 解析发送方地址
        let (senderIP, senderPort): (String, UInt16) = storageBytes.withUnsafeBytes { ptr in
            let family = ptr.loadUnaligned(fromByteOffset: 1, as: UInt8.self)
            var ipBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if family == UInt8(AF_INET) {
                var addr4 = ptr.loadUnaligned(fromByteOffset: 0, as: sockaddr_in.self)
                inet_ntop(AF_INET, &addr4.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                return (String(cString: ipBuf), UInt16(bigEndian: addr4.sin_port))
            } else if family == UInt8(AF_INET6) {
                var addr6 = ptr.loadUnaligned(fromByteOffset: 0, as: sockaddr_in6.self)
                inet_ntop(AF_INET6, &addr6.sin6_addr, &ipBuf, socklen_t(INET6_ADDRSTRLEN))
                // 检查是否是 IPv4-mapped（::ffff:x.x.x.x），提取 IPv4
                let ipStr = String(cString: ipBuf)
                if ipStr.hasPrefix("::ffff:") {
                    let v4str = String(ipStr.dropFirst(7))
                    return (v4str, UInt16(bigEndian: addr6.sin6_port))
                }
                // link-local 地址附加 scope
                let scope = addr6.sin6_scope_id
                var ifnameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if scope > 0, if_indextoname(scope, &ifnameBuf) != nil {
                    return ("\(ipStr)%\(String(cString: ifnameBuf))", UInt16(bigEndian: addr6.sin6_port))
                }
                return (ipStr, UInt16(bigEndian: addr6.sin6_port))
            }
            return ("unknown", 0)
        }

        // Notify first packet (for video endpoint tracking)
        let clientKey = "\(senderIP):\(senderPort)"
        if knownClientKey != clientKey {
            knownClientKey = clientKey
            onFirstPacketFromClient?(senderIP, senderPort)
        }

        let data = Data(bytes: buf, count: n)
        handlePacket(data)
    }

    private func handlePacket(_ data: Data) {
        guard let parsed = Packet.parse(data) else { return }

        switch parsed.type {
        case Packet.typeControl:
            guard let str = String(data: parsed.payload, encoding: .utf8) else { return }
            NSLog("[UDPServer] control event raw: '\(str)'")
            guard let event = ControlEvent.parse(str) else {
                NSLog("[UDPServer] ControlEvent.parse failed for: '\(str)'")
                return
            }
            // Dispatch CGEvent injection on main thread — required for accessibility API
            DispatchQueue.main.async { [weak self] in
                self?.onControlEvent?(event)
            }

        case Packet.typeAudio:
            // Hand raw PCM bytes directly to the audio receiver on its own queue.
            // No main-thread dispatch needed — AVAudioEngine scheduling is thread-safe.
            onAudioData?(parsed.payload)

        default:
            break
        }
    }

    // MARK: - Outbound（复用同一 POSIX socket，与入站 fd 相同）
    //
    // 原实现用独立的 NWConnection 发包，存在两个问题：
    //   1. NWConnection 建立需要时间，在此期间发出的帧被丢弃
    //   2. NWConnection 的源端口是系统随机分配的，不是 8891
    // 改用 sendto() 复用入站 fd，直接发往记录的客户端地址。

    func send(_ data: Data, to host: String, port: UInt16) {
        guard serverFd >= 0 else { return }

        // 尝试 IPv4
        var addr4 = sockaddr_in()
        if inet_pton(AF_INET, host, &addr4.sin_addr) == 1 {
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port   = port.bigEndian
            data.withUnsafeBytes { rawBuf in
                withUnsafeBytes(of: &addr4) { addrPtr in
                    _ = sendto(serverFd, rawBuf.baseAddress!, data.count, 0,
                               addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return
        }

        // 尝试 IPv6（剥离 %scope 后缀再解析）
        let cleanHost = host.components(separatedBy: "%").first ?? host
        var addr6 = sockaddr_in6()
        if inet_pton(AF_INET6, cleanHost, &addr6.sin6_addr) == 1 {
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port   = port.bigEndian
            if host.contains("%") {
                let ifname = String(host.split(separator: "%").last ?? "")
                addr6.sin6_scope_id = if_nametoindex(ifname)
            }
            data.withUnsafeBytes { rawBuf in
                withUnsafeBytes(of: &addr6) { addrPtr in
                    _ = sendto(serverFd, rawBuf.baseAddress!, data.count, 0,
                               addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                               socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            return
        }

        NSLog("[UDPServer] send: 无法解析目标地址 \(host)")
    }
}
