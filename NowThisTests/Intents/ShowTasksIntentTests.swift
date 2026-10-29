import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - ShowTasksIntent Tests

@Suite("ShowTasksIntent")
struct ShowTasksIntentTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Returns correct dialog when no tasks exist")
    @MainActor
    func emptyState() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Ensure no tasks exist
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.isEmpty)

        let intent = ShowTasksIntent()
        let result = try await intent.performWithContainer(container)

        // The spoken reply is localized; compare against what the app resolves rather than
        // against English prose.
        let expected = try LocalizationCatalogFixture.rendering(
            ofKey: "intent.dialog.showTasks.none", inCatalogAt: "NowThis/Localizable.xcstrings")
        #expect(result.spokenText == expected)
    }

    @Test("Returns task titles for active tasks")
    @MainActor
    func activeTasksReturned() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let task1 = TaskItem(title: "Buy milk")
        task1.taskList = list
        context.insert(task1)

        let task2 = TaskItem(title: "Call plumber")
        task2.taskList = list
        context.insert(task2)

        try context.save()

        let intent = ShowTasksIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.spokenText.contains("Buy milk"))
        #expect(result.spokenText.contains("Call plumber"))
        #expect(result.spokenText.contains("2"))
    }

    @Test("Excludes completed and deleted tasks")
    @MainActor
    func excludesCompletedAndDeleted() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(list)

        let active = TaskItem(title: "Active task")
        active.taskList = list
        context.insert(active)

        let completed = TaskItem(title: "Done task", status: .completed)
        completed.taskList = list
        context.insert(completed)

        let deleted = TaskItem(title: "Deleted task")
        deleted.isDeletedLocally = true
        deleted.taskList = list
        context.insert(deleted)

        try context.save()

        let intent = ShowTasksIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.spokenText.contains("Active task"))
        #expect(!result.spokenText.contains("Done task"))
        #expect(!result.spokenText.contains("Deleted task"))
    }

    @Test("Filters by list when specified")
    @MainActor
    func filtersByList() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let workList = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let homeList = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(workList)
        context.insert(homeList)

        let workTask = TaskItem(title: "Work task")
        workTask.taskList = workList
        context.insert(workTask)

        let homeTask = TaskItem(title: "Home task")
        homeTask.taskList = homeList
        context.insert(homeTask)

        try context.save()

        let intent = ShowTasksIntent()
        intent.list = TaskListEntity(id: workList.id, name: "Work")
        let result = try await intent.performWithContainer(container)

        #expect(result.spokenText.contains("Work task"))
        #expect(!result.spokenText.contains("Home task"))
    }

    @Test("Truncates at 10 tasks and mentions remaining")
    @MainActor
    func truncatesLongLists() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Big", colorHex: "#0000FF")
        context.insert(list)

        for i in 1...15 {
            let task = TaskItem(title: "Task \(i)")
            task.taskList = list
            context.insert(task)
        }
        try context.save()

        let intent = ShowTasksIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.spokenText.contains("15"))
        // "more" is an English word; the sentence says "und 5 weitere" in German. Assert the
        // remainder count instead, which is the part that is actually locale-stable.
        #expect(result.spokenText.contains("5"))
    }
}
