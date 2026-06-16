import Foundation
import SwiftData

/// Represents a CalDAV calendar collection that contains VTODO resources.
///
/// Each `TaskList` maps to a single CalDAV calendar on the Nextcloud server.
/// Collections are discovered via PROPFIND on the calendar-home-set and
/// tracked locally for delta synchronization using the CTag mechanism.
@Model
final class TaskList {

    // MARK: - Identity

    /// Local unique identifier.
    @Attribute(.unique) var id: String

    /// Remote CalDAV collection URI.
    var serverURL: String

    /// User-facing display name of the task list.
    var name: String

    /// Hex color string for UI display (e.g., "#007AFF").
    var colorHex: String

    // MARK: - Sync Metadata

    /// Calendar collection tag for delta tracking.
    /// Compared against the server CTag to determine if any resources changed.
    var ctag: String?

    /// Alias for `ctag` used by the SyncEngine.
    var syncCTag: String? {
        get { ctag }
        set { ctag = newValue }
    }

    /// Path component used for constructing CalDAV request URLs.
    var calendarPath: String?

    // MARK: - Configuration

    /// Per-list read-only toggle. When true, the UI disables all mutation controls.
    var isReadOnly: Bool = false

    // MARK: - Relationships

    /// The server account this list belongs to.
    var account: ServerAccount?

    /// All tasks in this collection. Cascade-deletes when the list is removed.
    @Relationship(deleteRule: .cascade, inverse: \TaskItem.taskList)
    var tasks: [TaskItem] = []

    /// All journal entries in this collection.
    @Relationship(deleteRule: .cascade, inverse: \JournalEntry.taskList)
    var journals: [JournalEntry] = []

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        serverURL: String,
        name: String,
        colorHex: String
    ) {
        self.id = id
        self.serverURL = serverURL
        self.name = name
        self.colorHex = colorHex
    }
}
