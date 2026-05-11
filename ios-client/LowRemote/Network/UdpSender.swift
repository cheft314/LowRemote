import Foundation

/// UDP 发送器，共享 UdpReceiver 的同一 POSIX socket
/// 对齐 Android UdpSender.kt
final class UdpSender {

    private var sharedFd: Int32 = -1
    private var destHost: String = ""
    private var destPort: UInt16 = 0
    private var destAddr: sockaddr_in = sockaddr_in()

    private let queue = DispatchQueue(label: "LowRemote.UDPSend", qos: .userInteractive)

    // MARK: - Setup

    /// 绑定到 UdpReceiver 共享的 fd，设置目标地址
    func attach(fd: Int32, host: String, port: UInt16) {
        sharedFd = fd
        destHost = host
        destPort = port

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        destAddr = addr
    }

    // MARK: - Send

    func send(_ data: Data) {
        guard sharedFd >= 0 else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            data.withUnsafeBytes { rawBuf in
                withUnsafeBytes(of: &self.destAddr) { addrPtr in
                    sendto(self.sharedFd,
                           rawBuf.baseAddress!,
                           data.count,
                           0,
                           addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                           socklen_t(MemoryLayout<sockaddr_in>.size))
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
