import Foundation
import os
import Security

/// Provides CRUD access to the macOS Keychain for auth tokens.
struct KeychainManager: Sendable {
    enum TokenKey: String, Sendable {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case userEmail = "user_email"
        case authServerURL = "auth_server_url"
    }

    private static let serviceName = "com.therapyrecorder.auth"
    private static let logger = Logger(subsystem: "com.macos-sample", category: "KeychainManager")

    static func saveToken(_ value: String, forKey key: TokenKey) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
        ]

        // Try updating first; add if not found.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Keychain save failed for \(key.rawValue): \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            logger.error("Keychain update failed for \(key.rawValue): \(updateStatus)")
        }
    }

    static func getToken(forKey key: TokenKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(forKey key: TokenKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Keychain delete failed for \(key.rawValue): \(status)")
        }
    }

    static func deleteAll() {
        for key in [TokenKey.idToken, .refreshToken, .userEmail, .authServerURL] {
            deleteToken(forKey: key)
        }
    }
}
