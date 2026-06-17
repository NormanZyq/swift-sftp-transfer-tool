import Foundation
import Observation

/// 一列 tab 容器：左侧 / 右侧各一个，可混合放本地或远程 tab。
/// 取代了原 `AppModel.localTabs` / `AppModel.remoteTabs` 的固定语义。
@MainActor
@Observable
final class PaneColumnModel: Identifiable {
    let id = UUID()
    var tabs: [BrowserTab] = []
    var selectedIndex: Int = 0

    /// 选中项。
    var activeTab: BrowserTab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    /// 选中项的面板（最常用的派生属性）。
    var activePane: PaneModel? { activeTab?.pane }

    /// 选中项的远程 tab（仅当 active 是 .remote 时非 nil）。
    var activeRemoteTab: RemoteTab? { activeTab?.remoteTab }

    /// 选中项是否处于「已连接远程」状态。
    var isActiveRemoteConnected: Bool {
        activeRemoteTab?.state == .connected
    }

    // MARK: 操作

    func append(_ tab: BrowserTab) {
        tabs.append(tab)
        selectedIndex = tabs.count - 1
    }

    /// 关闭一个 tab。`minCount` 防止删到空（默认 0，允许删空但要小心）。
    func close(at index: Int, minCount: Int = 0) {
        guard tabs.indices.contains(index), tabs.count > minCount else { return }
        if case .remote(let tab) = tabs[index] {
            tab.disconnectIfNeeded()
        }
        tabs.remove(at: index)
        if selectedIndex >= tabs.count {
            selectedIndex = max(0, tabs.count - 1)
        }
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
    }
}
