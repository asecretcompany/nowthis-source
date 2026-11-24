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

    @Test("Declining confirmation leaves subtree, persistence journal and reminders untouched")
    @MainActor
    func rejectedConfirmationHasNoEffects() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let parent = TaskItem(title: "Persisted title")
        let child = TaskItem(title: "Child")
        child.parentTask = parent; child.parentUID = parent.uid
        context.insert(parent); context.insert(child)
        try context.save()
        let store = CoordinatorNotificationStore(pending: [
            .init(identifier: "reminder-" + parent.id, fireDate: nil, badge: nil, title: nil),
            .init(identifier: "nag-" + child.id, fireDate: nil, badge: nil, title: nil)])
        let intent = DeleteTaskIntent(task: TaskEntity(id: parent.id, title: "Stale entity title",
            isCompleted: false, listName: ""))
        struct Declined: Error {}
        var saves = 0
        await #expect(throws: Declined.self) {
            _ = try await intent.performWithConfirmation(container, store: store, save: { saves += 1 }) { _ in
                throw Declined()
            }
        }
        #expect(!parent.isDeletedLocally && !child.isDeletedLocally)
        #expect(!context.hasChanges)
        #expect(saves == 0)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(store.pending.count == 2)
        #expect(store.readCount == 0 && store.authorizationChecks == 0)
        #expect(store.removedIdentifiers.isEmpty && store.addedIdentifiers.isEmpty)
    }

    @Test("Accepted confirmation uses the persisted title and deletes only afterward")
    @MainActor
    func acceptedConfirmationUsesPersistedTitle() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let parent = TaskItem(title: "Current persisted title")
        let child = TaskItem(title: "Child")
        child.parentTask = parent; child.parentUID = parent.uid
        context.insert(parent); context.insert(child)
        try context.save()
        let store = CoordinatorNotificationStore(pending: [
            .init(identifier: "reminder-" + parent.id, fireDate: nil, badge: nil, title: nil),
            .init(identifier: "nag-" + child.id, fireDate: nil, badge: nil, title: nil)])
        let intent = DeleteTaskIntent(task: TaskEntity(id: parent.id, title: "Old shortcut title",
            isCompleted: false, listName: ""))
        var prompts: [String] = []
        let result = try await intent.performWithConfirmation(container, store: store) { dialog async throws in
            prompts.append(String(localized: dialog))
            #expect(!parent.isDeletedLocally && !child.isDeletedLocally)
            #expect(!context.hasChanges)
            #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
            #expect(store.readCount == 0 && store.removedIdentifiers.isEmpty)
        }
        #expect(prompts == ["Delete “Current persisted title” and any subtasks?"])
        #expect(result.spokenText.contains("Current persisted title"))
        #expect(!result.spokenText.contains("Old shortcut title"))
        #expect(parent.isDeletedLocally && child.isDeletedLocally)
        #expect(parent.isDirty && child.isDirty)
        let saved = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(saved.count == 2 && saved.allSatisfy(\.isDeletedLocally))
        #expect(store.pending.isEmpty)
    }

    @Test("Missing or already deleted task fails before requesting confirmation", arguments: [false, true])
    @MainActor
    func unavailableTaskDoesNotPrompt(alreadyDeleted: Bool) async throws {
        let container = try makeContainer()
        let task = TaskItem(title: "Unavailable")
        task.isDeletedLocally = true
        if alreadyDeleted {
            container.mainContext.insert(task)
            try container.mainContext.save()
        }
        let intent = DeleteTaskIntent(task: TaskEntity(id: task.id, title: "Stale title",
            isCompleted: false, listName: ""))
        var prompted = false
        await #expect(throws: IntentError.taskNotFound) {
            _ = try await intent.performWithConfirmation(container) { _ in prompted = true }
        }
        #expect(!prompted)
    }

    @Test("Task removed or soft deleted during confirmation is not mutated", arguments: [false, true])
    @MainActor
    func revalidatesAfterConfirmation(softDelete: Bool) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = TaskItem(title: "Removed while confirming")
        context.insert(task); try context.save()
        let intent = DeleteTaskIntent(task: TaskEntity(id: task.id, title: "Stale title",
            isCompleted: false, listName: ""))
        let store = CoordinatorNotificationStore()
        var mutationSaves = 0
        var prompted = false
        await #expect(throws: IntentError.taskNotFound) {
            _ = try await intent.performWithConfirmation(container, store: store,
                save: { mutationSaves += 1 }) { _ in
                    prompted = true
                    // Simulate a sync save while the original context has the
                    // task registered from title resolution before suspension.
                    let syncContext = ModelContext(container)
                    let taskID = intent.task.id
                    let descriptor = FetchDescriptor<TaskItem>(
                        predicate: #Predicate<TaskItem> { $0.id == taskID })
                    let syncedTask = try #require(syncContext.fetch(descriptor).first)
                    if softDelete { syncedTask.isDeletedLocally = true } else { syncContext.delete(syncedTask) }
                    try syncContext.save()
                }
        }
        #expect(prompted)
        #expect(mutationSaves == 0)
        #expect(!context.hasChanges)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(store.readCount == 0 && store.removedIdentifiers.isEmpty)
    }

    @Test("Permission revoked in the system confirmation callback prevents delete")
    @MainActor
    func permissionRevokedDuringConfirmationRefusesDelete() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let list = TaskList(serverURL: "", name: "Shared", colorHex: "#FF0000")
        let task = TaskItem(title: "Keep this task")
        task.taskList = list
        seed.insert(list)
        seed.insert(task)
        try seed.save()

        let taskID = task.id
        let listID = list.id
        let intent = DeleteTaskIntent(task: TaskEntity(id: taskID, title: task.title,
            isCompleted: false, listName: list.name))
        let store = CoordinatorNotificationStore()
        var mutationSaves = 0
        var prompted = false
        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithConfirmation(
                context: { ModelContext(container) }, store: store,
                save: { mutationSaves += 1 }) { _ in
                    prompted = true
                    let permissionContext = ModelContext(container)
                    let descriptor = FetchDescriptor<TaskList>(
                        predicate: #Predicate { $0.id == listID })
                    let currentList = try #require(permissionContext.fetch(descriptor).first)
                    currentList.isReadOnly = true
                    try permissionContext.save()
                }
        }

        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        #expect(prompted)
        #expect(!saved.isDeletedLocally && !saved.isDirty)
        #expect(mutationSaves == 0)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(store.pending.isEmpty && store.removedIdentifiers.isEmpty)
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

    @Test("A read-only grandchild behind a soft-deleted intermediate blocks the whole subtree")
    @MainActor
    func readOnlyCrossListDescendantRefusesBeforeAnyTombstone() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let writable = TaskList(serverURL: "", name: "Writable", colorHex: "#007AFF")
        let readOnly = TaskList(serverURL: "", name: "Shared read only", colorHex: "#FF0000")
        readOnly.isReadOnly = true
        let root = TaskItem(title: "Root")
        let intermediate = TaskItem(title: "Existing tombstone")
        let grandchild = TaskItem(title: "Protected child")
        root.taskList = writable
        intermediate.taskList = writable
        grandchild.taskList = readOnly
        intermediate.isDeletedLocally = true
        intermediate.isDirty = true
        grandchild.parentTask = intermediate
        root.subtasks.append(intermediate)
        context.insert(writable); context.insert(readOnly)
        context.insert(root); context.insert(intermediate); context.insert(grandchild)
        try context.save()
        let ids = [root.id, intermediate.id, grandchild.id]
        let intent = DeleteTaskIntent(task: TaskEntity(id: root.id, title: root.title,
            isCompleted: false, listName: writable.name))
        let store = CoordinatorNotificationStore()
        var saves = 0

        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithContainer(container, store: store, save: { saves += 1 })
        }

        let reader = ModelContext(container)
        let saved = try reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
        let byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        #expect(saved.count == 3)
        #expect(byID[root.id]?.isDeletedLocally == false)
        #expect(byID[intermediate.id]?.isDeletedLocally == true)
        #expect(byID[intermediate.id]?.isDirty == true)
        #expect(byID[grandchild.id]?.isDeletedLocally == false)
        #expect(saves == 0)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(store.pending.isEmpty && store.removedIdentifiers.isEmpty)
    }

    @Test("A descendant added during confirmation invalidates the confirmed scope")
    @MainActor
    func lateDescendantDuringConfirmationRefusesWholeDelete() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        let list = TaskList(serverURL: "", name: "Work", colorHex: "#007AFF")
        let root = TaskItem(title: "Root")
        let child = TaskItem(title: "Child")
        root.taskList = list; child.taskList = list
        child.parentTask = root
        seed.insert(list); seed.insert(root); seed.insert(child)
        try seed.save()
        let ids = [root.id, child.id]
        let intent = DeleteTaskIntent(task: TaskEntity(id: root.id, title: root.title,
            isCompleted: false, listName: list.name))
        let store = CoordinatorNotificationStore()
        var saves = 0

        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithConfirmation(
                context: { ModelContext(container) }, store: store, save: { saves += 1 }) { _ in
                    let concurrent = ModelContext(container)
                    let currentChild = try #require(concurrent.fetch(
                        FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == ids[1] })).first)
                    let late = TaskItem(title: "Added after confirmation started")
                    late.taskList = currentChild.taskList
                    late.parentTask = currentChild
                    concurrent.insert(late)
                    try concurrent.save()
                }
        }

        let reader = ModelContext(container)
        let saved = try reader.fetch(FetchDescriptor<TaskItem>())
        #expect(saved.count == 3)
        #expect(saved.allSatisfy { !$0.isDeletedLocally })
        #expect(saves == 0)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(store.pending.isEmpty && store.removedIdentifiers.isEmpty)
    }

    @Test("A child reparented during confirmation invalidates the confirmed scope")
    @MainActor
    func reparentedChildDuringConfirmationRefusesWholeDelete() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.autosaveEnabled = false
        let list = TaskList(serverURL: "", name: "Work", colorHex: "#007AFF")
        let root = TaskItem(title: "Root")
        let child = TaskItem(title: "Child")
        let otherParent = TaskItem(title: "Other parent")
        root.taskList = list; child.taskList = list; otherParent.taskList = list
        child.parentTask = root
        seed.insert(list); seed.insert(root); seed.insert(child); seed.insert(otherParent)
        try seed.save()
        let ids = [root.id, child.id, otherParent.id]
        let intent = DeleteTaskIntent(task: TaskEntity(id: root.id, title: root.title,
            isCompleted: false, listName: list.name))
        let store = CoordinatorNotificationStore()
        var saves = 0

        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithConfirmation(
                context: { ModelContext(container) }, store: store, save: { saves += 1 }) { _ in
                    let concurrent = ModelContext(container)
                    let parent = try #require(concurrent.fetch(
                        FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == ids[2] })).first)
                    let movedChild = try #require(concurrent.fetch(
                        FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == ids[1] })).first)
                    movedChild.parentTask = parent
                    try concurrent.save()
                }
        }

        let reader = ModelContext(container)
        let rows = try reader.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { !$0.isDeletedLocally })
        #expect(saves == 0)
        #expect(try ReminderSchedulingJournal.capture(in: ModelContext(container)).isEmpty)
        #expect(store.pending.isEmpty && store.removedIdentifiers.isEmpty)
    }

}
