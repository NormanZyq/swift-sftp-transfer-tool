import Foundation
import Observation
import Citadel

/// 一个远程 tab = 一台服务器 = 一条 SSH/SFTP 连接。
/// 自身拥有连接状态、面板与专属的 SFTPSession（与其他 tab 不共享）。
/// 连接流程由 AppModel 驱动：AppModel 在活跃 tab 上跑 attemptConnect 流程，
/// 把本 tab 的 session / state 作为副作用更新。
@MainActor
@Observable
final class RemoteTab: Identifiable {
    enum ConnectionState: Sendable { case disconnected, connecting, connected }

    let id = UUID()

    /// 该 tab 关联的主机。允许为 nil：用户可能先建空 tab 再从 picker 选主机。
    var host: HostEntry?

    var state: ConnectionState = .disconnected
    var statusText = "未连接"

    /// 自己的 SFTP 通道（独立 actor），与其他 tab 不共享。
    let session = SFTPSession()

    /// 该 tab 自己的文件面板（远程）。
    let pane: PaneModel

    /// 反向引用：等 AppModel 创建本 tab 后回填，让 PaneModel 可以找到所属 AppModel
    /// （用于 engine / 共享弹窗等）。弱引用避免循环（AppModel → RemoteTab → PaneModel → AppModel）。
    weak var appRef: AppModel?

    init(host: HostEntry? = nil) {
        self.host = host
        self.pane = PaneModel(kind: .remote)
    }

    var title: String {
        host?.alias ?? "新连接"
    }

    /// 是否已连上。`AppModel.isActiveRemoteTabConnected` 等会读取此值。
    var isConnected: Bool { state == .connected }

    /// 关闭该 tab 时如果还连着，先断开。断开后调用方负责从 tabs 数组中移除。
    func disconnectIfNeeded() {
        guard state != .disconnected else { return }
        Task { [session] in
            await session.disconnect()
            self.pane.items = []
            self.pane.selection = []
            self.state = .disconnected
            self.statusText = "未连接"
        }
    }
}
