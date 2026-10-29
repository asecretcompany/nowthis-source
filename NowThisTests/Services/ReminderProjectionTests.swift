import Foundation
import SwiftData
import Testing
import UserNotifications

@testable import NowThis

@Suite("Reminder value projection")
struct ReminderProjectionTests {

    @Test("Value planner matches the existing model planner")
    func valuePlannerMatchesModelPlanner() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tasks = [
            makeTask("timed", dueDate: now.addingTimeInterval(3_600), reminderOffset: 900),
            makeTask("all-day", dueDate: now.addingTimeInterval(86_400), isDateOnly: true),
            makeTask("nag", dueDate: now.addingTimeInterval(7_200), reminderOffset: 0, nagging: true),
            makeTask("completed", dueDate: now.addingTimeInterval(9_000), status: .completed),
            makeTask("locally-deleted", dueDate: now.addingTimeInterval(10_000), deleted: true)
        ]
        let allDayMinutes = 8 * 60 + 15
        let values = tasks.map(ReminderTaskInput.init(task:))

        let expected = ReminderScheduler.planNotifications(
            tasks: tasks,
            now: now,
            maxCount: 60,
            badgesEnabled: true,
            allDayReminderMinutes: allDayMinutes
        )
        let actual = ReminderNotificationPlanner.plan(
            tasks: values,
            now: now,
            maxCount: 60,
            badgesEnabled: true,
            allDayReminderMinutes: allDayMinutes
        )

