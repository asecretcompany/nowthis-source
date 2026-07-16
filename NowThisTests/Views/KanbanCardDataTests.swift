import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - KanbanCardData Tests
//
// Regression coverage for the Kanban board crash: a `KanbanCardView` that was
// still retained in the LazyVStack re-evaluated its body during a layout pass
// and read `TaskItem.priority` on a model a background sync had hard-deleted,
// tripping SwiftData's `BackingData.getValue` assertion. The board now hands
// cards an immutable `KanbanCardData` snapshot built from a live task, and the
// snapshot's failable initializer refuses to read an invalidated model.

@Suite("Kanban Card Data Snapshot")
struct KanbanCardDataTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Snapshot of a deleted task is nil instead of crashing")
    @MainActor
    func snapshotIsNilForDeletedModel() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let task = TaskItem(title: "Doomed", priority: .high)
        context.insert(task)
        try context.save()

        // Simulate the sync engine hard-deleting the row out from under the card.
        context.delete(task)
        try context.save()

        // Must NOT crash — previously trapped in TaskItem.priority.getter.
        #expect(KanbanCardData(task: task) == nil)
    }

    @Test("Snapshot of a live task carries its display fields")
    @MainActor
    func snapshotCarriesFieldsForLiveModel() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(title: "Ship it", priority: .high, status: .inProcess)
        task.dueDate = due
        context.insert(task)
        try context.save()

        let snapshot = try #require(KanbanCardData(task: task))
        #expect(snapshot.title == "Ship it")
        #expect(snapshot.status == .inProcess)
        #expect(snapshot.priority == .high)
        #expect(snapshot.dueDate == due)
    }
}
