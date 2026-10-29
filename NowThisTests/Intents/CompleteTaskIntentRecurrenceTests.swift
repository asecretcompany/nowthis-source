import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - CompleteTaskIntent Recurrence Tests

/// `CompleteTaskIntent` is the completion path for Siri, Shortcuts, and the
/// interactive widget. It hand-rolled its own status mutation and never
/// consulted `recurrenceRule`, so a repeating task completed from any of those
/// three surfaces was marked done instead of advancing to its next occurrence —
/// the opposite of what the in-app checkbox does with the same task.
@Suite("CompleteTaskIntent recurrence")
struct CompleteTaskIntentRecurrenceTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    private func entity(for task: TaskItem) -> TaskEntity {
        TaskEntity(
            id: task.id,
            title: task.title,
            isCompleted: task.status == .completed,
            listName: "Work"
        )
    }

    @Test("Completing a recurring task advances it instead of completing it")
    @MainActor
    func recurringTaskAdvancesRatherThanCompleting() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(title: "Water the plants")
        task.dueDate = due
        task.recurrenceRule = "FREQ=DAILY"
        context.insert(task)
        try context.save()

        let intent = CompleteTaskIntent()
        intent.task = entity(for: task)
        let isNowCompleted = try await intent.performWithContainer(container)

        let expectedDue = Calendar.current.date(byAdding: .day, value: 1, to: due)

        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(task.dueDate == expectedDue)
        #expect(isNowCompleted == false)
        #expect(task.isDirty == true)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Completing a non-recurring task still completes it")
    @MainActor
    func nonRecurringTaskStillCompletes() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let task = TaskItem(title: "File the taxes")
        task.dueDate = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(task)
        try context.save()

        let intent = CompleteTaskIntent()
        intent.task = entity(for: task)
        let isNowCompleted = try await intent.performWithContainer(container)

        #expect(task.status == .completed)
        #expect(task.completedDate != nil)
        #expect(task.percentComplete == 100)
        #expect(isNowCompleted == true)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }

    @Test("Uncompleting a task through the intent is unchanged")
    @MainActor
    func uncompletingIsUnchanged() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let task = TaskItem(title: "Already done")
        task.status = .completed
        task.completedDate = Date(timeIntervalSince1970: 1_700_000_000)
        task.percentComplete = 100
        context.insert(task)
        try context.save()

        let intent = CompleteTaskIntent()
        intent.task = entity(for: task)
        let isNowCompleted = try await intent.performWithContainer(container)

        #expect(task.status == .needsAction)
        #expect(task.completedDate == nil)
        #expect(task.percentComplete == 0)
        #expect(isNowCompleted == false)
        #expect(try !ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
    }
}
