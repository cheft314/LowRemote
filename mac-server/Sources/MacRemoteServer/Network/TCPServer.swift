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
    /// Called when FILE_START is parsed: return the expected byte count so the
    /// server can switch the connection into binary-receive mode.
    var onFileStart: ((String /*filename*/, Int /*size*/, String /*clientHost*/) -> Void)?
    /// Called with each raw chunk of file data as it arrives.
    var onFileChunk: ((Data, String /*clientHost*/) -> Void)?
    /// Called after FILE_END is received.
    var onFileEnd: ((String /*clientHost*/) -> Void)?

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

        client.onLine = { [weak self, weak client] line in
            guard let self = self else { return }
            // Intercept FILE_START / FILE_END before forwarding to onCommand
            if line.hasPrefix("FILE_START:") {
                // Format: FILE_START:<filename>:<filesize>
                let rest  = String(line.dropFirst("FILE_START:".count))
                let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2,
                   let sz = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    let filename = parts[0]
                    // Notify AppDelegate so it can prepare the file on disk
                    self.onFileStart?(filename, sz, remoteHost)
                    // Tell this connection to switch to binary mode
                    client?.beginFileReceive(size: sz)
                    // Send green-light back to Android
                    self.broadcast("FILE_READY\n")
                }
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines) == "FILE_END" {
                self.onFileEnd?(remoteHost)
            } else {
                self.onCommand?(line, remoteHost)
            }
        }
        client.onFileData = { [weak self] chunk in
            self?.onFileChunk?(chunk, remoteHost)
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

    /// Receive buffer — accumulates raw bytes from the network.
    private var buffer = Data()

    // ── File-receive state ────────────────────────────────────────────────────
    /// When > 0 the connection is in binary-receive mode: the next
    /// `fileBytesRemaining` bytes belong to the current file transfer.
    private var fileBytesRemaining: Int = 0
    private var fileBuffer = Data()
    var onFileData: ((Data) -> Void)?   // called with chunks while receiving
    var onFileEnd:  (() -> Void)?       // called after FILE_END line is drained

    var onLine:   ((String) -> Void)?
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

    /// Switch into binary-receive mode for a file of `size` bytes.
    /// Safe to call multiple times (resets state for each new file).
    func beginFileReceive(size: Int) {
        fileBytesRemaining = size
        fileBuffer = Data()   // always start fresh — never carry over from a previous file
    }

    // MARK: - Private receive loop

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if error != nil || isComplete {
                self.onClosed?()
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    /// Main demux: consume bytes from `buffer` in the correct mode.
    ///
    /// IMPORTANT: Swift `Data` indices are NOT always 0-based after mutations.
    /// We always rebuild `buffer` as a fresh `Data` to ensure startIndex == 0
    /// and avoid subscript-out-of-bounds crashes on Foundation-bridged buffers.
    private func drainBuffer() {
        while !buffer.isEmpty {
            if fileBytesRemaining > 0 {
                // ── Binary mode: consume up to fileBytesRemaining bytes ────────
                let take = min(fileBytesRemaining, buffer.count)
                let chunk = Data(buffer.prefix(take))
                // Rebuild buffer from scratch to guarantee startIndex == 0
                buffer = buffer.count > take ? Data(buffer[take...]) : Data()
                fileBuffer.append(chunk)
                fileBytesRemaining -= take
                onFileData?(chunk)
                // When fileBytesRemaining reaches 0, continue the loop in
                // line mode to consume the trailing FILE_END\n from the wire.
            } else {
                // ── Line mode: drain \n-delimited lines ───────────────────────
                // Use a manual byte scan so we are never confused by Data's
                // internal index representation after prior mutations.
                guard let newlineOffset = buffer.firstIndex(of: 0x0A) else { break }
                // Safety: ensure the slice range is valid
                guard newlineOffset <= buffer.endIndex else { break }
                let lineData = Data(buffer[buffer.startIndex..<newlineOffset])
                // Advance past the '\n' byte
                let nextStart = buffer.index(after: newlineOffset)
                buffer = nextStart < buffer.endIndex ? Data(buffer[nextStart...]) : Data()
                if let line = String(data: lineData, encoding: .utf8) {
                    onLine?(line)
                }
            }
        }
    }
}
