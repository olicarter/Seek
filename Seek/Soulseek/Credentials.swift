import Foundation
import Security

/// Soulseek login, kept in the iCloud Keychain so every device can sign in.
enum Credentials {
    private static let item = KeychainItem(service: "dev.olicarter.seek.soulseek")

    static func load() -> (username: String, password: String)? {
        guard let (account, data) = item.load(), let password = String(data: data, encoding: .utf8) else { return nil }
        return (account, password)
    }

    static func save(username: String, password: String) {
        item.save(account: username, data: Data(password.utf8))
    }

    static func clear() {
        item.clear()
    }
}

/// A single synchronizable generic-password keychain entry.
struct KeychainItem {
    let service: String

    func load() -> (account: String, data: Data)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data
        else { return nil }
        return (account, data)
    }

    func save(account: String, data: Data) {
        clear()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        // A command-line tool (the Mac server) can't use iCloud Keychain: this Mac's own keychain then.
        if SecItemAdd(item as CFDictionary, nil) == errSecMissingEntitlement {
            var local = item
            local[kSecAttrSynchronizable as String] = false
            SecItemAdd(local as CFDictionary, nil)
        }
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
