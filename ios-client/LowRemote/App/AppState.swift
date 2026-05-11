import SwiftUI
import Combine

/// 全局应用状态，单例注入所有视图
@Observable
final class AppState {

    // 当前远程会话（跨视图共享）
    let session    = RemoteSession()
    // 已保存主机列表
    let hostsStore = SavedHostsStore()

    // 权限引导是否已完成
    var permissionGuideShown: Bool {
        get { UserDefaults.standard.bool(forKey: "permissionGuideShown") }
        set { UserDefaults.standard.set(newValue, forKey: "permissionGuideShown") }
    }

    // 全局 Toast 消息
    var toastMessage: String? = nil

    // MARK: - Toast

    func showToast(_ message: String, duration: Double = 2.5) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.toastMessage == message { self?.toastMessage = nil }
        }
    }
}
