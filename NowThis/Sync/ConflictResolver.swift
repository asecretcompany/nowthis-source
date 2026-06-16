import Foundation

/// Handles 412 Precondition Failed conflicts during CalDAV sync.
///
/// When the server returns 412, it means the ETag we sent in `If-Match`
/// no longer matches the server version. This resolver determines the
/// correct action to take.
///
/// **Current strategy:** Server Wins (Last-Writer-Wins with server priority).
/// This is the safest default for an initial implementation because it
/// prevents data corruption. A future version can add user-facing merge UI.
struct ConflictResolver {

    /// The resolution action for a conflict.
    enum Resolution {
        /// Refresh the local copy from the server and discard local changes.
        case serverWins
        /// Force-push the local version (overwrite server). Use cautiously.
        case localWins
        /// Both versions are kept; user must manually resolve.
        case manualMerge
    }

    /// Resolves a conflict between local and remote versions of a task.
    ///
    /// - Parameters:
    ///   - localModified: When the local version was last modified.
    ///   - remoteModified: When the remote version was last modified (if available).
    /// - Returns: The resolution action.
    static func resolve(
        localModified: Date?,
        remoteModified: Date?
    ) -> Resolution {
        // For MVP: server always wins to prevent data loss
        // The user can always re-edit locally after a sync
        return .serverWins
    }
}
