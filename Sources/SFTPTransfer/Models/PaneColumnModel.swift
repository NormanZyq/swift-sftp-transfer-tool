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

    /// 仅"取出"一个 tab，不做任何断开 / 清理。用于跨列移动。
    /// 远程 tab 的 SFTPSession 是 actor 引用，移列后 actor 继续存活，无需重连。
    func take(at index: Int) -> BrowserTab? {
        guard tabs.indices.contains(index) else { return nil }
        let tab = tabs.remove(at: index)
        if selectedIndex >= tabs.count {
            selectedIndex = max(0, tabs.count - 1)
        }
        return tab
    }

    /// 按 tab id 查找并取出（不断开）。找不到返回 nil。
    func take(tabID: UUID) -> BrowserTab? {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        return take(at: idx)
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
    }
}
