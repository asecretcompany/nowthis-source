import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - DeleteTaskIntent Tests

@Suite("DeleteTaskIntent")
struct DeleteTaskIntentTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Soft-deletes a task and marks dirty")
    @MainActor
    func softDeletesTask() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let task = TaskItem(title: "Delete me")
        task.taskList = list
        context.insert(task)
        try context.save()

        let entity = TaskEntity(
            id: task.id,
            title: task.title,
            isCompleted: false,
            listName: "Work"
        )

        var intent = DeleteTaskIntent()
        intent.task = entity
        _ = try await intent.performWithContainer(container)

        // Re-fetch the task
        let taskID = task.id
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.id == taskID }
        )
        descriptor.fetchLimit = 1
        let fetched = try context.fetch(descriptor).first

        #expect(fetched?.isDeletedLocally == true)
        #expect(fetched?.isDirty == true)
    }

    @Test("Returns confirmation dialog with task title")
    @MainActor
    func returnsConfirmationDialog() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let task = TaskItem(title: "Important task")
        task.taskList = list
        context.insert(task)
        try context.save()

        let entity = TaskEntity(
            id: task.id,
            title: task.title,
            isCompleted: false,
            listName: "Work"
        )

        var intent = DeleteTaskIntent()
        intent.task = entity
        let result = try await intent.performWithContainer(container)

        #expect(result.dialog.contains("Important task"))
    }

    @Test("Throws error for non-existent task")
    @MainActor
    func throwsForMissingTask() async throws {
        let container = try makeContainer()

        let entity = TaskEntity(
            id: "nonexistent-id",
            title: "Ghost",
            isCompleted: false,
            listName: "Nowhere"
        )

        var intent = DeleteTaskIntent()
        intent.task = entity

        await #expect(throws: IntentError.self) {
            try await intent.performWithContainer(container)
        }
    }
}
