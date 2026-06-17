import SwiftUI
import AppKit

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
    @State private var propertyTarget: FileItem?
    @State private var propertyState: RemotePropertyState = .idle
    @State private var propertyTask: Task<Void, Never>?
    @State private var quickPropertyTarget: FileItem?
    @State private var quickPropertyState: RemotePropertyState = .idle
    @State private var quickPropertyTask: Task<Void, Never>?
    @State private var quickKeyMonitor: Any?
    @State private var isHoveringForQuickProperties = false

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
        .overlay(alignment: .topTrailing) {
            if let quickPropertyTarget {
                RemoteQuickPropertyPanel(item: quickPropertyTarget, state: quickPropertyState)
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: quickPropertyTarget?.id)
        .onHover { isHoveringForQuickProperties = $0 }
        .background {
            PaneFocusTrackingView {
                focusThisPane()
            }
        }
        .onAppear {
            pathField = pane.currentPath
            installQuickPropertyMonitor()
        }
        .onDisappear {
            removeQuickPropertyMonitor()
            closeQuickPropertyPanel()
        }
        .onChange(of: pane.currentPath) { _, newValue in pathField = newValue }
        .onChange(of: pane.selection) { _, _ in
            refreshQuickPropertyPanelForSelection()
        }
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
        .sheet(item: $propertyTarget, onDismiss: {
            propertyTask?.cancel()
            propertyTask = nil
            propertyState = .idle
        }) { item in
            RemotePropertySheet(item: item, state: propertyState) {
                propertyTarget = nil
            }
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
            // 统一使用 TransferItemRef：本地条目 → .local；远程条目 → .remote(tabID:)。
            ForEach(pane.displayedItems) { item in
                TableRow(item)
                    .draggable(draggableRef(for: item))
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

    /// 把当前面板的 FileItem 包装成对应的 TransferItemRef。
    private func draggableRef(for item: FileItem) -> TransferItemRef {
        if pane.isRemote, let tab = app.remoteTab(forPane: pane) {
            return .remote(tabID: tab.id, path: item.path, name: item.name, isDirectory: item.isDirectory)
        }
        return .local(path: item.path, name: item.name, isDirectory: item.isDirectory)
    }

    @ViewBuilder
    private var table: some View {
        // 任何面板都接收统一 TransferItemRef；目标端点 = 当前面板的 endpoint。
        tableCore.dropDestination(for: TransferItemRef.self) { refs, _ in
            app.dropTransferItems(refs, into: pane)
            return true
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<FileItem.ID>) -> some View {
        let targets = pane.displayedItems.filter { ids.contains($0.id) }
        if pane.isRemote {
            Button("下载") { pane.selection = ids; app.transferFromPaneToOpposite(pane) }
                .disabled(targets.isEmpty || !app.canUploadDownloadFromPaneToOpposite(pane))
            if targets.count == 1, let only = targets.first {
                Button("查看属性…") { showRemoteProperties(for: only) }
            }
        } else {
            Button("上传") { pane.selection = ids; app.transferFromPaneToOpposite(pane) }
                .disabled(targets.isEmpty || !app.canUploadDownloadFromPaneToOpposite(pane))
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

    private func showRemoteProperties(for item: FileItem) {
        propertyTask?.cancel()
        propertyTarget = item
        propertyState = .loading
        guard let session = pane.remoteSession else {
            propertyState = .failed("尚未连接到服务器")
            return
        }

        propertyTask = Task {
            do {
                let properties = try await session.properties(for: item)
                guard !Task.isCancelled else { return }
                propertyState = .loaded(properties)
            } catch is CancellationError {
                // sheet 关闭时取消即可，不需要打扰用户。
            } catch {
                guard !Task.isCancelled else { return }
                propertyState = .failed(error.localizedDescription)
                app.handleRemoteOperationFailure(error, pane: pane, action: "读取远程属性失败", showAlert: false)
            }
        }
    }

    private func focusThisPane() {
        if let column = app.column(forPane: pane) {
            app.setFocus(to: column)
        }
    }

    private func installQuickPropertyMonitor() {
        guard quickKeyMonitor == nil else { return }
        quickKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldHandleQuickPropertyKey(event) else { return event }
            if !event.isARepeat {
                Task { @MainActor in toggleQuickPropertyPanel() }
            }
            return nil
        }
    }

    private func removeQuickPropertyMonitor() {
        if let quickKeyMonitor {
            NSEvent.removeMonitor(quickKeyMonitor)
            self.quickKeyMonitor = nil
        }
    }

    private func shouldHandleQuickPropertyKey(_ event: NSEvent) -> Bool {
        guard pane.isRemote, pane.isEnabled, isHoveringForQuickProperties else { return false }
        guard event.charactersIgnoringModifiers == " " else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }
        guard !isTextInputActive() else { return false }
        return true
    }

    private func isTextInputActive() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func toggleQuickPropertyPanel() {
        if quickPropertyTarget != nil {
            closeQuickPropertyPanel()
            return
        }
        guard let item = singleSelectedDisplayedItem() else { return }
        showQuickProperties(for: item)
    }

    private func refreshQuickPropertyPanelForSelection() {
        guard quickPropertyTarget != nil else { return }
        guard let item = singleSelectedDisplayedItem() else {
            closeQuickPropertyPanel()
            return
        }
        if quickPropertyTarget?.id != item.id {
            showQuickProperties(for: item)
        }
    }

    private func singleSelectedDisplayedItem() -> FileItem? {
        guard pane.selection.count == 1, let id = pane.selection.first else { return nil }
        return pane.displayedItems.first { $0.id == id }
    }

    private func showQuickProperties(for item: FileItem) {
        quickPropertyTask?.cancel()
        quickPropertyTarget = item
        quickPropertyState = .loading
        guard let session = pane.remoteSession else {
            quickPropertyState = .failed("尚未连接到服务器")
            return
        }

        quickPropertyTask = Task {
            do {
                let properties = try await session.properties(for: item)
                guard !Task.isCancelled else { return }
                quickPropertyState = .loaded(properties)
            } catch is CancellationError {
                // 选择变化或再次按空格时取消即可。
            } catch {
                guard !Task.isCancelled else { return }
                quickPropertyState = .failed(error.localizedDescription)
                app.handleRemoteOperationFailure(error, pane: pane, action: "读取远程属性失败", showAlert: false)
            }
        }
    }

    private func closeQuickPropertyPanel() {
        quickPropertyTask?.cancel()
        quickPropertyTask = nil
        quickPropertyTarget = nil
        quickPropertyState = .idle
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

/// 只负责把“鼠标事件落在这个文件面板里”上报给 SwiftUI。
/// 用本地事件监听而不是透明 overlay，避免拦截 Table、按钮、文本框的原有交互。
private struct PaneFocusTrackingView: NSViewRepresentable {
    var onFocus: () -> Void

    func makeNSView(context: Context) -> FocusTrackingNSView {
        let view = FocusTrackingNSView()
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ nsView: FocusTrackingNSView, context: Context) {
        nsView.onFocus = onFocus
    }

    final class FocusTrackingNSView: NSView {
        var onFocus: (() -> Void)?
        private var mouseMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMouseMonitor()
            } else {
                installMouseMonitor()
            }
        }

        deinit {
            removeMouseMonitor()
        }

        private func installMouseMonitor() {
            removeMouseMonitor()
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func removeMouseMonitor() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            onFocus?()
        }
    }
}

private enum RemotePropertyState {
    case idle
    case loading
    case loaded(RemoteItemProperties)
    case failed(String)
}

private struct RemotePropertySheet: View {
    let item: FileItem
    let state: RemotePropertyState
    let onClose: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .font(.title2)
                    .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.isDirectory ? "远程文件夹" : "远程文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                propertyRow("位置", item.path)
                propertyRow("类型", item.isDirectory ? "文件夹" : "文件")
                propertyRow("修改时间", item.modified.map { Self.dateFormatter.string(from: $0) } ?? "未知")
                sizeRows
            }

            if case .loading = state {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(item.isDirectory ? "正在递归计算文件夹大小…" : "正在读取属性…")
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("关闭") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var sizeRows: some View {
        switch state {
        case .idle, .loading:
            propertyRow("大小", item.isDirectory ? "计算中…" : formatSize(item.size))
        case .loaded(let properties):
            propertyRow("大小", formatSize(properties.totalSize))
            if item.isDirectory {
                propertyRow("包含", "\(properties.fileCount) 个文件，\(properties.directoryCount) 个文件夹")
            }
        case .failed:
            propertyRow("大小", item.isDirectory ? "计算失败" : formatSize(item.size))
        }
    }

    private func propertyRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

private struct RemoteQuickPropertyPanel: View {
    let item: FileItem
    let state: RemotePropertyState

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .font(.title3)
                    .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                quickRow("类型", item.isDirectory ? "文件夹" : "文件")
                quickRow("修改时间", item.modified.map { Self.dateFormatter.string(from: $0) } ?? "未知")
                switch state {
                case .idle, .loading:
                    quickRow("大小", item.isDirectory ? "计算中…" : formatSize(item.size))
                case .loaded(let properties):
                    quickRow("大小", formatSize(properties.totalSize))
                    if item.isDirectory {
                        quickRow("包含", "\(properties.fileCount) 个文件，\(properties.directoryCount) 个文件夹")
                    }
                case .failed:
                    quickRow("大小", item.isDirectory ? "计算失败" : formatSize(item.size))
                }
            }

            if case .loading = state {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(item.isDirectory ? "正在递归计算…" : "正在读取…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func quickRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
