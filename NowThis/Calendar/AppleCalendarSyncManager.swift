import EventKit
import SwiftData

/// One-way push sync from NowThis tasks to Apple Calendar via EventKit.
///
/// Creates and manages a dedicated "NowThis" `EKCalendar` in the default
/// calendar source. Tasks with due dates are synced as `EKEvent` entries.
/// Completed tasks get a `✓` prefix. Deleted tasks remove their events.
///
/// This manager never reads events back — NowThis is always the source of truth.
@MainActor
final class AppleCalendarSyncManager: ObservableObject {

    @Published var isSyncing = false
    @Published var lastError: String?

    private let permissionManager: CalendarPermissionManager

    /// The identifier of the managed "NowThis" calendar.
    private static let calendarTitleKey = "NowThis"
    private static let calendarColorKey = "nowthis_calendar_id"

    init(permissionManager: CalendarPermissionManager) {
        self.permissionManager = permissionManager
    }

    /// Syncs all tasks with due dates to Apple Calendar.
    ///
    /// - Parameter modelContext: The SwiftData context to read tasks from.
    func syncAll(modelContext: ModelContext) async {
        guard permissionManager.hasAccess else {
            lastError = "Calendar access not granted"
            return
        }

        isSyncing = true
        lastError = nil

        do {
            let calendar = try findOrCreateCalendar()
            let predicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
            let descriptor = FetchDescriptor<TaskItem>(
                predicate: predicate
            )
            let tasks = try modelContext.fetch(descriptor)

            for task in tasks {
                try syncTask(task, to: calendar)
            }

            // Clean up events for deleted tasks
            try cleanupDeletedEvents(tasks: tasks, calendar: calendar)

            try modelContext.save()
        } catch {
            lastError = error.localizedDescription
        }

        isSyncing = false
    }

    /// Syncs a single task to Apple Calendar (for per-task "Add to Calendar").
    ///
    /// - Parameters:
    ///   - task: The task to sync.
    ///   - calendarIdentifier: Optional specific calendar ID. If nil, uses the managed "NowThis" calendar.
    func syncSingleTask(_ task: TaskItem, to calendarIdentifier: String? = nil) throws {
        guard permissionManager.hasAccess else {
            throw CalendarSyncError.noAccess
        }

        let store = permissionManager.eventStore
        let calendar: EKCalendar

        if let id = calendarIdentifier,
           let specific = store.calendar(withIdentifier: id) {
            calendar = specific
        } else {
            calendar = try findOrCreateCalendar()
        }

        try syncTask(task, to: calendar)
    }

    /// Returns all writable calendars for the "Add to Calendar" picker.
    func writableCalendars() -> [EKCalendar] {
        guard permissionManager.hasAccess else { return [] }
        return permissionManager.eventStore
            .calendars(for: .event)
            .filter { $0.allowsContentModifications }
    }

    // MARK: - Private

    /// Finds the existing "NowThis" calendar or creates a new one.
    private func findOrCreateCalendar() throws -> EKCalendar {
        let store = permissionManager.eventStore

        // Search for existing
        if let existing = store.calendars(for: .event)
            .first(where: { $0.title == Self.calendarTitleKey }) {
            return existing
        }

        // Create new
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarTitleKey
        calendar.cgColor = CGColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1.0) // Purple tint

        // Find default source
        if let defaultSource = store.defaultCalendarForNewEvents?.source {
            calendar.source = defaultSource
        } else if let localSource = store.sources.first(where: { $0.sourceType == .local }) {
            calendar.source = localSource
        } else if let firstSource = store.sources.first {
            calendar.source = firstSource
        } else {
            throw CalendarSyncError.noCalendarSource
        }

        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    /// Creates or updates an EKEvent for a single task.
    private func syncTask(_ task: TaskItem, to calendar: EKCalendar) throws {
        let store = permissionManager.eventStore

        guard let dueDate = task.dueDate else {
            // No due date — remove event if one exists
            if let eventID = task.calendarEventID {
                try removeEvent(identifier: eventID)
                task.calendarEventID = nil
            }
            return
        }

        let event: EKEvent

        // Try to find existing event
        if let eventID = task.calendarEventID,
           let existing = store.event(withIdentifier: eventID) {
            event = existing
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }

        // Map task fields to event
        let startDate = task.startDate ?? dueDate
        event.title = task.status == .completed ? "✓ \(task.title)" : task.title
        event.startDate = startDate
        event.endDate = Calendar.current.date(byAdding: .minute, value: 30, to: startDate) ?? startDate
        event.notes = task.descriptionText
        event.location = task.locationName

        if let url = task.url, let eventURL = URL(string: url) {
            event.url = eventURL
        }

        try store.save(event, span: .thisEvent)
        task.calendarEventID = event.eventIdentifier
    }

    /// Removes an EKEvent by identifier.
    private func removeEvent(identifier: String) throws {
        let store = permissionManager.eventStore
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent)
    }

    /// Cleans up orphaned events for tasks that have been deleted.
    private func cleanupDeletedEvents(tasks: [TaskItem], calendar: EKCalendar) throws {
        let store = permissionManager.eventStore
        let taskEventIDs = Set(tasks.compactMap(\.calendarEventID))

        // Find events in NowThis calendar within a wide range
        let startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        let endDate = Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: [calendar]
        )

        let events = store.events(matching: predicate)
        for event in events {
            if !taskEventIDs.contains(event.eventIdentifier) {
                try? store.remove(event, span: .thisEvent)
            }
        }
    }
}

// MARK: - Errors

enum CalendarSyncError: LocalizedError {
    case noAccess
    case noCalendarSource

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "Calendar access not granted. Please enable in Settings."
        case .noCalendarSource:
            return "No calendar source available on this device."
        }
    }
}
