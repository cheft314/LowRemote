import Foundation
import Network

/// UDP server that:
///   - Listens on a port for control events from the Android client
///   - Learns the client's UDP source endpoint from the first packet
///   - Exposes `send(_:to:port:)` to push encoded video fragments back
///
/// 实现说明：
///   使用 BSD socket (GCDAsyncSocket 思路的纯 Foundation 实现) 而非 NWListener，
///   原因是 NWListener 对 UDP 的连接模型存在第一个包丢失的竞态，
///   且无法直接在同一 socket 上收发（NWListener 只接收）。
///   改用 GCD + POSIX socket 在同一 fd 上收发，消除这个竞态。
final class UDPServer {

    private let listenPort: UInt16
    private let queue = DispatchQueue(label: "LowRemote.UDPServer", qos: .userInteractive)

    private var serverFd: Int32 = -1
    private var source: DispatchSourceRead?

    /// For sending video back to the client, we keep a separate outbound
    /// NWConnection so we don't need to know the client's source port in advance.
    private var outboundConnections: [String: NWConnection] = [:]
    private let outLock = NSLock()
    private let outQueue = DispatchQueue(label: "LowRemote.UDPServer.out")

    var onControlEvent: ((ControlEvent) -> Void)?
    var onFirstPacketFromClient: ((String, UInt16) -> Void)?
    /// Called on the UDPServer's GCD queue with raw PCM bytes (16 kHz, mono, 16-bit LE).
    var onAudioData: ((Data) -> Void)?

    private var knownClientKey: String?

    init(port: UInt16) {
        self.listenPort = port
    }

    func start() {
        // Create UDP socket
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
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

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafeBytes(of: &addr) { ptr in
            bind(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
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

        NSLog("[UDPServer] listening on UDP :\(listenPort)")
    }

    func stop() {
        source?.cancel()
        source = nil
        serverFd = -1
        outLock.lock()
        for c in outboundConnections.values { c.cancel() }
        outboundConnections.removeAll()
        outLock.unlock()
    }

    // MARK: - Inbound (same fd, GCD)

    private func readPacket() {
        guard serverFd >= 0 else { return }

        var buf = [UInt8](repeating: 0, count: 65536)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = withUnsafeMutableBytes(of: &senderAddr) { addrPtr in
            recvfrom(serverFd,
                     &buf,
                     buf.count,
                     0,
                     addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                     &senderLen)
        }

        guard n > 0 else { return }

        // Extract sender IP and port
        let senderIP: String
        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addr = senderAddr.sin_addr
        inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        senderIP = String(cString: ipBuf)
        let senderPort = UInt16(bigEndian: senderAddr.sin_port)

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

    // MARK: - Outbound (NWConnection, separate from receive path)

    func send(_ data: Data, to host: String, port: UInt16) {
        let key = "\(host):\(port)"
        outLock.lock()
        var conn = outboundConnections[key]
        if conn == nil {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                outLock.unlock()
                return
            }
            let newConn = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .udp
            )
            newConn.stateUpdateHandler = { _ in }
            newConn.start(queue: outQueue)
            outboundConnections[key] = newConn
            conn = newConn
        }
        outLock.unlock()

        conn?.send(content: data, completion: .contentProcessed { _ in })
    }
}
