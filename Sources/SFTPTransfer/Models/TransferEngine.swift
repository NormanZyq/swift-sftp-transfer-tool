import Foundation
import Observation

/// 传输引擎：接收基于统一端点模型的传输请求，按源/目标端点组合派发到具体实现：
/// - 本地 -> 本地：FileManager 复制。
/// - 本地 -> 远程：复用原 SFTP 上传通道。
/// - 远程 -> 本地：复用原 SFTP 下载通道。
/// - 远程 -> 远程：先经本机中转（暂存临时文件后上传）。后续可替换为流式中转以减少磁盘占用。
///
/// 全局日志 / 进度 / 最近结果继续保留。同一时刻仍只跑一个传输任务。
@MainActor
@Observable
final class TransferEngine {
    /// 旧版 upload/download 请求的兼容入口。
    /// 新代码应直接构造 `TransferRequest` 并调用 `run(_:sessionResolver:)`。
    struct LegacyRequest: Sendable {
        let direction: Direction
        let srcPath: String
        let dstPath: String
        let isDirectory: Bool
    }

    enum Direction: Sendable { case upload, download }

    /// 由调用方提供：给定一个远程 tab id，返回对应的 SFTPSession（可能为 nil：tab 已关闭）。
    /// 引擎不持有任何 session，统一由 AppModel 管理生命周期。
    typealias SessionResolver = @MainActor (RemoteTab.ID) -> SFTPSession?

    private struct FileTask {
        let sourceEndpoint: TransferEndpoint
        let destinationEndpoint: TransferEndpoint
        let src: String
        let dst: String
    }

    var isRunning = false
    var currentName = ""
    var currentBytes = 0
    var currentTotal = 0
    var queueIndex = 0
    var queueTotal = 0
    /// 平均传输速度（字节/秒），按当前文件进度计算；仅在传输中有效。
    var bytesPerSecond: Double = 0
    /// 当前文件预计剩余秒数；仅在有总字节数时有效。
    var etaSeconds: Int = 0
    private var currentFileStartedAt: Date?
    private var currentFileLastTick: Date?
    private var currentFileLastBytes: Int = 0
    private(set) var log: [String] = []

    /// 最近一次传输的结果，供界面做轻量提醒（toast）。每次结束都会生成新值（含唯一 id）。
    var lastOutcome: Outcome?

