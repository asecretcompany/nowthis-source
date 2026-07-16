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

    /// When the last *full* inbound pull of this collection completed.
    /// Bounds the CTag skip optimization (see `SyncEngine.shouldSkipPull`): even
    /// when the server CTag still matches, a full pull is forced once this is
    /// stale, so a cached/stale `getctag` can never silently suppress server
    /// changes indefinitely. `nil` until the first full pull.
    var lastFullPullDate: Date?

    /// Path component used for constructing CalDAV request URLs.
    var calendarPath: String?

    // MARK: - Configuration

    /// Per-list read-only toggle. When true, the UI disables all mutation controls.
    var isReadOnly: Bool = false

    /// Per-list override for the default due date applied to new tasks, stored as
    /// a `DefaultDueDateRule` raw value. `nil` = fall back to the global default.
    /// Local-only app configuration (not serialized to CalDAV). Typed access is
    /// via the `defaultDueDateRule` extension in the app target.
    var defaultDueDateRuleRaw: String?

    /// Per-list override for whether new tasks get a default reminder: `"on"`,
    /// `"off"`, or `nil` (use the global setting). Local-only app configuration.
    var defaultReminderModeRaw: String?

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
