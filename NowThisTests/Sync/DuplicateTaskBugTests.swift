import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Duplicate Task Cleanup Tests

@Suite("Duplicate Task Cleanup")
struct DuplicateTaskCleanupTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    @Test("cleanupDuplicateUIDs removes duplicate tasks keeping newest")
    func removeDuplicatesKeepsNewest() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)

        // Create 3 tasks with same UID, different modification dates
        let oldDate = Date(timeIntervalSince1970: 1000)
        let midDate = Date(timeIntervalSince1970: 2000)
        let newDate = Date(timeIntervalSince1970: 3000)

        let task1 = TaskItem(id: "id-1", uid: "shared-uid", title: "Practice guitar")
        task1.lastModifiedDate = oldDate
        task1.taskList = list

        let task2 = TaskItem(id: "id-2", uid: "shared-uid", title: "Practice guitar")
        task2.lastModifiedDate = newDate
        task2.taskList = list

        let task3 = TaskItem(id: "id-3", uid: "shared-uid", title: "Practice guitar")
        task3.lastModifiedDate = midDate
        task3.taskList = list

        context.insert(task1)
        context.insert(task2)
        context.insert(task3)

        // Also insert a unique task to verify it's preserved
        let uniqueTask = TaskItem(id: "id-4", uid: "unique-uid", title: "Laundry")
        uniqueTask.taskList = list
        context.insert(uniqueTask)
        try context.save()

        let removed = TaskListHelpers.cleanupDuplicateUIDs(in: context)
        try context.save()

        #expect(removed == 2, "Should remove 2 duplicates")

        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(remaining.count == 2, "Should have 2 tasks: 1 surviving duplicate + 1 unique")

        let survivingDupe = remaining.first(where: { $0.uid == "shared-uid" })
        #expect(survivingDupe != nil)
        #expect(survivingDupe?.id == "id-2", "Should keep the newest (id-2)")
        #expect(survivingDupe?.lastModifiedDate == newDate)

        let unique = remaining.first(where: { $0.uid == "unique-uid" })
        #expect(unique != nil)
        #expect(unique?.id == "id-4")
    }

    @Test("cleanupDuplicateUIDs preserves all unique tasks")
    func preservesUniqueTasks() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task1 = TaskItem(id: "id-1", uid: "uid-A", title: "Task A")
        let task2 = TaskItem(id: "id-2", uid: "uid-B", title: "Task B")
        let task3 = TaskItem(id: "id-3", uid: "uid-C", title: "Task C")

        context.insert(task1)
        context.insert(task2)
        context.insert(task3)
        try context.save()

        let removed = TaskListHelpers.cleanupDuplicateUIDs(in: context)
        try context.save()

        #expect(removed == 0, "Should remove nothing when all UIDs are unique")

        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(remaining.count == 3, "All unique tasks should be preserved")
    }

    @Test("cleanupDuplicateUIDs handles empty store")
    func handlesEmptyStore() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let removed = TaskListHelpers.cleanupDuplicateUIDs(in: context)

        #expect(removed == 0)

        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(remaining.isEmpty)
    }

    @Test("cleanupDuplicateUIDs skips soft-deleted tasks")
    func skipsSoftDeleted() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let task1 = TaskItem(id: "id-1", uid: "shared-uid", title: "Guitar")
        task1.lastModifiedDate = Date(timeIntervalSince1970: 1000)

        let task2 = TaskItem(id: "id-2", uid: "shared-uid", title: "Guitar")
        task2.lastModifiedDate = Date(timeIntervalSince1970: 2000)
        task2.isDeletedLocally = true // soft-deleted

        context.insert(task1)
        context.insert(task2)
        try context.save()

        let removed = TaskListHelpers.cleanupDuplicateUIDs(in: context)
        try context.save()

        // task2 is soft-deleted so should be excluded from dedup consideration.
        // Only task1 remains as the live version — no duplicates among live tasks.
        #expect(removed == 0, "Soft-deleted tasks should not participate in dedup")

        let live = try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDeletedLocally }
        ))
        #expect(live.count == 1)
    }
}
