import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// 服务器密钥与 known_hosts 记录不一致（疑似中间人/服务器换密钥）。
struct HostKeyMismatch: LocalizedError {
    let host: String
    let fingerprint: String
    var errorDescription: String? {
        "\(host) 的密钥与 known_hosts 记录不一致（指纹 \(fingerprint)）。出于安全已拒绝连接。"
    }
}

/// 主机不在 known_hosts 中，需要用户确认指纹后才信任（TOFU）。
struct UnknownHostKey: LocalizedError {
    let host: String
    let port: Int
    let fingerprint: String
    let openSSHLine: String
    var errorDescription: String? {
        "主机 \(host) 不在 known_hosts 中（指纹 \(fingerprint)）。"
    }
}

enum KnownHosts {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/known_hosts"
    }

    /// 与 `ssh-keygen -l` 一致的 SHA256 指纹。
    static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let openSSH = String(openSSHPublicKey: key) // "alg base64[ comment]"
        let tokens = openSSH.split(separator: " ")
        guard tokens.count >= 2, let blob = Data(base64Encoded: String(tokens[1])) else {
            return "SHA256:?"
        }
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    /// 某行 known_hosts 的 host 字段是否匹配目标（支持明文与 |1| 哈希条目）。
    static func hostFieldMatches(_ field: String, candidates: [String]) -> Bool {
        if field.hasPrefix("|1|") {
            let parts = field.split(separator: "|").map(String.init)
            guard parts.count == 3, let salt = Data(base64Encoded: parts[1]) else { return false }
            let expected = parts[2]
            let key = SymmetricKey(data: salt)
            for name in candidates {
                let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: key)
                if Data(mac).base64EncodedString() == expected { return true }
            }
            return false
        } else {
            let patterns = field.split(separator: ",").map(String.init)
            return candidates.contains { patterns.contains($0) }
        }
    }

    static func candidates(host: String, port: Int) -> [String] {
        port == 22 ? [host] : ["[\(host)]:\(port)", host]
    }

    /// 收集 known_hosts 中、匹配目标主机的受信任公钥。
    static func trustedKeys(host: String, port: Int, path: String = defaultPath) -> Set<NIOSSHPublicKey> {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let names = candidates(host: host, port: port)
        var result = Set<NIOSSHPublicKey>()
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let first = fields.first, first.hasPrefix("@") { fields.removeFirst() } // 跳过 @cert-authority/@revoked
            guard fields.count >= 3, hostFieldMatches(fields[0], candidates: names) else { continue }
            if let pk = try? NIOSSHPublicKey(openSSHPublicKey: "\(fields[1]) \(fields[2])") {
                result.insert(pk)
            }
        }
        return result
    }

    /// 用户确认信任后，把主机密钥写入 known_hosts。
    static func append(host: String, port: Int, openSSHLine: String, path: String = defaultPath) {
        let hostToken = port == 22 ? host : "[\(host)]:\(port)"
        let entry = "\(hostToken) \(openSSHLine)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            try? fh.write(contentsOf: data)
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// 校验结果（供上层在连接抛错后判定，避免依赖 NIO 是否包裹了原始错误）。
enum HostKeyOutcome: Sendable {
    case unknown(UnknownHostKey)
    case mismatch(HostKeyMismatch)
}

/// 基于 known_hosts 的主机密钥校验器：命中→通过；有记录但不符→拒绝（中间人）；
/// 无记录→以 `UnknownHostKey` 失败，交由上层弹窗确认后写入 known_hosts 并重连。
/// 绝不无条件接受任何主机密钥。
final class KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let known: Set<NIOSSHPublicKey>

    private let lock = NSLock()
    private var _outcome: HostKeyOutcome?
    /// 最近一次校验的非通过结果（线程安全读取）。
    var outcome: HostKeyOutcome? {
        lock.lock(); defer { lock.unlock() }
        return _outcome
    }
    private func record(_ value: HostKeyOutcome) {
        lock.lock(); _outcome = value; lock.unlock()
    }

    init(host: String, port: Int, known: Set<NIOSSHPublicKey>) {
        self.host = host
        self.port = port
        self.known = known
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if known.contains(hostKey) {
            validationCompletePromise.succeed(())
        } else if !known.isEmpty {
            let mismatch = HostKeyMismatch(host: host, fingerprint: KnownHosts.fingerprint(hostKey))
            record(.mismatch(mismatch))
            validationCompletePromise.fail(mismatch)
        } else {
            let unknown = UnknownHostKey(
                host: host,
                port: port,
                fingerprint: KnownHosts.fingerprint(hostKey),
                openSSHLine: String(openSSHPublicKey: hostKey)
            )
            record(.unknown(unknown))
            validationCompletePromise.fail(unknown)
        }
    }
}
