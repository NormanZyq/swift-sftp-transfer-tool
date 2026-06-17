import Foundation
import Observation
import Citadel

/// 顶层应用状态：主机列表、本地 / 远程多 tab、传输引擎、各种交互弹窗。
///
/// 多 tab 设计：
/// - 左侧是若干个「本地 tab」：每个 tab = 一个 PaneModel(.local)，自带 path / 历史。
/// - 右侧是若干个「远程 tab」：每个 tab = 一台服务器 = 一条独立 SFTPSession 通道。
/// - 顶栏 picker 把已有 tab 聚焦，或为新主机开一个新 tab。
/// - 传输始终从当前活跃本地 tab 出发，到当前活跃远程 tab 结束。
@MainActor
@Observable
final class AppModel {
    // MARK: 主机列表
    var hosts: [HostEntry] = []
    /// picker 当前选中的主机 ID。始终与活跃远程 tab 的 host 保持一致：
    /// tab 切换 / 关闭 / 新增时由对应路径同步更新。
    var selectedHostID: HostEntry.ID?
    var serverConfigPresented = false
    private var serverCatalog = StoredServerCatalog()

    // MARK: Tab 容器
    /// 左侧列：默认放本地 tab，可混合。
    let leftColumn = PaneColumnModel()
    /// 右侧列：默认放远程 tab，可混合。
    let rightColumn = PaneColumnModel()

    // MARK: 共享传输引擎
    let engine = TransferEngine()

    // MARK: 全局弹窗（来自最近一次 connect 流程的中间态）
    var errorMessage: String?
    var passphrasePrompt: PassphrasePrompt?
    var hostKeyPrompt: HostKeyPrompt?

    /// 当前传输任务的句柄，用于取消。
    private var transferTask: Task<Void, Never>?

    init() {
        loadServerCatalog()
        selectedHostID = hosts.first?.id

        // 初始：左侧 1 个本地 tab，定位到主目录；右侧 1 个空远程 tab（用户随后从 picker 选主机）
        addLocalTab(initialPath: LocalFileSystem.home)
        addRemoteTab()
        if let firstHost = hosts.first {
            assignHostToActiveRemoteTab(firstHost)
        }
    }

    // MARK: 服务器配置

    func refreshSSHConfigHosts() {
        rebuildHosts()
        saveServerCatalog()
        engine.appendLog("已刷新 ~/.ssh/config 服务器条目")
    }

    func saveManualHost(_ host: HostEntry, password: String?) throws {
        var saved = host
        saved.customID = host.customID ?? UUID().uuidString
        saved.source = .manual
        saved.authentication = .password
        saved.identityFile = nil

        if let password, !password.isEmpty {
            try PasswordVault.savePassword(password, for: saved.id)
        } else if !serverCatalog.manualHosts.contains(where: { $0.id == saved.id }) {
            throw PasswordVaultError.missingPassword
        }

        if let idx = serverCatalog.manualHosts.firstIndex(where: { $0.id == saved.id }) {
            serverCatalog.manualHosts[idx] = saved
        } else {
            serverCatalog.manualHosts.append(saved)
            serverCatalog.order.append(saved.id)
        }

        rebuildHosts()
        saveServerCatalog()
    }

    func deleteManualHost(_ id: HostEntry.ID) {
        guard let host = hosts.first(where: { $0.id == id }), host.isEditable else { return }
        serverCatalog.manualHosts.removeAll { $0.id == id }
        serverCatalog.order.removeAll { $0 == id }
        try? PasswordVault.deletePassword(for: id)
        rebuildHosts()
        saveServerCatalog()
    }

