import Foundation
import AppKit

/// 本地文件系统操作（基于 FileManager）。
enum LocalFileSystem {
    static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static var iCloudDrive: String {
        home + "/Library/Mobile Documents/com~apple~CloudDocs"
    }

    /// 一个快捷位置（名称 + 路径 + 图标）。
    struct Place: Identifiable, Sendable {
        let name: String
        let path: String
        let systemImage: String
        var id: String { path }
    }

    /// 本地面板「位置」菜单用的常用快捷位置；只返回在本机实际存在的（如未启用 iCloud 则自动略过）。
    static var quickPlaces: [Place] {
        let h = home
        let candidates: [Place] = [
            Place(name: "主目录",      path: h,                          systemImage: "house"),
            Place(name: "iCloud 云盘", path: iCloudDrive,                systemImage: "icloud"),
            Place(name: "桌面",        path: h + "/Desktop",             systemImage: "desktopcomputer"),
            Place(name: "文档",        path: h + "/Documents",           systemImage: "doc"),
            Place(name: "下载",        path: h + "/Downloads",           systemImage: "arrow.down.circle"),
        ]
        return candidates.filter { isDirectory($0.path) }
    }

    /// 已挂载的外接 / 可移除 / 网络卷（用于「位置」菜单的「外接磁盘」分区）；排除内置启动盘。
    static var externalVolumes: [Place] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsInternalKey, .volumeIsBrowsableKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var out: [Place] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard v.volumeIsBrowsable ?? false else { continue }
            let isInternal = v.volumeIsInternal ?? false
            let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
            guard removable || !isInternal else { continue }   // 外接/可移除/网络卷，排除内置盘
            let name = v.volumeName ?? url.lastPathComponent
            out.append(Place(name: name, path: url.path, systemImage: "externaldrive"))
        }
        return out
    }

    static func list(_ path: String, showHidden: Bool = false) -> [FileItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var items: [FileItem] = []
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = attrs?[.modificationDate] as? Date
            items.append(FileItem(name: name, path: full, isDirectory: isDir.boolValue, size: size, modified: mtime))
        }
        return items.sorted(by: FileItem.defaultSort)
    }

    /// 在 dir 下递归查找名称包含 query（不区分大小写）的条目，最多 limit 条。
    /// 设计为 `nonisolated`，便于放到后台线程跑（见 `PaneModel.runSearch`），避免卡 UI。
    static func search(in dir: String, query: String, includeHidden: Bool, limit: Int = 2000) -> [FileItem] {
        let q = query.lowercased()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                     includingPropertiesForKeys: keys,
                                     options: options) else { return [] }
        var out: [FileItem] = []
        for case let url as URL in en {
            if out.count >= limit { break }
            guard url.lastPathComponent.lowercased().contains(q) else { continue }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            out.append(FileItem(
                name: url.lastPathComponent,
                path: url.path,
                isDirectory: vals?.isDirectory ?? false,
                size: UInt64(vals?.fileSize ?? 0),
                modified: vals?.contentModificationDate
            ))
        }
        return out
    }

    static func makeDirectory(in parent: String, name: String) throws {
        let path = (parent as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    static func rename(at path: String, to newName: String) throws {
        let dst = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
        try FileManager.default.moveItem(atPath: path, toPath: dst)
    }

    /// 删除到「废纸篓」，比直接 rm 更安全、更原生。
    static func moveToTrash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// 在访达中打开 / 显示给定路径：单个目录→打开该目录；文件或多项→在访达中选中显示。
    /// 由主线程（视图按钮）调用。
    static func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        if urls.count == 1, isDirectory(urls[0].path) {
            NSWorkspace.shared.open(urls[0])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}
