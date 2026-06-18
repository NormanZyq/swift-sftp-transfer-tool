import Foundation
import Citadel
import NIOCore
import NIOSSH
import Logging

enum SFTPSessionError: LocalizedError {
    case notConnected
    case connectionLost

    var errorDescription: String? {
        switch self {
        case .notConnected: return L10n.tr("尚未连接到服务器")
        case .connectionLost: return L10n.tr("连接已断开，请重新连接后重试")
        }
    }
}

struct RemoteItemProperties: Sendable {
    let item: FileItem
    let totalSize: UInt64
    let fileCount: Int
    let directoryCount: Int
}

/// 封装一条 SSH/SFTP 连接。用 actor 串行化对唯一 SFTP 通道的访问
/// （取代 Python 版「同一时刻只允许一个线程使用通道」的手动约束）。
actor SFTPSession {
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private(set) var host: HostEntry?

    var isConnected: Bool { sftp != nil }

    // MARK: 连接生命周期

    func connect(host: HostEntry, auth: SSHAuthenticationMethod, validator: KnownHostsValidator) async throws {
        var logger = Logger(label: "nl.orlandos.citadel.sftp")
        logger.logLevel = .warning // 降噪：不打印 info 级别的通道开关日志

        let settings = SSHClientSettings(
            host: host.hostName,
            port: host.port,
            authenticationMethod: { auth },
            hostKeyValidator: .custom(validator)
        )
        let client = try await SSHClient.connect(to: settings)
        let sftp = try await client.openSFTP(logger: logger)
        self.client = client
        self.sftp = sftp
        self.host = host
    }

    func disconnect() async {
        await closeStoredConnections()
    }

    private func closeStoredConnections() async {
        let sftp = self.sftp
        let client = self.client
        self.sftp = nil
        self.client = nil
        self.host = nil
        if let sftp { try? await sftp.close() }
        if let client { try? await client.close() }
    }

    private func requireSFTP() throws -> SFTPClient {
        guard let sftp else { throw SFTPSessionError.notConnected }
        guard sftp.isActive else { throw SFTPSessionError.connectionLost }
        return sftp
    }

    private func withSFTP<T>(_ operation: (SFTPClient) async throws -> T) async throws -> T {
        let sftp = try requireSFTP()
        do {
            return try await operation(sftp)
        } catch {
            if Self.isConnectionLost(error) {
                await closeStoredConnections()
                throw SFTPSessionError.connectionLost
            }
            throw error
        }
    }

    // MARK: 浏览 / 增删改

    func homeDirectory() async throws -> String {
        try await withSFTP { sftp in
            try await sftp.getRealPath(atPath: ".")
        }
    }

    func list(_ path: String) async throws -> [FileItem] {
        let names = try await withSFTP { sftp in
            try await sftp.listDirectory(atPath: path)
        }
        var items: [FileItem] = []
        for comp in names.flatMap({ $0.components }) {
            let name = comp.filename
            if name == "." || name == ".." { continue }
            let isDir = comp.longname.hasPrefix("d")
                || ((comp.attributes.permissions ?? 0) & 0o170000) == 0o040000
            items.append(FileItem(
                name: name,
                path: SFTPSession.join(path, name),
                isDirectory: isDir,
                size: comp.attributes.size ?? 0,
                modified: comp.attributes.accessModificationTime?.modificationTime
            ))
        }
        return items.sorted(by: FileItem.defaultSort)
    }

    func makeDirectory(at path: String) async throws {
        try await withSFTP { sftp in
            try await sftp.createDirectory(atPath: path)
        }
    }

    /// 递归创建目录（mkdir -p）。已存在则跳过。
    func makeDirectoryRecursive(_ path: String) async throws {
        let sftp = try requireSFTP()
        if path.isEmpty || path == "/" || path == "." { return }
        do {
            _ = try await sftp.getAttributes(at: path)
            return // 已存在
        } catch {
            if Self.isConnectionLost(error) {
                await closeStoredConnections()
                throw SFTPSessionError.connectionLost
            }
        }
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path && !parent.isEmpty && parent != "/" {
            try await makeDirectoryRecursive(parent)
        }
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            if Self.isConnectionLost(error) {
                await closeStoredConnections()
                throw SFTPSessionError.connectionLost
            }
            // 兼容并发创建或权限表现不标准的服务器：后续文件操作会给出最终错误。
        }
    }

    func rename(from: String, to: String) async throws {
        try await withSFTP { sftp in
            try await sftp.rename(at: from, to: to)
        }
    }

    /// 删除：文件直接删；目录先递归删子项再 rmdir。
    func remove(path: String, isDirectory: Bool) async throws {
        if !isDirectory {
            try await withSFTP { sftp in
                try await sftp.remove(at: path)
            }
            return
        }
        for child in try await list(path) {
            try await remove(path: child.path, isDirectory: child.isDirectory)
        }
        try await withSFTP { sftp in
            try await sftp.rmdir(at: path)
        }
    }

    /// 递归收集目录下所有文件（不含目录本身），用于传输展开。
    func walkFiles(_ dir: String) async throws -> [FileItem] {
        var out: [FileItem] = []
        for item in try await list(dir) {
            if item.isDirectory {
                out += try await walkFiles(item.path)
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// 递归收集目录下所有后代条目（文件与目录，不含目录本身）。
    /// 用于目录传输展开，以保留空目录和目录结构。
    func walkItems(_ dir: String) async throws -> [FileItem] {
        var out: [FileItem] = []
        for item in try await list(dir) {
            out.append(item)
            if item.isDirectory {
                out += try await walkItems(item.path)
            }
        }
        return out
    }

    /// 远程条目属性。目录大小需要递归统计，可能耗时；调用方应异步展示进度。
    func properties(for item: FileItem) async throws -> RemoteItemProperties {
        if !item.isDirectory {
            return RemoteItemProperties(item: item, totalSize: item.size, fileCount: 1, directoryCount: 0)
        }

        let stats = try await directoryStats(item.path)
        return RemoteItemProperties(
            item: item,
            totalSize: stats.size,
            fileCount: stats.files,
            directoryCount: stats.directories
        )
    }

    private func directoryStats(_ dir: String) async throws -> (size: UInt64, files: Int, directories: Int) {
        var total: UInt64 = 0
        var files = 0
        var directories = 0

        for child in try await list(dir) {
            try Task.checkCancellation()
            if child.isDirectory {
                directories += 1
                let childStats = try await directoryStats(child.path)
                total += childStats.size
                files += childStats.files
                directories += childStats.directories
            } else {
                total += child.size
                files += 1
            }
        }

        return (total, files, directories)
    }

    /// 在 dir 下递归查找名称包含 query（不区分大小写）的条目（文件与目录均含），最多 limit 条。
    /// 用显式栈做迭代遍历，避免递归 `inout` 跨 await；同时响应任务取消，无权限的子目录跳过。
    func search(in dir: String, query: String, includeHidden: Bool, limit: Int = 2000) async throws -> [FileItem] {
        let q = query.lowercased()
        var out: [FileItem] = []
        var stack = [dir]
        while let current = stack.popLast() {
            if out.count >= limit { break }
            try Task.checkCancellation()
            let entries: [FileItem]
            do {
                entries = try await list(current)
            } catch {
                if Self.isConnectionLost(error) { throw error }
                continue
            }
            for e in entries {
                if !includeHidden && e.name.hasPrefix(".") { continue }
                if e.name.lowercased().contains(q) {
                    out.append(e)
                    if out.count >= limit { break }
                }
                if e.isDirectory { stack.append(e.path) }
            }
        }
        return out
    }

    // MARK: 传输（分块 + 进度回调）

    private static let chunkSize = 1 << 18 // 256 KB

    /// 上传单个本地文件到远程路径。progress(已传字节, 总字节)。
    func upload(localPath: String, remotePath: String,
                onProgress: @Sendable (Int, Int) -> Void) async throws {
        try await withSFTP { sftp in
            let total = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? NSNumber)??.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
            defer { try? handle.close() }

            let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
            do {
                var offset = 0
                var lastReported = 0
                onProgress(0, total)
                while true {
                    try Task.checkCancellation()
                    let data = (try handle.read(upToCount: SFTPSession.chunkSize)) ?? Data()
                    if data.isEmpty { break }
                    try await file.write(ByteBuffer(bytes: data), at: UInt64(offset))
                    offset += data.count
                    if offset - lastReported >= (1 << 19) { // 每 ~512KB 汇报一次
                        onProgress(offset, total)
                        lastReported = offset
                    }
                }
                onProgress(offset, total)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    /// 下载远程文件到本地路径。progress(已传字节, 总字节)。
    func download(remotePath: String, localPath: String,
                  onProgress: @Sendable (Int, Int) -> Void) async throws {
        try await withSFTP { sftp in
            FileManager.default.createFile(atPath: localPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: localPath))
            defer { try? handle.close() }

            let file = try await sftp.openFile(filePath: remotePath, flags: .read)
            do {
                let total = Int((try await file.readAttributes()).size ?? 0)
                var offset: UInt64 = 0
                var lastReported = 0
                onProgress(0, total)
                while true {
                    try Task.checkCancellation()
                    let buffer = try await file.read(from: offset, length: UInt32(SFTPSession.chunkSize))
                    let count = buffer.readableBytes
                    if count == 0 { break }
                    var b = buffer
                    if let data = b.readData(length: count) { try handle.write(contentsOf: data) }
                    offset += UInt64(count)
                    if Int(offset) - lastReported >= (1 << 19) {
                        onProgress(Int(offset), total)
                        lastReported = Int(offset)
                    }
                }
                onProgress(Int(offset), total)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    // MARK: 工具

    /// POSIX 路径拼接。
    nonisolated static func join(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    /// Citadel/NIO 在 idle timeout 后可能只在下一次 I/O 抛出通道错误。
    /// 这里集中识别这类“会话已不可复用”的错误，避免 UI 继续显示已连接。
    nonisolated static func isConnectionLost(_ error: Error) -> Bool {
        if let sessionError = error as? SFTPSessionError {
            switch sessionError {
            case .connectionLost, .notConnected: return true
            }
        }
        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .connectionClosed, .missingResponse:
                return true
            case .errorStatus(let status):
                return status.errorCode == .noConnection || status.errorCode == .connectionLost
            default:
                return false
            }
        }
        if let status = error as? SFTPMessage.Status {
            return status.errorCode == .noConnection || status.errorCode == .connectionLost
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .eof:
                return true
            default:
                return false
            }
        }
        if let sshError = error as? NIOSSHError {
            return sshError.type == .tcpShutdown || sshError.type == .creatingChannelAfterClosure
        }

        let message = String(describing: error).lowercased()
        return message.contains("connection reset")
            || message.contains("broken pipe")
            || message.contains("socket is not connected")
            || message.contains("connection closed")
            || message.contains("connection lost")
            || message.contains("i/o on closed channel")
    }
}
