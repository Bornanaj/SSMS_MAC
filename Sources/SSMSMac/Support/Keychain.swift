import Foundation
import Security

/// Stores connection passwords in the login keychain, so they never touch our JSON files.
enum Keychain {
    private static let service = "dev.ssmsmac.connections"

    static func setPassword(_ password: String, for account: String) {
        guard !account.isEmpty else { return }
        let data = Data(password.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func password(for account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The synchronous read blocks on the security daemon, and macOS may decide to
    /// prompt — which never returns if the caller is the main thread mid-layout. Every
    /// UI path goes through this instead.
    static func password(for account: String) async -> String? {
        guard !account.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: password(for: account))
            }
        }
    }

    static func removePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
