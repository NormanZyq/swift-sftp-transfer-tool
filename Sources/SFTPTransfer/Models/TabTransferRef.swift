import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// 应用内拖拽专用的私有类型：tab 标签本身（用于跨列移动 tab）。
    static let sftpTabTransfer = UTType(exportedAs: "local.shyulatte.sftptransfer.tab-transfer")
}

/// tab 拖拽载体：包含源列 id 和 tab id。
/// 接收方按 tab id 在源列中找到对应 tab，移除后追加到目标列。
struct TabTransferRef: Codable, Sendable, Transferable, Hashable {
    /// 源列 `PaneColumnModel.id`
    let sourceColumnID: UUID
    /// `BrowserTab.id`（即 `PaneModel.id` 或 `RemoteTab.id`）
    let tabID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sftpTabTransfer)
    }
}
