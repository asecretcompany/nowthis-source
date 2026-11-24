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
    private let operations: Operations

    struct Operations: Sendable {
        var add: @Sendable (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
        var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
        var copyMatching: @Sendable (CFDictionary) -> (OSStatus, AnyObject?) = { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query, &result)
            return (status, result)
        }
        var delete: @Sendable (CFDictionary) -> OSStatus = { SecItemDelete($0) }
    }

    // MARK: - Initializer

    /// Creates a KeychainManager scoped to the given service identifier.
    /// - Parameter service: The Keychain service name. Defaults to the app's CalDAV service.
    init(service: String = AppConstants.keychainService, operations: Operations = Operations()) {
        self.service = service
        self.operations = operations
    }

    // MARK: - Public API

    /// Saves or updates a password for the given account identifier.
    ///
    /// Replaces only the value of an existing item, preserving its protection.
    /// If there is no item yet, inserts one with device-only protection.
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

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        let changes = [kSecValueData as String: data] as CFDictionary
        var status = operations.update(query as CFDictionary, changes)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = operations.add(newItem as CFDictionary)
            if status == errSecDuplicateItem {
                // Another caller inserted this identity between the update and add.
                status = operations.update(query as CFDictionary, changes)
            }
        }
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

        let (status, dataTypeRef) = operations.copyMatching(query as CFDictionary)

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

        let status = operations.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osError(status)
        }
    }

    /// Synchronous so launch can authenticate a cache without crossing the actor.
    /// This separate, non-synchronizing item uses the main app's default access
    /// group; no Widget/Watch access group or CalDAV credential policy is changed.
    nonisolated static func proEntitlementSigningKey(
        createIfMissing: Bool,
        service: String = "com.asecretcompany.nowthis.pro-cache"
    ) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "snapshot-signing.v1",
            kSecAttrSynchronizable as String: false
        ]
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else {
                throw KeychainError.unexpectedData
            }
            return data
        }
        guard status == errSecItemNotFound else { throw KeychainError.osError(status) }
        guard createIfMissing else { return nil }

        var data = Data(count: 32)
        let randomStatus = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw KeychainError.osError(randomStatus) }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another caller won creation. Never replace an existing signing key.
            guard let existing = try proEntitlementSigningKey(createIfMissing: false, service: service) else {
                throw KeychainError.itemNotFound
            }
            return existing
        }
        guard addStatus == errSecSuccess else { throw KeychainError.osError(addStatus) }
        return data
    }

}
