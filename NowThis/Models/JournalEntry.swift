import Foundation
import SwiftData

/// Represents an iCalendar VJOURNAL component (RFC-5545 §3.6.3).
///
/// Journal entries support Markdown content and can be bidirectionally
/// linked to `TaskItem` instances for meeting-minutes → action-items workflows.
/// Full CRUD and CalDAV sync are deferred to post-MVP (v1.3).
@Model
final class JournalEntry {

    // MARK: - Identity

    /// Local unique identifier.
    @Attribute(.unique) var id: String

    /// RFC-5545 UID — globally unique iCalendar identifier.
    var uid: String

    // MARK: - Content

    /// VJOURNAL SUMMARY — the journal entry title.
    var title: String

    /// VJOURNAL DESCRIPTION — raw Markdown text body.
    var content: String

    // MARK: - Dates

    /// VJOURNAL CREATED timestamp.
    var createdDate: Date

    /// VJOURNAL LAST-MODIFIED timestamp.
    var lastModifiedDate: Date

    // MARK: - Sync Metadata

    /// Server ETag for conflict detection.
    var etag: String?

    /// Full URL of this .ics resource on the CalDAV server.
    var calendarURL: String?

    /// Flags local modifications awaiting upstream push.
    var isDirty: Bool = false

    /// Soft-delete flag for offline sync queueing.
    var isDeletedLocally: Bool = false

    // MARK: - Relationships

    /// The task list (CalDAV collection) this journal belongs to.
    var taskList: TaskList?

    /// Many-to-many relationship with tasks for bidirectional linking.
    var associatedTasks: [TaskItem] = []

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        uid: String = UUID().uuidString,
        title: String,
        content: String = ""
    ) {
        self.id = id
        self.uid = uid
        self.title = title
        self.content = content
        self.createdDate = Date()
        self.lastModifiedDate = Date()
    }
}
