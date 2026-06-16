import Foundation
import SwiftData

/// Represents a single task synchronized with a Nextcloud CalDAV VTODO component.
///
/// This is the core data model of the application. It maps 1:1 to an iCalendar
/// VTODO component (RFC-5545 §3.6.2) and supports infinite nesting via the
/// self-referential `parentTask` / `subtasks` relationship.
///
/// The SwiftData store is the Single Source of Truth (SSOT). The UI reads/writes
/// this model exclusively; the Sync Engine independently reconciles it with the
/// remote CalDAV server.
@Model
final class TaskItem {

    // MARK: - Identity

    /// Local unique identifier (UUID string). Used as the SwiftData primary key.
    @Attribute(.unique) var id: String

    /// RFC-5545 UID — globally unique iCalendar identifier.
    /// Persisted to the VTODO `UID` property and used for cross-device identity.
    var uid: String

    /// Server ETag for conflict detection. Populated on every fetch from the server.
    /// Used in `If-Match` headers during PUT/DELETE requests.
    var etag: String?

    // MARK: - Core Properties

    /// VTODO SUMMARY — the task's display title.
    var title: String

    /// VTODO DESCRIPTION — supports Markdown formatting.
    var descriptionText: String?

    /// VTODO STATUS — mapped via `TaskStatus` enum.
    var status: TaskStatus

    /// VTODO PRIORITY — mapped via `TaskPriority` enum (0-9 → 4-tier).
    var priority: TaskPriority

    /// VTODO PERCENT-COMPLETE — integer 0-100.
    var percentComplete: Int

    /// VTODO COMPLETED — UTC timestamp when the task was marked done.
    var completedDate: Date?

    // MARK: - Dates

    /// VTODO CREATED — UTC timestamp of initial creation.
    var createdDate: Date

    /// VTODO LAST-MODIFIED — UTC timestamp of most recent modification.
    var lastModifiedDate: Date?

    /// VTODO DUE — optional due date/time.
    var dueDate: Date?

    /// True when `dueDate` was parsed from a date-only iCalendar value
    /// (`DUE;VALUE=DATE:YYYYMMDD`). Date-only tasks are due at the end of
    /// the local day, not at midnight UTC.
    var isDueDateOnly: Bool = false

    /// VTODO DTSTART — optional start date/time.
    var startDate: Date?

    /// True when `startDate` was parsed from a date-only iCalendar value.
    var isStartDateOnly: Bool = false

    // MARK: - Recurrence

    /// VTODO RRULE — stored as the raw iCalendar string for future expansion.
    var recurrenceRule: String?

    /// UID of the parent task on the server. Used for RELATED-TO;RELTYPE=PARENT.
    /// After sync, this is resolved into the `parentTask` relationship.
    var parentUID: String?

    // MARK: - Hierarchy (Infinite Nesting)

    /// The parent task in the hierarchy. Maps to `RELATED-TO;RELTYPE=PARENT`.
    var parentTask: TaskItem?

    /// Child tasks. Cascade-deletes when the parent is removed.
    @Relationship(deleteRule: .cascade, inverse: \TaskItem.parentTask)
    var subtasks: [TaskItem] = []

    // MARK: - Relationships

    /// The task list (CalDAV collection) this task belongs to.
    var taskList: TaskList?

    /// VTODO CATEGORIES — many-to-many relationship with tags.
    @Relationship(inverse: \Tag.tasks) var tags: [Tag] = []

    /// VJOURNAL association — many-to-many with journal entries.
    @Relationship(inverse: \JournalEntry.associatedTasks)
    var associatedJournals: [JournalEntry] = []

    // MARK: - Extended Properties

    /// VTODO LOCATION — free text location name.
    var locationName: String?

    /// VTODO GEO latitude component.
    var latitude: Double?

    /// VTODO GEO longitude component.
    var longitude: Double?

    /// Geofence trigger radius in meters (app-specific, not iCal standard).
    var geofenceRadius: Double?

    /// URL associated with this task (VTODO URL property).
    var url: String?

    /// User-defined sort order for manual sorting. Lower values sort first.
    var manualSortOrder: Int = 0

    // MARK: - Sync Metadata

    /// Full URL of this .ics resource on the CalDAV server.
    var calendarURL: String?

    /// True if this task has never been pushed to the server.
    var isLocalOnly: Bool

    /// Flags that this task has local modifications awaiting upstream push.
    var isDirty: Bool = false

    /// Soft-delete flag for offline sync queueing.
    /// When true, the sync engine will issue a DELETE on next push,
    /// then hard-delete from SwiftData on server confirmation.
    var isDeletedLocally: Bool = false

    /// Timestamp of the last successful sync for this item.
    var lastSyncDate: Date?

    /// Apple Calendar `EKEvent.eventIdentifier` for EventKit sync tracking.
    var calendarEventID: String?

    /// Nextcloud Calendar VEVENT href for CalDAV calendar sync tracking.
    var calendarEventHref: String?

    /// Seconds before the due date to fire a reminder notification.
    /// 0 = at due time, 300 = 5 min before, 900 = 15 min before, etc.
    /// Nil = no reminder. Only meaningful when dueDate is non-nil.
    var reminderOffset: Int?

    // MARK: - Sync Aliases (Computed)

    /// Alias for `descriptionText` used by the SyncEngine.
    var notes: String {
        get { descriptionText ?? "" }
        set { descriptionText = newValue.isEmpty ? nil : newValue }
    }

    /// Alias for `locationName` used by the SyncEngine.
    var location: String? {
        get { locationName }
        set { locationName = newValue }
    }

    /// Alias for `calendarURL` used by the SyncEngine.
    var remoteHref: String? {
        get { calendarURL }
        set { calendarURL = newValue }
    }

    /// Alias for `isDeletedLocally` used by the SyncEngine.
    var isDeleted: Bool {
        get { isDeletedLocally }
        set { isDeletedLocally = newValue }
    }

    /// Raw integer priority (0-9) for iCalendar serialization.
    var priorityRaw: Int {
        get { priority.rawValue }
        set { priority = TaskPriority(rawValue: newValue) ?? TaskPriority.none }
    }

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        uid: String = UUID().uuidString,
        title: String,
        descriptionText: String? = nil,
        priority: TaskPriority = .none,
        status: TaskStatus = .needsAction
    ) {
        self.id = id
        self.uid = uid
        self.title = title
        self.descriptionText = descriptionText
        self.createdDate = Date()
        self.lastModifiedDate = Date()
        self.priority = priority
        self.status = status
        self.percentComplete = 0
        self.isLocalOnly = true
    }
}