    func moveHost(_ id: HostEntry.ID, by delta: Int) {
        guard let from = hosts.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(hosts.count - 1, from + delta))
        guard from != to else { return }
        let host = hosts.remove(at: from)
        hosts.insert(host, at: to)
        serverCatalog.order = hosts.map(\.id)
        saveServerCatalog()
    }

    func moveHosts(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted()
        guard !moving.isEmpty else { return }
        let movedHosts = moving.map { hosts[$0] }
        for index in moving.reversed() {
            hosts.remove(at: index)
        }
        let removedBeforeDestination = moving.filter { $0 < toOffset }.count
        let insertion = max(0, min(hosts.count, toOffset - removedBeforeDestination))
        hosts.insert(contentsOf: movedHosts, at: insertion)
        serverCatalog.order = hosts.map(\.id)
        saveServerCatalog()
    }

    func hostPassword(_ id: HostEntry.ID) -> String? {
        try? PasswordVault.password(for: id)
    }

    func testConnection(host: HostEntry, password: String?) async -> Result<Void, Error> {
        do {
            let auth = try PrivateKeyLoader.authMethod(for: host, passphrase: nil, passwordOverride: password)
            let known = KnownHosts.trustedKeys(host: host.hostName, port: host.port)
            let validator = KnownHostsValidator(host: host.hostName, port: host.port, known: known)
            let session = SFTPSession()
            do {
                try await session.connect(host: host, auth: auth, validator: validator)
                _ = try? await session.homeDirectory()
                await session.disconnect()
                return .success(())
            } catch {
                await session.disconnect()
                if case .unknown(let info) = validator.outcome { return .failure(info) }
                if case .mismatch(let mismatch) = validator.outcome { return .failure(mismatch) }
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    private func loadServerCatalog() {
        serverCatalog = ServerStore.load()
        rebuildHosts()
    }

    private func rebuildHosts() {
        let sshHosts = SSHConfig.loadHosts()
        hosts = ServerStore.merged(
            sshHosts: sshHosts,
            manualHosts: serverCatalog.manualHosts,
            order: serverCatalog.order
        )
        serverCatalog.order = hosts.map(\.id)
        if let selectedHostID, hosts.contains(where: { $0.id == selectedHostID }) {
            return
        }
        selectedHostID = activeRemoteTab?.host.flatMap { active in
            hosts.first(where: { $0.id == active.id })?.id
        } ?? hosts.first?.id
    }

    private func saveServerCatalog() {
        do {
            try ServerStore.save(serverCatalog)
        } catch {
            fail(error)
        }
    }

    // MARK: 派生属性

    /// 兼容旧调用点：活跃的「本地 tab」——左侧列的活跃 tab 若是 .local 则返回它。
    /// 顶栏「传输到另一侧」按钮和拖拽目标都通过这个判断"本地侧"是否就绪。
    var activeLocalPane: PaneModel? {
        if case .local(let pane) = leftColumn.activeTab { return pane }
        return nil
    }

    /// 兼容旧调用点：活跃的「远程 tab」——右侧列的活跃 tab 若是 .remote 则返回它。
    /// 顶栏 host picker、连接按钮等仍按"右侧活跃远程 tab"工作；后续可扩展为支持两列任一活跃 tab。
    var activeRemoteTab: RemoteTab? {
        rightColumn.activeRemoteTab
    }

    /// 当前活跃远程 tab 是否已连接。多 tab 模式下，远程面板的可用性、传输的"目标 session"
    /// 等都看这个标志。
    var isActiveRemoteTabConnected: Bool {
        activeRemoteTab?.isConnected == true
    }

    /// 遍历所有列中存在的远程 tab（用于 session 反查）。包含左侧 / 右侧两列。
    /// 同名 `allRemoteTabsList`（方法）也提供等价能力；这里保留属性以兼容旧调用点。
    private var allRemoteTabs: [RemoteTab] {
        (leftColumn.tabs + rightColumn.tabs).compactMap { $0.remoteTab }
    }

    /// 兼容旧调用点：picker 是否能发起连接 = 活跃远程 tab 存在且未在连接中。
    var canConnect: Bool {
        guard let tab = activeRemoteTab, tab.host != nil else { return false }
        return tab.state == .disconnected
    }

    /// 顶栏 host picker 只替换当前远程 tab 的主机，不跨 tab 查找或切换。
    /// 若当前 tab 已有连接，则先断开旧会话，再自动连接到新选中的主机。
    func selectHost(_ id: HostEntry.ID?) {
        selectedHostID = id
        guard let id,
              let host = hosts.first(where: { $0.id == id }),
              let tab = activeRemoteTab,
              tab.host?.id != host.id else { return }

        if tab.state == .disconnected {
            assign(host, to: tab)
        } else {
            replaceConnectedHost(on: tab, with: host)
        }
    }

    // MARK: Tab 管理

    /// 兼容旧调用点：左侧列里的本地 tab 列表。
    var localTabs: [PaneModel] {
        leftColumn.tabs.compactMap { tab -> PaneModel? in
            if case .local(let pane) = tab { return pane }
            return nil
        }
    }
    var selectedLocalTabIndex: Int {
        get { leftColumn.selectedIndex }
        set { leftColumn.selectedIndex = newValue }
    }

    /// 兼容旧调用点：右侧列里的远程 tab 列表。
    var remoteTabs: [RemoteTab] {
        rightColumn.tabs.compactMap { $0.remoteTab }
    }
    var selectedRemoteTabIndex: Int {
        get { rightColumn.selectedIndex }
        set { rightColumn.selectedIndex = newValue }
    }

    /// 新建本地 tab（默认追加到左侧列）。`path` 缺省 = 主目录。
    @discardableResult
    func addLocalTab(initialPath path: String = LocalFileSystem.home, in column: PaneColumnModel? = nil) -> PaneModel {
        let pane = PaneModel(kind: .local)
        pane.app = self
        pane.seedHistory(path)
        (column ?? leftColumn).append(.local(pane))
        Task { await pane.reload() }
        return pane
    }

    /// 关闭一个本地 tab。index 越界或只剩一个本地 tab 时不关闭。
    func closeLocalTab(at index: Int) {
        // 找到左侧列中第 N 个 .local tab 的实际列索引
        var n = 0
        for (colIdx, tab) in leftColumn.tabs.enumerated() {
            if case .local = tab {
                if n == index {
                    leftColumn.close(at: colIdx, minCount: leftColumn.tabs.count - 1)
                    return
                }
                n += 1
            }
        }
    }

    /// 新建远程 tab（默认追加到右侧列）。`host` 可为 nil。
    @discardableResult
    func addRemoteTab(host: HostEntry? = nil, in column: PaneColumnModel? = nil) -> RemoteTab {
        let tab = RemoteTab(host: host)
        tab.appRef = self
        tab.pane.app = self
        tab.pane.remoteSession = tab.session
        (column ?? rightColumn).append(.remote(tab))
        if let host {
            tab.pane.remoteTitle = "\(host.user)@\(host.alias)"
            selectedHostID = host.id
        }
        return tab
    }

    /// 关闭右侧列里第 N 个远程 tab。
    func closeRemoteTab(at index: Int) {
        var n = 0
        for (colIdx, tab) in rightColumn.tabs.enumerated() {
            if case .remote = tab {
                if n == index {
                    rightColumn.close(at: colIdx)
                    break
                }
                n += 1
            }
        }
        // 同步顶栏 picker
        if let active = activeRemoteTab {
            selectedHostID = active.host?.id
        } else {
            selectedHostID = nil
        }
    }

    /// 选中右侧列中第 N 个远程 tab。
    func selectRemoteTab(at index: Int) {
        var n = 0
        for (colIdx, tab) in rightColumn.tabs.enumerated() {
            if case .remote = tab {
                if n == index {
                    rightColumn.select(colIdx)
                    let tab = rightColumn.tabs[colIdx]
                    if case .remote(let rtab) = tab {
                        if let host = rtab.host {
                            rtab.pane.remoteTitle = "\(host.user)@\(host.alias)"
                            selectedHostID = host.id
                        } else {
                            selectedHostID = nil
                        }
                    }
                    return
                }
                n += 1
            }
        }
    }

    /// 把活跃远程 tab 关联到某台主机（顶栏 picker 选了一台新主机时用）。
    func assignHostToActiveRemoteTab(_ host: HostEntry) {
        guard let tab = activeRemoteTab else { return }
        assign(host, to: tab)
    }

    private func assign(_ host: HostEntry, to tab: RemoteTab) {
        if tab.host?.id != host.id {
            tab.shouldRestorePathOnNextConnect = false
        }
        tab.host = host
        tab.pane.remoteTitle = "\(host.user)@\(host.alias)"
        selectedHostID = host.id
    }

    private func replaceConnectedHost(on tab: RemoteTab, with host: HostEntry) {
        tab.statusText = "正在切换到 \(host.alias)…"

        Task { [weak self, tab] in
            await tab.session.disconnect()
            tab.pane.items = []
            tab.pane.selection = []
            tab.state = .connecting
            tab.statusText = "连接中 \(host.alias)…"
            self?.assign(host, to: tab)
            await self?.runConnect(tab: tab, host: host, passphrase: nil)
        }
    }

    // MARK: 连接 / 断开

    /// 连接当前活跃远程 tab。`passphrase` 用于带口令私钥的二次输入。
    func connect(passphrase: String? = nil) {
        guard let tab = activeRemoteTab, let host = tab.host, tab.state == .disconnected else { return }
        tab.state = .connecting
        tab.statusText = "连接中 \(host.alias)…"

        Task { [weak self] in
            await self?.runConnect(tab: tab, host: host, passphrase: passphrase)
        }
    }

    /// 把上次弹出的口令回填进对应 tab 的连接流程。
    func submitPassphrase(_ passphrase: String) {
        guard passphrasePrompt != nil else { return }
        passphrasePrompt = nil
        connect(passphrase: passphrase)
    }

    func confirmUnknownHost() {
        guard let prompt = hostKeyPrompt, let tab = activeRemoteTab, tab.host != nil else { return }
        hostKeyPrompt = nil
        KnownHosts.append(host: prompt.info.host, port: prompt.info.port, openSSHLine: prompt.info.openSSHLine)
        engine.appendLog("已将 \(prompt.info.host) 写入 known_hosts")
        connect(passphrase: prompt.passphrase)
    }

    func cancelUnknownHost() {
        hostKeyPrompt = nil
        activeRemoteTab?.state = .disconnected
        activeRemoteTab?.statusText = "未连接"
    }

    /// 真正跑 connect 的私有方法：被 `connect` 触发，因 pass prompt / 未知主机可能要重入。
    private func runConnect(tab: RemoteTab, host: HostEntry, passphrase: String?) async {
        let auth: SSHAuthenticationMethod
        do {
            auth = try PrivateKeyLoader.authMethod(for: host, passphrase: passphrase)
        } catch PrivateKeyError.needsPassphrase {
            tab.state = .disconnected
            tab.statusText = "未连接"
            passphrasePrompt = PassphrasePrompt(host: host)
            return
        } catch {
            tab.state = .disconnected
            tab.statusText = "未连接"
            fail(error)
            return
        }

        let known = KnownHosts.trustedKeys(host: host.hostName, port: host.port)
        let validator = KnownHostsValidator(host: host.hostName, port: host.port, known: known)

        do {
            try await tab.session.connect(host: host, auth: auth, validator: validator)
            tab.state = .connected
            tab.statusText = "已连接 \(host.alias)"
            engine.appendLog("✓ 已连接 \(host.alias)")
            try await loadInitialRemoteDirectory(for: tab)
            tab.shouldRestorePathOnNextConnect = false
        } catch {
            switch validator.outcome {
            case .unknown(let info):
                tab.state = .disconnected
                tab.statusText = "未连接"
                hostKeyPrompt = HostKeyPrompt(host: host, passphrase: passphrase, info: info)
            case .mismatch(let mismatch):
                tab.state = .disconnected
                tab.statusText = "未连接"
                fail(mismatch)
            case .none:
                tab.state = .disconnected
                tab.statusText = "未连接"
                fail(error)
            }
        }
    }

    private func loadInitialRemoteDirectory(for tab: RemoteTab) async throws {
        let home: String
        do {
            home = try await tab.session.homeDirectory()
        } catch {
            if SFTPSession.isConnectionLost(error) { throw error }
            home = "/"
        }

        let restorePath = tab.shouldRestorePathOnNextConnect ? tab.pane.currentPath : nil
        if let restorePath, !restorePath.isEmpty {
            do {
                let items = try await tab.session.list(restorePath)
                applyRemoteListing(items, path: restorePath, to: tab.pane)
                if restorePath != home {
                    engine.appendLog("已恢复远程目录 \(restorePath)")
                }
                return
            } catch {
                if SFTPSession.isConnectionLost(error) { throw error }
                engine.appendLog("无法恢复远程目录 \(restorePath)，已回到初始目录：\(error.localizedDescription)")
            }
        }

        let items = try await tab.session.list(home)
        applyRemoteListing(items, path: home, to: tab.pane)
    }

    private func applyRemoteListing(_ items: [FileItem], path: String, to pane: PaneModel) {
        pane.seedHistory(path)
        pane.items = items
        pane.selection = []
        pane.searchResults = nil
    }

    /// 断开当前活跃远程 tab。
    func disconnect() {
        guard let tab = activeRemoteTab else { return }
        tab.disconnectIfNeeded()
        engine.appendLog("已断开连接")
    }

    @discardableResult
    func handleRemoteOperationFailure(_ error: Error,
                                      pane: PaneModel,
                                      action: String,
                                      showAlert: Bool = true) -> Bool {
        if SFTPSession.isConnectionLost(error),
           let tab = remoteTabs.first(where: { $0.pane === pane }) {
            markConnectionLost(tab, action: action, showAlert: showAlert)
            return true
        }
        engine.appendLog("✗ \(action)：\(error.localizedDescription)")
        if showAlert {
            errorMessage = "\(action)：\(error.localizedDescription)"
        }
        return false
    }

    private func markConnectionLost(_ tab: RemoteTab, action: String, showAlert: Bool = true) {
        guard tab.state != .disconnected else { return }
        tab.state = .disconnected
        tab.statusText = "连接已断开"
        tab.shouldRestorePathOnNextConnect = true
        tab.pane.selection = []
        tab.pane.searchResults = nil
        let hostName = tab.host?.alias ?? "服务器"
        let message = "与 \(hostName) 的连接已断开，请重新连接后重试。"
        engine.appendLog("✗ \(action)：\(message)")
        if showAlert { errorMessage = message }
        Task { [session = tab.session] in
            await session.disconnect()
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        engine.appendLog("✗ \(error.localizedDescription)")
    }

    // MARK: 传输

    // MARK: 通用「传输到另一侧」

    /// 当前是否可发起"传输到另一侧"：两侧都有活跃 tab，源端有选中，远程目标端已连接。
    var canTransfer: Bool {
        guard let src = sourceTabForTransfer, !src.pane.selection.isEmpty else { return false }
        if let dest = destinationTabForTransfer, dest.isRemote, !isActiveRemoteTabConnected {
            return false
        }
        return true
    }

    /// 当前"传输到另一侧"操作是否为 远程 → 远程（需要本机中转）。
    var isRemoteToRemoteTransfer: Bool {
        guard let src = sourceTabForTransfer, let dest = destinationTabForTransfer else { return false }
        return src.isRemote && dest.isRemote
    }

    /// 把当前两侧活跃 tab 的传输意图快照化：用于"远程中转确认"对话框中暂存请求。
    /// 视图层不直接构造 TransferRequest，所以这里封装。
    struct TransferSnapshot: Sendable {
        let requests: [TransferRequest]
        let sourcePane: PaneModel
        let destinationPane: PaneModel
        let actionLabel: String
        let involvedRemoteTabIDs: Set<RemoteTab.ID>
    }

    /// 在用户点击"传输到另一侧"时构造快照（不发起传输）。
    /// 远程端点必须已连接；本调用假定 `canTransfer == true`。
    @discardableResult
    func makeTransferSnapshot() -> TransferSnapshot? {
        guard let srcTab = sourceTabForTransfer,
              let destTab = destinationTabForTransfer,
              !engine.isRunning else { return nil }
        let srcItems = srcTab.pane.selectedItems
        guard !srcItems.isEmpty else { return nil }
        let destDir = destTab.pane.currentPath
        let srcEndpoint = srcTab.kindEndpoint
        let destEndpoint = destTab.kindEndpoint
        let requests: [TransferRequest] = srcItems.map { item in
            TransferRequest(
                source: TransferItem(endpoint: srcEndpoint, path: item.path, name: item.name, isDirectory: item.isDirectory),
                destination: destEndpoint,
                destinationDirectory: destDir
            )
        }
        return TransferSnapshot(
            requests: requests,
            sourcePane: srcTab.pane,
            destinationPane: destTab.pane,
            actionLabel: Self.titleForTransfer(source: srcTab, destination: destTab),
            involvedRemoteTabIDs: collectRemoteTabIDs(in: [srcTab, destTab])
        )
    }

    /// 由"传输"按钮或"远程中转确认"对话框调用：按快照执行。
    func performTransferFromSnapshot(_ snapshot: TransferSnapshot) {
        guard !engine.isRunning else { return }
        transferTask = Task { [weak self, engine] in
            guard let self else { return }
            let result = await engine.run(snapshot.requests) { [weak self] tabID in
                self?.sessionResolver(for: tabID)
            }
            if result.connectionLost {
                for tabID in snapshot.involvedRemoteTabIDs {
                    if let tab = self.allRemoteTabsList.first(where: { $0.id == tabID }) {
                        self.markConnectionLost(tab, action: snapshot.actionLabel)
                    }
                }
            }
            await snapshot.sourcePane.reload()
            await snapshot.destinationPane.reload()
        }
    }

    /// 传输按钮的文案：按源端 / 目标端组合给出。
    var transferButtonTitle: String {
        guard let src = sourceTabForTransfer, let dest = destinationTabForTransfer else { return "传输" }
        return Self.titleForTransfer(source: src, destination: dest)
    }

    /// 传输按钮的图标：按源端 / 目标端组合给出。
    var transferButtonIcon: String {
        guard let src = sourceTabForTransfer, let dest = destinationTabForTransfer else { return "arrow.right.arrow.left" }
        return Self.iconForTransfer(source: src, destination: dest)
    }

    /// 源端 = 左侧活跃 tab。
    private var sourceTabForTransfer: BrowserTab? { leftColumn.activeTab }
    /// 目标端 = 右侧活跃 tab。
    private var destinationTabForTransfer: BrowserTab? { rightColumn.activeTab }

    /// 把活跃源端 tab 的选中项按通用模型转到目标端 tab 的当前目录。
    func transferToOtherSide() {
        guard let srcTab = sourceTabForTransfer,
              let destTab = destinationTabForTransfer,
              canTransfer,
              !engine.isRunning else { return }

        let srcItems = srcTab.pane.selectedItems
        guard !srcItems.isEmpty else { return }
        let destDir = destTab.pane.currentPath
        let srcEndpoint = srcTab.kindEndpoint
        let destEndpoint = destTab.kindEndpoint

        let requests: [TransferRequest] = srcItems.map { item in
            TransferRequest(
                source: TransferItem(endpoint: srcEndpoint, path: item.path, name: item.name, isDirectory: item.isDirectory),
                destination: destEndpoint,
                destinationDirectory: destDir
            )
        }
        let actionLabel = Self.titleForTransfer(source: srcTab, destination: destTab)
        let involvedRemoteTabIDs = collectRemoteTabIDs(in: [srcTab, destTab])

        transferTask = Task { [weak self, engine] in
            guard let self else { return }
            let result = await engine.run(requests) { [weak self] tabID in
                self?.sessionResolver(for: tabID)
            }
            if result.connectionLost {
                for tabID in involvedRemoteTabIDs {
                    if let tab = self.allRemoteTabsList.first(where: { $0.id == tabID }) {
                        self.markConnectionLost(tab, action: actionLabel)
                    }
                }
            }
            await srcTab.pane.reload()
            await destTab.pane.reload()
        }
    }

    // MARK: 传输 - 旧入口（保留为 API；新代码用 transferToOtherSide）

    /// 上传：本地活跃 tab 的选中 → 远程活跃 tab 的当前目录。
    /// 等价于 `transferToOtherSide`，但要求源是 .local、目标 .remote。
    func uploadSelection() {
        guard sourceTabForTransfer?.isLocal == true,
              destinationTabForTransfer?.isRemote == true else { return }
        transferToOtherSide()
    }

    /// 下载：远程活跃 tab 的选中 → 本地活跃 tab 的当前目录。
    /// 等价于 `transferToOtherSide`，但要求源是 .remote、目标 .local。
    func downloadSelection() {
        guard sourceTabForTransfer?.isRemote == true,
              destinationTabForTransfer?.isLocal == true else { return }
        transferToOtherSide()
    }

    // MARK: 辅助

    private func collectRemoteTabIDs(in tabs: [BrowserTab]) -> Set<RemoteTab.ID> {
        Set(tabs.compactMap { $0.remoteTab?.id })
    }

    /// 所有列中的远程 tab 列表（用于断线时反查 session）。
    private var allRemoteTabsList: [RemoteTab] {
        (leftColumn.tabs + rightColumn.tabs).compactMap { $0.remoteTab }
    }

    private static func titleForTransfer(source: BrowserTab, destination: BrowserTab) -> String {
        switch (source.isRemote, destination.isRemote) {
        case (false, true): return "上传选中"
        case (true, false): return "下载选中"
        case (false, false): return "本地复制"
        case (true, true):  return "远程中转"
        }
    }

    private static func iconForTransfer(source: BrowserTab, destination: BrowserTab) -> String {
        switch (source.isRemote, destination.isRemote) {
        case (false, true): return "arrow.right"
        case (true, false): return "arrow.left"
        case (false, false): return "doc.on.doc"
        case (true, true):  return "arrow.triangle.swap"
        }
    }

    // MARK: -

    /// 远程 session 解析器：给定 tab id 返回对应 SFTPSession。
    /// 由 TransferEngine 在需要远程 I/O 时回调；引擎不持有任何 session。
    private func sessionResolver(for tabID: RemoteTab.ID) -> SFTPSession? {
        (leftColumn.tabs + rightColumn.tabs)
            .compactMap { $0.remoteTab }
            .first(where: { $0.id == tabID })?.session
    }

    /// 拖拽统一入口：把一组 `TransferItemRef` 投到目标面板 `destinationPane` 的当前目录。
    /// 源端可以是本地或远程；目标端由目标面板的 `kind` 决定（与「左/右」解耦）。
    /// - 同侧拖拽（如本地 → 本地）也走这里，传参会自然形成 local→local 请求。
    /// - 远程源端会按 ref 的 `tabID` 反查 SFTPSession；tab 已关闭时跳过并提示。
    func dropTransferItems(_ refs: [TransferItemRef], into destinationPane: PaneModel) {
        guard !engine.isRunning, !refs.isEmpty else { return }
        let destDir = destinationPane.currentPath
        let destEndpoint: TransferEndpoint
        switch destinationPane.kind {
        case .local:
            destEndpoint = .local
        case .remote:
            // 只有活跃远程 tab 可作为目标：未连接时不接受。
            guard isActiveRemoteTabConnected, let tab = activeRemoteTab else { return }
            destEndpoint = .remote(tabID: tab.id, hostID: tab.host?.id)
        }

        var requests: [TransferRequest] = []
        for ref in refs {
            let srcEndpoint = ref.sourceEndpoint
            // 校验远程源端：tab 必须仍存在
            if case .remote(let tabID, _) = srcEndpoint,
               (leftColumn.tabs + rightColumn.tabs).compactMap({ $0.remoteTab })
                .first(where: { $0.id == tabID }) == nil {
                engine.appendLog("✗ 跳过 \(ref.name)：来源远程 tab 已关闭")
                continue
            }
            // 校验远程目标端：必须已连接
            if case .remote = destEndpoint, !isActiveRemoteTabConnected { return }
            requests.append(TransferRequest(
                source: TransferItem(endpoint: srcEndpoint, path: ref.path, name: ref.name, isDirectory: ref.isDirectory),
                destination: destEndpoint,
                destinationDirectory: destDir
            ))
        }
        guard !requests.isEmpty else { return }
        // 涉及的远程 tab（用于连接断开后回填状态 / 决定刷新哪个面板）
        let involvedRemoteTabIDs = Set(refs.compactMap { ref -> RemoteTab.ID? in
            if case .remote(let tabID, _, _, _) = ref { return tabID }
            return nil
        })
        let targetTab = activeRemoteTab // 仅用于断线时打点
        let actionLabel = describeTransferAction(refs: refs, dest: destEndpoint)
        transferTask = Task { [weak self, engine] in
            guard let self else { return }
            let result = await engine.run(requests) { [weak self] tabID in
                self?.sessionResolver(for: tabID)
            }
            if result.connectionLost, let tab = targetTab {
                self.markConnectionLost(tab, action: actionLabel)
            }
            // 刷新源端面板：远程 ref 所属 tab 的 pane
            for tabID in involvedRemoteTabIDs {
                if let t = self.remoteTabs.first(where: { $0.id == tabID }) {
                    await t.pane.reload()
                }
            }
            // 刷新目标面板
            await destinationPane.reload()
        }
    }

    /// 生成"上传/下载/中转"的友好日志前缀。
    private func describeTransferAction(refs: [TransferItemRef], dest: TransferEndpoint) -> String {
        let hasRemote = refs.contains { if case .remote = $0 { return true } else { return false } }
        let hasLocal = refs.contains { if case .local = $0 { return true } else { return false } }
        switch (hasRemote, hasLocal, dest) {
        case (true, false, .local): return "下载"
        case (false, true, .remote): return "上传"
        case (true, false, .remote): return "远程中转"
        case (false, true, .local): return "本地复制"
        case (true, true, _): return "传输"
        case (false, false, _): return "传输"
        }
    }

    // MARK: 传输请求构造

    // 注：旧的 makeLocalToRemoteRequests / makeRemoteToLocalRequests / runTransfer 已被
    // transferToOtherSide 取代；transferToOtherSide 直接在活跃 tab 上构造 TransferRequest，
    // 既支持四种端点组合，也避免重复代码。

    /// 取消进行中的传输（协作式：在文件之间或分块循环中尽快停止）。
    func cancelTransfer() {
        transferTask?.cancel()
    }
}

// MARK: - 弹窗数据

struct PassphrasePrompt: Identifiable {
    let id = UUID()
    let host: HostEntry
}

struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let host: HostEntry
    let passphrase: String?
    let info: UnknownHostKey
}
