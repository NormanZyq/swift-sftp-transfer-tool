import Foundation
import Observation
import Citadel

/// 顶层应用状态：主机列表、连接状态、会话、传输引擎、两个面板，以及各种交互弹窗。
@MainActor
@Observable
final class AppModel {
    enum ConnectionState: Sendable { case disconnected, connecting, connected }

    // 连接
    var hosts: [HostEntry] = []
    var selectedHostID: HostEntry.ID?
    var state: ConnectionState = .disconnected
    var statusText = "未连接"

    let session = SFTPSession()
    let engine: TransferEngine
    let local = PaneModel(kind: .local)
    let remote = PaneModel(kind: .remote)

    // 交互弹窗
    var errorMessage: String?
    var passphrasePrompt: PassphrasePrompt?
    var hostKeyPrompt: HostKeyPrompt?

    /// 当前传输任务的句柄，用于取消。
    private var transferTask: Task<Void, Never>?

    init() {
        engine = TransferEngine(session: session)
        local.app = self
        remote.app = self
        hosts = SSHConfig.loadHosts()
        selectedHostID = hosts.first?.id
        local.seedHistory(LocalFileSystem.home)
        Task { await local.reload() }
    }

    var selectedHost: HostEntry? {
        hosts.first { $0.id == selectedHostID }
    }

    var isConnected: Bool { state == .connected }

    // MARK: 连接 / 断开

    func connect() {
        guard let host = selectedHost, state == .disconnected else { return }
        Task { await attemptConnect(host: host, passphrase: nil) }
    }

    func submitPassphrase(_ passphrase: String) {
        guard let prompt = passphrasePrompt else { return }
        passphrasePrompt = nil
        Task { await attemptConnect(host: prompt.host, passphrase: passphrase) }
    }

    func confirmUnknownHost() {
        guard let prompt = hostKeyPrompt else { return }
        hostKeyPrompt = nil
        KnownHosts.append(host: prompt.info.host, port: prompt.info.port, openSSHLine: prompt.info.openSSHLine)
        engine.appendLog("已将 \(prompt.info.host) 写入 known_hosts")
        Task { await attemptConnect(host: prompt.host, passphrase: prompt.passphrase) }
    }

    func cancelUnknownHost() {
        hostKeyPrompt = nil
        setDisconnected()
    }

    private func attemptConnect(host: HostEntry, passphrase: String?) async {
        state = .connecting
        statusText = "连接中 \(host.alias)…"

        let auth: SSHAuthenticationMethod
        do {
            auth = try PrivateKeyLoader.authMethod(for: host, passphrase: passphrase)
        } catch PrivateKeyError.needsPassphrase {
            state = .disconnected
            statusText = "未连接"
            passphrasePrompt = PassphrasePrompt(host: host)
            return
        } catch {
            fail(error)
            return
        }

        let known = KnownHosts.trustedKeys(host: host.hostName, port: host.port)
        let validator = KnownHostsValidator(host: host.hostName, port: host.port, known: known)

        do {
            try await session.connect(host: host, auth: auth, validator: validator)
            state = .connected
            statusText = "已连接 \(host.alias)"
            engine.appendLog("✓ 已连接 \(host.alias)")
            let home = (try? await session.homeDirectory()) ?? "/"
            remote.seedHistory(home)
            await remote.reload()
        } catch {
            switch validator.outcome {
            case .unknown(let info):
                state = .disconnected
                statusText = "未连接"
                hostKeyPrompt = HostKeyPrompt(host: host, passphrase: passphrase, info: info)
            case .mismatch(let mismatch):
                fail(mismatch)
            case .none:
                fail(error)
            }
        }
    }

    func disconnect() {
        Task {
            await session.disconnect()
            remote.items = []
            remote.selection = []
            setDisconnected()
            engine.appendLog("已断开连接")
        }
    }

    private func setDisconnected() {
        state = .disconnected
        statusText = "未连接"
    }

    private func fail(_ error: Error) {
        setDisconnected()
        errorMessage = error.localizedDescription
        engine.appendLog("✗ \(error.localizedDescription)")
    }

    // MARK: 传输

    func uploadSelection() {
        guard isConnected, !engine.isRunning else { return }
        let targets = local.selectedItems
        guard !targets.isEmpty else { return }
        let remoteDir = remote.currentPath
        let requests = targets.map { item in
            TransferEngine.Request(
                direction: .upload,
                srcPath: item.path,
                dstPath: SFTPSession.join(remoteDir, item.name),
                isDirectory: item.isDirectory
            )
        }
        transferTask = Task {
            await engine.run(requests)
            await remote.reload()
        }
    }

    func downloadSelection() {
        guard isConnected, !engine.isRunning else { return }
        let targets = remote.selectedItems
        guard !targets.isEmpty else { return }
        let localDir = local.currentPath
        let requests = targets.map { item in
            TransferEngine.Request(
                direction: .download,
                srcPath: item.path,
                dstPath: (localDir as NSString).appendingPathComponent(item.name),
                isDirectory: item.isDirectory
            )
        }
        transferTask = Task {
            await engine.run(requests)
            await local.reload()
        }
    }

    /// 拖拽：本地路径 → 远程目录（上传）。
    func dropLocalPaths(_ localPaths: [String], toRemoteDir remoteDir: String) {
        guard isConnected, !engine.isRunning else { return }
        let requests = localPaths.map { path -> TransferEngine.Request in
            TransferEngine.Request(
                direction: .upload,
                srcPath: path,
                dstPath: SFTPSession.join(remoteDir, (path as NSString).lastPathComponent),
                isDirectory: LocalFileSystem.isDirectory(path)
            )
        }
        transferTask = Task { await engine.run(requests); await remote.reload() }
    }

    /// 拖拽：远程条目 → 本地目录（下载）。
    func dropRemoteItems(_ refs: [RemoteItemRef], toLocalDir localDir: String) {
        guard isConnected, !engine.isRunning else { return }
        guard !refs.isEmpty else { return }
        let requests = refs.map { ref in
            TransferEngine.Request(
                direction: .download,
                srcPath: ref.path,
                dstPath: (localDir as NSString).appendingPathComponent(ref.name),
                isDirectory: ref.isDirectory
            )
        }
        transferTask = Task { await engine.run(requests); await local.reload() }
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
