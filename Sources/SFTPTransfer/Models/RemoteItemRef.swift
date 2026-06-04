import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// 应用内拖拽专用的私有类型：远程文件条目（不与访达等外部落点混淆）。
    static let sftpRemoteItem = UTType(exportedAs: "local.shyulatte.sftptransfer.remote-item")
}

/// 远程条目的可拖拽载体：远程面板 → 本地面板触发下载。
/// 远程路径无法用真实文件 URL 表示，故用自定义 `Transferable`（仅应用内有意义）。
struct RemoteItemRef: Codable, Sendable, Transferable {
    let path: String
    let name: String
    let isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sftpRemoteItem)
    }
}
