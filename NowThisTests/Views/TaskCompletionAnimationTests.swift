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

    @Test("Completing a task sets isAnimating before changing status")
    @MainActor
    func completeTriggersAnimationBeforeStatusChange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(title: "Test task")
        context.insert(task)

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.8)
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

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.1)
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

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.8)
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

        let coordinator = TaskCompletionCoordinator(animationDelay: 0.3)
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

        var statusAtCallbackTime: TaskStatus?
        let coordinator = TaskCompletionCoordinator(animationDelay: 0.05)
        coordinator.toggle(task) {
            statusAtCallbackTime = task.status
        }

        try await Task.sleep(for: .milliseconds(150))

        // The status should have been .completed when the callback fired
        #expect(statusAtCallbackTime == .completed)
    }
}
