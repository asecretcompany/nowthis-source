import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TaskCountIntent Tests

@Suite("TaskCountIntent")
struct TaskCountIntentTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Returns 0 when no tasks exist")
    @MainActor
    func emptyState() async throws {
        let container = try makeContainer()

        let intent = TaskCountIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.value == 0)
    }

    @Test("Counts active tasks correctly")
    @MainActor
    func countsActiveTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        for i in 1...5 {
            let task = TaskItem(title: "Task \(i)")
            task.taskList = list
            context.insert(task)
        }

        // Add one completed — should not be counted
        let completed = TaskItem(title: "Done", status: .completed)
        completed.taskList = list
        context.insert(completed)

        try context.save()

        let intent = TaskCountIntent()
        let result = try await intent.performWithContainer(container)

        #expect(result.value == 5)
        #expect(result.dialog.contains("5"))
    }

    @Test("Counts tasks filtered by list")
    @MainActor
    func countsByList() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let workList = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let homeList = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(workList)
        context.insert(homeList)

        for i in 1...3 {
            let task = TaskItem(title: "Work \(i)")
            task.taskList = workList
            context.insert(task)
        }
        let homeTask = TaskItem(title: "Home 1")
        homeTask.taskList = homeList
        context.insert(homeTask)

        try context.save()

        var intent = TaskCountIntent()
        intent.list = TaskListEntity(id: workList.id, name: "Work")
        let result = try await intent.performWithContainer(container)

        #expect(result.value == 3)
        #expect(result.dialog.contains("Work"))
    }
}
