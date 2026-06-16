import Foundation
import SwiftData

/// Tracks per-collection synchronization state for the CalDAV sync engine.
///
/// Each `SyncMetadata` instance corresponds to a single CalDAV calendar
/// collection and stores the sync-token and CTag needed for efficient
/// delta synchronization.
@Model
final class SyncMetadata {

    // MARK: - Identity

    /// Local unique identifier.
    @Attribute(.unique) var id: String

    /// CalDAV collection path (e.g., "/remote.php/dav/calendars/user/tasks/").
    var collectionPath: String

    // MARK: - Sync State

    /// WebDAV sync-token for delta synchronization.
    /// When present, the engine can issue a `sync-collection` REPORT
    /// to fetch only changed/deleted resources since this token was issued.
    var syncToken: String?

    /// Last known CTag (calendar collection tag).
    /// Compared against the server's current CTag to detect any changes.
    var lastCTag: String?

    /// Timestamp of the last successful full sync pass.
    var lastFullSync: Date?

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        collectionPath: String
    ) {
        self.id = id
        self.collectionPath = collectionPath
    }
}
