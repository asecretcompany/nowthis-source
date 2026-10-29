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

    /// Sentinel `serverURL` marking the local list that holds tasks rescued from a removed
    /// account.
    ///
    /// The list used to be found by `name == String(localized: "Recovered Tasks")`. Remove an
    /// account in English, switch the device to German, remove another — and a *second*
    /// recovery list is created, with the first one's tasks stranded in it. The name is
    /// user-facing and translated; identity must not be.
    ///
    /// Safe as a `serverURL`: every locally created list uses `""`, and this list belongs to a
    /// Vault account, which is never synced.
    static let recoveryListServerURL = "nowthis://recovered"

    /// Whether this is the rescued-tasks list. Independent of its name, which the user may
    /// rename and which ships translated.
    var isRecoveryList: Bool { serverURL == Self.recoveryListServerURL }

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

    /// Whether the server lets this user change the list's tasks — false for a list
    /// shared with them read-only. Set from `current-user-privilege-set` at discovery;
    /// always false for a server that does not report privileges, and for local lists.
    ///
    /// Only the move picker reads it today, to refuse a destination the PUT would be
    /// refused by. The rest of the app's editing controls do not consult it yet.
    var isReadOnly: Bool = false

    /// Confirmed loss of server access hides cached shared photos until a fresh pull.
    var photoAccessRevoked: Bool?

    /// Set when the user edits this list's name or colour locally, and cleared once that
    /// edit has been PROPPATCHed to the server.
    ///
    /// The list analogue of `TaskItem.isDirty`. Discovery runs on every sync and adopts the
    /// remote name and colour; without this flag a recolour was reverted by the sync that
    /// followed it about two seconds later.
    var isMetadataDirty: Bool = false

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

    // MARK: - Remote Metadata

    /// Applies a discovered calendar's name and colour to this list.
    ///
    /// An empty `colorHex` means the server holds no colour for this collection, which is
    /// silence rather than an instruction — the local colour stands.
    ///
    /// A list whose own name or colour has not reached the server yet adopts neither: the
    /// push has to win, or discovery reverts the edit that is still waiting to go out.
    func applyRemoteMetadata(name: String, colorHex: String) {
        guard !isMetadataDirty else { return }
        self.name = name
        if !colorHex.isEmpty {
            self.colorHex = colorHex
        }
    }
}
