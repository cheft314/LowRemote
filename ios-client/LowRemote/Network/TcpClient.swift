import Foundation
import Network

/// TCP 控制通道，完整对齐 Android TcpClient.kt
/// 使用 Network.framework NWConnection（行分隔协议）
final class TcpClient {

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "LowRemote.TCP", qos: .userInitiated)

    /// 收到一行文本（已去掉 \n）
    var onLine: ((String) -> Void)?
    /// 连接断开
    var onDisconnected: (() -> Void)?

    private(set) var isConnected = false

    // 接收缓冲区
    private var receiveBuffer = Data()

    // MARK: - Public

    func connect(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false); return
            }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: params
            )
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.startReceiving()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    self?.isConnected = false
                    self?.onDisconnected?()
                    continuation.resume(returning: false)
                default: break
                }
            }
            conn.start(queue: queue)
            connection = conn
        }
    }

    func disconnect() {
        isConnected = false
        connection?.cancel()
        connection = nil
    }

    /// 发送一行文本（自动追加 \n）
    func send(_ line: String) {
        guard isConnected, let data = "\(line)\n".data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// 发送原始二进制流（用于文件传输）
    func sendRaw(_ data: Data) {
        guard isConnected else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Private receive loop

    private func startReceiving() {
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainLines()
            }
            if error != nil || isComplete {
                self.isConnected = false
                self.onDisconnected?()
                return
            }
            self.receive()
        }
    }

    private func drainLines() {
        while let idx = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer[receiveBuffer.startIndex..<idx]
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    DispatchQueue.main.async { self.onLine?(trimmed) }
                }
            }
        }
    }
}
