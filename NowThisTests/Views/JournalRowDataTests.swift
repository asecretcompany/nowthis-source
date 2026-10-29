import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - JournalRowData Tests
//
// Same class of crash as `TaskRowData`: a `JournalRow` retained in the journals
// List re-evaluated its body and read `entry.title` on a model whose backing
// row had been deleted, tripping SwiftData's `BackingData` assertion. Rows now
// render from an immutable snapshot taken while the entry is still valid.

@Suite("Journal Row Data Snapshot")
struct JournalRowDataTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Snapshot of a deleted entry is nil instead of crashing")
    @MainActor
    func snapshotIsNilForDeletedEntry() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let entry = JournalEntry(title: "Doomed", content: "gone")
        context.insert(entry)
        try context.save()

        context.delete(entry)
        try context.save()

        #expect(entry.modelContext == nil)
        // Must NOT crash — previously trapped in JournalEntry.title.getter.
        #expect(JournalRowData(entry: entry) == nil)
    }

    @Test("Snapshot carries the fields the row renders")
    @MainActor
    func snapshotCarriesFields() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let entry = JournalEntry(title: "Standup", content: "notes here")
        context.insert(entry)
        let task = TaskItem(title: "Linked", priority: .none)
        context.insert(task)
        entry.associatedTasks = [task]
        try context.save()

        let snapshot = try #require(JournalRowData(entry: entry))
        #expect(snapshot.title == "Standup")
        #expect(snapshot.content == "notes here")
        #expect(snapshot.createdDate == entry.createdDate)
        #expect(snapshot.associatedTaskCount == 1)
    }
}

// MARK: - Editor Guard Signal
//
// The full-screen editors (`TaskDetailView`, `JournalEditorView`) can't render
// from a value snapshot — they hold two-way bindings into the model. They guard
// on `modelContext == nil` instead and dismiss. These tests pin the signal that
// guard depends on: an account delete cascades two levels down and invalidates
// the tasks an open editor may still be bound to.

@Suite("Editor liveness guard signal")
struct EditorLivenessGuardTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Account delete invalidates a task an open detail view is bound to")
    @MainActor
    func accountDeleteInvalidatesOpenTask() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let account = ServerAccount(
            displayName: "Acc", serverBaseURL: "https://x.test", username: "u"
        )
        let list = TaskList(serverURL: "https://x.test", name: "L", colorHex: "#FF0000")
        list.account = account
        let task = TaskItem(title: "Open in detail view", priority: .none)
        task.taskList = list
        context.insert(account)
        context.insert(list)
        context.insert(task)
        try context.save()

        #expect(task.modelContext != nil, "live before the delete")

        context.delete(account)
        try context.save()

        // This is the signal TaskDetailView's guard reads to dismiss instead of
        // rendering. If SwiftData ever stops nil-ing it, the guard silently
        // stops working and this test is the tripwire.
        #expect(task.modelContext == nil)
        #expect(list.modelContext == nil)
    }
}
