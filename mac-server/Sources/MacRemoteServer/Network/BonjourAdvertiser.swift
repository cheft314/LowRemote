import Foundation

/// Registers a Bonjour/mDNS service so Android clients can discover this Mac
/// on the local network. Uses `NetService` (Foundation) as the spec prescribes.
final class BonjourAdvertiser: NSObject, NetServiceDelegate {

    private let serviceType: String
    private let serviceName: String
    private let tcpPort: Int32
    private let udpPort: Int32
    private var service: NetService?

    init(serviceType: String, serviceName: String, tcpPort: Int32, udpPort: Int32) {
        self.serviceType = serviceType
        self.serviceName = serviceName
        self.tcpPort = tcpPort
        self.udpPort = udpPort
    }

    func start() {
        let service = NetService(domain: "local.",
                                 type: serviceType,
                                 name: serviceName,
                                 port: tcpPort)
        service.delegate = self

        // TXT record lets clients discover the UDP port and a friendly name
        // before even connecting to TCP.
        let txt: [String: Data] = [
            "tcp_port": "\(tcpPort)".data(using: .utf8)!,
            "udp_port": "\(udpPort)".data(using: .utf8)!,
            "device": serviceName.data(using: .utf8)!,
            "version": "1".data(using: .utf8)!
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        self.service = service
        NSLog("[Bonjour] Publishing \(serviceName).\(serviceType) on TCP:\(tcpPort)")
    }

    func stop() {
        service?.stop()
        service = nil
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[Bonjour] Published as \(sender.name).\(sender.type)\(sender.domain)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("[Bonjour] Publish failed: \(errorDict)")
    }
}
