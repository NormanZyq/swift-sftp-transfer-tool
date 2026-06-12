import Foundation
import Citadel
import Crypto

enum PrivateKeyError: LocalizedError {
    case fileNotFound(String)
    case unreadable(String)
    case unsupportedType(String)
    case needsPassphrase
    case wrongPassphrase
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let p):    return "私钥文件不存在：\(p)"
        case .unreadable(let p):      return "无法读取私钥文件：\(p)"
        case .unsupportedType(let t): return "暂不支持的密钥类型：\(t)（目前支持 ed25519 / rsa）"
        case .needsPassphrase:        return "该私钥带有口令，需要输入口令"
        case .wrongPassphrase:        return "私钥口令不正确"
        case .parseFailed(let m):     return "解析私钥失败：\(m)"
        }
    }
}

/// 从本机私钥文件构造 Citadel 认证方式。私钥仅在本地读取，绝不外传。
enum PrivateKeyLoader {
    static func resolveIdentityPath(for host: HostEntry) -> String {
        let raw = host.identityFile ?? "~/.ssh/id_ed25519"
        return (raw as NSString).expandingTildeInPath
    }

    /// 不确定是否需要口令时，先传 `passphrase: nil`；若抛 `.needsPassphrase`，
    /// 再向用户索要后用口令重试。
    static func authMethod(for host: HostEntry, passphrase: String?, passwordOverride: String? = nil) throws -> SSHAuthenticationMethod {
        if host.authentication == .password {
            let password = try passwordOverride ?? PasswordVault.password(for: host.id)
            return .passwordBased(username: host.user, password: password)
        }

        let path = resolveIdentityPath(for: host)
        guard FileManager.default.fileExists(atPath: path) else {
            throw PrivateKeyError.fileNotFound(path)
        }
        guard let keyString = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw PrivateKeyError.unreadable(path)
        }

        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
        } catch {
            throw PrivateKeyError.parseFailed("\(error)")
        }

        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        do {
            if keyType == .ed25519 {
                let pk = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: decryptionKey)
                return .ed25519(username: host.user, privateKey: pk)
            } else if keyType == .rsa {
                let pk = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: decryptionKey)
                return .rsa(username: host.user, privateKey: pk)
            } else {
                throw PrivateKeyError.unsupportedType("\(keyType)")
            }
        } catch let e as PrivateKeyError {
            throw e
        } catch {
            // 解析失败：未给口令时多半是带口令的私钥；给了口令仍失败则口令错误。
            throw passphrase == nil ? PrivateKeyError.needsPassphrase : PrivateKeyError.wrongPassphrase
        }
    }
}
