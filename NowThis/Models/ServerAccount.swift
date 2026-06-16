import Foundation
import SwiftData

/// The mode of operation for a server account.
enum AccountMode: String, Codable {
    /// Vault Mode — fully local, no server sync. Privacy-first.
    case vault

    /// Nextcloud Mode — syncs with a CalDAV server.
    case nextcloud
}

/// How a Nextcloud account was authenticated.
enum AuthMethod: String, Codable {
    /// User manually entered an app password.
    case manual

    /// Authenticated via Nextcloud Login Flow v2.
    case loginFlow
}

/// Stores account metadata for a connected server (or local vault).
///
/// **Critical:** Credentials (passwords/app-passwords) are NEVER stored here.
/// They are stored exclusively in the iOS Keychain via `KeychainManager`.
/// This model only holds non-sensitive metadata needed for UI display
/// and sync orchestration.
@Model
final class ServerAccount {

    // MARK: - Identity

    /// Local unique identifier. Also used as the Keychain account key.
    @Attribute(.unique) var id: String

    /// User-facing display name for this account.
    var displayName: String

    /// The base URL of the Nextcloud server (e.g., "https://cloud.example.com").
    /// Empty string for Vault Mode accounts.
    var serverBaseURL: String

    /// The username used for authentication.
    /// Empty string for Vault Mode accounts.
    var username: String

    /// The account's operating mode.
    var mode: AccountMode

    /// How this account was authenticated (stored).
    /// Optional because pre-Build-28 rows have `nil` in the backing store
    /// after SwiftData lightweight migration.
    var storedAuthMethod: AuthMethod?

    /// Safe accessor that falls back to `.manual` for pre-migration rows.
    var resolvedAuthMethod: AuthMethod {
        storedAuthMethod ?? .manual
    }

    // MARK: - Sync State

    /// Timestamp of the last successful full sync.
    var lastSyncDate: Date?

    // MARK: - Relationships

    /// All task lists belonging to this account.
    @Relationship(deleteRule: .cascade, inverse: \TaskList.account)
    var taskLists: [TaskList] = []

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        displayName: String,
        serverBaseURL: String,
        username: String,
        mode: AccountMode = .nextcloud
    ) {
        self.id = id
        self.displayName = displayName
        self.serverBaseURL = serverBaseURL
        self.username = username
        self.mode = mode
    }

    /// Convenience initializer for Vault Mode accounts.
    convenience init(vaultDisplayName: String = "Vault") {
        self.init(
            displayName: vaultDisplayName,
            serverBaseURL: "",
            username: "",
            mode: .vault
        )
    }
}
