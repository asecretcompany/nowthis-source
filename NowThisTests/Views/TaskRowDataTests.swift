import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - TaskRowData Tests
//
// Regression coverage for the task-row crash: deleting an account cascades
// `ServerAccount` → `TaskList` → `TaskItem` on the **main** context, which
// invalidates every task a retained `TaskRowView` is still holding. The next
// layout pass read `task.status` and tripped SwiftData's assertion:
//
//   SwiftData/BackingData.swift:249: Fatal error: This backing data was
//   detached from a context without resolving attribute faults: … \TaskItem.status
//
// Rows now render from an immutable `TaskRowData` snapshot taken while the
// task is still valid, so no live model is dereferenced during a later pass.

@Suite("Task Row Data Snapshot")
struct TaskRowDataTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// The exact production shape: `AccountManager.removeAccount` deletes the
    /// account on the main context and the cascade reaches the tasks two levels
    /// down. Without the guard this aborts the test process with a signal kill.
    @Test("Snapshot of a task invalidated by an account-delete cascade is nil")
    @MainActor
    func snapshotIsNilAfterAccountCascade() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = ServerAccount(
            displayName: "Acc", serverBaseURL: "https://x.test", username: "u"
        )
        let list = TaskList(serverURL: "https://x.test", name: "L", colorHex: "#FF0000")
        list.account = account
        let task = TaskItem(title: "Row still on screen", priority: .high)
        task.taskList = list
        context.insert(account)
        context.insert(list)
        context.insert(task)
        try context.save()

        context.delete(account)
        try context.save()

        #expect(task.modelContext == nil, "cascade must invalidate the task")
        // Must NOT crash — previously trapped in TaskItem.status.getter.
        #expect(TaskRowData(task: task) == nil)
    }

    @Test("Snapshot of a directly deleted task is nil instead of crashing")
    @MainActor
    func snapshotIsNilForDeletedModel() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let task = TaskItem(title: "Doomed", priority: .high)
        context.insert(task)
        try context.save()

        context.delete(task)
        try context.save()

        #expect(TaskRowData(task: task) == nil)
    }

    @Test("Snapshot carries the fields the row renders")
    @MainActor
    func snapshotCarriesFields() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(title: "Ship it", priority: .high, status: .inProcess)
        task.dueDate = due
        task.descriptionText = "with notes"
        context.insert(task)

        let child = TaskItem(title: "Child", priority: .none, status: .completed)
        child.parentTask = task
        context.insert(child)
        try context.save()

        let snapshot = try #require(TaskRowData(task: task))
        #expect(snapshot.title == "Ship it")
        #expect(snapshot.status == .inProcess)
        #expect(snapshot.priority == .high)
        #expect(snapshot.dueDate == due)
        #expect(snapshot.descriptionText == "with notes")
        #expect(snapshot.directSubtaskCount == 1)
        #expect(snapshot.subtasksTotal == 1)
        #expect(snapshot.subtasksCompleted == 1)
    }

    @Test("Aggregated subtask progress counts the whole hierarchy")
    @MainActor
    func snapshotAggregatesNestedSubtasks() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let root = TaskItem(title: "Root", priority: .none)
        context.insert(root)
        let child = TaskItem(title: "Child", priority: .none, status: .completed)
        child.parentTask = root
        context.insert(child)
        let grandchild = TaskItem(title: "Grandchild", priority: .none)
        grandchild.parentTask = child
        context.insert(grandchild)
        try context.save()

        let snapshot = try #require(TaskRowData(task: root))
        #expect(snapshot.directSubtaskCount == 1, "only immediate children")
        #expect(snapshot.subtasksTotal == 2, "child + grandchild")
        #expect(snapshot.subtasksCompleted == 1)
    }

    @Test("Soft-deleted subtasks are excluded from progress")
    @MainActor
    func snapshotIgnoresSoftDeletedSubtasks() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let root = TaskItem(title: "Root", priority: .none)
        context.insert(root)
        let gone = TaskItem(title: "Gone", priority: .none, status: .completed)
        gone.parentTask = root
        gone.isDeletedLocally = true
        context.insert(gone)
        try context.save()

        let snapshot = try #require(TaskRowData(task: root))
        #expect(snapshot.subtasksTotal == 0)
        #expect(snapshot.subtasksCompleted == 0)
    }
}
