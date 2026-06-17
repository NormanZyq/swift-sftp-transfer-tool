import Foundation
import Citadel

/// 传输端点抽象：UI 不再固定"左本地/右远程"，传输层只关心源端 / 目标端的类型。
///
/// 远程端点用 `RemoteTab` 引用间接指向对应 `SFTPSession`，避免把非 `Sendable` 的
/// SFTP 通道 / Citadel 句柄直接传进传输层（actor 之间互传非 Sendable 值会编译失败或
/// 引入不可预期的重入）。
enum TransferEndpoint: Sendable, Hashable {
    case local
    case remote(tabID: RemoteTab.ID, hostID: HostEntry.ID?)
}

/// 一项可被传输的条目：源端类型 + 路径 + 名称 + 是否目录。
struct TransferItem: Sendable, Hashable {
    let endpoint: TransferEndpoint
    let path: String       // 源端绝对路径
    let name: String       // 顶层条目名（用于目标端拼路径）
    let isDirectory: Bool
}

/// 一个传输请求：从源 item 复制到目标 endpoint 下的某个目录。
struct TransferRequest: Sendable, Hashable {
    let source: TransferItem
    let destination: TransferEndpoint
    let destinationDirectory: String

    /// "把 `name` 拼到 `destinationDirectory` 下" 的目标绝对路径。
    /// 实际传输时由具体的端点实现决定（本地用 NSString 拼，远程用 POSIX 规则拼）。
    var destinationName: String { source.name }
}

extension TransferRequest {
    /// 由具体端点把 `(dir, name)` 拼成目标绝对路径。本地 / 远程的路径分隔差异在这里集中处理。
    static func resolveDestinationPath(endpoint: TransferEndpoint, directory: String, name: String) -> String {
        switch endpoint {
        case .local:
            return (directory as NSString).appendingPathComponent(name)
        case .remote:
            return SFTPSession.join(directory, name)
        }
    }
}
