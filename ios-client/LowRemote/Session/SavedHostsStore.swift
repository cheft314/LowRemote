import Foundation

/// 持久化已保存的主机列表（UserDefaults + Codable）
/// 对齐 Android SavedHostsStore.kt
@Observable
final class SavedHostsStore {

    private let key = "saved_hosts_v1"
    private(set) var hosts: [RemoteDevice] = []

    init() {
        load()
    }

    // MARK: - Public API

    func add(_ device: RemoteDevice) {
        // 同 host+port 去重
        if !hosts.contains(where: { $0.host == device.host && $0.tcpPort == device.tcpPort }) {
            hosts.insert(device, at: 0)
            save()
        }
    }

    func remove(at offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
        save()
    }

    func remove(_ device: RemoteDevice) {
        hosts.removeAll { $0.id == device.id }
        save()
    }

    func update(_ device: RemoteDevice) {
        if let idx = hosts.firstIndex(where: { $0.id == device.id }) {
            hosts[idx] = device
            save()
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RemoteDevice].self, from: data) else { return }
        hosts = decoded
    }
}
