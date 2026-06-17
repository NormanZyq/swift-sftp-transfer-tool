import Foundation
import Observation

/// 一个文件面板的状态与操作（本地或远程通用）。
@MainActor
@Observable
final class PaneModel: Identifiable {
    /// 面板实例的唯一标识（多 tab 场景下，SwiftUI ForEach 需要）。
    let id = UUID()

    enum Kind: Sendable { case local, remote }

    let kind: Kind
    var currentPath: String = "/"
    var items: [FileItem] = []
    var selection: Set<FileItem.ID> = []
    var searchText: String = ""
    var isLoading = false

    /// 表头点击驱动的排序。默认按名称升序。
    var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name)]

    /// 是否显示点文件（隐藏文件）。
    var showHidden = false

    /// 搜索框回车是否在当前目录下递归查找（而非仅过滤当前目录）。
    var recursiveSearch = false
    /// 递归搜索的结果；为 nil 表示处于普通浏览模式。
    var searchResults: [FileItem]? = nil
    /// 递归搜索进行中。
    var isSearching = false

    /// 浏览历史（访问过的路径栈），用于 后退/前进。
    private(set) var history: [String] = []
    private(set) var historyIndex = -1
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    weak var app: AppModel?

    /// 仅远程面板使用：所属 RemoteTab 的 SFTPSession（多 tab 模式下各 tab 自己的通道）。
    /// 本地面板忽略此字段。
    var remoteSession: SFTPSession? {
        didSet { /* 仅供视图层观察以触发刷新；远程 I/O 路径直接读最新值 */ }
    }

    init(kind: Kind) { self.kind = kind }

    /// 远程面板的标题由所属 tab 显式设置（"user@host:port" 之类），没设时退回 "远程"。
    /// 本地面板的标题永远是 "本地"。
    var remoteTitle: String?
    var title: String {
        switch kind {
        case .local: return "本地"
        case .remote: return remoteTitle ?? "远程"
        }
    }

    var isRemote: Bool { kind == .remote }

    /// 本地面板始终可用；远程面板只在其所属 tab 当前活跃且已连接时可用。
    /// 多 tab 模式下由 AppModel 在切换 tab 时刷新此值。
    var isEnabled: Bool {
        if kind == .local { return true }
        return app?.isActiveRemoteTabConnected == true
    }

    /// 当前展示的条目。
    /// - 普通模式：按隐藏开关过滤点文件，再按搜索词过滤当前目录，最后排序。
    /// - 递归搜索结果模式：直接展示搜索结果（已在搜索时按隐藏开关过滤），仅排序。
    /// 排序时目录恒在前（文件管理器习惯，与方向无关），方向由比较器自身处理，
    /// 末位用名称做稳定兜底（Swift 的 `sorted` 不保证稳定）。
    var displayedItems: [FileItem] {
        let source: [FileItem]
        if recursiveSearch, let searchResults {
            source = searchResults
        } else {
            var base = items
            if !showHidden { base = base.filter { !$0.name.hasPrefix(".") } }
            if !searchText.isEmpty {
                base = base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            }
            source = base
        }
        return source.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in sortOrder {
                switch comparator.compare(a, b) {
                case .orderedAscending:  return true
                case .orderedDescending: return false
                case .orderedSame:       continue
                }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    // MARK: 浏览

    func reload() async {
        _ = await reloadCurrentPath()
    }

    @discardableResult
    private func reloadCurrentPath(showAlert: Bool = true) async -> Bool {
        searchResults = nil   // 任何刷新/导航都退出递归搜索结果模式
        switch kind {
        case .local:
            items = LocalFileSystem.list(currentPath, showHidden: true) // 全部取回，显示时再按开关过滤
            selection = []
            return true
        case .remote:
            guard let app, app.isActiveRemoteTabConnected, let session = remoteSession else {
                items = []
                selection = []
                return false
            }
            isLoading = true
            defer { isLoading = false }
            do {
                items = try await session.list(currentPath)
                selection = []
                return true
            } catch {
                app.handleRemoteOperationFailure(error, pane: self, action: "无法列出 \(currentPath)", showAlert: showAlert)
                selection = []
                return false
            }
        }
    }

    /// 跳转并记入历史（截断当前位置之后的前进项；与上一条相同则不重复入栈）。
    func navigate(to path: String) {
        let previousPath = currentPath
        let previousHistory = history
        let previousHistoryIndex = historyIndex

        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last != path {
            history.append(path)
        }
        historyIndex = history.count - 1
        currentPath = path
        Task {
            let ok = await reloadCurrentPath()
            if !ok {
                currentPath = previousPath
                history = previousHistory
                historyIndex = previousHistoryIndex
            }
        }
    }

    /// 重置历史并定位到 path（用于初始化 / 连接后定位 home）。不触发 reload，由调用方刷新。
    func seedHistory(_ path: String) {
        history = [path]
        historyIndex = 0
        currentPath = path
    }

    /// 历史后退（上一个访问过的目录）。
    func goBack() {
        guard canGoBack else { return }
        let previousPath = currentPath
        let previousHistoryIndex = historyIndex
        historyIndex -= 1
        currentPath = history[historyIndex]
        Task {
            let ok = await reloadCurrentPath()
            if !ok {
                currentPath = previousPath
                historyIndex = previousHistoryIndex
            }
        }
    }

    /// 历史前进（下一个访问过的目录）。
    func goForward() {
        guard canGoForward else { return }
        let previousPath = currentPath
        let previousHistoryIndex = historyIndex
        historyIndex += 1
        currentPath = history[historyIndex]
        Task {
            let ok = await reloadCurrentPath()
            if !ok {
                currentPath = previousPath
                historyIndex = previousHistoryIndex
            }
        }
    }

    func open(_ item: FileItem) {
        guard item.isDirectory else { return }
        navigate(to: item.path)
    }

    func goUp() {
        let parent: String
        switch kind {
        case .local:
            parent = (currentPath as NSString).deletingLastPathComponent
        case .remote:
            let trimmed = currentPath.hasSuffix("/") && currentPath != "/"
                ? String(currentPath.dropLast()) : currentPath
            parent = (trimmed as NSString).deletingLastPathComponent
        }
        if !parent.isEmpty, parent != currentPath { navigate(to: parent) }
    }

    func goHome() {
        switch kind {
        case .local:
            navigate(to: LocalFileSystem.home)
        case .remote:
            guard let app, app.isActiveRemoteTabConnected, let session = remoteSession else { return }
            Task {
                do {
                    navigate(to: try await session.homeDirectory())
                } catch {
                    app.handleRemoteOperationFailure(error, pane: self, action: "无法读取远程主目录")
                }
            }
        }
    }

    // MARK: 搜索

    /// 在当前目录下递归搜索（仅在 recursiveSearch 开启且有关键词时生效）。
    /// 本地走 detached 任务避免阻塞主线程；远程经 actor 串行化的 SFTP 通道。
    func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard recursiveSearch, !query.isEmpty else { searchResults = nil; return }
        isSearching = true
        defer { isSearching = false }
        let dir = currentPath
        let hidden = showHidden
        switch kind {
        case .local:
            searchResults = await Task.detached(priority: .userInitiated) {
                LocalFileSystem.search(in: dir, query: query, includeHidden: hidden)
            }.value
        case .remote:
            guard let app, app.isActiveRemoteTabConnected, let session = remoteSession else { searchResults = []; return }
            do {
                searchResults = try await session.search(in: dir, query: query, includeHidden: hidden)
            } catch {
                app.handleRemoteOperationFailure(error, pane: self, action: "搜索失败")
                searchResults = []
            }
        }
        selection = []
    }

    /// 退出递归搜索结果模式（保持当前目录不变）。
    func clearSearchResults() { searchResults = nil }

    // MARK: 增删改

    func makeFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                switch kind {
                case .local:
                    try LocalFileSystem.makeDirectory(in: currentPath, name: trimmed)
                case .remote:
                    guard let session = remoteSession, app != nil else { return }
                    try await session.makeDirectory(at: SFTPSession.join(currentPath, trimmed))
                }
                await reload()
            } catch {
                if kind == .remote, app?.handleRemoteOperationFailure(error, pane: self, action: "新建文件夹失败") == true {
                    return
                } else {
                    app?.errorMessage = "新建文件夹失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        Task {
            do {
                switch kind {
                case .local:
                    try LocalFileSystem.rename(at: item.path, to: trimmed)
                case .remote:
                    guard let session = remoteSession, app != nil else { return }
                    let dst = SFTPSession.join((item.path as NSString).deletingLastPathComponent, trimmed)
                    try await session.rename(from: item.path, to: dst)
                }
                await reload()
            } catch {
                if kind == .remote, app?.handleRemoteOperationFailure(error, pane: self, action: "重命名失败") == true {
                    return
                } else {
                    app?.errorMessage = "重命名失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func delete(_ targets: [FileItem]) {
        guard !targets.isEmpty else { return }
        Task {
            for item in targets {
                do {
                    switch kind {
                    case .local:
                        try LocalFileSystem.moveToTrash(item.path)
                    case .remote:
                        guard let session = remoteSession else { return }
                        try await session.remove(path: item.path, isDirectory: item.isDirectory)
                    }
                } catch {
                    if kind == .remote,
                       app?.handleRemoteOperationFailure(error, pane: self, action: "删除「\(item.name)」失败") == true {
                        return
                    }
                    app?.errorMessage = "删除「\(item.name)」失败：\(error.localizedDescription)"
                }
            }
            await reload()
        }
    }
}
