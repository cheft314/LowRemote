import Foundation

/// 通过 mDNS 发现的 Mac 设备信息
struct RemoteDevice: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var host: String
    var tcpPort: UInt16
    var udpPort: UInt16

    init(id: UUID = UUID(), name: String, host: String,
         tcpPort: UInt16 = 8890, udpPort: UInt16 = 8891) {
        self.id      = id
        self.name    = name
        self.host    = host
        self.tcpPort = tcpPort
        self.udpPort = udpPort
    }
}
