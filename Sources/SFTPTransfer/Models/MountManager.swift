import Foundation
import AppKit
import Darwin

struct MountRequest: Identifiable, Sendable {
    let id = UUID()
    let host: HostEntry
    let remotePath: String
    let localPath: String
    let expectedSource: String
}

struct MountRecord: Identifiable, Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case active
        case stale
        case conflict
    }

    let id: UUID
    var host: HostEntry
    var remotePath: String
    var localPath: String
    var expectedSource: String
    var mountedAt: Date
    var state: State = .stale

    var title: String {
        "\(host.alias):\(remotePath)"
    }
}

enum MountDependencyStatus: Equatable, Sendable {
    case ready
    case missingMacFuse
    case missingSSHFS

    var message: String {
        switch self {
        case .ready:
            return ""
        case .missingMacFuse:
            return L10n.tr("挂载功能需要安装 macFUSE。当前没有检测到 macFUSE，因此无法挂载远程目录。")
        case .missingSSHFS:
            return L10n.tr("挂载功能需要安装 sshfs。当前没有检测到 sshfs，因此无法挂载远程目录。")
        }
    }
}

enum MountError: LocalizedError {
    case macFuseMissing
    case sshfsMissing
    case localDirectoryMissing(String)
    case localPathIsSymlink(String)
    case localDirectoryNotEmpty(String)
    case localPathAlreadyMounted(String)
    case mountNotManaged(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .macFuseMissing:
            return L10n.tr("无法开启挂载功能：未检测到 macFUSE。")
        case .sshfsMissing:
            return L10n.tr("无法开启挂载功能：未检测到 sshfs。")
        case .localDirectoryMissing(let path):
            return L10n.tr("无法挂载：本地目录不存在或不是文件夹：%@", path)
        case .localPathIsSymlink(let path):
            return L10n.tr("无法挂载：本地目录是符号链接，为避免误操作已拒绝：%@", path)
        case .localDirectoryNotEmpty(let path):
            return L10n.tr("无法挂载：本地目录不是空目录。为避免隐藏或覆盖本地文件，请先选择一个空目录：%@", path)
        case .localPathAlreadyMounted(let path):
            return L10n.tr("无法挂载：本地目录已经是挂载点：%@", path)
        case .mountNotManaged(let path):
            return L10n.tr("无法取消挂载：该路径当前不是本应用创建的有效 sshfs 挂载：%@", path)
        case .commandFailed(let message):
            return message
        }
    }
}

@MainActor
@Observable
final class MountManager {
    var records: [MountRecord] = []
    var busyRecordIDs: Set<UUID> = []
    var isMounting = false

    init() {
        load()
        refreshStatuses()
    }

    var dependencyStatus: MountDependencyStatus {
        MountSystem.dependencyStatus()
    }

    func makeRequest(host: HostEntry, remotePath: String, localPath: String) throws -> MountRequest {
        try MountSystem.makeRequest(host: host, remotePath: remotePath, localPath: localPath)
    }

    func refreshStatuses() {
        records = records.map { record in
            var updated = record
            updated.state = MountSystem.state(for: record)
            return updated
        }
    }

    func mount(_ request: MountRequest) async throws {
        isMounting = true
        defer { isMounting = false }

        try await Task.detached {
            try MountSystem.mount(request)
        }.value

        var record = MountRecord(
            id: UUID(),
            host: request.host,
            remotePath: request.remotePath,
            localPath: request.localPath,
            expectedSource: request.expectedSource,
            mountedAt: Date(),
            state: .active
        )
        record.state = MountSystem.state(for: record)
        records.removeAll { $0.localPath == record.localPath && $0.expectedSource == record.expectedSource }
        records.append(record)
        save()
    }

    func unmount(_ record: MountRecord) async throws {
        busyRecordIDs.insert(record.id)
        defer { busyRecordIDs.remove(record.id) }

        try await Task.detached {
            try MountSystem.unmount(record)
        }.value

        refreshStatuses()
        save()
    }

    func remount(_ record: MountRecord) async throws {
        busyRecordIDs.insert(record.id)
        defer { busyRecordIDs.remove(record.id) }

        let request = MountRequest(
            host: record.host,
            remotePath: record.remotePath,
            localPath: record.localPath,
            expectedSource: record.expectedSource
        )
        try await Task.detached {
            try MountSystem.mount(request)
        }.value

        refreshStatuses()
        save()
    }

    func deleteRecord(_ record: MountRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else {
            records = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([MountRecord].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(records)
            try data.write(to: Self.storeURL, options: [.atomic])
        } catch {
            // 挂载记录保存失败不影响已经完成的挂载；下一次打开时只是不再显示这条记录。
        }
    }

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SFTPTransfer", isDirectory: true)
            .appendingPathComponent("mounts.json")
    }
}

private enum MountSystem {
    struct MountedFileSystem {
        let mountedOn: String
        let mountedFrom: String
        let type: String
    }