    struct Outcome: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case success, failure, cancelled }
        let kind: Kind
        let message: String
        let id = UUID()
    }

    struct RunResult: Sendable {
        let connectionLost: Bool
    }

    init() {}

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func appendLog(_ message: String) {
        let ts = Self.timeFormatter.string(from: Date())
        log.append("[\(ts)] \(message)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    /// 包一层进度回调：除了原更新 currentBytes / currentTotal，还维护速度与剩余时间。
    /// 速度按"近 1 秒滑窗"计算，避免初次启动时 huge spike 干扰显示。
    private func progressWrapper() -> @Sendable (Int, Int) -> Void {
        return { [weak self] done, total in
            Task { @MainActor in
                guard let self else { return }
                self.currentBytes = done
                self.currentTotal = total
                let now = Date()
                if let last = self.currentFileLastTick {
                    let dt = now.timeIntervalSince(last)
                    if dt >= 0.5 {
                        let dBytes = max(0, done - self.currentFileLastBytes)
                        // 滑窗速度：上一次报告到现在这段时间的字节数 / 时间
                        self.bytesPerSecond = dt > 0 ? Double(dBytes) / dt : 0
                        self.currentFileLastTick = now
                        self.currentFileLastBytes = done
                        if total > done, self.bytesPerSecond > 0 {
                            self.etaSeconds = Int(Double(total - done) / self.bytesPerSecond)
                        } else {
                            self.etaSeconds = 0
                        }
                    }
                } else {
                    self.currentFileLastTick = now
                    self.currentFileLastBytes = done
                }
            }
        }
    }

    // MARK: 旧版入口（保留以兼容旧调用点；新代码应使用 `run(_:sessionResolver:)`）

    /// 旧版 upload/download 入口：根据 `Direction` 推断源/目标端点类型并转交给新版。
    /// 当前调用方只可能是"本地活跃 tab"+"远程活跃 tab"组合（多 tab 模式下也是同样组合，
    /// 只是 session 来自不同 tab）。所以这里把 local/remote 各取一个 endpoint。
    func run(_ legacyRequests: [LegacyRequest], session: SFTPSession,
             localEndpoint: TransferEndpoint = .local,
             remoteEndpoint: TransferEndpoint = .remote(tabID: UUID(), hostID: nil)) async -> RunResult {
        // 注意：旧版入口无法拿到具体的 tab id，所以这里用一个占位 ID。
        // 旧路径只服务 upload/download，不会走到需要 tab id 解析的 remote→remote 分支。
        let requests: [TransferRequest] = legacyRequests.map { r in
            let (src, dst) = r.direction == .upload
                ? (localEndpoint, remoteEndpoint)
                : (remoteEndpoint, localEndpoint)
            return TransferRequest(
                source: TransferItem(endpoint: src, path: r.srcPath,
                                     name: (r.srcPath as NSString).lastPathComponent,
                                     isDirectory: r.isDirectory),
                destination: dst,
                destinationDirectory: (r.dstPath as NSString).deletingLastPathComponent
            )
        }
        let resolver: SessionResolver = { _ in session }
        return await run(requests, sessionResolver: resolver)
    }

    // MARK: 新版入口：基于端点模型的统一派发

    /// 执行一批传输请求。`sessionResolver` 在每次需要拿远程 session 时调用。
    func run(_ requests: [TransferRequest], sessionResolver: SessionResolver) async -> RunResult {
        guard !isRunning else { return RunResult(connectionLost: false) }
        isRunning = true
        defer {
            isRunning = false
            currentName = ""
            currentFileStartedAt = nil
            currentFileLastTick = nil
            currentFileLastBytes = 0
            bytesPerSecond = 0
            etaSeconds = 0
        }

        appendLog("开始处理 \(requests.count) 项")
        var tasks: [FileTask] = []
        var failed = 0
        var connectionLost = false
        for r in requests {
            do {
                tasks += try await expand(r, sessionResolver: sessionResolver)
            } catch {
                if SFTPSession.isConnectionLost(error) { connectionLost = true }
                appendLog("✗ 展开失败 \(r.source.name): \(error.localizedDescription)")
                failed += 1
            }
        }

        queueTotal = tasks.count
        queueIndex = 0
        guard !tasks.isEmpty else {
            appendLog("没有要传输的文件")
            lastOutcome = failed > 0 ? Outcome(kind: .failure, message: "传输失败") : nil
            return RunResult(connectionLost: connectionLost)
        }

        // 按 (endpoint, 已确保的父目录) 缓存：同一传输批次内，同一父目录只 mkdir 一次。
        // 用 endpointKey 字符串化后做 key（不同 tab 的 remote endpoint 互不干扰）。
        var ensuredDirsKeyed: [String: Set<String>] = [:]
        var done = 0

        for (i, task) in tasks.enumerated() {
            if Task.isCancelled { break }
            queueIndex = i + 1
            currentName = (task.src as NSString).lastPathComponent
            currentBytes = 0
            currentTotal = 0
            currentFileStartedAt = Date()
            currentFileLastTick = Date()
            currentFileLastBytes = 0
            bytesPerSecond = 0
            etaSeconds = 0
            do {
                let key = endpointKey(task.destinationEndpoint)
                var set = ensuredDirsKeyed[key] ?? []
                let parent = (task.dst as NSString).deletingLastPathComponent
                if !set.contains(parent) {
                    try await ensureParentDirectory(parent, on: task.destinationEndpoint, sessionResolver: sessionResolver)
                    set.insert(parent)
                    ensuredDirsKeyed[key] = set
                }
                try await performTransfer(task, sessionResolver: sessionResolver)
                appendLog("✓ \(currentName)")
                currentBytes = currentTotal
                done += 1
            } catch is CancellationError {
                break
            } catch {
                if SFTPSession.isConnectionLost(error) { connectionLost = true }
                appendLog("✗ \(currentName): \(error.localizedDescription)")
                failed += 1
                if connectionLost { break }
            }
        }

        if Task.isCancelled {
            appendLog("⊘ 已取消")
            lastOutcome = Outcome(kind: .cancelled, message: "已取消（完成 \(done) 项）")
        } else if failed > 0 {
            appendLog("完成 \(done) 项，\(failed) 项失败")
            lastOutcome = Outcome(kind: .failure,
                                  message: done > 0 ? "完成 \(done) 项，\(failed) 项失败" : "传输失败")
        } else {
            appendLog("✓ 全部完成")
            lastOutcome = Outcome(kind: .success, message: "已完成 · \(done) 项")
        }
        return RunResult(connectionLost: connectionLost)
    }

    /// 把一个请求展开成具体的文件任务（目录递归）。
    private func expand(_ r: TransferRequest, sessionResolver: SessionResolver) async throws -> [FileTask] {
        if !r.source.isDirectory {
            let dst = TransferRequest.resolveDestinationPath(
                endpoint: r.destination,
                directory: r.destinationDirectory,
                name: r.source.name
            )
            return [FileTask(sourceEndpoint: r.source.endpoint,
                             destinationEndpoint: r.destination,
                             src: r.source.path, dst: dst)]
        }
        switch (r.source.endpoint, r.destination) {
        case (.local, .local):
            var out: [FileTask] = []
            let base = r.source.path
            if let en = FileManager.default.enumerator(atPath: base) {
                while let rel = en.nextObject() as? String {
                    let full = (base as NSString).appendingPathComponent(rel)
                    if LocalFileSystem.isDirectory(full) { continue }
                    let dst = (r.destinationDirectory as NSString).appendingPathComponent(rel)
                    out.append(FileTask(sourceEndpoint: .local, destinationEndpoint: .local,
                                         src: full, dst: dst))
                }
            }
            return out
        case (.local, .remote):
            var out: [FileTask] = []
            let base = r.source.path
            if let en = FileManager.default.enumerator(atPath: base) {
                while let rel = en.nextObject() as? String {
                    let full = (base as NSString).appendingPathComponent(rel)
                    if LocalFileSystem.isDirectory(full) { continue }
                    let dst = SFTPSession.join(r.destinationDirectory, rel)
                    out.append(FileTask(sourceEndpoint: .local, destinationEndpoint: r.destination,
                                         src: full, dst: dst))
                }
            }
            return out
        case (.remote, .local):
            guard let srcSession = sessionResolver(remoteTabID(r.source.endpoint)) else {
                throw SFTPSessionError.notConnected
            }
            let files = try await srcSession.walkFiles(r.source.path)
            let prefix = r.source.path.hasSuffix("/") ? r.source.path : r.source.path + "/"
            return files.map { f in
                let rel = f.path.hasPrefix(prefix) ? String(f.path.dropFirst(prefix.count)) : f.name
                let dst = (r.destinationDirectory as NSString).appendingPathComponent(rel)
                return FileTask(sourceEndpoint: r.source.endpoint, destinationEndpoint: .local,
                                 src: f.path, dst: dst)
            }
        case (.remote, .remote):
            guard let srcSession = sessionResolver(remoteTabID(r.source.endpoint)) else {
                throw SFTPSessionError.notConnected
            }
            let files = try await srcSession.walkFiles(r.source.path)
            let prefix = r.source.path.hasSuffix("/") ? r.source.path : r.source.path + "/"
            return files.map { f in
                let rel = f.path.hasPrefix(prefix) ? String(f.path.dropFirst(prefix.count)) : f.name
                let dst = SFTPSession.join(r.destinationDirectory, rel)
                return FileTask(sourceEndpoint: r.source.endpoint, destinationEndpoint: r.destination,
                                 src: f.path, dst: dst)
            }
        }
    }

    /// 按端点组合执行单文件传输。
    private func performTransfer(_ task: FileTask, sessionResolver: SessionResolver) async throws {
        switch (task.sourceEndpoint, task.destinationEndpoint) {
        case (.local, .local):
            try FileManager.default.createDirectory(
                atPath: (task.dst as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: task.dst) {
                try FileManager.default.removeItem(atPath: task.dst)
            }
            try FileManager.default.copyItem(atPath: task.src, toPath: task.dst)
        case (.local, .remote):
            guard let session = sessionResolver(remoteTabID(task.destinationEndpoint)) else {
                throw SFTPSessionError.notConnected
            }
            try await session.upload(localPath: task.src, remotePath: task.dst, onProgress: progressWrapper())
        case (.remote, .local):
            guard let session = sessionResolver(remoteTabID(task.sourceEndpoint)) else {
                throw SFTPSessionError.notConnected
            }
            try await session.download(remotePath: task.src, localPath: task.dst, onProgress: progressWrapper())
        case (.remote, .remote):
            // 当前实现：先经本机临时文件下载再上传。后续可替换为流式中转以避免落盘。
            try await relayRemoteToRemote(
                sourceTabID: remoteTabID(task.sourceEndpoint),
                destinationTabID: remoteTabID(task.destinationEndpoint),
                remoteSrc: task.src,
                remoteDst: task.dst,
                sessionResolver: sessionResolver
            )
        }
    }

    /// 确保目标端的父目录存在；本地走 FileManager，远程走 SFTPSession。
    private func ensureParentDirectory(_ parent: String,
                                       on endpoint: TransferEndpoint,
                                       sessionResolver: SessionResolver) async throws {
        switch endpoint {
        case .local:
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        case .remote:
            guard let session = sessionResolver(remoteTabID(endpoint)) else {
                throw SFTPSessionError.notConnected
            }
            try await session.makeDirectoryRecursive(parent)
        }
    }

    /// 远程 -> 远程：先下载到本机临时文件，再上传到目标 session。
    /// 中转使用 `FileManager.default.temporaryDirectory` 下的唯一子目录；
    /// 传输结束（成功 / 失败 / 取消）都会清理临时文件。
    private func relayRemoteToRemote(sourceTabID: RemoteTab.ID,
                                     destinationTabID: RemoteTab.ID,
                                     remoteSrc: String,
                                     remoteDst: String,
                                     sessionResolver: SessionResolver) async throws {
        guard let srcSession = sessionResolver(sourceTabID) else {
            throw SFTPSessionError.notConnected
        }
        guard let dstSession = sessionResolver(destinationTabID) else {
            throw SFTPSessionError.notConnected
        }
        // 临时文件：用 UUID 避免并行传输冲突；放在系统临时目录。
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: tempDir.path, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let localTmp = tempDir.appendingPathComponent((remoteSrc as NSString).lastPathComponent).path

        // 第一段：远程源 -> 本地临时文件（复用下载实现）
        try await srcSession.download(remotePath: remoteSrc, localPath: localTmp, onProgress: progressWrapper())
        // 检查取消：避免下载完但已被取消时仍继续上传
        try Task.checkCancellation()
        // 第二段：本地临时文件 -> 远程目标
        try await dstSession.upload(localPath: localTmp, remotePath: remoteDst, onProgress: progressWrapper())
    }
}

// MARK: - 端点辅助

/// 从 `TransferEndpoint.remote` 取出 `RemoteTab.ID`；本地端点抛错（不应被调用）。
private func remoteTabID(_ endpoint: TransferEndpoint) -> RemoteTab.ID {
    if case let .remote(tabID, _) = endpoint { return tabID }
    // 旧版兼容路径用占位 UUID；新代码中此函数只对 .remote 调用。
    return UUID()
}

/// 给端点生成一个字符串 key，用于 `ensuredDirs` 这类按端点去重的字典。
private func endpointKey(_ endpoint: TransferEndpoint) -> String {
    switch endpoint {
    case .local: return "local"
    case .remote(let id, _): return "remote:\(id.uuidString)"
    }
}
