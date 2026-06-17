import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// 应用内拖拽专用的私有类型：本地或远程文件条目（不与访达等外部落点混淆）。
    /// 远程路径无法用真实文件 URL 表示，故用自定义 `Transferable`（仅应用内有意义）。
    static let sftpTransferItem = UTType(exportedAs: "local.shyulatte.sftptransfer.transfer-item")
}

/// 拖拽条目统一类型：覆盖本地 / 远程两种来源。
/// 替代了原来的「本地用 URL、远程用 RemoteItemRef」两套拖拽数据模型。
///
/// - 接收方（drop destination）通过 `endpoint` 决定目标端类型（不再硬编码"左本地/右远程"）。
/// - 远程 ref 内嵌 `tabID`，drop 时可以反查所属 `SFTPSession`；tab 关闭时拒绝传输。
enum TransferItemRef: Codable, Sendable, Transferable, Hashable {
    case local(path: String, name: String, isDirectory: Bool)
    case remote(tabID: UUID, path: String, name: String, isDirectory: Bool)

    var path: String {
        switch self {
        case .local(let path, _, _), .remote(_, let path, _, _):
            return path
        }
    }

    var name: String {
        switch self {
        case .local(_, let name, _), .remote(_, _, let name, _):
            return name
        }
    }

    var isDirectory: Bool {
        switch self {
        case .local(_, _, let isDir), .remote(_, _, _, let isDir):
            return isDir
        }
    }

    /// 源端 endpoint。本地条目 → `.local`；远程条目 → `.remote(tabID:)`。
    var sourceEndpoint: TransferEndpoint {
        switch self {
        case .local:
            return .local
        case .remote(let tabID, _, _, _):
            return .remote(tabID: tabID, hostID: nil)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sftpTransferItem)
    }
}
