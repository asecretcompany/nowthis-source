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

    @Test("Deleting a task subtree cancels registered reminders after a durable save")
    @MainActor
    func deletionPersistsRecoveryBeforeRemovingSubtreeRequests() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let parent = TaskItem(title: "Parent")
        let child = TaskItem(title: "Child")
        child.parentTask = parent; child.parentUID = parent.uid
        context.insert(parent); context.insert(child)
        try context.save()
        let ids = ["reminder-" + parent.id, "nag-" + child.id]
        let store = CoordinatorNotificationStore(pending: ids.map {
            .init(identifier: $0, fireDate: nil, badge: nil, title: nil)
        })
        var observedDurableTicket = false
        store.onRead = { _ in
            observedDurableTicket = observedDurableTicket
                || ((try? ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty) == false)
        }
        let intent = DeleteTaskIntent(task: TaskEntity(id: parent.id, title: parent.title,
            isCompleted: false, listName: ""))
        _ = try await intent.performWithContainer(container, store: store)
        #expect(parent.isDeletedLocally && child.isDeletedLocally)
        #expect(observedDurableTicket)
        #expect(store.pending.isEmpty)
    }

    @Test("Failed delete persistence preserves registered requests and saved task state")
    @MainActor
    func failedDeletionDoesNotRemoveReminder() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = TaskItem(title: "Keep reminder")
        context.insert(task); try context.save()
        let id = "reminder-" + task.id
        let store = CoordinatorNotificationStore(pending: [
            .init(identifier: id, fireDate: nil, badge: nil, title: nil)])
        let intent = DeleteTaskIntent(task: TaskEntity(id: task.id, title: task.title,
            isCompleted: false, listName: ""))
        struct SaveFailure: Error {}
        await #expect(throws: SaveFailure.self) {
            _ = try await intent.performWithContainer(container, store: store, save: { throw SaveFailure() })
        }
        #expect(store.pending[id] != nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.isDeletedLocally == false)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        context.rollback()
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

        let intent = DeleteTaskIntent()
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

        let intent = DeleteTaskIntent()
        intent.task = entity
        let result = try await intent.performWithContainer(container)

        #expect(result.spokenText.contains("Important task"))
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

        let intent = DeleteTaskIntent()
        intent.task = entity

        await #expect(throws: IntentError.self) {
            try await intent.performWithContainer(container)
        }
    }
}
