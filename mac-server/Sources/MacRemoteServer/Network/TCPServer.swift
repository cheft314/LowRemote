import Foundation
import Network

/// Simple line-based TCP control server.
///
/// - Listens on the given port
/// - Accepts one or more clients (we treat it as single-client in practice)
/// - Parses `\n`-terminated UTF-8 commands and forwards them to `onCommand`
/// - Supports broadcasting a string back to all connected clients
final class TCPServer {

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private let queue = DispatchQueue(label: "LowRemote.TCPServer")
    private let lock = NSLock()

    var onCommand: ((String, String) -> Void)?
    var onClientConnected: ((String) -> Void)?
    var onClientDisconnected: (() -> Void)?

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                NSLog("[TCPServer] state: \(state)")
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("[TCPServer] Failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let conns = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for c in conns { c.cancel() }
    }

    func disconnectAll() {
        lock.lock()
        let conns = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for c in conns { c.cancel() }
    }

    func broadcast(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        for c in conns { c.send(data) }
    }

    // MARK: - Private

    private func accept(_ conn: NWConnection) {
        let client = ClientConnection(connection: conn, queue: queue)
        let key = ObjectIdentifier(client)

        let remoteHost = Self.remoteHostString(conn) ?? "unknown"

        client.onLine = { [weak self] line in
            self?.onCommand?(line, remoteHost)
        }
        client.onClosed = { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.connections.removeValue(forKey: key)
            let remaining = self.connections.count
            self.lock.unlock()
            if remaining == 0 {
                self.onClientDisconnected?()
            }
        }

        lock.lock()
        connections[key] = client
        lock.unlock()

        client.start()
        onClientConnected?(remoteHost)
    }

    private static func remoteHostString(_ conn: NWConnection) -> String? {
        if case let .hostPort(host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return nil
            }
        }
        return nil
    }
}

private final class ClientConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    var onLine: ((String) -> Void)?
    var onClosed: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.onClosed?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if error != nil || isComplete {
                self.onClosed?()
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func drainLines() {
        while let idx = buffer.firstIndex(of: 0x0A) { // '\n'
            let lineData = buffer.subdata(in: 0..<idx)
            buffer.removeSubrange(0...idx)
            if let line = String(data: lineData, encoding: .utf8) {
                onLine?(line)
            }
        }
    }
}
