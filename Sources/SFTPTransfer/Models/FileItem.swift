import Foundation

/// 本地或远程的一个文件/目录条目（统一模型）。
/// 本地：`path` 为文件系统路径；远程：`path` 为服务器上的 POSIX 绝对路径。
struct FileItem: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date?

    var id: String { path }

    /// 用于排序的修改时间：缺失时视为最早，避免 `Date?` 不满足 `Comparable`。
    var modifiedSortKey: Date { modified ?? .distantPast }
}

extension FileItem {
    /// 默认排序：目录在前，其余按名称（不区分大小写）。
    static func defaultSort(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

/// 体积的人类可读表示。
func formatSize(_ n: UInt64) -> String {
    if n < 1024 { return "\(n) B" }
    var value = Double(n)
    for unit in ["KB", "MB", "GB", "TB"] {
        value /= 1024
        if value < 1024 { return String(format: "%.1f %@", value, unit) }
    }
    return String(format: "%.1f PB", value)
}
