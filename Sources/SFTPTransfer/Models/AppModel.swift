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

    // MARK: Tab 集合
    /// 左侧本地 tab 列表与当前选中。
    var localTabs: [PaneModel] = []
    var selectedLocalTabIndex: Int = 0

    /// 右侧远程 tab 列表与当前选中。
    var remoteTabs: [RemoteTab] = []
    var selectedRemoteTabIndex: Int = 0

    // MARK: 共享传输引擎
    let engine = TransferEngine()

    // MARK: 全局弹窗（来自最近一次 connect 流程的中间态）
    var errorMessage: String?
    var passphrasePrompt: PassphrasePrompt?
    var hostKeyPrompt: HostKeyPrompt?

    /// 当前传输任务的句柄，用于取消。
    private var transferTask: Task<Void, Never>?

    init() {
        hosts = SSHConfig.loadHosts()
        selectedHostID = hosts.first?.id

        // 初始：1 个本地 tab，定位到主目录；1 个空远程 tab（用户随后从 picker 选主机）
        addLocalTab(initialPath: LocalFileSystem.home)
        addRemoteTab()
        if let firstHost = hosts.first {
            assignHostToActiveRemoteTab(firstHost)
        }
    }

    // MARK: 派生属性

    var activeLocalPane: PaneModel? {
        guard localTabs.indices.contains(selectedLocalTabIndex) else { return nil }
        return localTabs[selectedLocalTabIndex]
    }

    var activeRemoteTab: RemoteTab? {
        guard remoteTabs.indices.contains(selectedRemoteTabIndex) else { return nil }
        return remoteTabs[selectedRemoteTabIndex]
    }

    /// 当前活跃远程 tab 是否已连接。多 tab 模式下，远程面板的可用性、传输的"目标 session"
    /// 等都看这个标志。
    var isActiveRemoteTabConnected: Bool {
        activeRemoteTab?.isConnected == true
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

    /// 新建本地 tab。`path` 缺省 = 主目录。
    @discardableResult
    func addLocalTab(initialPath path: String = LocalFileSystem.home) -> PaneModel {
        let pane = PaneModel(kind: .local)
        pane.app = self
        pane.seedHistory(path)
        localTabs.append(pane)
        selectedLocalTabIndex = localTabs.count - 1
        Task { await pane.reload() }
        return pane
    }

    /// 关闭一个本地 tab。index 越界或只剩一个时不关闭。
    func closeLocalTab(at index: Int) {
        guard localTabs.count > 1, localTabs.indices.contains(index) else { return }
        localTabs.remove(at: index)
        if selectedLocalTabIndex >= localTabs.count {
            selectedLocalTabIndex = localTabs.count - 1
        }
    }

    /// 新建远程 tab。`host` 可为 nil。
    @discardableResult
    func addRemoteTab(host: HostEntry? = nil) -> RemoteTab {
        let tab = RemoteTab(host: host)
        tab.appRef = self
        tab.pane.app = self
        tab.pane.remoteSession = tab.session
        remoteTabs.append(tab)
        selectedRemoteTabIndex = remoteTabs.count - 1
        if let host {
            tab.pane.remoteTitle = "\(host.user)@\(host.alias)"
            selectedHostID = host.id
        }
        return tab
    }

    /// 关闭一个远程 tab。若已连接则先断开。
    func closeRemoteTab(at index: Int) {
        guard remoteTabs.indices.contains(index) else { return }
        let tab = remoteTabs[index]
        tab.disconnectIfNeeded()
        remoteTabs.remove(at: index)
        if selectedRemoteTabIndex >= remoteTabs.count {
            selectedRemoteTabIndex = max(0, remoteTabs.count - 1)
        }
        // 同步顶栏 picker：让 picker 反映新活跃 tab 的 host（或无）。
        if let active = activeRemoteTab {
            selectedHostID = active.host?.id
        } else {
            selectedHostID = nil
        }
    }

    /// 选中远程 tab：刷新其面板的 remoteTitle 以反映当前活跃状态，并同步顶栏 picker。
    func selectRemoteTab(at index: Int) {
        guard remoteTabs.indices.contains(index) else { return }
        selectedRemoteTabIndex = index
        let tab = remoteTabs[index]
        if let host = tab.host {
            tab.pane.remoteTitle = "\(host.user)@\(host.alias)"
            selectedHostID = host.id
        } else {
            selectedHostID = nil
        }
    }

    /// 把活跃远程 tab 关联到某台主机（顶栏 picker 选了一台新主机时用）。
    func assignHostToActiveRemoteTab(_ host: HostEntry) {
        guard let tab = activeRemoteTab else { return }
        assign(host, to: tab)
    }

    private func assign(_ host: HostEntry, to tab: RemoteTab) {
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
            let home = (try? await tab.session.homeDirectory()) ?? "/"
            tab.pane.seedHistory(home)
            await tab.pane.reload()
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

    /// 断开当前活跃远程 tab。
    func disconnect() {
        guard let tab = activeRemoteTab else { return }
        tab.disconnectIfNeeded()
        engine.appendLog("已断开连接")
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        engine.appendLog("✗ \(error.localizedDescription)")
    }

    // MARK: 传输

    /// 上传：本地活跃 tab 的选中 → 远程活跃 tab 的当前目录。
    func uploadSelection() {
        guard let localPane = activeLocalPane,
              isActiveRemoteTabConnected,
              let tab = activeRemoteTab,
              !engine.isRunning else { return }
        let targets = localPane.selectedItems
        guard !targets.isEmpty else { return }
        let remoteDir = tab.pane.currentPath
        let requests = targets.map { item in
            TransferEngine.Request(
                direction: .upload,
                srcPath: item.path,
                dstPath: SFTPSession.join(remoteDir, item.name),
                isDirectory: item.isDirectory
            )
        }
        transferTask = Task { [engine, tab] in
            await engine.run(requests, session: tab.session)
            await tab.pane.reload()
        }
    }

    /// 下载：远程活跃 tab 的选中 → 本地活跃 tab 的当前目录。
    func downloadSelection() {
        guard let localPane = activeLocalPane,
              isActiveRemoteTabConnected,
              let tab = activeRemoteTab,
              !engine.isRunning else { return }
        let targets = tab.pane.selectedItems
        guard !targets.isEmpty else { return }
        let localDir = localPane.currentPath
        let requests = targets.map { item in
            TransferEngine.Request(
                direction: .download,
                srcPath: item.path,
                dstPath: (localDir as NSString).appendingPathComponent(item.name),
                isDirectory: item.isDirectory
            )
        }
        transferTask = Task { [engine, tab, localPane] in
            await engine.run(requests, session: tab.session)
            await localPane.reload()
        }
    }

    /// 拖拽：本地路径 → 远程 tab 的目录（上传）。
    func dropLocalPaths(_ localPaths: [String], toRemoteDir remoteDir: String) {
        guard isActiveRemoteTabConnected,
              let tab = activeRemoteTab,
              !engine.isRunning else { return }
        let requests = localPaths.map { path -> TransferEngine.Request in
            TransferEngine.Request(
                direction: .upload,
                srcPath: path,
                dstPath: SFTPSession.join(remoteDir, (path as NSString).lastPathComponent),
                isDirectory: LocalFileSystem.isDirectory(path)
            )
        }
        transferTask = Task { [engine, tab] in
            await engine.run(requests, session: tab.session)
            await tab.pane.reload()
        }
    }

    /// 拖拽：远程条目 → 本地 tab 的目录（下载）。
    func dropRemoteItems(_ refs: [RemoteItemRef], toLocalDir localDir: String) {
        guard isActiveRemoteTabConnected,
              let tab = activeRemoteTab,
              !engine.isRunning else { return }
        guard !refs.isEmpty else { return }
        let requests = refs.map { ref in
            TransferEngine.Request(
                direction: .download,
                srcPath: ref.path,
                dstPath: (localDir as NSString).appendingPathComponent(ref.name),
                isDirectory: ref.isDirectory
            )
        }
        transferTask = Task { [engine, tab] in
            await engine.run(requests, session: tab.session)
            if let localPane = activeLocalPane { await localPane.reload() }
        }
    }

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
