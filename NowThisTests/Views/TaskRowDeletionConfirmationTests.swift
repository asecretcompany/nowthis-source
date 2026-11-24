import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Task Row Deletion Confirmation")
@MainActor
struct TaskRowDeletionConfirmationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: TaskItem.self, TaskList.self, JournalEntry.self,
                           NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                           SavedFilter.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func insert(_ title: String, parent: TaskItem? = nil, in context: ModelContext) -> TaskItem {
        let task = TaskItem(title: title, priority: .none)
        context.insert(task)
        task.parentTask = parent
        task.isDirty = false
        return task
    }

    @Test("A parent waits for confirmation naming children and grandchildren")
    func parentWaitsForConfirmation() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Parent", in: context)
        let child = insert("Child", parent: root, in: context)
        let grandchild = insert("Grandchild", parent: child, in: context)
        try context.save()
        let originalModified = root.lastModifiedDate
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        coordinator.request(root, in: context) { task, scope in
            effects += 1
            _ = TaskDeletionPersistence.perform(task, in: context, confirmed: scope)
        }
        #expect(coordinator.subtaskCount == 2)
        #expect(!root.isDeletedLocally)
        #expect(!child.isDeletedLocally)
        #expect(!grandchild.isDeletedLocally)
        #expect(!root.isDirty)
        #expect(root.lastModifiedDate == originalModified)
        #expect(!context.hasChanges)
        #expect(effects == 0, "save/journal/reminder callback must wait for confirmation")
    }

    @Test("Cancel leaves models and the persistence/reminder callback untouched")
    func cancellationHasNoEffects() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Parent", in: context)
        let child = insert("Child", parent: root, in: context)
        try context.save()
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        coordinator.request(root, in: context) { task, scope in
            _ = TaskDeletionPersistence.perform(task, in: context, confirmed: scope)
            effects += 1
        }
        coordinator.cancel()
        _ = coordinator.confirm(in: context) { _, _ in effects += 1 }
        #expect(coordinator.subtaskCount == nil)
        #expect(!root.isDeletedLocally && !child.isDeletedLocally)
        #expect(!context.hasChanges)
        #expect(try ReminderSchedulingJournal.capture(in: context).isEmpty)
        #expect(effects == 0)
    }

    @Test("Confirmed parent deletes the entire subtree exactly once")
    func confirmedDeletionRunsOnce() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Parent", in: context)
        let child = insert("Child", parent: root, in: context)
        let grandchild = insert("Grandchild", parent: child, in: context)
        let outside = insert("Other task", in: context)
        try context.save()
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        var deletedIDs: [String] = []
        let errors = ErrorState()
        let delete: (TaskItem, TaskWriteEligibility.DeletionScope) -> Void = { task, scope in
            effects += 1
            deletedIDs = TaskDeletionPersistence.perform(task, in: context, errorState: errors, confirmed: scope,
                save: { try context.save() }) ?? []
        }
        coordinator.request(root, in: context, delete: delete)
        coordinator.confirm(in: context, delete: delete)
        coordinator.confirm(in: context, delete: delete)
        coordinator.request(root, in: context, delete: delete)
        #expect(effects == 1)
        #expect(errors.currentError == nil)
        #expect(try ReminderSchedulingJournal.capture(in: context).count == 1)
        #expect(!context.hasChanges)
        #expect(Set(deletedIDs) == Set([root.id, child.id, grandchild.id]))
        #expect(deletedIDs.count == 3)
        #expect(root.isDeletedLocally && child.isDeletedLocally && grandchild.isDeletedLocally)
        #expect(!outside.isDeletedLocally)
        #expect(coordinator.subtaskCount == nil)
    }

    @Test("A leaf deletes immediately without deleting its parent")
    func leafDeletesImmediately() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Parent", in: context)
        let leaf = insert("Leaf", parent: root, in: context)
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        try context.save()
        coordinator.request(leaf, in: context) { task, scope in
            _ = TaskDeletionPersistence.perform(task, in: context, confirmed: scope)
            effects += 1
        }
        #expect(leaf.isDeletedLocally)
        #expect(!root.isDeletedLocally)
        #expect(effects == 1)
        #expect(coordinator.subtaskCount == nil)
    }

    @Test("Cycles count each descendant once and confirmed deletion terminates")
    func cycleIsBounded() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Root", in: context)
        let child = insert("Child", parent: root, in: context)
        root.parentTask = child
        try context.save()
        var coordinator = TaskDeletionCoordinator()
        var deletedIDs: [String] = []
        coordinator.request(root, in: context) { task, scope in
            deletedIDs = TaskDeletionPersistence.perform(task, in: context, confirmed: scope) ?? []
        }
        #expect(coordinator.subtaskCount == 1)
        #expect(deletedIDs.isEmpty)
        _ = coordinator.confirm(in: context) { task, scope in
            deletedIDs = TaskDeletionPersistence.perform(task, in: context, confirmed: scope) ?? []
        }
        #expect(Set(deletedIDs) == Set([root.id, child.id]))
        #expect(deletedIDs.count == 2)
    }

    @Test("Soft-deleted parents cannot present or accept confirmation")
    func softDeletedModelsAreIgnored() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Root", in: context)
        _ = insert("Child", parent: root, in: context)
        try context.save()
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        coordinator.request(root, in: context, errorState: ErrorState()) { _, _ in effects += 1 }
        root.isDeletedLocally = true
        #expect(coordinator.confirm(in: context, errorState: ErrorState()) { _, _ in effects += 1 } == .invalidTask)
        coordinator.request(root, in: context, errorState: ErrorState()) { _, _ in effects += 1 }
        #expect(effects == 0)
        #expect(coordinator.subtaskCount == nil)
    }

    @Test("Hard-deleted models cannot present or accept confirmation")
    func invalidatedModelsAreIgnored() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Root", in: context)
        _ = insert("Child", parent: root, in: context)
        try context.save()
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        coordinator.request(root, in: context, errorState: ErrorState()) { _, _ in effects += 1 }
        context.delete(root)
        try context.save()
        #expect(root.modelContext == nil)
        _ = coordinator.confirm(in: context) { _, _ in effects += 1 }
        coordinator.request(root, in: context, errorState: ErrorState()) { _, _ in effects += 1 }
        #expect(effects == 0)
        #expect(coordinator.subtaskCount == nil)
    }
    @Test("A live grandchild below a deleted branch still requires confirmation")
    func deletedBranchPreservesFullDeletion() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Root", in: context)
        let deletedChild = insert("Deleted child", parent: root, in: context)
        let grandchild = insert("Live grandchild", parent: deletedChild, in: context)
        deletedChild.isDeletedLocally = true
        try context.save()
        #expect(TaskRowData(task: root)?.subtasksTotal == 0, "visible progress prunes deleted branches")
        var coordinator = TaskDeletionCoordinator()
        var deletedIDs: [String] = []
        coordinator.request(root, in: context) { task, scope in
            deletedIDs = TaskDeletionPersistence.perform(task, in: context, confirmed: scope) ?? []
        }
        #expect(coordinator.subtaskCount == 1, "the destructive operation still reaches the live grandchild")
        coordinator.cancel()
        #expect(deletedIDs.isEmpty && !root.isDeletedLocally && !grandchild.isDeletedLocally)
        #expect(!context.hasChanges)
        #expect(try ReminderSchedulingJournal.capture(in: context).isEmpty)
        coordinator.request(root, in: context) { task, scope in
            deletedIDs = TaskDeletionPersistence.perform(task, in: context, confirmed: scope) ?? []
        }
        _ = coordinator.confirm(in: context) { task, scope in
            deletedIDs = TaskDeletionPersistence.perform(task, in: context, confirmed: scope) ?? []
        }
        #expect(Set(deletedIDs) == Set([root.id, deletedChild.id, grandchild.id]))
        #expect(deletedIDs.count == 3)
        #expect(grandchild.isDeletedLocally)
    }

    @Test("Changed descendant counts refresh confirmation before deleting")
    func changedHierarchyRequiresFreshConfirmation() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Root", in: context)
        _ = insert("Child", parent: root, in: context)
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        try context.save()
        coordinator.request(root, in: context, errorState: ErrorState()) { _, _ in effects += 1 }
        _ = insert("Another child", parent: root, in: context)
        #expect(coordinator.confirm(in: context, errorState: ErrorState()) { _, _ in effects += 1 } == .subtasksChanged)
        #expect(coordinator.subtaskCount == nil)
        #expect(effects == 0)
        try context.save()
        coordinator.request(root, in: context) { task, scope in
            _ = TaskDeletionPersistence.perform(task, in: context, confirmed: scope)
            effects += 1
        }
        #expect(coordinator.confirm(in: context) { task, scope in
            _ = TaskDeletionPersistence.perform(task, in: context, confirmed: scope)
            effects += 1
        } == .deleted)
        #expect(effects == 1 && root.isDeletedLocally)
    }

    @Test("A same-count child replacement during confirmation does not delete the stale closure")
    func sameCountReplacementRequiresFreshConfirmation() throws {
        let store = try container()
        let context = store.mainContext
        let list = TaskList(serverURL: "", name: "Work", colorHex: "#007AFF")
        let root = insert("Root", in: context)
        let child = insert("Original child", parent: root, in: context)
        let otherParent = insert("Other parent", in: context)
        root.taskList = list
        child.taskList = list
        otherParent.taskList = list
        context.insert(list)
        try context.save()
        let rootID = root.id
        let childID = child.id
        let otherParentID = otherParent.id
        var coordinator = TaskDeletionCoordinator()
        var deleteCalls = 0
        coordinator.request(root, in: context) { _, _ in deleteCalls += 1 }
        #expect(coordinator.subtaskCount == 1)

        let concurrent = ModelContext(store)
        concurrent.autosaveEnabled = false
        let moved = try #require(concurrent.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == childID })).first)
        let destination = try #require(concurrent.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == otherParentID })).first)
        let currentRoot = try #require(concurrent.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == rootID })).first)
        moved.parentTask = destination
        let replacement = insert("Replacement child", parent: currentRoot, in: concurrent)
        replacement.taskList = currentRoot.taskList
        let replacementID = replacement.id
        try concurrent.save()

        let reader = ModelContext(store)
        let savedRoot = try #require(reader.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == rootID })).first)
        #expect(TaskListHelpers.deletionSubtree(of: savedRoot).dropFirst()
            .filter { !$0.isDeletedLocally }.count == 1)
        #expect(coordinator.confirm(in: context) { _, _ in deleteCalls += 1 } == .subtasksChanged)
        #expect(deleteCalls == 0)
        let finalReader = ModelContext(store)
        let rows = try finalReader.fetch(FetchDescriptor<TaskItem>())
        #expect(rows.first { $0.id == rootID }?.isDeletedLocally == false)
        #expect(rows.first { $0.id == childID }?.isDeletedLocally == false)
        #expect(rows.first { $0.id == replacementID }?.isDeletedLocally == false)
        #expect(!context.hasChanges)
    }

    @Test("A permission revoked during row confirmation prevents deletion")
    func permissionRevokedDuringRowConfirmationRefusesDelete() throws {
        let store = try container()
        let context = store.mainContext
        let list = TaskList(serverURL: "", name: "Shared", colorHex: "#007AFF")
        let root = insert("Root", in: context)
        let child = insert("Child", parent: root, in: context)
        root.taskList = list
        child.taskList = list
        context.insert(list)
        try context.save()
        let listID = list.id
        let rootID = root.id
        let childID = child.id
        let errors = ErrorState()
        var coordinator = TaskDeletionCoordinator()
        var deleteCalls = 0
        coordinator.request(root, in: context, errorState: errors) { _, _ in deleteCalls += 1 }
        #expect(coordinator.subtaskCount == 1)

        let concurrent = ModelContext(store)
        let currentList = try #require(concurrent.fetch(
            FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first)
        currentList.isReadOnly = true
        try concurrent.save()

        #expect(coordinator.confirm(in: context, errorState: errors) { _, _ in deleteCalls += 1 } == .invalidTask)
        #expect(deleteCalls == 0)
        #expect(errors.isPresented)
        #expect(errors.currentError?.contains("read-only") == true)
        #expect(!context.hasChanges)
        let reader = ModelContext(store)
        let rows = try reader.fetch(FetchDescriptor<TaskItem>())
        #expect(rows.first { $0.id == rootID }?.isDeletedLocally == false)
        #expect(rows.first { $0.id == childID }?.isDeletedLocally == false)
        #expect(try ReminderSchedulingJournal.capture(in: reader).isEmpty)
    }

    @Test("The deletion traversal retains uninserted fixtures and ID cycle protection")
    func deletionTraversalPreservesFixtureSemantics() {
        let root = TaskItem(title: "Root", priority: .none)
        let child = TaskItem(title: "Child", priority: .none)
        root.subtasks = [child]
        child.subtasks = [root]
        let now = Date(timeIntervalSince1970: 1234)
        let deletedIDs = TaskListHelpers.markDeleted(root, now: now)
        #expect(deletedIDs == [root.id, child.id])
        #expect(root.isDeletedLocally && child.isDeletedLocally)
        #expect(root.isDirty && child.isDirty)
        #expect(root.lastModifiedDate == now && child.lastModifiedDate == now)
    }

    @Test("Confirmation may delete the root when no active descendants remain")
    func removedDescendantsAllowConfirmedRootDeletion() throws {
        let store = try container()
        let context = store.mainContext
        let root = insert("Root", in: context)
        let child = insert("Child", parent: root, in: context)
        var coordinator = TaskDeletionCoordinator()
        var effects = 0
        try context.save()
        coordinator.request(root, in: context, errorState: ErrorState()) { _, _ in effects += 1 }
        child.isDeletedLocally = true
        #expect(coordinator.confirm(in: context, errorState: ErrorState()) { _, _ in effects += 1 } == .subtasksChanged)
        #expect(effects == 0 && !root.isDeletedLocally)
        try context.save()
        coordinator.request(root, in: context) { task, scope in
            _ = TaskDeletionPersistence.perform(task, in: context, confirmed: scope)
            effects += 1
        }
        #expect(effects == 1 && root.isDeletedLocally)
    }

    @Test("Deletion traversal retains ID-based duplicate suppression")
    func duplicateIDsAreVisitedOnce() {
        let root = TaskItem(title: "Root", priority: .none)
        let first = TaskItem(title: "First", priority: .none)
        let duplicate = TaskItem(title: "Duplicate", priority: .none)
        duplicate.id = first.id
        root.subtasks = [first, duplicate]
        #expect(TaskListHelpers.markDeleted(root) == [root.id, duplicate.id])
        #expect(duplicate.isDeletedLocally)
        #expect(!first.isDeletedLocally)
    }

}
