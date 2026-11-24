import Foundation
import SwiftData

/// Immutable reminder-relevant task data. This is the only task representation used by the
/// projection worker, so no SwiftData model crosses an actor hop or suspension point.
struct ReminderTaskInput: Sendable, Equatable {
    let id: String
    let title: String
    let hasActiveStatus: Bool
    let dueDate: Date?
    let isDueDateOnly: Bool
    let reminderOffset: Int?
    let isNaggingReminder: Bool
    let isDeletedLocally: Bool

    init(task: TaskItem) {
        id = task.id
        title = task.title
        hasActiveStatus = task.status != .completed && task.status != .cancelled
        dueDate = task.dueDate
        isDueDateOnly = task.isDueDateOnly
        reminderOffset = task.reminderOffset
        isNaggingReminder = task.isNaggingReminder
        isDeletedLocally = task.isDeletedLocally
    }

    init(
        id: String,
        title: String,
        hasActiveStatus: Bool,
        dueDate: Date?,
        isDueDateOnly: Bool,
        reminderOffset: Int?,
        isNaggingReminder: Bool,
        isDeletedLocally: Bool
    ) {
        self.id = id
        self.title = title
        self.hasActiveStatus = hasActiveStatus
        self.dueDate = dueDate
        self.isDueDateOnly = isDueDateOnly
        self.reminderOffset = reminderOffset
        self.isNaggingReminder = isNaggingReminder
        self.isDeletedLocally = isDeletedLocally
    }
}

/// Main-context edits captured synchronously before projection starts.
struct ReminderTaskOverlay: Sendable, Equatable {
    let upserts: [ReminderTaskInput]
    let deletedIDs: Set<String>

    init(upserts: [ReminderTaskInput], deletedIDs: Set<String>) {
        self.upserts = upserts
        self.deletedIDs = deletedIDs
    }

    @MainActor
    init(modelContext: ModelContext) {
        let changedTasks = modelContext.insertedModelsArray.compactMap { $0 as? TaskItem }
            + modelContext.changedModelsArray.compactMap { $0 as? TaskItem }
        upserts = Dictionary(changedTasks.map { ($0.id, ReminderTaskInput(task: $0)) },
                             uniquingKeysWith: { _, latest in latest })
            .values.sorted { $0.id < $1.id }
        deletedIDs = Set(modelContext.deletedModelsArray.compactMap { ($0 as? TaskItem)?.id })
    }

    func applying(to saved: [ReminderTaskInput]) -> [ReminderTaskInput] {
        var valuesByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var order = saved.map(\.id)

        for input in upserts {
            if valuesByID[input.id] == nil { order.append(input.id) }
            valuesByID[input.id] = input
        }
        for id in deletedIDs {
            valuesByID.removeValue(forKey: id)
        }

        return order.compactMap { valuesByID[$0] }
    }
}

/// All time-sensitive inputs are fixed on the main actor at the start of one generation.
struct ReminderProjectionRequest: Sendable {
    let now: Date
    let calendar: Calendar
    let allDayReminderMinutes: Int
    let maxCount: Int
    let badgesEnabled: Bool
    let overlay: ReminderTaskOverlay
}

struct ReminderProjectionResult: Sendable {
    let tasks: [ReminderTaskInput]
    var ticketIDs: Set<String> = []
    var overlayIsSaved = true
}

protocol ReminderProjectionWorking: Sendable {
    func project(_ request: ReminderProjectionRequest) async -> ReminderProjectionResult?
}

/// Owns its own context and only returns Sendable values to the caller.
actor ReminderProjectionWorker: ReminderProjectionWorking {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func project(_ request: ReminderProjectionRequest) async -> ReminderProjectionResult? {
        do {
            return try BackgroundRunBudget.protectingCurrent {
                let context = ModelContext(container)
                // Capture tickets before task rows: a concurrent commit can only leave extra
                // work pending, never let a newer ticket acknowledge an older task snapshot.
                let ticketIDs = try recoveryTickets(in: context)
                let tasks = try taskInputs(in: context, overlay: request.overlay)
                return ReminderProjectionResult(tasks: tasks, ticketIDs: ticketIDs,
                    overlayIsSaved: request.overlay.upserts.isEmpty && request.overlay.deletedIDs.isEmpty)
            }
        } catch { return nil }
    }

    func badgeCount(_ request: ReminderProjectionRequest) -> Int? {
        try? BackgroundRunBudget.protectingCurrent {
            let context = ModelContext(container)
            // Keep the existing hold if the recovery journal cannot be read.
            _ = try recoveryTickets(in: context)
            let tasks = try taskInputs(in: context, overlay: request.overlay)
            return BadgeTimeline(inputs: tasks, allDayReminderMinutes: request.allDayReminderMinutes,
                                 calendar: request.calendar).count(asOf: request.now)
        }
    }

    private func recoveryTickets(in context: ModelContext) throws -> Set<String> {
        ReminderSchedulingJournal.isAvailable(in: container)
            ? try ReminderSchedulingJournal.capture(in: context) : []
    }

    private func taskInputs(in context: ModelContext, overlay: ReminderTaskOverlay) throws -> [ReminderTaskInput] {
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.dueDate != nil && !$0.isDeletedLocally
        })
        let saved = try context.fetch(descriptor)
        return overlay.applying(to: saved.map(ReminderTaskInput.init(task:)))
    }
}

/// Rejects results from any request superseded while its worker was suspended.
@MainActor
final class ReminderProjectionCoalescer {
    private(set) var generation: UInt64 = 0

    @discardableResult
    func beginRequest() -> UInt64 {
        generation &+= 1
        return generation
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        self.generation == generation
    }

    @discardableResult
    func applyIfCurrent(_ generation: UInt64, _ apply: () -> Void) -> Bool {
        guard isCurrent(generation) else { return false }
        apply()
        return true
    }
}

enum ReminderNotificationPlanner {
    static func plan(
        tasks: [ReminderTaskInput],
        now: Date,
        maxCount: Int,
        badgesEnabled: Bool,
        allDayReminderMinutes: Int = TaskDefaultsPreferences.allDayReminderMinutes,
        calendar: Calendar = .current
    ) -> [ReminderScheduler.PlannedNotification] {
        let interval = PerformanceTrace.begin(PerformanceTrace.reminderPlanName, count: tasks.count)
        defer { PerformanceTrace.end(PerformanceTrace.reminderPlanName, interval) }
        return planRequests(tasks: tasks, now: now, maxRequests: maxCount,
                            foreignPendingCount: 0, badgesEnabled: badgesEnabled,
                            allDayReminderMinutes: allDayReminderMinutes,
                            calendar: calendar).primaryEntries
    }
}
