import Foundation

/// UDP 发送器，共享 UdpReceiver 的同一 POSIX socket
/// 支持 IPv4 和 IPv6 目标地址
/// 对齐 Android UdpSender.kt
final class UdpSender {

    private var sharedFd: Int32 = -1
    private var destHost: String = ""
    private var destPort: UInt16 = 0

    // 缓存解析结果：IPv4 用 sockaddr_in，IPv6 用 sockaddr_in6
    private var destAddrData: Data = Data()
    private var destAddrLen:  socklen_t = 0

    private let queue = DispatchQueue(label: "LowRemote.UDPSend", qos: .userInteractive)

    // MARK: - Setup

    /// 绑定到 UdpReceiver 共享的 fd，设置目标地址
    func attach(fd: Int32, host: String, port: UInt16) {
        sharedFd = fd
        destHost = host
        destPort = port

        // 尝试 IPv4
        var addr4 = sockaddr_in()
        if inet_pton(AF_INET, host, &addr4.sin_addr) == 1 {
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port   = port.bigEndian
            destAddrData = withUnsafeBytes(of: addr4) { Data($0) }
            destAddrLen  = socklen_t(MemoryLayout<sockaddr_in>.size)
            NSLog("[UDPSend] 目标 IPv4 \(host):\(port)")
            return
        }

        // 尝试 IPv6（link-local 格式可能带 %ifname，需先剥离）
        let cleanHost = host.components(separatedBy: "%").first ?? host
        var addr6 = sockaddr_in6()
        if inet_pton(AF_INET6, cleanHost, &addr6.sin6_addr) == 1 {
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port   = port.bigEndian
            // link-local 地址需要 scope_id
            if host.contains("%") {
                let ifname = String(host.split(separator: "%").last ?? "")
                addr6.sin6_scope_id = if_nametoindex(ifname)
            }
            destAddrData = withUnsafeBytes(of: addr6) { Data($0) }
            destAddrLen  = socklen_t(MemoryLayout<sockaddr_in6>.size)
            NSLog("[UDPSend] 目标 IPv6 \(host):\(port) scope=\(addr6.sin6_scope_id)")
            return
        }

        NSLog("[UDPSend] ⚠️ 无法解析目标地址: \(host)")
    }

    // MARK: - Send

    func send(_ data: Data) {
        guard sharedFd >= 0, !destAddrData.isEmpty else { return }
        let addrData = destAddrData
        let addrLen  = destAddrLen
        queue.async { [weak self] in
            guard let self = self else { return }
            data.withUnsafeBytes { rawBuf in
                addrData.withUnsafeBytes { addrPtr in
                    _ = sendto(self.sharedFd,
                               rawBuf.baseAddress!,
                               data.count,
                               0,
                               addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                               addrLen)
                }
            }
        }
    }

    func sendEvent(_ eventString: String, frameId: UInt32) {
        let packet = Packet.encodeControl(frameId: frameId, eventString: eventString)
        send(packet)
    }

    func sendAudio(_ pcmData: Data, frameId: UInt32) {
        let packet = Packet.encodeAudio(frameId: frameId, payload: pcmData)
        send(packet)
    }
}
