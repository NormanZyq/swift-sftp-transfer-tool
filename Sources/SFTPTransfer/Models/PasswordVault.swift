import Foundation
import Security

enum PasswordVaultError: LocalizedError {
    case missingPassword
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            return L10n.tr("未保存该服务器的密码")
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return L10n.tr("钥匙串操作失败：%@", message)
            }
            return L10n.tr("钥匙串操作失败：%d", status)
        }
    }
}

enum PasswordVault {
    private static let service = "local.shyulatte.sftptransfer.password"

    static func password(for hostID: String) throws -> String {
        var query = baseQuery(account: hostID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw PasswordVaultError.missingPassword }
        guard status == errSecSuccess else { throw PasswordVaultError.unexpectedStatus(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw PasswordVaultError.missingPassword
        }
        return password
    }

    static func savePassword(_ password: String, for hostID: String) throws {
        let data = Data(password.utf8)
        var query = baseQuery(account: hostID)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasswordVaultError.unexpectedStatus(status) }
    }

    static func deletePassword(for hostID: String) throws {
        let status = SecItemDelete(baseQuery(account: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordVaultError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
