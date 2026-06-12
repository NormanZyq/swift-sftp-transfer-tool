import Foundation

/// 一个解析后的 SSH 主机配置，或用户在应用内保存的服务器配置。
struct HostEntry: Identifiable, Hashable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case sshConfig
        case manual
    }

    enum Authentication: String, Codable, Sendable {
        case privateKey
        case password
    }

    var customID: String?
    var alias: String
    var hostName: String
    var user: String
    var port: Int
    var identityFile: String?
    var source: Source = .sshConfig
    var authentication: Authentication = .privateKey

    var id: String { customID ?? "ssh:\(alias)" }
    var display: String { "\(alias)  —  \(user)@\(hostName):\(port)" }
    var isEditable: Bool { source == .manual }
}

/// `~/.ssh/config` 的子集解析（Host / HostName / User / Port / IdentityFile）。
enum SSHConfig {
    struct Block {
        var patterns: [String]
        var settings: [String: String] = [:]
    }

    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/config"
    }

    static func parseBlocks(path: String) -> [Block] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var blocks: [Block] = []
        var current: Block?

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            line = line.replacingOccurrences(of: "=", with: " ")
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let key = parts.first?.lowercased() else { continue }
            let value = parts.dropFirst().joined(separator: " ")

            if key == "host" {
                if let c = current { blocks.append(c) }
                current = Block(patterns: Array(parts.dropFirst()))
            } else if current != nil, current!.settings[key] == nil {
                current!.settings[key] = value
            }
        }
        if let c = current { blocks.append(c) }
        return blocks
    }

    /// 按 ssh 语义解析别名：在所有匹配区块中「首个出现的值生效」。
    static func resolve(alias: String, blocks: [Block], defaultUser: String) -> HostEntry {
        var hostName: String?
        var user: String?
        var port: Int?
        var identity: String?

        for block in blocks where block.patterns.contains(where: { $0 == alias || $0 == "*" }) {
            if hostName == nil, let v = block.settings["hostname"] { hostName = v }
            if user == nil, let v = block.settings["user"] { user = v }
            if port == nil, let v = block.settings["port"] { port = Int(v) }
            if identity == nil, let v = block.settings["identityfile"] { identity = v }
        }

        return HostEntry(
            alias: alias,
            hostName: hostName ?? alias,
            user: user ?? defaultUser,
            port: port ?? 22,
            identityFile: identity,
            source: .sshConfig,
            authentication: .privateKey
        )
    }

    static func selectableAliases(_ blocks: [Block]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for block in blocks {
            for p in block.patterns where !p.contains("*") && !p.contains("?") {
                if seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    /// 加载并解析所有可选主机。
    static func loadHosts(path: String = defaultPath) -> [HostEntry] {
        let blocks = parseBlocks(path: path)
        let user = NSUserName()
        return selectableAliases(blocks).map { resolve(alias: $0, blocks: blocks, defaultUser: user) }
    }
}
