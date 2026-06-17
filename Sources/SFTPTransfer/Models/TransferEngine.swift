import Foundation
import Observation

/// 传输引擎：接收上传/下载请求，递归展开目录，按顺序经由唯一 SFTP 通道传输，
/// 并发布每文件 / 队列进度与日志。
///
/// 多 tab 模式下不同远程 tab 拥有各自的 SFTPSession；每次传输由调用方传入
/// 对应 session，全局日志 / 进度 / 最近结果继续保留（同一时刻仍只跑一个传输）。
@MainActor
@Observable
final class TransferEngine {
    enum Direction: Sendable { case upload, download }

    struct Request: Sendable {
        let direction: Direction
        let srcPath: String   // 源绝对路径
        let dstPath: String   // 目标绝对路径
        let isDirectory: Bool
    }

    private struct FileTask { let direction: Direction; let src: String; let dst: String }

    var isRunning = false
    var currentName = ""
    var currentBytes = 0
    var currentTotal = 0
    var queueIndex = 0
    var queueTotal = 0
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

    /// 执行一批传输请求，使用调用方指定的 session。
    func run(_ requests: [Request], session: SFTPSession) async -> RunResult {
        guard !isRunning else { return RunResult(connectionLost: false) }
        isRunning = true
        defer {
            isRunning = false
            currentName = ""
        }

        appendLog("开始处理 \(requests.count) 项")
        var tasks: [FileTask] = []
        var failed = 0
        var connectionLost = false
        for r in requests {
            do {
                tasks += try await expand(r, session: session)
            } catch {
                if SFTPSession.isConnectionLost(error) { connectionLost = true }
                appendLog("✗ 展开失败 \((r.srcPath as NSString).lastPathComponent): \(error.localizedDescription)")
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

        var ensuredRemoteDirs = Set<String>()
        var ensuredLocalDirs = Set<String>()
        var done = 0

        for (i, task) in tasks.enumerated() {
            if Task.isCancelled { break }
            queueIndex = i + 1
            currentName = (task.src as NSString).lastPathComponent
            currentBytes = 0
            currentTotal = 0
            do {
                switch task.direction {
                case .upload:
                    let parent = (task.dst as NSString).deletingLastPathComponent
                    if !ensuredRemoteDirs.contains(parent) {
                        try await session.makeDirectoryRecursive(parent)
                        ensuredRemoteDirs.insert(parent)
                    }
                    try await session.upload(localPath: task.src, remotePath: task.dst) { done, total in
                        Task { @MainActor in self.currentBytes = done; self.currentTotal = total }
                    }
                    appendLog("↑ \(currentName)")
                case .download:
                    let parent = (task.dst as NSString).deletingLastPathComponent
                    if !ensuredLocalDirs.contains(parent) {
                        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                        ensuredLocalDirs.insert(parent)
                    }
                    try await session.download(remotePath: task.src, localPath: task.dst) { done, total in
                        Task { @MainActor in self.currentBytes = done; self.currentTotal = total }
                    }
                    appendLog("↓ \(currentName)")
                }
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
    private func expand(_ r: Request, session: SFTPSession) async throws -> [FileTask] {
        if !r.isDirectory {
            return [FileTask(direction: r.direction, src: r.srcPath, dst: r.dstPath)]
        }
        switch r.direction {
        case .upload:
            var out: [FileTask] = []
            let base = r.srcPath
            if let en = FileManager.default.enumerator(atPath: base) {
                while let rel = en.nextObject() as? String {
                    let full = (base as NSString).appendingPathComponent(rel)
                    if LocalFileSystem.isDirectory(full) { continue }
                    out.append(FileTask(direction: .upload, src: full, dst: r.dstPath + "/" + rel))
                }
            }
            return out
        case .download:
            let files = try await session.walkFiles(r.srcPath)
            let prefix = r.srcPath.hasSuffix("/") ? r.srcPath : r.srcPath + "/"
            return files.map { f in
                let rel = f.path.hasPrefix(prefix) ? String(f.path.dropFirst(prefix.count)) : f.name
                return FileTask(direction: .download, src: f.path,
                                dst: (r.dstPath as NSString).appendingPathComponent(rel))
            }
        }
    }
}
