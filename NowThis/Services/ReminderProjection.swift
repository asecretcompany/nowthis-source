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
    var foreignPendingCount = 0
}

struct ReminderProjectionResult: Sendable {
    let tasks: [ReminderTaskInput]
    let plan: [ReminderScheduler.PlannedNotification]
    let badgeCount: Int
    var requestPlan: ReminderRequestPlan? = nil
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
                let ticketIDs: Set<String>
                do {
                    ticketIDs = ReminderSchedulingJournal.isAvailable(in: container)
                        ? try ReminderSchedulingJournal.capture(in: context) : []
                } catch { return nil }
                let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate {
                    $0.dueDate != nil && !$0.isDeletedLocally
                })
                guard let saved = try? context.fetch(descriptor) else { return nil }

                let tasks = request.overlay.applying(to: saved.map(ReminderTaskInput.init(task:)))
                let requestPlan = ReminderNotificationPlanner.planRequests(
                    tasks: tasks,
                    now: request.now,
                    maxRequests: request.maxCount,
                    foreignPendingCount: request.foreignPendingCount,
                    badgesEnabled: request.badgesEnabled,
                    allDayReminderMinutes: request.allDayReminderMinutes,
                    calendar: request.calendar
                )
                let badgeCount = request.badgesEnabled
                    ? BadgeTimeline(inputs: tasks, allDayReminderMinutes: request.allDayReminderMinutes,
                                    calendar: request.calendar).count(asOf: request.now)
                    : 0
                return ReminderProjectionResult(tasks: tasks, plan: requestPlan.primaryEntries,
                    badgeCount: badgeCount, requestPlan: requestPlan, ticketIDs: ticketIDs,
                    overlayIsSaved: request.overlay.upserts.isEmpty && request.overlay.deletedIDs.isEmpty)
            }
        } catch { return nil }
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
