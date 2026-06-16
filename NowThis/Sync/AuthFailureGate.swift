import Foundation
import CryptoKit

/// Tracks Nextcloud accounts whose credentials the server has rejected (HTTP 401),
/// so the sync scheduler stops re-sending the same failing Basic-Auth credentials.
///
/// **Why this exists:** Nextcloud's brute-force protection counts every failed
/// CalDAV Basic-Auth request as an incorrect login attempt. Sync runs on many
/// triggers (app foreground, task mutations, and `.task`/refresh on the Tasks,
/// Calendar, Kanban, and Matrix tabs), so without this gate a single stale or
/// revoked app password is re-sent over and over and locks the user out of their
/// own server.
///
/// The gate is in-memory (so it naturally resets on app relaunch — at most one
/// attempt per cold launch) and **auto-clears when the stored password changes**,
/// i.e. as soon as the user re-authenticates. Only the SHA-256 hash of the failing
/// password is retained, never the password itself.
struct AuthFailureGate {

    private var failedPasswordHashes: [String: String] = [:]

    /// Records that `password` failed authentication for `accountID`.
    mutating func recordFailure(accountID: String, password: String) {
        failedPasswordHashes[accountID] = Self.hash(password)
    }

    /// Returns `true` when `currentPassword` for `accountID` is the same credential
    /// that already failed — re-sending it would just be another failed login.
    /// Returns `false` for accounts with no recorded failure or whose password has
    /// since changed (the user re-authenticated).
    func shouldSkip(accountID: String, currentPassword: String) -> Bool {
        guard let failed = failedPasswordHashes[accountID] else { return false }
        return failed == Self.hash(currentPassword)
    }

    private static func hash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
