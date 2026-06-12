import SwiftUI

/// 单个文件面板（本地或远程通用）：路径栏 + 搜索 + 多选表格 + 右键菜单。
struct FilePaneView: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var app

    @State private var pathField = ""
    @State private var newFolderPresented = false
    @State private var newFolderName = ""
    @State private var renameTarget: FileItem?
    @State private var renameText = ""
    @State private var deleteTargets: [FileItem] = []
    @State private var deletePresented = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 6) {
            header
            pathBar
            table
        }
        .padding(6)
        .disabled(!pane.isEnabled)
        .onAppear { pathField = pane.currentPath }
        .onChange(of: pane.currentPath) { _, newValue in pathField = newValue }
        .alert("新建文件夹", isPresented: $newFolderPresented) {
            TextField("名称", text: $newFolderName)
            Button("创建") { pane.makeFolder(named: newFolderName) }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil },
                                          set: { if !$0 { renameTarget = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确定") {
                if let target = renameTarget { pane.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(deleteMessage, isPresented: $deletePresented, titleVisibility: .visible) {
            Button(pane.isRemote ? "删除" : "移到废纸篓", role: .destructive) {
                pane.delete(deleteTargets)
                deleteTargets = []
            }
            Button("取消", role: .cancel) { deleteTargets = [] }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(pane.title).font(.headline)
            if pane.recursiveSearch, let results = pane.searchResults {
                Text("· 搜索结果 \(results.count)\(results.count >= 2000 ? "+" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清除") { pane.clearSearchResults() }
                    .buttonStyle(.borderless).font(.caption)
            }
            Spacer()
            if pane.isLoading || pane.isSearching { ProgressView().controlSize(.small) }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            // 导航簇：后退 / 前进 / 上级 / 主目录
            HStack(spacing: 2) {
                Button { pane.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!pane.canGoBack).help("后退")
                Button { pane.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!pane.canGoForward).help("前进")
                Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
                    .help("上级目录")
                Button { pane.goHome() } label: { Image(systemName: "house") }
                    .help("主目录")
            }

            toolbarDivider

            Button { Task { await pane.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新")
            if !pane.isRemote { placesMenu }

            toolbarDivider

            TextField("路径", text: $pathField)
                .textFieldStyle(.roundedBorder)
                .onSubmit { pane.navigate(to: pathField) }

            Button {
                pane.recursiveSearch.toggle()
                if !pane.recursiveSearch { pane.clearSearchResults() }
            } label: {
                Image(systemName: pane.recursiveSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
            }
            .help(pane.recursiveSearch ? "递归搜索：回车在子目录中查找（点击切回仅当前目录）"
                                       : "仅过滤当前目录（点击切换为递归搜索）")
            TextField(pane.recursiveSearch ? "递归搜索后回车" : "搜索", text: $pane.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit { if pane.recursiveSearch { Task { await pane.runSearch() } } }
                .onChange(of: pane.searchText) { _, newValue in
                    if newValue.isEmpty { pane.clearSearchResults() }
                }

            toolbarDivider

            overflowMenu
        }
        .buttonStyle(.borderless)
    }

    /// 工具栏分组之间的竖直分隔。
    private var toolbarDivider: some View {
        Divider().frame(height: 16)
    }

    /// 「位置」菜单（仅本地）：常用快捷位置 + 外接磁盘分区，当前位置带勾。
    private var placesMenu: some View {
        Menu {
            ForEach(LocalFileSystem.quickPlaces) { placeButton($0) }
            let volumes = LocalFileSystem.externalVolumes
            if !volumes.isEmpty {
                Section("外接磁盘") {
                    ForEach(volumes) { placeButton($0) }
                }
            }
        } label: {
            Image(systemName: "mappin.and.ellipse")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("快速位置")
    }

    private func placeButton(_ place: LocalFileSystem.Place) -> some View {
        Button {
            if pane.currentPath != place.path { pane.navigate(to: place.path) }
        } label: {
            Label(place.name, systemImage: pane.currentPath == place.path ? "checkmark" : place.systemImage)
        }
    }

    /// 溢出菜单：把不常用的动作收纳起来，保持工具栏清爽。
    private var overflowMenu: some View {
        Menu {
            Button { newFolderName = ""; newFolderPresented = true } label: {
                Label("新建文件夹…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Toggle(isOn: $pane.showHidden) {
                Label("显示隐藏文件", systemImage: "eye")
            }
            if !pane.isRemote {
                Divider()
                Button { LocalFileSystem.revealInFinder([pane.currentPath]) } label: {
                    Label("在访达中打开当前目录", systemImage: "arrow.up.forward.app")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    private var tableCore: some View {
        Table(of: FileItem.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("名称", value: \.name) { item in
                Label(item.name, systemImage: item.isDirectory ? "folder.fill" : "doc")
            }
            TableColumn("大小", value: \.size) { item in
                Text(item.isDirectory ? "—" : formatSize(item.size))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("修改时间", value: \.modifiedSortKey) { item in
                Text(item.modified.map { Self.dateFormatter.string(from: $0) } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
        } rows: {
            // 行级 .draggable：点到文字也能正常选中（单元格级 draggable 会拦截点击），并支持多选拖拽。
            if pane.isRemote {
                ForEach(pane.displayedItems) { item in
                    TableRow(item)
                        .draggable(RemoteItemRef(path: item.path, name: item.name, isDirectory: item.isDirectory))
                }
            } else {
                ForEach(pane.displayedItems) { item in
                    TableRow(item)
                        .draggable(URL(fileURLWithPath: item.path))
                }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let item = pane.displayedItems.first(where: { $0.id == id }) {
                pane.open(item)
            }
        }
    }

    @ViewBuilder
    private var table: some View {
        if pane.isRemote {
            // 远程面板：接收来自本地 / 访达的 URL → 上传。
            tableCore.dropDestination(for: URL.self) { urls, _ in
                guard app.isActiveRemoteTabConnected else { return false }
                app.dropLocalPaths(urls.map(\.path), toRemoteDir: pane.currentPath)
                return true
            }
        } else {
            // 本地面板：接收来自远程面板的条目 → 下载。
            tableCore.dropDestination(for: RemoteItemRef.self) { refs, _ in
                guard app.isActiveRemoteTabConnected else { return false }
                app.dropRemoteItems(refs, toLocalDir: pane.currentPath)
                return true
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<FileItem.ID>) -> some View {
        let targets = pane.displayedItems.filter { ids.contains($0.id) }
        if pane.isRemote {
            Button("下载") { pane.selection = ids; app.downloadSelection() }
                .disabled(targets.isEmpty)
        } else {
            Button("上传") { pane.selection = ids; app.uploadSelection() }
                .disabled(targets.isEmpty || !app.isActiveRemoteTabConnected)
        }
        if !pane.isRemote, !targets.isEmpty {
            Button("在访达中打开") { LocalFileSystem.revealInFinder(targets.map(\.path)) }
        }
        Divider()
        Button("新建文件夹…") { newFolderName = ""; newFolderPresented = true }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        if targets.count == 1, let only = targets.first {
            Button("重命名…") { renameTarget = only; renameText = only.name }
        }
        if !targets.isEmpty {
            Button(pane.isRemote ? "删除" : "移到废纸篓", role: .destructive) {
                deleteTargets = targets
                deletePresented = true
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
    }

    private var deleteMessage: String {
        if deleteTargets.count == 1 {
            return pane.isRemote ? "确定删除「\(deleteTargets[0].name)」？此操作不可撤销。"
                                 : "把「\(deleteTargets[0].name)」移到废纸篓？"
        }
        return pane.isRemote ? "确定删除选中的 \(deleteTargets.count) 项？此操作不可撤销。"
                             : "把选中的 \(deleteTargets.count) 项移到废纸篓？"
    }
}
