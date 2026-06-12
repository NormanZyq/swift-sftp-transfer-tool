import Foundation

struct StoredServerCatalog: Codable {
    var order: [HostEntry.ID] = []
    var manualHosts: [HostEntry] = []
}

enum ServerStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SFTPTransfer", isDirectory: true)
            .appendingPathComponent("servers.json")
    }

    static func load() -> StoredServerCatalog {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return StoredServerCatalog() }
        return (try? JSONDecoder().decode(StoredServerCatalog.self, from: data)) ?? StoredServerCatalog()
    }

    static func save(_ catalog: StoredServerCatalog) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        try data.write(to: url, options: .atomic)
    }

    static func merged(sshHosts: [HostEntry], manualHosts: [HostEntry], order: [HostEntry.ID]) -> [HostEntry] {
        var byID: [HostEntry.ID: HostEntry] = [:]
        for host in sshHosts { byID[host.id] = host }
        for host in manualHosts { byID[host.id] = host }

        var result: [HostEntry] = []
        for id in order {
            if let host = byID.removeValue(forKey: id) {
                result.append(host)
            }
        }

        let remaining = byID.values.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
            return lhs.alias.localizedStandardCompare(rhs.alias) == .orderedAscending
        }
        return result + remaining
    }
}