        #expect(actual == expected)
    }

    @Test("Pending changed values replace saved values and deleted IDs disappear")
    func overlayReplacesAndDeletesSavedInputs() {
        let original = input("edited", dueDate: Date(timeIntervalSince1970: 100))
        let untouched = input("untouched", dueDate: Date(timeIntervalSince1970: 200))
        let changed = input("edited", dueDate: Date(timeIntervalSince1970: 300), title: "Unsaved")
        let inserted = input("inserted", dueDate: Date(timeIntervalSince1970: 400))
        let overlay = ReminderTaskOverlay(upserts: [changed, inserted], deletedIDs: ["removed"])

        let merged = overlay.applying(to: [original, untouched, input("removed", dueDate: Date())])

        #expect(merged == [changed, untouched, inserted])
    }

    @Test("Main-context edits, inserts, and deletions are captured as values")
    @MainActor
    func capturesPendingModelChanges() throws {
        let container = try ModelContainer(
            for: Schema(SchemaV2.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let editedTask = makeTask("edited", dueDate: Date(timeIntervalSince1970: 100))
        let removedTask = makeTask("removed", dueDate: Date(timeIntervalSince1970: 200))
        context.insert(editedTask)
        context.insert(removedTask)
        try context.save()
        let savedEditedValue = ReminderTaskInput(task: editedTask)

        editedTask.title = "Unsaved title"
        editedTask.dueDate = Date(timeIntervalSince1970: 300)
        let insertedTask = makeTask("inserted", dueDate: Date(timeIntervalSince1970: 400))
        context.insert(insertedTask)
        context.delete(removedTask)

        let overlay = ReminderTaskOverlay(modelContext: context)
        let merged = overlay.applying(to: [
            savedEditedValue,
            input("removed", dueDate: Date(timeIntervalSince1970: 200))
        ])

        #expect(overlay.upserts.contains { $0.id == "edited" && $0.title == "Unsaved title" })
        #expect(overlay.upserts.contains { $0.id == "inserted" })
        #expect(overlay.deletedIDs.contains("removed"))
        #expect(merged.map(\.id) == ["edited", "inserted"])
    }

    @Test("A stale generation cannot apply its notification delta")
    @MainActor
    func staleGenerationDoesNotApply() async {
        let worker = PausedReminderProjectionWorker()
        let coalescer = ReminderProjectionCoalescer()
        var effects: [String] = []
        let firstGeneration = coalescer.beginRequest()
        let firstWork = Task { await worker.project(request()) }

        await worker.waitUntilStarted()
        let latestGeneration = coalescer.beginRequest()
        await worker.resume(with: nil)
        _ = await firstWork.value

        let applied = coalescer.applyIfCurrent(firstGeneration) {
            effects.append("register")
            effects.append("remove")
        }

        #expect(!applied)
        #expect(coalescer.isCurrent(latestGeneration))
        #expect(effects.isEmpty)
    }

    @Test("A newer request after account deletion invalidates a paused old plan")
    @MainActor
    func accountDeletionDuringWorkerDoesNotResurrectNotifications() async throws {
        let container = try ModelContainer(
            for: Schema(SchemaV2.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let task = makeTask("deleted", dueDate: Date().addingTimeInterval(3_600), reminderOffset: 0)
        context.insert(task)
        try context.save()
        let taskValue = ReminderTaskInput(task: task)
        let fireDate = Date().addingTimeInterval(3_600)
        let plan = ReminderScheduler.PlannedNotification(
            taskID: "deleted",
            fireDate: fireDate,
            badge: 1,
            kind: .reminder,
            isNagging: false,
            title: task.title
        )
        let worker = PausedReminderProjectionWorker()
        let store = RecordingNotificationStore(stored: [
            ReminderScheduler.PendingSnapshot(
                identifier: "reminder-old", fireDate: nil, badge: nil, title: nil)
        ])

        let reconcile = Task {
            await ReminderScheduler.reconcileScheduledNotifications(
                modelContext: context,
                store: store,
                badgesEnabled: true,
                worker: worker
            )
        }
        await worker.waitUntilStarted()
        context.delete(task)
        await ReminderScheduler.reconcileScheduledNotifications(
            modelContext: context,
            store: store,
            badgesEnabled: true,
            worker: ImmediateReminderProjectionWorker()
        )
        await worker.resume(with: ReminderProjectionResult(
            tasks: [taskValue], plan: [plan], badgeCount: 1))
        _ = await reconcile.value

        #expect(store.addedIdentifiers.isEmpty)
        #expect(store.removedIdentifiers.isEmpty)
    }

    private func request() -> ReminderProjectionRequest {
        ReminderProjectionRequest(
            now: Date(),
            calendar: .current,
            allDayReminderMinutes: TaskDefaultsPreferences.defaultAllDayReminderMinutes,
            maxCount: 60,
            badgesEnabled: true,
            overlay: ReminderTaskOverlay(upserts: [], deletedIDs: [])
        )
    }

    private func makeTask(
        _ id: String,
        dueDate: Date,
        isDateOnly: Bool = false,
        reminderOffset: Int? = nil,
        nagging: Bool = false,
        status: TaskStatus = .needsAction,
        deleted: Bool = false
    ) -> TaskItem {
        let task = TaskItem(title: id)
        task.id = id
        task.dueDate = dueDate
        task.isDueDateOnly = isDateOnly
        task.reminderOffset = reminderOffset
        task.isNaggingReminder = nagging
        task.status = status
        task.isDeletedLocally = deleted
        return task
    }

    private func input(
        _ id: String,
        dueDate: Date,
        title: String = "Task"
    ) -> ReminderTaskInput {
        ReminderTaskInput(
            id: id,
            title: title,
            hasActiveStatus: true,
            dueDate: dueDate,
            isDueDateOnly: false,
            reminderOffset: nil,
            isNaggingReminder: false,
            isDeletedLocally: false
        )
    }
}

@MainActor
private final class RecordingNotificationStore: NotificationStore {
    private(set) var addedIdentifiers: [String] = []
    private(set) var removedIdentifiers: [String] = []
    private let pending: [ReminderScheduler.PendingSnapshot]

    init(stored: [ReminderScheduler.PendingSnapshot]) {
        pending = stored
    }

    func authorizationAllowsScheduling(allowPrompt: Bool) async -> Bool { true }

    func pendingSnapshots() async -> [ReminderScheduler.PendingSnapshot] { pending }

    func add(_ request: UNNotificationRequest) async throws {
        addedIdentifiers.append(request.identifier)
    }

    func remove(identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}

private actor ImmediateReminderProjectionWorker: ReminderProjectionWorking {
    func project(_ request: ReminderProjectionRequest) async -> ReminderProjectionResult? { nil }
}

private actor PausedReminderProjectionWorker: ReminderProjectionWorking {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<ReminderProjectionResult?, Never>?

    func project(_ request: ReminderProjectionRequest) async -> ReminderProjectionResult? {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume(with result: ReminderProjectionResult?) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}
