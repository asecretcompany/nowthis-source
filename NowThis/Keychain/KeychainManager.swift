import Foundation
import Security

/// Thread-safe Keychain wrapper using Actor isolation.
///
/// All credentials are stored as `kSecClassGenericPassword` items
/// scoped to the app's Keychain service identifier. Passwords are
/// protected with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// to ensure they remain encrypted at rest and are never backed up
/// to other devices.
///
/// **Critical:** This is the ONLY place credentials are stored.
/// Never store passwords in UserDefaults or SwiftData.
actor KeychainManager {

    // MARK: - Error Types

    /// Typed errors for Keychain operations.
    enum KeychainError: Error, LocalizedError {
        case itemNotFound
        case duplicateItem
        case unexpectedData
        case osError(OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return String(localized: "Credential not found in Keychain.")
            case .duplicateItem:
                return String(localized: "Credential already exists.")
            case .unexpectedData:
                return String(localized: "Keychain returned unexpected data format.")
            case .osError(let status):
                return String(localized: "Keychain error: \(status)")
            }
        }
    }

    // MARK: - Properties

    private let service: String

    // MARK: - Initializer

    /// Creates a KeychainManager scoped to the given service identifier.
    /// - Parameter service: The Keychain service name. Defaults to the app's CalDAV service.
    init(service: String = AppConstants.keychainService) {
        self.service = service
    }

    // MARK: - Public API

    /// Saves or updates a password for the given account identifier.
    ///
    /// Uses delete-then-add to handle the `errSecDuplicateItem` case cleanly,
    /// avoiding the need to distinguish between insert and update operations.
    ///
    /// - Parameters:
    ///   - password: The plaintext password or app-password to store.
    ///   - accountID: The unique identifier for this account (matches `ServerAccount.id`).
    /// - Throws: `KeychainError.unexpectedData` if the password can't be encoded,
    ///           or `KeychainError.osError` for other Keychain failures.
    func save(password: String, for accountID: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        // Purge prior occurrence to avoid duplicate errors
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osError(status)
        }
    }

    /// Retrieves the stored password for the given account identifier.
    ///
    /// - Parameter accountID: The unique identifier for the account.
    /// - Returns: The stored password string, or `nil` if no item exists.
    /// - Throws: `KeychainError.osError` for unexpected Keychain failures,
    ///           or `KeychainError.unexpectedData` if the stored data isn't valid UTF-8.
    func retrieve(for accountID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecItemNotFound { return nil }

        guard status == errSecSuccess else {
            throw KeychainError.osError(status)
        }

        guard let data = dataTypeRef as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }

        return password
    }

    /// Deletes the stored password for the given account identifier.
    ///
    /// This operation is idempotent — deleting a non-existent item does not throw.
    ///
    /// - Parameter accountID: The unique identifier for the account.
    /// - Throws: `KeychainError.osError` for unexpected Keychain failures.
    func delete(for accountID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osError(status)
        }
    }
}
