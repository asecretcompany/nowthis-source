import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Sync Push Detection Tests

@Suite("Sync Push Detection — Predicate-Based Dirty/Deleted Lookup")
struct SyncPushDetectionTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    @Test("findDirtyTasks returns dirty tasks via predicate fetch")
    func dirtyTaskFoundViaPredicate() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)

        let dirtyTask = TaskItem(uid: "dirty-uid", title: "Edit me")
        dirtyTask.isDirty = true
        dirtyTask.taskList = list
        context.insert(dirtyTask)

        let cleanTask = TaskItem(uid: "clean-uid", title: "Clean task")
        cleanTask.isDirty = false
        cleanTask.taskList = list
        context.insert(cleanTask)

        try context.save()

        // Use a fresh context to simulate a background context where
        // the relationship might be stale/unfaulted.
        let bgContext = ModelContext(container)

        // Re-fetch the list in the background context
        let listID = list.id
        let fetchedList = try bgContext.fetch(
            FetchDescriptor<TaskList>(
                predicate: #Predicate { $0.id == listID }
            )
        ).first!

        let engine = SyncEngine()
        let dirtyUIDs = await engine.testFindDirtyTasks(for: fetchedList, modelContext: bgContext)

        #expect(dirtyUIDs.count == 1, "Should find exactly 1 dirty task")
        #expect(dirtyUIDs.first == "dirty-uid")
    }

    @Test("findDeletedTasks returns soft-deleted tasks via predicate fetch")
    func deletedTaskFoundViaPredicate() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)

        let deletedTask = TaskItem(uid: "deleted-uid", title: "Delete me")
        deletedTask.isDeletedLocally = true
        deletedTask.taskList = list
        context.insert(deletedTask)

        let activeTask = TaskItem(uid: "active-uid", title: "Active task")
        activeTask.isDeletedLocally = false
        activeTask.taskList = list
        context.insert(activeTask)

        try context.save()

        let bgContext = ModelContext(container)
        let listID = list.id
        let fetchedList = try bgContext.fetch(
            FetchDescriptor<TaskList>(
                predicate: #Predicate { $0.id == listID }
            )
        ).first!

        let engine = SyncEngine()
        let deletedUIDs = await engine.testFindDeletedTasks(for: fetchedList, modelContext: bgContext)

        #expect(deletedUIDs.count == 1, "Should find exactly 1 deleted task")
        #expect(deletedUIDs.first == "deleted-uid")
    }

    @Test("findDirtyTasks excludes soft-deleted dirty tasks")
    func dirtyButDeletedExcluded() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)

        // Task is both dirty and deleted — should NOT appear in findDirtyTasks
        let task = TaskItem(uid: "both-uid", title: "Both dirty and deleted")
        task.isDirty = true
        task.isDeletedLocally = true
        task.taskList = list
        context.insert(task)
        try context.save()

        let bgContext = ModelContext(container)
        let listID = list.id
        let fetchedList = try bgContext.fetch(
            FetchDescriptor<TaskList>(
                predicate: #Predicate { $0.id == listID }
            )
        ).first!

        let engine = SyncEngine()
        let dirtyUIDs = await engine.testFindDirtyTasks(for: fetchedList, modelContext: bgContext)

        #expect(dirtyUIDs.isEmpty, "Deleted+dirty tasks should not appear in findDirtyTasks")
    }
}
