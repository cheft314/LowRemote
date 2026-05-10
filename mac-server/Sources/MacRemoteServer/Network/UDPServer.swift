import Foundation
import Network

/// UDP server that:
///   - Listens on a port for control events from the Android client
///   - Learns the client's UDP source endpoint from the first packet
///   - Exposes `send(_:to:port:)` to push encoded video fragments back
final class UDPServer {

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "LowRemote.UDPServer")

    /// A short-lived connection per client endpoint (spun up by NWListener).
    private var clientConnections: [String: NWConnection] = [:]
    private let lock = NSLock()

    /// For sending: we keep one outbound NWConnection keyed by "host:port" so that
    /// repeated sends don't allocate a new socket each time.
    private var outboundConnections: [String: NWConnection] = [:]

    var onControlEvent: ((ControlEvent) -> Void)?
    var onFirstPacketFromClient: ((String, UInt16) -> Void)?

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                NSLog("[UDPServer] state: \(state)")
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("[UDPServer] Failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        for c in clientConnections.values { c.cancel() }
        clientConnections.removeAll()
        for c in outboundConnections.values { c.cancel() }
        outboundConnections.removeAll()
        lock.unlock()
    }

    // MARK: - Inbound

    private func accept(_ conn: NWConnection) {
        let key: String
        var clientHost = "unknown"
        var clientPort: UInt16 = 0
        if case let .hostPort(host, port) = conn.endpoint {
            switch host {
            case .ipv4(let a): clientHost = "\(a)"
            case .ipv6(let a): clientHost = "\(a)"
            case .name(let n, _): clientHost = n
            @unknown default: break
            }
            clientPort = port.rawValue
            key = "\(clientHost):\(clientPort)"
        } else {
            key = UUID().uuidString
        }

        lock.lock()
        clientConnections[key] = conn
        let isFirst = clientConnections.count == 1
        lock.unlock()

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(conn)
            case .failed, .cancelled:
                self?.lock.lock()
                self?.clientConnections.removeValue(forKey: key)
                self?.lock.unlock()
            default:
                break
            }
        }
        conn.start(queue: queue)

        if isFirst {
            onFirstPacketFromClient?(clientHost, clientPort)
        } else {
            // Multiple clients: still update endpoint so latest wins.
            onFirstPacketFromClient?(clientHost, clientPort)
        }
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.handlePacket(data)
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.receive(conn)
        }
    }

    private func handlePacket(_ data: Data) {
        guard let parsed = Packet.parse(data) else { return }
        if parsed.type == Packet.typeControl {
            if let str = String(data: parsed.payload, encoding: .utf8),
               let event = ControlEvent.parse(str) {
                onControlEvent?(event)
            }
        }
        // Video-typed inbound packets are ignored (server only sends them).
    }

    // MARK: - Outbound

    func send(_ data: Data, to host: String, port: UInt16) {
        let key = "\(host):\(port)"
        lock.lock()
        var conn = outboundConnections[key]
        if conn == nil {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                lock.unlock()
                return
            }
            let newConn = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .udp
            )
            newConn.stateUpdateHandler = { _ in }
            newConn.start(queue: queue)
            outboundConnections[key] = newConn
            conn = newConn
        }
        lock.unlock()

        conn?.send(content: data, completion: .contentProcessed { _ in })
    }
}
