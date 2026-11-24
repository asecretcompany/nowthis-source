import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TaskCompletionCoordinator Tests

@Suite("Task Completion Animation")
struct TaskCompletionAnimationTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self,
            configurations: config
        )
    }

    @Test("Permission revoked while completion animates refuses before task, save and publication")
    @MainActor
    func revokePermissionDuringRowCompletion() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = TaskList(serverURL: "", name: "Shared", colorHex: "#FF0000")
        let task = TaskItem(title: "Keep status")
        let unrelated = TaskItem(title: "Peer")
        context.insert(list)
        context.insert(task)
        context.insert(unrelated)
        task.taskList = list
        task.isDirty = false
        task.percentComplete = 40
        let stamp = task.lastModifiedDate
        try context.save()
        let listID = list.id
        let taskID = task.id
        var saves = 0
        var effects = 0
        let errors = ErrorState()
        let coordinator = TaskCompletionCoordinator(animationDelay: 0.15,
            onWidgetReload: { effects += 1 }, onCompletionDonation: { _ in effects += 1 })
        coordinator.toggle(task, save: {
            saves += 1
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
        }, errorState: errors, requestReconcile: { effects += 1 }) { effects += 1 }
        #expect(coordinator.isAnimating)
        let peer = ModelContext(container)
        let current = try #require(peer.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first)
        current.isReadOnly = true
        try peer.save()
        for _ in 0..<150 {
            if !coordinator.isAnimating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!coordinator.isAnimating)
        #expect(errors.currentError != nil)
        #expect(saves == 0 && effects == 0)
        #expect(task.status == .needsAction && task.percentComplete == 40 && !task.isDirty)
        #expect(task.lastModifiedDate == stamp)
        unrelated.title = "Peer saved later"
        try context.save()
        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        #expect(saved.status == .needsAction && saved.percentComplete == 40 && !saved.isDirty)
        #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("Unsupported recurrence stops animation and all completion side effects", arguments: ["FREQ=MONTHLY;BYMONTHDAY=15", "FREQ=DAILY;COUNT=3"])
    @MainActor
    func unsupportedRuleShowsErrorWithoutCallbacks(_ raw: String) async throws {
        let container = try makeContainer()
        let task = TaskItem(title: "Imported rule")
        task.recurrenceRule = raw
        task.dueDate = Date()
        task.isDirty = false
        container.mainContext.insert(task)
        try container.mainContext.save()
        var reloads = 0
        var callbacks = 0
        let coordinator = TaskCompletionCoordinator(animationDelay: 0, onWidgetReload: { reloads += 1 }, onCompletionDonation: { _ in })
        coordinator.toggle(task) { callbacks += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.completionError != nil)
        #expect(!coordinator.isAnimating)
        #expect(reloads == 0)
        #expect(callbacks == 0)
        #expect(task.status == .needsAction)
        #expect(!task.isDirty)
        #expect(!container.mainContext.hasChanges)
    }

    @Test("Completing a task sets isAnimating before changing status")
    @MainActor
    func completeTriggersAnimationBeforeStatusChange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task")
        context.insert(task)
        try context.save()

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.8, onCompletionDonation: { _ in })
        var callbackCalled = false
        coordinator.toggle(task) { callbackCalled = true }

        // Animation should be active immediately
        #expect(coordinator.isAnimating == true)
        // Status should NOT have changed yet
        #expect(task.status == .needsAction)
        // Callback should NOT have fired yet
        #expect(callbackCalled == false)
    }

    @Test("Status changes to completed after the animation delay")
    @MainActor
    func statusChangesAfterDelay() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task")
        context.insert(task)
        try context.save()

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.1, onCompletionDonation: { _ in })
        var callbackCalled = false
        coordinator.toggle(task) { callbackCalled = true }

        // Wait for the delay to elapse
        try await Task.sleep(for: .milliseconds(200))

        #expect(task.status == .completed)
        #expect(task.completedDate != nil)
        #expect(task.percentComplete == 100)
        #expect(task.isDirty == true)
        #expect(callbackCalled == true)
        #expect(coordinator.isAnimating == false)
    }

    @Test("Un-completing a task is immediate with no animation delay")
    @MainActor
    func uncompleteIsImmediate() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task")
        task.status = .completed
        task.completedDate = Date()
        task.percentComplete = 100
        context.insert(task)
        try context.save()

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.8, onCompletionDonation: { _ in })
        var callbackCalled = false
        coordinator.toggle(task) { callbackCalled = true }

        // Un-complete should be immediate — no animation state
        #expect(coordinator.isAnimating == false)
        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(task.isDirty == true)
        #expect(callbackCalled == true)
    }

    @Test("Cancelling stops the delayed status change")
    @MainActor
    func cancelPreventsStatusChange() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task")
        context.insert(task)
        try context.save()

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.3, onCompletionDonation: { _ in })
        coordinator.toggle(task) { }

        // Cancel before the delay elapses
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(500))

        // Status should remain unchanged
        #expect(task.status == .needsAction)
    }

    @Test("Status is already changed when onStatusChanged fires")
    @MainActor
    func statusChangedBeforeCallback() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task")
        context.insert(task)
        try context.save()

        var statusAtCallbackTime: TaskStatus?
        let coordinator = TaskCompletionCoordinator(animationDelay: 0.05, onCompletionDonation: { _ in })
        coordinator.toggle(task) {
            statusAtCallbackTime = task.status
        }

        try await Task.sleep(for: .milliseconds(150))

        // The status should have been .completed when the callback fired
        #expect(statusAtCallbackTime == .completed)
    }

    @Test("Completion donates stable values after save even if save invalidates the model")
    @MainActor
    func donationUsesSnapshotAfterCommit() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let task = TaskItem(title: "Same title")
        task.id = "completion-stable-id"
        context.insert(list)
        context.insert(task)
        task.taskList = list
        try context.save()
        var events: [String] = []
        var donated: TaskEntity?
        let coordinator = TaskCompletionCoordinator(animationDelay: 0,
            onWidgetReload: { events.append("widget") },
            onCompletionDonation: {
                donated = $0
                events.append("donate")
            })
        coordinator.toggle(task, save: {
            try context.save()
            events.append("save")
            context.delete(task)
            try context.save()
        }) { events.append("publish") }
        try await Task.sleep(for: .milliseconds(100))
        let entity = try #require(donated)
        #expect(entity.id == "completion-stable-id")
        #expect(entity.title == "Same title")
        #expect(entity.listName == "Work")
        #expect(entity.isCompleted)
        #expect(events == ["save", "donate", "widget", "publish"])
    }


    @Test("A committed completion donates after its row coordinator is released")
    @MainActor
    func donationOutlivesRowCoordinator() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = TaskItem(title: "Leaving the row")
        task.id = "departed-row-task"
        context.insert(task)
        try context.save()
        var donatedID: String?
        var coordinator: TaskCompletionCoordinator? = TaskCompletionCoordinator(animationDelay: 0.02,
            onWidgetReload: {}, onCompletionDonation: { donatedID = $0.id })
        let releasedCoordinator = { [weak coordinator] in coordinator }
        coordinator?.toggle(task, save: { try context.save() }) {}
        coordinator = nil
        #expect(releasedCoordinator() == nil)
        try await Task.sleep(for: .milliseconds(900))
        #expect(task.status == .completed)
        #expect(donatedID == "departed-row-task")
    }

}