    static func makeRequest(host: HostEntry, remotePath: String, localPath: String) throws -> MountRequest {
        try ensureDependencies()
        let normalizedLocal = URL(fileURLWithPath: localPath).standardizedFileURL.path
        let normalizedRemote = remotePath.isEmpty ? "/" : remotePath
        try validateMountPoint(normalizedLocal)
        return MountRequest(
            host: host,
            remotePath: normalizedRemote,
            localPath: normalizedLocal,
            expectedSource: remoteSource(host: host, remotePath: normalizedRemote)
        )
    }

    static func mount(_ request: MountRequest) throws {
        try ensureDependencies()
        try validateMountPoint(request.localPath)
        guard let sshfs = sshfsPath() else { throw MountError.sshfsMissing }

        var arguments = [request.expectedSource, request.localPath]
        arguments += [
            "-o", "reconnect",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "defer_permissions",
            "-o", "noappledouble",
            "-o", "volname=\(volumeName(for: request))"
        ]

        var standardInput: String?
        if request.host.source == .manual {
            arguments += ["-p", "\(request.host.port)"]
            if request.host.authentication == .privateKey, let identity = expandedIdentityFile(request.host.identityFile) {
                arguments += ["-o", "IdentityFile=\(identity)"]
            } else if request.host.authentication == .password {
                guard let password = try? PasswordVault.password(for: request.host.id), !password.isEmpty else {
                    throw MountError.commandFailed(L10n.tr("挂载失败：未找到该服务器保存的密码。"))
                }
                arguments += ["-o", "password_stdin"]
                standardInput = password + "\n"
            }
        }
        if standardInput == nil {
            arguments += ["-o", "BatchMode=yes"]
        }

        let result = ProcessRunner.run(sshfs, arguments: arguments, standardInput: standardInput)
        guard result.exitCode == 0 else {
            throw MountError.commandFailed(L10n.tr("挂载失败：%@", result.combinedOutput))
        }
    }

    static func unmount(_ record: MountRecord) throws {
        guard state(for: record) == .active else {
            throw MountError.mountNotManaged(record.localPath)
        }
        let result = ProcessRunner.run("/sbin/umount", arguments: [record.localPath])
        guard result.exitCode == 0 else {
            throw MountError.commandFailed(L10n.tr("取消挂载失败：%@", result.combinedOutput))
        }
    }

    static func state(for record: MountRecord) -> MountRecord.State {
        guard let mounted = mountedFileSystem(at: record.localPath),
              mounted.mountedOn == URL(fileURLWithPath: record.localPath).standardizedFileURL.path else {
            return .stale
        }
        guard mounted.mountedFrom == record.expectedSource else {
            return .conflict
        }
        return .active
    }

    static func dependencyStatus() -> MountDependencyStatus {
        guard isMacFuseInstalled() else { return .missingMacFuse }
        guard sshfsPath() != nil else { return .missingSSHFS }
        return .ready
    }

    private static func ensureDependencies() throws {
        switch dependencyStatus() {
        case .ready:
            return
        case .missingMacFuse:
            throw MountError.macFuseMissing
        case .missingSSHFS:
            throw MountError.sshfsMissing
        }
    }

    private static func isMacFuseInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
            || FileManager.default.fileExists(atPath: "/Library/Filesystems/osxfuse.fs")
    }

    private static func sshfsPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/sshfs",
            "/usr/local/bin/sshfs",
            "/usr/bin/sshfs"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let result = ProcessRunner.run("/usr/bin/env",
                                       arguments: ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "which", "sshfs"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func validateMountPoint(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MountError.localDirectoryMissing(path)
        }

        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            throw MountError.localPathIsSymlink(path)
        }

        if let mounted = mountedFileSystem(at: path), mounted.mountedOn == path {
            throw MountError.localPathAlreadyMounted(path)
        }

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw MountError.commandFailed(L10n.tr("无法挂载：不能检查本地目录是否为空：%@", path))
        }
        if !contents.isEmpty {
            throw MountError.localDirectoryNotEmpty(path)
        }
    }

    private static func remoteSource(host: HostEntry, remotePath: String) -> String {
        if host.source == .sshConfig {
            return "\(host.alias):\(remotePath)"
        }
        return "\(host.user)@\(host.hostName):\(remotePath)"
    }

    private static func expandedIdentityFile(_ identityFile: String?) -> String? {
        guard let identityFile, !identityFile.isEmpty else { return nil }
        return (identityFile as NSString).expandingTildeInPath
    }

    private static func volumeName(for request: MountRequest) -> String {
        let remoteName = (request.remotePath as NSString).lastPathComponent
        let suffix = remoteName.isEmpty ? "root" : remoteName
        return "\(request.host.alias)-\(suffix)"
    }

    private static func mountedFileSystem(at path: String) -> MountedFileSystem? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return MountedFileSystem(
            mountedOn: string(from: info.f_mntonname),
            mountedFrom: string(from: info.f_mntfromname),
            type: string(from: info.f_fstypename)
        )
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }
}

private enum ProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            let joined = [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return joined.isEmpty ? L10n.tr("命令退出码 %d", exitCode) : joined
        }
    }

    static func run(_ executable: String, arguments: [String], standardInput: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        do {
            try process.run()
            if let standardInput {
                stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            }
            try? stdinPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
