import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - SearchTasksIntent Tests

@Suite("SearchTasksIntent")
struct SearchTasksIntentTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Finds matching tasks by title")
    @MainActor
    func findsMatchingTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let task1 = TaskItem(title: "Buy groceries")
        task1.taskList = list
        context.insert(task1)

        let task2 = TaskItem(title: "Buy coffee")
        task2.taskList = list
        context.insert(task2)

        let task3 = TaskItem(title: "Call dentist")
        task3.taskList = list
        context.insert(task3)

        try context.save()

        var intent = SearchTasksIntent()
        intent.query = "Buy"
        let result = try await intent.performWithContainer(container)

        #expect(result.dialog.contains("Buy groceries"))
        #expect(result.dialog.contains("Buy coffee"))
        #expect(!result.dialog.contains("Call dentist"))
    }

    @Test("Returns empty result message for no matches")
    @MainActor
    func noMatchesFound() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let task = TaskItem(title: "Buy groceries")
        task.taskList = list
        context.insert(task)
        try context.save()

        var intent = SearchTasksIntent()
        intent.query = "nonexistent"
        let result = try await intent.performWithContainer(container)

        #expect(result.dialog.contains("No tasks found") || result.dialog.contains("no tasks found"))
    }

    @Test("Case-insensitive search")
    @MainActor
    func caseInsensitive() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let task = TaskItem(title: "Buy Groceries")
        task.taskList = list
        context.insert(task)
        try context.save()

        var intent = SearchTasksIntent()
        intent.query = "buy"
        let result = try await intent.performWithContainer(container)

        #expect(result.dialog.contains("Buy Groceries"))
    }
}
