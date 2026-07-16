import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - QuickAddTaskIntent Tests

/// Verifies the natural-language Siri quick-add intent: a single spoken/typed
/// phrase is parsed into a task (title + due date/time) via `NaturalLanguageParser`.
@Suite("QuickAddTaskIntent")
struct QuickAddTaskIntentTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Parses title and clock time into a timed, non-all-day task")
    @MainActor
    func createsTimedTask() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        context.insert(inbox)
        try context.save()
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")

        var intent = QuickAddTaskIntent()
        intent.text = "Buy milk tomorrow at 5pm"
        let result = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task.title == "Buy milk")
        #expect(task.isDueDateOnly == false)
        let due = try #require(task.dueDate)
        #expect(Calendar.current.component(.hour, from: due) == 17)
        #expect(task.taskList?.id == inbox.id)
        #expect(task.isDirty == true)
        #expect(result.dialog.contains("Buy milk"))
    }

    @Test("Bare keyword date creates an all-day (date-only) task")
    @MainActor
    func createsAllDayTask() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        context.insert(inbox)
        try context.save()
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")

        var intent = QuickAddTaskIntent()
        intent.text = "Submit report tomorrow"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.title == "Submit report")
        #expect(task.dueDate != nil)
        #expect(task.isDueDateOnly == true)
    }

    @Test("Uses the configured default Siri list")
    @MainActor
    func usesConfiguredDefaultList() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let grocery = TaskList(serverURL: "", name: "Grocery", colorHex: "#00FF00")
        let work = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(grocery)
        context.insert(work)
        try context.save()
        UserDefaults.standard.set(work.id, forKey: "defaultSiriListID")

        var intent = QuickAddTaskIntent()
        intent.text = "Order coffee"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.taskList?.id == work.id)

        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")
    }

    @Test("Falls back to first alphabetical list when no default configured")
    @MainActor
    func fallsBackToFirstList() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let alpha = TaskList(serverURL: "", name: "Alpha", colorHex: "#FF0000")
        let beta = TaskList(serverURL: "", name: "Beta", colorHex: "#00FF00")
        context.insert(alpha)
        context.insert(beta)
        try context.save()
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")

        var intent = QuickAddTaskIntent()
        intent.text = "Water plants"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.taskList?.id == alpha.id)
    }

    @Test("Throws when there are no lists to add to")
    @MainActor
    func throwsWithoutLists() async throws {
        let container = try makeContainer()
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")

        var intent = QuickAddTaskIntent()
        intent.text = "Homeless task"
        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithContainer(container)
        }
    }

    @Test("Applies typed priority and tag sigils from the text")
    @MainActor
    func appliesTypedSigils() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let inbox = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        context.insert(inbox)
        try context.save()
        UserDefaults.standard.removeObject(forKey: "defaultSiriListID")

        var intent = QuickAddTaskIntent()
        intent.text = "Pay rent !high @finance tomorrow"
        _ = try await intent.performWithContainer(container)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let task = try #require(tasks.first)
        #expect(task.title == "Pay rent")
        #expect(task.priority == .high)
        #expect(task.tags.contains { $0.name == "finance" })
    }
}
