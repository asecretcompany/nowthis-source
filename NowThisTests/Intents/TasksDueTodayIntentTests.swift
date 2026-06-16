import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TasksDueTodayIntent Tests

@Suite("TasksDueTodayIntent")
struct TasksDueTodayIntentTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Returns empty dialog when no tasks due today")
    @MainActor
    func emptyState() async throws {
        let container = try makeContainer()

        let intent = TasksDueTodayIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.dialog.contains("Nothing due today") || result.dialog.contains("nothing due today") || result.dialog.contains("no tasks due"))
    }

    @Test("Returns tasks due today")
    @MainActor
    func tasksDueToday() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let todayTask = TaskItem(title: "Today's task")
        todayTask.dueDate = Date() // Due right now (today)
        todayTask.taskList = list
        context.insert(todayTask)

        let tomorrowTask = TaskItem(title: "Tomorrow's task")
        tomorrowTask.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        tomorrowTask.taskList = list
        context.insert(tomorrowTask)

        try context.save()

        let intent = TasksDueTodayIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.dialog.contains("Today's task"))
        #expect(!result.dialog.contains("Tomorrow's task"))
    }

    @Test("Excludes completed tasks from today's list")
    @MainActor
    func excludesCompleted() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let activeToday = TaskItem(title: "Active today")
        activeToday.dueDate = Date()
        activeToday.taskList = list
        context.insert(activeToday)

        let completedToday = TaskItem(title: "Done today", status: .completed)
        completedToday.dueDate = Date()
        completedToday.taskList = list
        context.insert(completedToday)

        try context.save()

        let intent = TasksDueTodayIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.dialog.contains("Active today"))
        #expect(!result.dialog.contains("Done today"))
    }
}
