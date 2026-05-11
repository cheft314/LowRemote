import Foundation
import Network

/// 使用 NWBrowser 扫描 _maclocalremote._tcp 服务
/// 对齐 Android MdnsDiscovery.kt (NsdManager)
final class MdnsDiscovery {

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "LowRemote.mDNS", qos: .userInitiated)

    /// 发现新设备
    var onDeviceFound:   ((RemoteDevice) -> Void)?
    /// 设备消失
    var onDeviceLost:    ((RemoteDevice) -> Void)?

    /// 当前已发现设备缓存 (name → device)
    private var discovered: [String: RemoteDevice] = [:]

    // MARK: - Public API

    func startDiscovery() {
        stopDiscovery()
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_maclocalremote._tcp",
            domain: "local."
        )
        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: params)
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                NSLog("[mDNS] browser failed: \(err), restarting...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.startDiscovery() }
            default: break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleChanges(changes)
        }
        b.start(queue: queue)
        browser = b
        NSLog("[mDNS] discovery started")
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Private

    private func handleChanges(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                resolve(result)
            case .removed(let result):
                if case .service(let name, _, _, _) = result.endpoint {
                    if let device = discovered.removeValue(forKey: name) {
                        DispatchQueue.main.async { self.onDeviceLost?(device) }
                    }
                }
            default: break
            }
        }
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

        // 使用 NWConnection 解析主机和端口
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self else { return }
            if case .ready = state, let c = conn {
                // 从已解析连接中取 remote endpoint
                if case .hostPort(let host, let port) = c.currentPath?.remoteEndpoint {
                    let hostStr = self.hostString(host)
                    var tcpPort: UInt16 = 8890
                    var udpPort: UInt16 = 8891

                    // 解析 TXT Record
                    // NWBrowser result 的 metadata 里直接携带 NWTXTRecord，无需再包装
                    if case .bonjour(let txtRecord) = result.metadata {
                        if let e = txtRecord.getEntry(for: "tcp_port"),
                           case .string(let s) = e,
                           let p = UInt16(s) {
                            tcpPort = p
                        }
                        if let e = txtRecord.getEntry(for: "udp_port"),
                           case .string(let s) = e,
                           let p = UInt16(s) {
                            udpPort = p
                        }
                    }

                    let device = RemoteDevice(
                        name: name,
                        host: hostStr,
                        tcpPort: tcpPort,
                        udpPort: udpPort
                    )
                    self.discovered[name] = device
                    DispatchQueue.main.async { self.onDeviceFound?(device) }
                }
                c.cancel()
            }
        }
        conn.start(queue: queue)
    }

    private func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return ""
        }
    }
}

