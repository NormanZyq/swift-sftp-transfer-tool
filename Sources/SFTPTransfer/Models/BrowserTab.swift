import Foundation
import Observation

/// 浏览器 tab：可承载「本地面板」或「远程面板」。
///
/// 设计为 enum 让两种 tab 共用一种容器 `PaneColumnModel`；左右两侧都能放任意种类的 tab，
/// 传输时按 drop 目标面板的 `kind` 自动派发到正确的端点。
///
/// 由于 PaneModel / RemoteTab 都是 `@MainActor @Observable`，本枚举的所有访问器都
/// 必须在主 actor 上调用。枚举本身标记为 `@MainActor` 以反映这一点。
@MainActor
enum BrowserTab: @preconcurrency Identifiable {
    case local(PaneModel)
    case remote(RemoteTab)

    var id: UUID {
        switch self {
        case .local(let pane): return pane.id
        case .remote(let tab): return tab.id
        }
    }

    /// 任何一个 tab 都有对应的 PaneModel；远程 tab 的 pane 由 RemoteTab 拥有。
    var pane: PaneModel {
        switch self {
        case .local(let pane): return pane
        case .remote(let tab): return tab.pane
        }
    }

    /// 远程 tab 才有 RemoteTab；本地 tab 返回 nil。
    var remoteTab: RemoteTab? {
        if case .remote(let tab) = self { return tab }
        return nil
    }

    /// tab 标题：本地 = 路径最后一段；远程 = 主机 alias。
    var title: String {
        switch self {
        case .local(let pane):
            let path = pane.currentPath
            if path == "/" { return "/" }
            let last = (path as NSString).lastPathComponent
            return last.isEmpty ? path : last
        case .remote(let tab):
            return tab.title
        }
    }

    /// 是否处于「远程」种类，决定 tab 栏的 accessory 与 + 菜单的内容。
    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// 是否处于「本地」种类。
    var isLocal: Bool { !isRemote }

    /// 端点抽象：本地 → `.local`；远程 → `.remote(tabID:)`。
    /// 用作 `TransferItem.endpoint`。
    var kindEndpoint: TransferEndpoint {
        switch self {
        case .local: return .local
        case .remote(let tab): return .remote(tabID: tab.id, hostID: tab.host?.id)
        }
    }

    /// 远程 tab 才有意义：穿透到 `RemoteTab` 实例。
    var owningRemoteTab: RemoteTab? {
        if case .remote(let tab) = self { return tab }
        return nil
    }
}
